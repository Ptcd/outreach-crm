// Migration 0043: an in-app call that never reached the phone company (no provider claim) un-pauses its
// card - at once from the browser, or by the minute sweep for a closed page. A claimed call and a
// personal-phone call are never released.
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


const release = (key = 'provider_gate_001') => as(THALIA, async () => (await one<{ r: Record<string, unknown> }>(
  `select public.release_unclaimed_human_call($1, $2) r`, [LEAD, key])).r)
const sweep = async (at: string) => (await one<{ n: number }>(
  `select public.sweep_unclaimed_human_calls(180, $1::timestamptz) n`, [at])).n
const paused = async () => (await one<{ p: boolean }>(`select human_takeover_at is not null p from public.leads where id = $1`, [LEAD])).p
const beginPersonal = (key: string) => as(THALIA, async () => (await one<{ r: Record<string, unknown> }>(
  `select public.begin_human_call($1, '4145550177', 'personal', $2, $3::timestamptz) r`, [LEAD, key, NOW])).r)

describe('releasing an in-app call that never reached the phone company', () => {
  it('the browser releases an unclaimed app call at once, and the card can call again', async () => {
    await begin('never_rang_001')
    expect(await release('never_rang_001')).toEqual({ ok: true, released: true })
    expect(await paused()).toBe(false)
    const ev = await one<{ reason: string; by: string }>(`select payload->>'reason' reason, by from public.belt_events
      where lead_id = $1 and event = 'human_call_resumed'`, [LEAD])
    expect(ev).toEqual({ reason: 'the call never reached the phone company', by: 'Thalia' })
    expect(await begin('second_try_002')).toMatchObject({ ok: true, paused: true })
    // the released key can never be claimed by pm-phone afterwards
    expect(await claim('never_rang_001')).toMatchObject({ allowed: false })
  })

  it('keeps a claimed call paused for its outcome', async () => {
    await begin('placed_001')
    expect(await claim('placed_001')).toMatchObject({ allowed: true })
    expect(await release('placed_001')).toMatchObject({ ok: true, released: false, reason: 'the call was placed: log its outcome' })
    expect(await sweep('2026-10-23T17:00:00Z')).toBe(0)
    expect(await paused()).toBe(true)
  })

  it('never releases a personal-phone call', async () => {
    await beginPersonal('personal_001')
    expect(await release('personal_001')).toMatchObject({ released: false, reason: 'a personal-phone call: log its outcome' })
    expect(await sweep('2026-10-23T17:00:00Z')).toBe(0)
    expect(await paused()).toBe(true)
  })

  it('the sweep releases an unclaimed app call only after three minutes', async () => {
    await begin('closed_page_001')
    expect(await sweep('2026-10-23T16:02:00Z')).toBe(0)
    expect(await paused()).toBe(true)
    expect(await sweep('2026-10-23T16:03:30Z')).toBe(1)
    expect(await paused()).toBe(false)
    const ev = await one<{ by: string }>(`select by from public.belt_events where lead_id = $1 and event = 'human_call_resumed'`, [LEAD])
    expect(ev).toEqual({ by: 'system' })
  })

  it('ignores a key that is not the active call, and the sweep is service-only', async () => {
    await begin('active_001')
    expect(await release('some_other_key')).toMatchObject({ ok: false, released: false })
    expect(await paused()).toBe(true)
    await expect(as(THALIA, () => db.query(`select public.sweep_unclaimed_human_calls(180)`))).rejects.toThrow(/permission denied/i)
    await expect(as(THALIA, () => db.query(
      `select public.release_unclaimed_call_core($1, 'active_001', 'x', 'x', now())`, [LEAD]))).rejects.toThrow(/permission denied/i)
  })
})
