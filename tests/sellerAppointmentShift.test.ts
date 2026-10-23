// The new continuity layer on the real migrations: one human-call pause on the existing conveyor,
// retry/resume behaviour, block-list enforcement at the app authorization door, and the recovery queue.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, beforeEach, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATIONS = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')
const LEAD = '00000000-0000-0000-0000-0000000000e1'
const NOW = '2026-10-22T17:00:00Z'
const THALIA = { sub: '00000000-0000-0000-0000-00000000000a', email: 'thalia@example.com' }
const ADIL = { sub: '00000000-0000-0000-0000-00000000000b', email: 'adil@example.com' }
const COLIN = { sub: '00000000-0000-0000-0000-00000000000c', email: 'colin@example.com' }
let db: PGlite

const one = async <T = Record<string, unknown>>(sql: string, params: unknown[] = []) => (await db.query<T>(sql, params)).rows[0]
async function as<T>(claims: object, fn: () => Promise<T>): Promise<T> {
  await db.query(`select set_config('request.jwt.claims', $1, false)`, [JSON.stringify(claims)])
  await db.exec('set role authenticated')
  try { return await fn() } finally { await db.exec('reset role'); await db.query(`select set_config('request.jwt.claims', '', false)`) }
}
const begin = (source: 'app' | 'personal', key: string, phone = '4145550177') => as(THALIA, async () =>
  (await one<{ r: Record<string, unknown> }>(`select public.begin_human_call($1, $2, $3, $4, $5::timestamptz) r`,
    [LEAD, phone, source, key, NOW])).r)
const belt = (event: string, payload: object = {}, at = NOW) =>
  one<{ r: Record<string, unknown> }>(`select public.belt_event($1, $2, $3::jsonb, 'test', $4::timestamptz) r`,
    [LEAD, event, JSON.stringify(payload), at])

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATIONS)
  await db.exec(`insert into public.team_members (email, role, person, display_name) values
    ('thalia@example.com', 'caller', 'thalia', 'Thalia'), ('adil@example.com', 'caller', 'adil', 'Adil'),
    ('colin@example.com', 'owner', 'colin', 'Colin')`)
})

beforeEach(async () => {
  await db.exec(`
    truncate public.belt_events, public.belt_health, public.belt_alerts_sent, public.hot_alerts, public.tasks,
      public.reply_drafts, public.reply_threads, public.twilio_inbound, public.suppressed_phones, public.messages,
      public.contacts, public.leads cascade;
    update public.touch_templates set enabled = false;
    insert into public.leads (id, wpie_owner_id, owner_name, property_address, municipality, mailing_state, lane, stage)
      values ('${LEAD}', 902, 'JANE ROE', '100 N MAIN ST, Milwaukee', 'Milwaukee', 'WI', 'flip', 'opener_sent');
    insert into public.contacts (lead_id, kind, value, value_normalized, line_type)
      values ('${LEAD}', 'phone', '4145550177', '4145550177', 'mobile');
  `)
})

