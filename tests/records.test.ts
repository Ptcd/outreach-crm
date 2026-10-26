// Records requests through the agent door (Colin 2026-10-26: "Muse drafts and tracks, but I approve each batch before it
// sends"): the agent drafts and proposes; nothing is claimable for sending until Colin approves; a dropped letter
// stays home; the send result and the Message-ID come back; a clerk's reply matches its request.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')
const COLIN = { sub: '00000000-0000-0000-0000-00000000000c', email: 'colin@example.com' }
let db: PGlite
const r = async (sql: string, params: unknown[] = []) => (await db.query<{ r: Record<string, unknown> }>(`select ${sql} as r`, params)).rows[0].r
const asColin = async <T>(fn: () => Promise<T>) => {
  await db.query(`select set_config('request.jwt.claims', $1, false)`, [JSON.stringify(COLIN)])
  await db.exec('set role authenticated')
  try { return await fn() } finally { await db.exec('reset role'); await db.query(`select set_config('request.jwt.claims', '', false)`) }
}

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
  await db.exec(`insert into public.team_members (email, role, person, display_name) values ('colin@example.com', 'owner', 'colin', 'Colin')`)
})

describe('records requests', () => {
  it('draft, propose, approve, send, reply: nothing sends without Colin', async () => {
    const a = (await db.query<{ id: string }>(`select public.records_upsert_request($1::jsonb) as id`,
      [JSON.stringify({ kind: 'municipal', name: 'City of Testville', county: 'Test', to_email: 'clerk@testville.gov', status: 'draft' })])).rows[0].id
    const b = (await db.query<{ id: string }>(`select public.records_upsert_request($1::jsonb) as id`,
      [JSON.stringify({ kind: 'rod', name: 'Test', county: 'Test', to_email: 'rod@co.test.wi.us', status: 'sent', sent_date: '2026-09-01' })])).rows[0].id
    expect(await db.query(`select public.records_upsert_request($1::jsonb) as id`, [JSON.stringify({ kind: 'rod', name: 'Test', to_email: 'x@y.z' })]))
      .toMatchObject({ rows: [{ id: null }] })                           // an existing row is never overwritten
    const due = (await r(`public.records_list('due', 50)`)) as unknown as { name: string; why_due: string }[]
    expect(due.map((x) => [x.name, x.why_due])).toEqual([['City of Testville', 'never sent'], ['Test', 'no answer since Sep 01: follow-up #1']])
    expect((await r(`public.records_templates()`)).municipal).toMatch(/Wis\. Stat\. 19\.31/)
    const letter = 'To the Records Custodian, City of Testville: under Wis. Stat. 19.31 I request code enforcement records; fees over $25, please send an estimate.'
    const d1 = await r(`public.records_save_draft($1, 'request', 'clerk@testville.gov', null, 'Public records request (City of Testville)', $2, null, 'Muse records')`, [a, letter])
    const d2 = await r(`public.records_save_draft($1, 'follow_up', 'rod@co.test.wi.us', null, 'Re: Public records request - lis pendens', $2, '<m1@x>', 'Muse records')`,
      [b, 'Hello, I am following up on my records request from September 1. Could you let me know the status or an expected date? Thank you.'])
    expect(d1).toMatchObject({ ok: true }); expect(d2).toMatchObject({ ok: true })
    expect(await r(`public.records_save_draft($1, 'request', 'clerk@testville.gov', null, 'Hi there friend', 'We buy houses for cash in your town, any leads? Please send me anything you have.', null, 'm')`, [a]))
      .toMatchObject({ ok: false })
    const batch = await r(`public.records_propose_batch(array[$1, $2]::uuid[], 'first letters', 'Muse records')`, [d1.draft_id, d2.draft_id])
    expect(batch).toMatchObject({ ok: true, letters: 2 })
    expect(await r(`public.records_claim_approved()`)).toEqual([])        // proposed is not approved
    await expect(db.query(`select public.records_decide_batch($1, true)`, [batch.batch_id])).rejects.toThrow(/only Colin/)
    const waiting = await asColin(() => r(`public.records_batches_waiting()`)) as unknown as { letters: unknown[] }[]
    expect(waiting[0].letters).toHaveLength(2)
    expect(await asColin(() => r(`public.records_decide_batch($1, true, array[$2]::uuid[])`, [batch.batch_id, d2.draft_id]))).toMatchObject({ ok: true, approved_letters: 1 })
    const claimed = (await r(`public.records_claim_approved()`)) as unknown as { draft_id: string; to: string }[]
    expect(claimed.map((x) => x.to)).toEqual(['clerk@testville.gov'])
    expect(await r(`public.records_sent($1, true, '<sent1@gmail.com>', null)`, [claimed[0].draft_id])).toMatchObject({ ok: true })
    expect((await db.query(`select status, message_id, sent_date is not null as dated from public.records_requests where id = $1`, [a])).rows[0])
      .toEqual({ status: 'sent', message_id: '<sent1@gmail.com>', dated: true })
    expect((await db.query(`select status from public.records_batches where id = $1`, [batch.batch_id])).rows[0]).toEqual({ status: 'sent' })
    expect(await r(`public.records_add_reply($1::jsonb)`, [JSON.stringify({ message_id: '<rep1@testville.gov>', in_reply_to: '<sent1@gmail.com>',
      from: 'someone.else@testville.gov', subject: 'RE: Public records request', received_at: '2026-10-27T15:00:00Z', body: 'Attached is the export.' })]))
      .toEqual({ ok: true, matched: true })
    const reps = (await r(`public.records_replies_list(true, 10)`)) as unknown as { reply_id: string; request: string }[]
    expect(reps[0].request).toBe('City of Testville')
    expect(await r(`public.records_mark($1, 'received', 'xlsx export', '2026-10-27', 'October 26, 2026', null, null, $2, 'Muse records')`, [a, reps[0].reply_id]))
      .toMatchObject({ ok: true, request: { status: 'received', next_due: '2027-01-25' } })
    expect((await r(`public.records_replies_list(true, 10)`)) as unknown as unknown[]).toEqual([])
  })

  it('four more offices, categories and a cadence per request, a follow-up every 14 days without end', async () => {
    const t = await r(`public.records_templates()`)
    for (const k of ['municipal', 'rod', 'treasurer', 'clerk_of_court', 'sheriff', 'police']) {
      expect(t[k]).toMatch(/Wis\. Stat\. 19\.31/)
      expect(t[k]).not.toMatch(/\b(cash|investors?|buy|buying)\b/i)
    }
    expect(t.categories).toEqual(expect.arrayContaining(['lis_pendens', 'federal_tax_liens', 'water_shutoffs', 'arrest_logs', 'sheriff_sales']))
    const made = await r(`public.records_set_request($1::jsonb, 'Muse')`, [JSON.stringify({ kind: 'treasurer', name: 'Test County Treasurer', county: 'Test',
      to_email: 'treasurer@co.test.wi.us', categories: ['tax_delinquency', 'certificates_of_sale'], cadence_days: 30 })])
    expect(made).toMatchObject({ ok: true, created: true })
    expect(await r(`public.records_set_request($1::jsonb, 'Muse')`, [JSON.stringify({ kind: 'treasurer', name: 'Test County Treasurer' })]))
      .toMatchObject({ ok: false, reason: expect.stringContaining('already') })
    expect(await r(`public.records_set_request($1::jsonb, 'Muse')`, [JSON.stringify({ kind: 'notary', name: 'X' })])).toMatchObject({ ok: false })
    expect(await r(`public.records_set_request($1::jsonb, 'Muse')`, [JSON.stringify({ request_id: made.request_id, categories: ['tax_delinquency'], note: 'narrowed' })]))
      .toMatchObject({ ok: true, updated: true })
    const id = made.request_id as string
    const why = async () => ((await r(`public.records_list('all', 500)`)) as unknown as { request_id: string; why_due: string | null; follow_up_count: number; categories: string[]; cadence_days: number }[])
      .find((x) => x.request_id === id)!
    expect(await why()).toMatchObject({ why_due: 'never sent', categories: ['tax_delinquency'], cadence_days: 30 })
    // asked 15 days ago and followed up 6 times already: still due, as follow-up #7
    await db.query(`update public.records_requests set status = 'sent', sent_date = current_date - 120, last_asked = current_date - 15, follow_up_count = 6 where id = $1`, [id])
    expect((await why()).why_due).toMatch(/follow-up #7$/)
    await db.query(`update public.records_requests set last_asked = current_date - 3 where id = $1`, [id])
    expect((await why()).why_due).toBeNull()
    // no records: the next ask comes after the request's own cadence, and the count starts over
    expect(await r(`public.records_mark($1, 'no_records', 'none this month', '2026-09-01', null, null, null, null, 'Muse')`, [id]))
      .toMatchObject({ ok: true, request: { status: 'no_records', next_due: '2026-10-01', follow_up_count: 0 } })
    expect((await why()).why_due).toBe('re-request: the cadence came round')
    // a fee quote goes to Colin
    await db.query(`update public.records_requests set status = 'needs_payment' where id = $1`, [id])
    expect(((await r(`public.records_list('for_colin', 50)`)) as unknown as { request_id: string }[]).map((x) => x.request_id)).toContain(id)
    expect(await r(`public.records_overview()`)).toMatchObject({ for_colin: 1 })
  })

  it('the records key role exists', async () => {
    const k = await asColin(async () => (await db.query<{ k: string }>(`select public.create_agent_key('Muse records', 'records') as k`)).rows[0].k)
    expect(k).toMatch(/^wpie_records_/)
    expect(await r(`public.agent_key_check($1)`, [k])).toMatchObject({ ok: true, role: 'records' })
  })
})
