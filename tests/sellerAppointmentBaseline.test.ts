// Baseline contract for the seller-to-appointment shift. Keep this deliberately narrow: these are
// the conveyor behaviours the shift is not allowed to regress while recovery, takeover and packet
// features are added on top of the one existing belt engine.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, beforeEach, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATIONS = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')
const LEAD = '00000000-0000-0000-0000-0000000000d1'
const NOW = '2026-10-22T17:00:00Z'
let db: PGlite

const one = async <T = Record<string, unknown>>(sql: string, params: unknown[] = []) => (await db.query<T>(sql, params)).rows[0]
const event = async (name: string, payload: Record<string, unknown> = {}, at = NOW) =>
  (await one<{ r: Record<string, unknown> }>(`select public.belt_event($1, $2, $3::jsonb, 'baseline', $4::timestamptz) as r`,
    [LEAD, name, JSON.stringify(payload), at])).r

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATIONS)
  await db.exec(`insert into public.team_members (email, role, person, display_name) values
    ('thalia@example.com', 'caller', 'thalia', 'Thalia'), ('colin@example.com', 'owner', 'colin', 'Colin')`)
})

beforeEach(async () => {
  await db.exec(`
    truncate public.belt_events, public.belt_health, public.belt_alerts_sent, public.ops_alerts, public.tasks,
      public.reply_drafts, public.reply_threads, public.twilio_inbound, public.suppressed_phones, public.messages,
      public.contacts, public.leads cascade;
    insert into public.leads (id, wpie_owner_id, owner_name, property_address, municipality, mailing_state, lane, stage)
      values ('${LEAD}', 901, 'JANE ROE', '100 N MAIN ST, Milwaukee', 'Milwaukee', 'WI', 'flip', 'opener_sent');
    insert into public.contacts (lead_id, kind, value, value_normalized, line_type)
      values ('${LEAD}', 'phone', '4145550177', '4145550177', 'mobile');
  `)
})

describe('seller-to-appointment conveyor baseline', () => {
  it('keeps an exact dated follow-up and schedules no stop before the seller date', async () => {
    await db.query(`select set_config('request.jwt.claims', $1, false)`, [JSON.stringify({
      sub: '00000000-0000-0000-0000-00000000000a', email: 'thalia@example.com',
    })])
    await db.exec('set role authenticated')
    try {
      await db.query(`select public.log_call($1, '4145550177', 'not_now', 'call me after the first Sunday in November',
        '2026-11-02T18:00:00Z'::timestamptz)`, [LEAD])
    } finally {
      await db.exec('reset role')
    }
    const lead = await one<{ belt: string; named: string; stop: string }>(`
      select belt, to_char(named_date at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') named,
        to_char(next_stop_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') stop
      from public.leads where id = $1`, [LEAD])
    expect(lead.belt).toBe('not_now_dated')
    expect(lead.named).toBe('2026-11-02T18:00:00Z')
    expect(new Date(lead.stop).getTime()).toBeGreaterThanOrEqual(new Date(lead.named).getTime())
  })

  it('shows live cards with no stop but excludes resting and terminal cards', async () => {
    await db.query(`update public.leads set belt = 'yes_unbooked', belt_step = 1, next_stop_at = null, assigned_to = 'thalia' where id = $1`, [LEAD])
    expect(await one<{ n: number }>(`select count(*)::int n from public.cards_no_stop where lead_id = $1`, [LEAD])).toEqual({ n: 1 })
    await db.query(`update public.leads set belt = 'dnc', stage = 'dnc' where id = $1`, [LEAD])
    expect(await one<{ n: number }>(`select count(*)::int n from public.cards_no_stop where lead_id = $1`, [LEAD])).toEqual({ n: 0 })
    await db.query(`update public.leads set belt = 'dormant', dormant_round = 3, stage = 'follow_up' where id = $1`, [LEAD])
    expect(await one<{ n: number }>(`select count(*)::int n from public.cards_no_stop where lead_id = $1`, [LEAD])).toEqual({ n: 0 })
  })

  it('keeps STOP final even if interest arrives later', async () => {
    await event('inbound_text', { intent: 'interested', interest: true })
    await event('stop', { key: 'stop:baseline' })
    const after = await event('inbound_text', { key: 'later:baseline', intent: 'interested', interest: true })
    expect(after).toMatchObject({ ok: true, belt: 'dnc' })
    expect(await one<{ n: number }>(`select count(*)::int n from public.tasks where lead_id = $1 and done_at is null`, [LEAD])).toEqual({ n: 0 })
  })

  it('reschedules one callback stop without duplicating tasks', async () => {
    await event('next_step', { kind: 'callback', at: '2026-10-23T19:00:00Z' })
    await event('next_step', { kind: 'callback', at: '2026-10-24T19:00:00Z' }, '2026-10-22T18:00:00Z')
    const tasks = (await db.query<{ due: string }>(`
      select to_char(due_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') due
      from public.tasks where lead_id = $1 and source = 'belt' and done_at is null`, [LEAD])).rows
    expect(tasks).toEqual([{ due: '2026-10-24T19:00:00Z' }])
  })

  it('slides seller contact off Sunday while belt-health staff alerts still run', async () => {
    const slide = await one<{ at: string }>(`
      select to_char(public.belt_slide('2026-10-25T18:00:00Z', 'America/Chicago', 'text', null)
        at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') at`)
    expect(slide.at).toBe('2026-10-26T14:00:00Z')
    await db.query(`insert into public.belt_health (at, kind, ok, checks, summary)
      values ('2026-10-25T15:00:00Z', 'run', true, '{"no_stop":0}', 'old run')`)
    const watch = await one<{ r: { alerted: string[] } }>(`select public.belt_watch('2026-10-25T18:00:00Z') as r`)
    expect(watch.r.alerted).toContain('heartbeat')
    expect(await one<{ n: number }>(`select count(*)::int n from public.ops_alerts`)).toEqual({ n: 1 })
  })
})