describe('human call takeover', () => {
  it('collapses concurrent duplicate taps into one pause event', async () => {
    const results = await as(THALIA, () => Promise.all([1, 2].map(async () =>
      (await one<{ r: { ok: boolean; duplicate: boolean } }>(
        `select public.begin_human_call($1, '4145550177', 'personal', 'concurrent_tap_001', $2::timestamptz) r`, [LEAD, NOW])).r)))
    expect(results.every((r) => r.ok)).toBe(true)
    expect(results.map((r) => r.duplicate).sort()).toEqual([false, true])
    expect(await one<{ n: number }>(`select count(*)::int n from public.belt_events where lead_id = $1 and event = 'human_call_started'`, [LEAD]))
      .toEqual({ n: 1 })
  })

  it('uses one retry-safe door for the app and personal phone and freezes a due automatic text', async () => {
    await belt('inbound_text', { intent: 'interested', interest: true })
    await belt('stop_done', { outcome: 'no_answer' })
    await db.query(`update public.leads set next_stop_at = $2::timestamptz where id = $1`, [LEAD, NOW])
    expect((await db.query(`select * from public.belt_due_texts($1::timestamptz, 10)`, [NOW])).rows).toHaveLength(1)

    expect(await begin('personal', 'personal_retry_001')).toMatchObject({ ok: true, duplicate: false, paused: true })
    expect(await begin('personal', 'personal_retry_001')).toMatchObject({ ok: true, duplicate: true, paused: true })
    expect(await begin('app', 'different_call_002')).toMatchObject({ ok: false, reason: 'another call is waiting for its outcome' })
    expect((await db.query(`select * from public.belt_due_texts($1::timestamptz, 10)`, [NOW])).rows).toHaveLength(0)
    const guarded = await one<{ r: { outcome: string; reason: string } }>(
      `select public.belt_claim_text_guarded($1, true, true, $2::timestamptz) r`, [LEAD, NOW])
    expect(guarded.r).toEqual({ outcome: 'refused', reason: 'human call in progress' })
    expect(await one<{ n: number }>(`select count(*)::int n from public.belt_events where lead_id = $1 and event = 'human_call_started'`, [LEAD]))
      .toEqual({ n: 1 })
  })

  it('resumes the exact untouched stop if the call never started, and rejects a stale key', async () => {
    await belt('inbound_text', { intent: 'interested', interest: true })
    await belt('stop_done', { outcome: 'no_answer' })
    await db.query(`update public.leads set next_stop_at = $2::timestamptz where id = $1`, [LEAD, NOW])
    expect((await one<{ r: { outcome: string } }>(`select public.belt_claim_text($1, true, false, $2::timestamptz) r`, [LEAD, NOW])).r.outcome)
      .toBe('awaiting_approval')
    const before = await one<{ at: string; who: string; step: number }>(`
      select next_stop_at::text at, next_stop_who who, belt_step::int step from public.leads where id = $1`, [LEAD])
    await begin('app', 'app_attempt_001')
    expect(await one<{ status: string }>(`select status from public.reply_drafts where lead_id = $1`, [LEAD])).toEqual({ status: 'superseded' })
    const stale = await as(THALIA, async () => (await one<{ r: Record<string, unknown> }>(
      `select public.resume_human_call($1, 'wrong_attempt', $2::timestamptz) r`, [LEAD, NOW])).r)
    expect(stale).toMatchObject({ ok: false, reason: 'that is not the active call' })
    const resumed = await as(THALIA, async () => (await one<{ r: Record<string, unknown> }>(
      `select public.resume_human_call($1, 'app_attempt_001', $2::timestamptz) r`, [LEAD, NOW])).r)
    expect(resumed).toMatchObject({ ok: true, duplicate: false, paused: false })
    expect(await one<{ at: string; who: string; step: number; paused: boolean }>(`
      select next_stop_at::text at, next_stop_who who, belt_step::int step, human_takeover_at is not null paused
      from public.leads where id = $1`, [LEAD])).toEqual({ ...before, paused: false })
    expect(await one<{ status: string }>(`select status from public.reply_drafts where lead_id = $1`, [LEAD])).toEqual({ status: 'awaiting_approval' })
  })

  it('hands back to the existing belt when an outcome is logged and keeps one next task', async () => {
    await belt('inbound_text', { intent: 'interested', interest: true })
    await begin('personal', 'personal_outcome_001')
    await as(THALIA, () => db.query(`select public.log_call($1, '4145550177', 'no_answer', 'rang out', null)`, [LEAD]))
    const state = await one<{ paused: boolean; belt: string; who: string }>(`
      select human_takeover_at is not null paused, belt, next_stop_who who from public.leads where id = $1`, [LEAD])
    expect(state).toMatchObject({ paused: false, belt: 'yes_unbooked', who: 'auto_text' })
    expect(await one<{ n: number }>(`select count(*)::int n from public.tasks where lead_id = $1 and done_at is null`, [LEAD])).toEqual({ n: 0 })
    expect(await begin('personal', 'personal_outcome_001')).toMatchObject({ ok: true, duplicate: true, paused: false })
    expect(await one<{ paused: boolean }>(`select human_takeover_at is not null paused from public.leads where id = $1`, [LEAD])).toEqual({ paused: false })
  })

  it('will not overlap a provider-uncertain automated text already marked sending', async () => {
    await belt('inbound_text', { intent: 'interested', interest: true })
    await belt('stop_done', { outcome: 'no_answer' })
    await db.query(`update public.leads set next_stop_at = $2::timestamptz where id = $1`, [LEAD, NOW])
    await one(`select public.belt_claim_text($1, true, true, $2::timestamptz)`, [LEAD, NOW])
    await db.query(`update public.reply_drafts set status = 'sending' where lead_id = $1`, [LEAD])
    expect(await begin('app', 'while_sending_001')).toMatchObject({
      ok: false, reason: 'an automated text is already sending; check its result before calling',
    })
    expect(await one<{ paused: boolean }>(`select human_takeover_at is not null paused from public.leads where id = $1`, [LEAD])).toEqual({ paused: false })
  })

  it('fails closed for STOP/DNC and an off-card number, and STOP clears an in-flight marker', async () => {
    expect(await begin('app', 'off_card_001', '4145550199')).toMatchObject({ ok: false, reason: 'that phone is not on this card' })
    await db.exec(`insert into public.suppressed_phones (phone10, reason, source) values ('4145550177', 'stop_reply', 'test')`)
    expect(await begin('app', 'blocked_001')).toMatchObject({ ok: false, reason: 'suppressed: stop_reply' })
    await db.exec(`delete from public.suppressed_phones`)
    await begin('personal', 'stop_during_001')
    await belt('stop', { key: 'stop:during-call' })
    expect(await one<{ belt: string; paused: boolean }>(`
      select belt, human_takeover_at is not null paused from public.leads where id = $1`, [LEAD]))
      .toEqual({ belt: 'dnc', paused: false })
  })

  it('does not let the missed-stop sweep move a paused call', async () => {
    await belt('inbound_text', { intent: 'interested', interest: true })
    await db.query(`update public.leads set next_stop_at = '2026-10-21T12:00:00Z' where id = $1`, [LEAD])
    await begin('app', 'missed_guard_001')
    const swept = await one<{ r: { swept: number } }>(`select public.belt_sweep_missed('2026-10-23T12:00:00Z') r`)
    expect(swept.r.swept).toBe(0)
    expect(await one<{ n: number }>(`select count(*)::int n from public.belt_events where event = 'stop_missed' and lead_id = $1`, [LEAD]))
      .toEqual({ n: 0 })
  })
})

