// 0315: a seller who writes back interested gets a call task that day; one nobody has called in 24 hours is named for
// Colin; a seller who was reached, said no afterwards, is parked or was passed on by Colin is not chased.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')
const NOW = '2026-11-24T21:00:00Z'       // Tuesday 3 PM Central

let db: PGlite
const rows = async <T>(sql: string, params: unknown[] = []) => (await db.query<T>(sql, params)).rows
const one = async <T>(sql: string, params: unknown[] = []) => (await rows<{ r: T }>(`select ${sql} as r`, params))[0].r
let n = 500
const card = async (name: string, who: 'thalia' | 'adil' = 'thalia') => {
  n += 1
  const id = (await rows<{ id: string }>(
    `insert into public.leads (wpie_owner_id, owner_name, lane, stage, property_address, locked_to, mailing_state)
     values ($1, $2, 'flip', 'follow_up', $3, $4::public.team_person, 'WI') returning id`, [n, name, `${n} Test St`, who]))[0].id
  await db.query(`insert into public.contacts (lead_id, kind, value, value_normalized, line_type) values ($1, 'phone', $2, $2, 'mobile')`, [id, `414555${n}0`])
  return id
}
const reply = (lead: string, intent: string, hoursAgo: number, body = 'Yes') =>
  db.query(`insert into public.reply_drafts (phone10, lead_id, inbound_body, inbound_at, intent, kind, status)
            values ('4145550000', $1, $2, $3::timestamptz - make_interval(hours => $4), $5, 'candidate', 'no_reply')`,
    [lead, body, NOW, hoursAgo, intent])
const called = (lead: string, status: string, hoursAgo: number) =>
  db.query(`insert into public.messages (lead_id, channel, direction, status, body, sent_at) values ($1, 'call', 'in', $2, 'Call', $3::timestamptz - make_interval(hours => $4))`,
    [lead, status, NOW, hoursAgo])
const warmIds = async () => (await rows<{ lead_id: string }>(`select lead_id from public.warm_sellers($1::timestamptz)`, [NOW])).map((r) => r.lead_id)
const C: Record<string, string> = {}

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
  await db.exec(`insert into public.team_members (email, role, person, display_name) values
    ('colin@example.com', 'owner', 'colin', 'Colin'), ('thalia@example.com', 'caller', 'thalia', 'Thalia'), ('adil@example.com', 'caller', 'adil', 'Tyler') on conflict do nothing`)
  await db.exec(`delete from public.caller_off_weekly`)
  C.fresh = await card('FRESH FRAN'); await reply(C.fresh, 'interested', 2, 'Yes I would sell')
  C.stale = await card('STALE STAN', 'adil'); await reply(C.stale, 'price_first', 50, 'What is your offer')
  C.reached = await card('REACHED RITA'); await reply(C.reached, 'interested', 30); await called(C.reached, 'reached_no_decision', 20)
  C.rangOut = await card('NO ANSWER NED'); await reply(C.rangOut, 'interested', 60); await called(C.rangOut, 'no_answer', 30)
  C.saidNo = await card('NOPE NORA'); await reply(C.saidNo, 'interested', 40); await reply(C.saidNo, 'not_interested', 10, 'Nope')
  C.parked = await card('PARKED PAT'); await reply(C.parked, 'interested', 40); await db.query(`update public.leads set parked_at = now() where id = $1`, [C.parked])
  C.passed = await card('PASSED PAUL'); await reply(C.passed, 'number_only', 40, '850000')
  await db.query(`insert into public.deal_sheets (lead_id, colin_pass) values ($1, true)`, [C.passed])
  C.cold = await card('COLD CARL'); await reply(C.cold, 'statement', 5, 'ok')
})

describe('who counts as a warm seller still waiting', () => {
  it('takes the ones who wrote back warm and were not reached, and leaves the rest', async () => {
    const ids = await warmIds()
    expect(ids).toEqual(expect.arrayContaining([C.fresh, C.stale, C.rangOut]))
    for (const k of ['reached', 'saidNo', 'parked', 'passed', 'cold']) expect(ids).not.toContain(C[k])
  })
})

describe('the tick', () => {
  it('gives each one a call task for the card\'s caller, once a day, with what they said', async () => {
    await db.query(`delete from public.tasks`)          // whatever the reply itself queued: the tick has to stand on its own
    const r = await one<{ tasks_made: number }>(`public.warm_sellers_tick($1::timestamptz)`, [NOW])
    expect(r.tasks_made).toBe(3)
    const t = (await rows<{ owner: string; source: string; title: string; note: string }>(`select owner::text, source, title, note from public.tasks where lead_id = $1 and source_key like 'warm:%'`, [C.stale]))[0]
    expect(t).toMatchObject({ owner: 'adil', source: 'call_next', title: 'Wrote back interested: call today' })
    expect(t.note).toContain('What is your offer')
    expect((await one<{ tasks_made: number }>(`public.warm_sellers_tick($1::timestamptz)`, [NOW])).tasks_made).toBe(0)
  })
  it('does not make a task on the caller\'s day off, or once someone is reached', async () => {
    const off = await card('OFF DAY OLA', 'adil'); await reply(off, 'interested', 3)
    await db.query(`delete from public.tasks where lead_id = $1`, [off])
    await db.query(`insert into public.caller_off (person, day) values ('adil', '2026-11-24')`)
    await one(`public.warm_sellers_tick($1::timestamptz)`, [NOW])
    expect(await rows(`select 1 from public.tasks where lead_id = $1 and source_key like 'warm:%'`, [off])).toHaveLength(0)
    await called(C.fresh, 'interested', 1)
    expect(await warmIds()).not.toContain(C.fresh)
  })
})

describe('what Colin is told', () => {
  it('names the ones nobody called in 24 hours, by caller, and keeps a score per caller', async () => {
    const o = await one<{ never_called: number; by_caller: Record<string, number>; who: { owner: string; caller: string }[] }>(`public.warm_sellers_open($1::timestamptz)`, [NOW])
    expect(o.never_called).toBe(1)                       // STALE STAN: 50 hours, no dial. FRESH is 2 hours old; NED was dialed.
    expect(o.by_caller).toEqual({ adil: 1 })
    expect(o.who[0]).toMatchObject({ owner: 'STALE STAN', caller: 'adil' })
    const s = await one<Record<string, { warm: number; reached: number; never_called: number }>>(`public.warm_scorecard(14, $1::timestamptz)`, [NOW])
    expect(s.thalia.reached).toBeGreaterThanOrEqual(2)   // RITA and FRAN
    expect(s.adil.never_called).toBeGreaterThanOrEqual(1)
  })
})
