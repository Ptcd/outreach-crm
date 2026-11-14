// 0231: a dial nobody logged does not hide the card for good. A placed call the phone record shows as not answered is
// released by the system after 12 hours; a call that connected is not guessed at, but after 12 hours it stops hiding the
// card from its list and stops blocking the next call.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, beforeEach, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATIONS = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')
const LEAD = '00000000-0000-0000-0000-0000000000d1'
const PHONE = '4145550177'
const PHONE2 = '4145550178'
const THALIA = { sub: '00000000-0000-0000-0000-00000000000a', email: 'thalia@example.com' }
const hoursAgo = (h: number) => new Date(Date.now() - h * 3600_000).toISOString()
let db: PGlite
let k = 0

const one = async <T = Record<string, unknown>>(sql: string, params: unknown[] = []) => (await db.query<T>(sql, params)).rows[0]
async function as<T>(claims: object, fn: () => Promise<T>): Promise<T> {
  await db.query(`select set_config('request.jwt.claims', $1, false)`, [JSON.stringify(claims)])
  await db.exec('set role authenticated')
  try { return await fn() } finally { await db.exec('reset role'); await db.query(`select set_config('request.jwt.claims', '', false)`) }
}
const begin = (key: string, at: string, phone = PHONE) => as(THALIA, async () => (await one<{ r: Record<string, unknown> }>(
  `select public.begin_human_call($1, $2, 'app', $3, $4::timestamptz) r`, [LEAD, phone, key, at])).r)
/** A dial that reached the phone company `hours` ago, with the phone record's verdict, and no outcome logged. */
async function placed(hours: number, status: string, seconds: number) {
  const key = `unlogged_dial_${String(++k).padStart(3, '0')}`
  const sid = `CA${String(k).padStart(32, '0')}`
  expect(await begin(key, hoursAgo(hours))).toMatchObject({ ok: true, paused: true })
  expect((await one<{ r: { allowed: boolean } }>(`select public.claim_human_call_provider($1, $2, $3, $4) r`, [LEAD, PHONE, key, sid])).r.allowed).toBe(true)
  await db.query(`insert into public.call_legs (call_sid, caller, direction, phone10, started_at, duration_s, status)
                  values ($1, 'thalia', 'out', $2, $3::timestamptz, $4, $5)`, [sid, PHONE, hoursAgo(hours), seconds, status])
  return key
}
const taken = async () => (await one<{ t: string | null; key: string | null }>(`select human_takeover_at::text t, human_takeover_key "key" from public.leads where id = $1`, [LEAD]))
const sweep = async () => (await one<{ n: number }>(`select public.sweep_unlogged_human_calls() n`)).n

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATIONS)
  await db.exec(`insert into public.team_members (email, role, person, display_name) values ('thalia@example.com', 'caller', 'thalia', 'Thalia')`)
}, 120_000)

beforeEach(async () => {
  await db.exec(`
    truncate public.human_call_provider_claims, public.call_legs, public.belt_events, public.belt_health, public.belt_alerts_sent,
      public.hot_alerts, public.tasks, public.reply_drafts, public.reply_threads, public.twilio_inbound,
      public.suppressed_phones, public.messages, public.contacts, public.leads cascade;
    insert into public.leads (id, wpie_owner_id, owner_name, property_address, municipality, mailing_state, lane, stage)
      values ('${LEAD}', 961, 'JANE UNLOGGED', '100 N MAIN ST', 'Milwaukee', 'WI', 'flip', 'opener_sent');
    insert into public.contacts (lead_id, kind, value, value_normalized, line_type)
      values ('${LEAD}', 'phone', '${PHONE}', '${PHONE}', 'mobile'), ('${LEAD}', 'phone', '${PHONE2}', '${PHONE2}', 'mobile');
  `)
})