describe('recovery queue', () => {
  it('includes touched missing/overdue work and a pending call with an explicit owner', async () => {
    await db.query(`update public.leads set stage = 'human_owned', call_facts = '{"motivation":{"value":{"text":"moving"}}}',
      next_action_at = null, next_stop_at = null, assigned_to = null where id = $1`, [LEAD])
    let row = await one<{ reason: string; recovery_owner: string }>(`
      select reason, recovery_owner::text from public.seller_recovery_queue where lead_id = $1`, [LEAD])
    expect(row.reason).toBe('missing_next_action')
    expect(['thalia', 'adil']).toContain(row.recovery_owner)

    await begin('personal', 'recovery_call_001')
    row = await one(`select reason, recovery_owner::text from public.seller_recovery_queue where lead_id = $1`, [LEAD])
    expect(row).toEqual({ reason: 'call_outcome_needed', recovery_owner: 'thalia' })
  })

  it('assigns Colin to owner work, Adil on weekends, Thalia on weekdays, while honoring an explicit assignee', async () => {
    const owner = async (assigned: string | null, who: string | null, beltName: string | null, stage: string, at: string) =>
      (await one<{ p: string }>(`select public.seller_recovery_owner($1::public.team_person, $2, $3, $4::public.lead_stage, $5::timestamptz)::text p`,
        [assigned, who, beltName, stage, at])).p
    expect(await owner(null, null, 'visit_booked', 'walkthrough_booked', '2026-10-24T15:00:00Z')).toBe('colin')
    expect(await owner(null, null, 'yes_unbooked', 'reply_received', '2026-10-24T15:00:00Z')).toBe('adil')
    expect(await owner(null, null, 'yes_unbooked', 'reply_received', '2026-10-23T15:00:00Z')).toBe('thalia')
    expect(await owner('adil', 'thalia_call', 'yes_unbooked', 'reply_received', '2026-10-23T15:00:00Z')).toBe('adil')
  })

  it('excludes terminal and fully suppressed cards', async () => {
    await db.query(`update public.leads set stage = 'human_owned', call_facts = '{"motivation":{"value":{"text":"moving"}}}' where id = $1`, [LEAD])
    expect((await db.query(`select 1 from public.seller_recovery_queue where lead_id = $1`, [LEAD])).rows).toHaveLength(1)
    await db.query(`update public.contacts set dnc_app = true where lead_id = $1`, [LEAD])
    expect((await db.query(`select 1 from public.seller_recovery_queue where lead_id = $1`, [LEAD])).rows).toHaveLength(0)
    await db.query(`update public.contacts set dnc_app = false where lead_id = $1`, [LEAD])
    await db.query(`update public.leads set stage = 'dnc', belt = 'dnc' where id = $1`, [LEAD])
    expect((await db.query(`select 1 from public.seller_recovery_queue where lead_id = $1`, [LEAD])).rows).toHaveLength(0)
  })

  it('does not turn untouched cold-text inventory into conversation recovery debt', async () => {
    await db.query(`update public.leads set belt = 'cold_texts', belt_step = 1, next_stop_at = null, next_action_at = null where id = $1`, [LEAD])
    await db.query(`insert into public.messages (lead_id, direction, channel, body, status, is_opener, sent_at)
      values ($1, 'out', 'sms', 'opener', 'sent', true, $2::timestamptz)`, [LEAD, NOW])
    expect((await db.query(`select 1 from public.seller_recovery_queue where lead_id = $1`, [LEAD])).rows).toHaveLength(0)
  })
})

