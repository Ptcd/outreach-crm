import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, beforeEach, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATIONS = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')
const LEAD = '00000000-0000-0000-0000-0000000000f1'
const OTHER = '00000000-0000-0000-0000-0000000000f2'
const NOW = '2026-10-23T16:00:00Z'
const THALIA = { sub: '00000000-0000-0000-0000-00000000000a', email: 'thalia@example.com' }
const SID1 = `CA${'1'.repeat(32)}`
const SID2 = `CA${'2'.repeat(32)}`
let db: PGlite

const one = async <T = Record<string, unknown>>(sql: string, params: unknown[] = []) => (await db.query<T>(sql, params)).rows[0]
async function as<T>(claims: object, fn: () => Promise<T>): Promise<T> {
  await db.query(`select set_config('request.jwt.claims', $1, false)`, [JSON.stringify(claims)])
  await db.exec('set role authenticated')
  try { return await fn() } finally { await db.exec('reset role'); await db.query(`select set_config('request.jwt.claims', '', false)`) }
}
const begin = (key = 'provider_gate_001') => as(THALIA, async () => (await one<{ r: Record<string, unknown> }>(
  `select public.begin_human_call($1, '4145550177', 'app', $2, $3::timestamptz) r`, [LEAD, key, NOW])).r)
const claim = async (key = 'provider_gate_001', sid = SID1, lead = LEAD, phone = '4145550177') =>
  (await one<{ r: Record<string, unknown> }>(
    `select public.claim_human_call_provider($1, $2, $3, $4) r`, [lead, phone, key, sid])).r

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATIONS)
  await db.exec(`insert into public.team_members (email, role, person, display_name)
    values ('thalia@example.com', 'caller', 'thalia', 'Thalia')`)
})

beforeEach(async () => {
  await db.exec(`
    truncate public.human_call_provider_claims, public.belt_events, public.belt_health, public.belt_alerts_sent,
      public.hot_alerts, public.tasks, public.reply_drafts, public.reply_threads, public.twilio_inbound,
      public.suppressed_phones, public.messages, public.contacts, public.leads cascade;
    insert into public.leads (id, wpie_owner_id, owner_name, property_address, municipality, mailing_state, lane, stage)
      values ('${LEAD}', 951, 'JANE PROVIDER', '100 N MAIN ST', 'Milwaukee', 'WI', 'flip', 'opener_sent'),
             ('${OTHER}', 952, 'JOHN OTHER', '200 N MAIN ST', 'Milwaukee', 'WI', 'flip', 'opener_sent');
    insert into public.contacts (lead_id, kind, value, value_normalized, line_type)
      values ('${LEAD}', 'phone', '4145550177', '4145550177', 'mobile'),
             ('${OTHER}', 'phone', '4145550188', '4145550188', 'mobile');
  `)
})

describe('provider-side human-call authorization', () => {
  it('claims one active attempt and makes an exact Twilio webhook retry idempotent', async () => {
    expect(await begin()).toMatchObject({ ok: true, paused: true })
    expect(await claim()).toEqual({ allowed: true, duplicate: false })
    expect(await claim()).toEqual({ allowed: true, duplicate: true })
    expect(await claim('provider_gate_001', SID2)).toMatchObject({ allowed: false, reason: 'that call authorization was already claimed' })
    expect(await one<{ n: number }>(`select count(*)::int n from public.human_call_provider_claims`)).toEqual({ n: 1 })
  })

  it('serializes simultaneous provider claims for one active attempt', async () => {
    await begin()
    const same = await Promise.all([1, 2].map(() => claim()))
    expect(same).toEqual(expect.arrayContaining([
      { allowed: true, duplicate: false }, { allowed: true, duplicate: true },
    ]))
    expect(await one<{ n: number }>(`select count(*)::int n from public.human_call_provider_claims`)).toEqual({ n: 1 })
  })

  it('requires the live lead, exact key and exact destination', async () => {
    await begin()
    expect(await claim('wrong_key_002')).toMatchObject({ allowed: false, reason: 'that is not the active call' })
    expect(await claim('provider_gate_001', SID1, OTHER, '4145550177')).toMatchObject({ allowed: false, reason: 'call authorization is not active' })
    expect(await claim('provider_gate_001', SID1, LEAD, '4145550188')).toMatchObject({ allowed: false, reason: 'the active call has a different destination' })
    expect(await claim('provider_gate_001', SID1, LEAD, '4145550199')).toMatchObject({ allowed: false, reason: 'the active call has a different destination' })
    expect(await claim('provider_gate_001', 'not-a-call-sid')).toMatchObject({ allowed: false, reason: 'bad provider call id' })
  })

  it('rechecks STOP/DNC and suppression after the browser was authorized', async () => {
    await begin('stop_after_begin_001')
    await one(`select public.belt_event($1, 'stop', '{"key":"stop:provider"}'::jsonb, 'test', $2::timestamptz)`, [LEAD, NOW])
    expect(await claim('stop_after_begin_001')).toMatchObject({ allowed: false, reason: 'this card is closed or do-not-contact' })

    await db.query(`update public.leads set stage = 'opener_sent', belt = null where id = $1`, [LEAD])
    await begin('blocked_after_begin_002')
    await db.exec(`insert into public.suppressed_phones (phone10, reason, source) values ('4145550177', 'stop_reply', 'test')`)
    expect(await claim('blocked_after_begin_002', SID2)).toMatchObject({ allowed: false, reason: 'suppressed: stop_reply' })
  })

  it('rejects a closed pause, logged outcome and reassignment without changing the conveyor', async () => {
    await begin('resume_before_provider_001')
    await as(THALIA, () => db.query(`select public.resume_human_call($1, 'resume_before_provider_001', $2::timestamptz)`, [LEAD, NOW]))
    expect(await claim('resume_before_provider_001')).toMatchObject({ allowed: false, reason: 'call authorization is not active' })

    await begin('outcome_before_provider_002')
    await as(THALIA, () => db.query(`select public.log_call($1, '4145550177', 'no_answer', 'rang out', null)`, [LEAD]))
    expect(await claim('outcome_before_provider_002', SID2)).toMatchObject({ allowed: false, reason: 'call authorization is not active' })

    await begin('reassigned_before_provider_003')
    await db.query(`update public.leads set assigned_to = 'adil' where id = $1`, [LEAD])
    expect(await claim('reassigned_before_provider_003', `CA${'3'.repeat(32)}`)).toMatchObject({
      allowed: false, reason: 'the card assignment changed after authorization',
    })
  })

  it('cannot reuse one provider call id for a different active attempt', async () => {
    await begin('first_provider_attempt_001')
    expect(await claim('first_provider_attempt_001', SID1)).toMatchObject({ allowed: true })
    await as(THALIA, () => db.query(`select public.resume_human_call($1, 'first_provider_attempt_001', $2::timestamptz)`, [LEAD, NOW]))
    await begin('second_provider_attempt_002')
    expect(await claim('second_provider_attempt_002', SID1)).toMatchObject({
      allowed: false, reason: 'that provider call already claimed another authorization',
    })
  })

  it('is a service-only gate; a signed-in browser cannot call it or read its claims', async () => {
    await expect(as(THALIA, () => db.query(
      `select public.claim_human_call_provider($1, '4145550177', 'provider_gate_001', $2)`, [LEAD, SID1],
    ))).rejects.toThrow(/permission denied/i)
    await expect(as(THALIA, () => db.query(`select * from public.human_call_provider_claims`))).rejects.toThrow(/permission denied/i)
  })
})
