// The bulk hand-off (0224): one agent deposits a set of verified rows once, another pulls and loads them in batches,
// the server writes each row's result, and the desk carries one report with counts, never rows. On the real
// migrations, with the acceptance test from the ask: 500 rows end to end with no desk post carrying row data.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')

let db: PGlite
const rows = async <T>(sql: string, params: unknown[] = []) => (await db.query<T>(sql, params)).rows
const one = async <T>(sql: string, params: unknown[] = []) => (await rows<{ r: T }>(`select ${sql} as r`, params))[0].r

type Counts = { rows: number; waiting: number; claimed: number; created: number; stacked: number; rejected: number }
type Dep = { ok: boolean; reason?: string; batch_id: string; status: string; added: number; updated: number; refused: { key: string; reason: string }[]; counts: Counts }
type Pull = { ok: boolean; reason?: string; batch_id: string; instructions: string; rows: { row_id: string; n: number; key: string; prospect: { address: string } }[]; counts: Counts }
type Load = { ok: boolean; reason?: string; loaded: number; created: number; stacked: number; rejected: number; errors: number; batch_done: boolean; counts: Counts
  results: { row_id: string; key: string; outcome: string; lead_id: string | null; reason: string | null }[] }
const deposit = (p: object, who = 'Muse') => one<Dep>(`public.agent_handoff_deposit($1::jsonb, $2)`, [JSON.stringify(p), who])
const pull = (batch: string | null, limit: number, who = 'Muse 2') => one<Pull>(`public.agent_handoff_pull($1, $2, $3)`, [batch, limit, who])
const load = (batch: string, limit: number, ids: string[] | null = null, who = 'Muse 2') =>
  one<Load>(`public.agent_handoff_load($1, $2::uuid[], $3, $4)`, [batch, ids, limit, who])
const row = (i: number, x: Record<string, unknown> = {}) => ({ key: `ev-${i}`, caller: i % 2 ? 'thalia' : 'tyler', note: `row ${i}`,
  prospect: { owner_name: `OWNER ${i}`, address: `${1000 + i} Handoff Ave`, city: 'Milwaukee', county: 'Milwaukee', zip: '53215',
    reasons: [{ kind: 'eviction', label: 'Filed an eviction', detail: `case 2026SC00${i}` }], notes: `verified row ${i}`, ...x } })

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
  await db.exec(`insert into public.team_members (email, role, person, display_name) values
    ('colin@example.com', 'owner', 'colin', 'Colin'), ('thalia@example.com', 'caller', 'thalia', 'Thalia'), ('adil@example.com', 'caller', 'adil', 'Tyler')
    on conflict do nothing`)
}, 120_000)