describe('simulated Thalia → Adil → Colin shift', () => {
  it('carries one card from an exact follow-up through weekend takeover to one Colin-owned visit', async () => {
    await as(THALIA, () => db.query(`select public.log_call($1, '4145550177', 'not_now', 'call after the move',
      '2026-11-05T18:00:00Z'::timestamptz)`, [LEAD]))
    expect(await one<{ belt: string; named: string }>(`
      select belt, to_char(named_date at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') named from public.leads where id = $1`, [LEAD]))
      .toEqual({ belt: 'not_now_dated', named: '2026-11-05T18:00:00Z' })

    const started = await as(ADIL, async () => (await one<{ r: Record<string, unknown> }>(
      `select public.begin_human_call($1, '4145550177', 'personal', 'adil_weekend_001', '2026-10-25T16:00:00Z') r`, [LEAD])).r)
    expect(started).toMatchObject({ ok: true, paused: true })
    expect(await one<{ by: string }>(`select human_takeover_by by from public.leads where id = $1`, [LEAD])).toEqual({ by: 'Adil' })
    await as(ADIL, () => db.query(`select public.log_call($1, '4145550177', 'interested', 'ready to schedule', null)`, [LEAD]))
    expect(await one<{ paused: boolean }>(`select human_takeover_at is not null paused from public.leads where id = $1`, [LEAD])).toEqual({ paused: false })

    const booked = await as(COLIN, async () => (await one<{ r: Record<string, unknown> }>(
      `select public.call_answer($1, 'next_step', '{"kind":"walk","at":"2026-11-06T19:00:00Z"}') r`, [LEAD])).r)
    expect(booked).toMatchObject({ ok: true, belt: 'visit_booked' })
    expect(await one<{ belt: string; stage: string; owner: string; tasks: number }>(`
      select l.belt, l.stage::text, l.assigned_to::text owner,
        (select count(*)::int from public.tasks t where t.lead_id = l.id and t.done_at is null and t.kind = 'visit') tasks
      from public.leads l where l.id = $1`, [LEAD])).toEqual({ belt: 'visit_booked', stage: 'walkthrough_booked', owner: 'colin', tasks: 1 })
  })
})
