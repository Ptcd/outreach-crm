// 0323: a seller who called, talked to the assistant and was promised a call back comes up in Power hour when that
// call is due, even though they have texted us before or were dialed this week. Until 2026-11-25 the assistant's task
// ("voice_agent") was held to the cold-list rules, and those leave out anyone who ever wrote back.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATIONS = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')
const NOON = '2026-11-17T18:00:00Z'      // Tuesday noon CT
const ADIL = { sub: '00000000-0000-0000-0000-00000000000b', email: 'adil@example.com' }
let db: PGlite
const one = async <T = Record<string, unknown>>(sql: string, params: unknown[] = []) => (await db.query<T>(sql, params)).rows[0]
async function as<T>(claims: object, fn: () => Promise<T>): Promise<T> {
  await db.query(`select set_config('request.jwt.claims', $1, false)`, [JSON.stringify(claims)])
  await db.exec('set role authenticated')
  try { return await fn() } finally { await db.exec('reset role'); await db.query(`select set_config('request.jwt.claims', '', false)`) }
}
type Row = { lead_id: string; source: string }
const queue = () => as(ADIL, async () => (await one<{ r: Row[] }>(`select public.power_dial_queue(100, $1::timestamptz) r`, [NOON])).r)

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATIONS)
  await db.exec(`insert into public.team_members (email, role, person, display_name) values ('adil@example.com', 'caller', 'adil', 'Tyler')`)
}, 120_000)

describe('the assistant promised a call back', () => {
  it('the card is in its caller\'s Power hour when the call is due, though the seller has texted before and was dialed yesterday', async () => {
    const id = (await one<{ id: string }>(
      `insert into public.leads (wpie_owner_id, owner_name, lane, stage, property_address, municipality, mailing_state, locked_to, assigned_to)
       values (-801, 'PAT CALLER', 'flip', 'reply_received', '801 Oak St', 'Green Bay', 'WI', 'adil', 'adil') returning id`)).id
    await db.query(`insert into public.contacts (lead_id, kind, value, value_normalized, line_type) values ($1, 'phone', '4145550801', '4145550801', 'mobile')`, [id])
    // they wrote back last week, and Tyler dialed them yesterday
    await db.query(`insert into public.messages (lead_id, direction, channel, body, from_number, sent_at) values ($1, 'in', 'sms', 'Who is this?', '+14145550801', $2::timestamptz - interval '6 days')`, [id, NOON])
    await db.query(`insert into public.messages (lead_id, direction, channel, body, from_number, sent_at, status) values ($1, 'in', 'call', 'Call (Tyler): No answer', '+14145550801', $2::timestamptz - interval '1 day', 'no_answer')`, [id, NOON])
    await db.query(`insert into public.tasks (lead_id, due_at, kind, owner, source, source_key, title, note, phone10)
      values ($1, $2::timestamptz - interval '10 minutes', 'call', 'adil', 'voice_agent', $3, 'Call back: they talked to the assistant', 'They spoke with the assistant (lane 1).', '4145550801')`, [id, NOON, `voice:${id}`])
    const q = await queue()
    expect(q.map((x) => x.lead_id)).toContain(id)
  })
})