describe('a dial nobody logged', () => {
  it('is released by the system when the phone record says nobody picked up', async () => {
    const key = await placed(13, 'no-answer', 0)
    expect(await sweep()).toBe(1)
    expect((await taken()).t).toBeNull()
    const e = await one<{ by: string; payload: { reason: string; phone_record: string } }>(
      `select by, payload from public.belt_events where lead_id = $1 and event = 'human_call_resumed'`, [LEAD])
    expect(e.by).toBe('system')
    expect(e.payload.phone_record).toBe('no-answer')
    expect(e.payload.reason).toContain('nobody picked up')
    expect(await one(`select count(*)::int n from public.belt_events where payload->>'key' = $1`, [`human_resume:${key}`])).toEqual({ n: 1 })
    expect(await sweep()).toBe(0)
  })

  it('a pickup of a few seconds (a voicemail greeting, a hang-up) counts as nobody', async () => {
    await placed(13, 'completed', 8)
    expect(await sweep()).toBe(1)
    expect((await taken()).t).toBeNull()
  })

  it('waits 12 hours: a caller still at the desk is not cut off', async () => {
    await placed(1, 'no-answer', 0)
    expect(await sweep()).toBe(0)
    expect((await taken()).t).not.toBeNull()
  })

  it('never guesses at a call that connected: the card stays paused and is listed for the morning email', async () => {
    await placed(13, 'completed', 83)
    expect(await sweep()).toBe(0)
    expect((await taken()).t).not.toBeNull()
    expect(await one(`select person::text, seconds from public.calls_never_logged where lead_id = $1`, [LEAD])).toEqual({ person: 'thalia', seconds: 83 })
  })

  it('a connected call left unlogged overnight does not block the next call; the texts it held stay held', async () => {
    const old = await placed(13, 'completed', 83)
    await db.query(`update public.leads set human_takeover_drafts = '[{"id":"00000000-0000-0000-0000-0000000000aa","status":"queued"}]'::jsonb where id = $1`, [LEAD])
    expect(await begin('unlogged_dial_next', hoursAgo(0), PHONE2)).toMatchObject({ ok: true, duplicate: false, paused: true })
    expect((await taken()).key).toBe('unlogged_dial_next')
    const e = await one<{ payload: { key: string; reason: string } }>(`select payload from public.belt_events where lead_id = $1 and event = 'human_call_abandoned'`, [LEAD])
    expect(e.payload.key).toBe(`human_abandon:${old}`)
    expect(await one(`select jsonb_array_length(human_takeover_drafts) n from public.leads where id = $1`, [LEAD])).toEqual({ n: 1 })
  })

  it('a call placed an hour ago still blocks a second call until it is logged', async () => {
    await placed(1, 'completed', 83)
    expect(await begin('unlogged_dial_soon', hoursAgo(0), PHONE2)).toMatchObject({ ok: false, reason: 'another call is waiting for its outcome' })
  })

  it('the card comes back on its caller\'s Power hour list once the unlogged dial is 12 hours old', async () => {
    const noon = '2026-11-17T18:00:00Z'      // Tuesday noon CT
    await db.query(`insert into public.tasks (lead_id, due_at, kind, owner, source, title, note) values ($1, $2::timestamptz, 'call', 'thalia', 'power_hour', 'Sheriff sale Dec 09: last call day Nov 25', 'list')`, [LEAD, noon])
    const inQueue = async () => as(THALIA, async () => {
      const q = (await one<{ r: { lead_id: string }[] }>(`select public.power_dial_queue(40, $1::timestamptz) r`, [noon])).r
      return q.some((c) => c.lead_id === LEAD)
    })
    expect(await inQueue()).toBe(true)
    await db.query(`update public.leads set human_takeover_at = $2::timestamptz - interval '1 hour', human_takeover_by = 'Thalia', human_takeover_key = 'unlogged_dial_q', human_takeover_phone = $3 where id = $1`, [LEAD, noon, PHONE])
    expect(await inQueue()).toBe(false)      // a call under way, or just made: not offered again
    await db.query(`update public.leads set human_takeover_at = $2::timestamptz - interval '13 hours' where id = $1`, [LEAD, noon])
    expect(await inQueue()).toBe(true)
  })
})