describe('a small batch', () => {
  let batch: string
  it('deposits in two calls; a bad row is refused with its reason and the same key replaces a waiting row', async () => {
    const a = await deposit({ title: 'Evictions, verified', instructions: 'No texting by the loader.', rows: [row(1), row(2), { key: 'bad', prospect: { owner_name: 'X' } }, { prospect: row(9).prospect }] })
    expect(a).toMatchObject({ ok: true, status: 'open', added: 2 })
    expect(a.refused.map((r) => r.reason)).toEqual(['the prospect has no address', 'no key (your own id for the row)'])
    batch = a.batch_id
    expect(batch).toMatch(/^H-\d+$/)
    const b = await deposit({ batch_id: batch, rows: [row(2, { notes: 'corrected' }), row(3)] })
    expect(b).toMatchObject({ ok: true, added: 1, updated: 1 })
    expect(b.counts).toMatchObject({ rows: 3, waiting: 3 })
  })
  it('only the depositor adds to it, and nobody loads it before it is final', async () => {
    expect((await deposit({ batch_id: batch, rows: [row(4)] }, 'Muse 2')).reason).toContain('deposited by Muse')
    expect((await pull(batch, 50)).reason).toContain('still being deposited')
    expect((await load(batch, 50)).reason).toContain('open')
    expect((await deposit({ batch_id: batch, final: true })).status).toBe('ready')
    expect((await deposit({ batch_id: batch, rows: [row(5)] })).reason).toContain('takes no more rows')
  })
  it('the loader pulls rows with the instructions, and a second loader gets the rest', async () => {
    const p = await pull(null, 2)
    expect(p).toMatchObject({ ok: true, batch_id: batch, instructions: 'No texting by the loader.' })
    expect(p.rows.map((r) => r.key)).toEqual(['ev-1', 'ev-2'])
    expect((await pull(batch, 2)).rows.map((r) => r.key)).toEqual(['ev-1', 'ev-2'])       // the same two, still held
    expect((await pull(batch, 5, 'Other')).rows.map((r) => r.key)).toEqual(['ev-3'])
    await db.query(`update public.handoff_rows set claimed_at = now() - interval '3 hours' where key = 'ev-3'`)
    await pull(batch, 2)                                                                  // a lapsed claim goes back in line
    expect(await one<string>(`(select status from public.handoff_rows where key = 'ev-3')`)).toBe('waiting')
  })
  it('loads through the duplicate guard: a new card goes to the row\'s caller, a property we have is stacked', async () => {
    await db.query(`select public.agent_add_prospect($1::jsonb, 'Muse')`, [JSON.stringify({ owner_name: 'SOMEONE ELSE', address: '1003 Handoff Ave', city: 'Milwaukee', county: 'Milwaukee' })])
    const l = await load(batch, 50)
    expect(l).toMatchObject({ ok: true, loaded: 2, created: 2, stacked: 0, batch_done: false })
    const cards = await rows<{ owner_name: string; locked_to: string }>(
      `select l.owner_name, l.locked_to::text from public.handoff_rows r join public.leads l on l.id = r.lead_id where r.key in ('ev-1', 'ev-2') order by r.n`)
    expect(cards).toEqual([{ owner_name: 'OWNER 1', locked_to: 'thalia' }, { owner_name: 'OWNER 2', locked_to: 'adil' }])
    const l2 = await load(batch, 50)
    expect(l2).toMatchObject({ loaded: 1, created: 0, stacked: 1, batch_done: true })
    expect(l2.results[0].reason).toContain('already had this property')
    expect(await one<number>(`(select count(*)::int from public.leads where property_address ilike '1003 Handoff Ave')`)).toBe(1)
  })
  it('one report on the desk with counts, and the rows stay readable by batch', async () => {
    const posts = await rows<{ topic: string; body: string }>(`select topic, body from public.desk_messages where topic like 'HAND-OFF DONE%'`)
    expect(posts.length).toBe(1)
    expect(posts[0].body).toContain('New cards: 2. Stacked onto a card we already had: 1. Rejected: 0.')
    expect(posts[0].body).not.toContain('Handoff Ave')
    const b = await one<{ status: string; counts: Counts; rows: { key: string; status: string; lead_id: string }[] }>(
      `public.agent_handoff_batches($1::jsonb, 'Muse')`, [JSON.stringify({ batch_id: batch, rows: true })])
    expect(b.status).toBe('done')
    expect(b.rows.map((r) => [r.key, r.status])).toEqual([['ev-1', 'created'], ['ev-2', 'created'], ['ev-3', 'stacked']])
    expect(b.rows.every((r) => !!r.lead_id)).toBe(true)
    expect((await load(batch, 50)).reason).toContain('done')
  })
  it('a row the loader refuses finishes the batch with its reason', async () => {
    const a = await deposit({ title: 'Two rows', rows: [row(21), row(22)], final: true })
    const p = await pull(a.batch_id, 10)
    const r = await one<{ ok: boolean; batch_done: boolean }>(`public.agent_handoff_reject($1, 'tenant, not the owner', 'Muse 2')`, [p.rows[0].row_id])
    expect(r).toMatchObject({ ok: true, batch_done: false })
    expect((await load(a.batch_id, 10)).batch_done).toBe(true)
    const b = await one<{ why_rejected: Record<string, number> }>(`public.agent_handoff_batches($1::jsonb, 'Muse')`, [JSON.stringify({ batch_id: a.batch_id })])
    expect(b.why_rejected).toEqual({ 'tenant, not the owner': 1 })
  })
})

describe('the acceptance test', () => {
  it('500 rows move end to end, 100 at a time, with no desk post carrying row data', async () => {
    const before = await one<number>(`(select count(*)::int from public.desk_messages)`)
    const all = Array.from({ length: 500 }, (_, i) => row(5000 + i))
    let batch = ''
    for (let i = 0; i < 500; i += 250) {
      const d = await deposit({ ...(batch ? { batch_id: batch } : { title: '500 verified rows', instructions: 'Load all.' }), rows: all.slice(i, i + 250), final: i + 250 >= 500 })
      expect(d.ok).toBe(true)
      batch = d.batch_id
    }
    let done = false; let calls = 0; let created = 0
    while (!done && calls < 10) {
      const l = await load(batch, 100)
      expect(l.ok).toBe(true)
      expect(l.errors).toBe(0)
      created += l.created; done = l.batch_done; calls += 1
    }
    expect({ done, calls, created }).toEqual({ done: true, calls: 5, created: 500 })
    const c = await one<Counts>(`public.handoff_counts((select id from public.handoff_batches where code = $1))`, [batch])
    expect(c).toMatchObject({ rows: 500, created: 500, waiting: 0, claimed: 0 })
    const posts = await rows<{ body: string }>(`select body from public.desk_messages order by id desc limit $1`, [(await one<number>(`(select count(*)::int from public.desk_messages)`)) - before])
    expect(posts.length).toBe(1)
    expect(posts[0].body).toContain('500 rows')
    expect(posts[0].body).not.toMatch(/Handoff Ave|OWNER \d/)
    expect(await one<number>(`(select count(*)::int from public.leads where property_address ilike '%Handoff Ave' and owner_name like 'OWNER 5%')`)).toBe(500)
  }, 240_000)
})
