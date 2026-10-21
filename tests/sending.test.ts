// Migration 0003 (app sending): every send-time check in claim_next_opener, the
// three locks, cap / pace / window, never-retry, the pause, and Colin's buttons.
// Runs on an in-memory Postgres (PGlite); nothing here can reach Twilio.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, beforeEach, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')

const COLIN = { sub: '00000000-0000-0000-0000-00000000000c', email: 'colin@example.com' }
const THALIA = { sub: '00000000-0000-0000-0000-00000000000a', email: 'thalia@example.com' }

// Thursday 2026-10-22. 15:00Z = 10:00 Central (CDT).
const DAY = '2026-10-22'
const T = (hhmm: string) => `${DAY}T${hhmm}:00Z`
const BODY = "Hi John, Colin Merrill here. I'm looking to buy another building and yours at 2825 S Logan Ave caught my eye. Any interest in selling? No worries if not, just reply STOP."

let db: PGlite

async function as<T>(who: { sub: string; email: string }, fn: () => Promise<T>): Promise<T> {
  await db.exec('reset role')
  await db.query(`select set_config('request.jwt.claims', $1, false)`, [JSON.stringify(who)])
  await db.exec('set role authenticated')
  try {
    return await fn()
  } finally {
    await db.exec('reset role')
    await db.query(`select set_config('request.jwt.claims', '', false)`)
  }
}

let owner = 1000
async function lead(opts: { stage?: string; phone?: string } = {}) {
  owner += 1
  const phone = opts.phone ?? `414555${String(owner).slice(-4)}`
  const r = await db.query<{ id: string }>(
    `insert into public.leads (wpie_owner_id, owner_name, lane, stage) values ($1, $3, 'hold', $2::public.lead_stage) returning id`,
    [owner, opts.stage ?? 'opener_queued', `OWNER ${owner}`])
  const id = r.rows[0].id
  await db.query(`insert into public.contacts (lead_id, kind, value, value_normalized, line_type) values ($1, 'phone', $2, $2, 'mobile')`, [id, phone])
  return { id, owner, phone }
}

async function opener(l: { id: string; owner: number; phone: string }, o: Record<string, unknown> = {}) {
  const r = await db.query<{ id: string }>(
    `insert into public.planned_openers (plan_date, wpie_owner_id, attempt, lead_id, phone, body, body_sha256, scheduled_at,
       window_start_utc, window_end_utc, dnc_state, per_hour, decision)
     values ($1, $2, 1, $3, $4, $5, encode(sha256(convert_to($6, 'UTF8')), 'hex'), $7, $8, $9, $10, $11, $12::public.opener_decision)
     returning id`,
    [o.plan_date ?? DAY, l.owner, l.id, o.phone ?? `+1${l.phone}`, o.body ?? BODY, o.hashed ?? o.body ?? BODY,
     o.scheduled_at ?? T('15:00'), 'window_start' in o ? o.window_start : T('15:00'), 'window_end' in o ? o.window_end : T('23:15'),
     o.dnc_state ?? 'unknown', o.per_hour ?? 12, o.decision ?? 'approved'])
  return r.rows[0].id
}

async function claim(at: string, dry = false) {
  const r = await db.query<{ j: { outcome: string; reason?: string; opener?: { id: string } } }>(
    `select public.claim_next_opener($1, $2::timestamptz) as j`, [dry, at])
  return r.rows[0].j
}

async function status(id: string) {
  return (await db.query<{ send_status: string; send_reason: string | null }>(
    `select send_status, send_reason from public.planned_openers where id = $1`, [id])).rows[0]
}

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
  await db.exec(`insert into public.team_members (email, role, person, display_name) values
    ('colin@example.com', 'owner', 'colin', 'Colin'), ('thalia@example.com', 'caller', 'thalia', 'Thalia')`)
})

beforeEach(async () => {
  await db.exec(`
    truncate public.opener_send_events, public.twilio_inbound, public.suppressed_phones, public.planned_openers,
             public.messages, public.contacts, public.leads cascade;
    update public.campaign_control set sending_enabled = true, paused = false, pause_reason = null, laptop_paused = false,
      daily_cap = 100, dnc_policy = 'allow_unknown', scrub_date = null, external_openers = 0, external_openers_date = null,
      banned_words = '{}';
  `)
})

describe('the locks', () => {
  it('sends nothing live while the app switch is off, but a dry run still checks', async () => {
    await db.exec(`update public.campaign_control set sending_enabled = false`)
    const id = await opener(await lead())
    expect(await claim(T('15:05'))).toMatchObject({ outcome: 'idle', reason: 'switch_off' })
    expect((await status(id)).send_status).toBe('planned')
    expect(await claim(T('15:05'), true)).toMatchObject({ outcome: 'would_send' })
    expect((await status(id)).send_status).toBe('would_send')
  })

  it('needs Colin to approve each text before a live send', async () => {
    const id = await opener(await lead(), { decision: 'pending' })
    expect(await claim(T('15:05'))).toMatchObject({ outcome: 'idle', reason: 'nothing_due' })
    await db.query(`update public.planned_openers set decision = 'approved' where id = $1`, [id])
    expect(await claim(T('15:05'))).toMatchObject({ outcome: 'send', opener: { id } })
    expect((await status(id)).send_status).toBe('sending')
  })

  it('picks up a dry-run "would send" entry once live, like the ledger picks up "simulated"', async () => {
    const id = await opener(await lead())
    expect(await claim(T('15:05'), true)).toMatchObject({ outcome: 'would_send' })
    expect(await claim(T('15:06'))).toMatchObject({ outcome: 'send', opener: { id } })
  })

  it('stops everything while paused (server or laptop) and only Colin clears the server pause', async () => {
    await opener(await lead())
    await db.exec(`update public.campaign_control set laptop_paused = true, laptop_pause_reason = 'watchdog'`)
    expect(await claim(T('15:05'))).toMatchObject({ outcome: 'idle', reason: 'paused' })
    await db.exec(`update public.campaign_control set laptop_paused = false, paused = true, pause_reason = 'x'`)
    expect(await claim(T('15:05'), true)).toMatchObject({ outcome: 'idle', reason: 'paused' })
    await expect(as(THALIA, () => db.query('select public.clear_pause()'))).rejects.toThrow(/only Colin/)
    await as(COLIN, () => db.query('select public.clear_pause()'))
    expect(await claim(T('15:05'))).toMatchObject({ outcome: 'send' })
    const c = (await db.query<{ pause_cleared_by: string; cleared: boolean }>(
      `select pause_cleared_by, pause_cleared_at is not null as cleared from public.campaign_control`)).rows[0]
    expect(c).toEqual({ pause_cleared_by: 'Colin', cleared: true })
  })

  it('the carrier-filter brake counts only sends after the last clear, so a clear sticks', async () => {
    await db.exec(`update public.campaign_control set pause_cleared_at = null, pause_cleared_by = null`)
    // Four filtered texts today trip it (3 of the last 50).
    for (let i = 0; i < 4; i++) {
      const id = await opener(await lead())
      await db.query(`update public.planned_openers set send_status = 'undelivered', claim_mode = 'live',
                       claimed_at = now() - make_interval(mins => 30 - $2), error_code = '30007' where id = $1`, [id, i])
    }
    await db.query(`select public.check_filter_rule(now())`)
    expect((await db.query<{ paused: boolean }>(`select paused from public.campaign_control`)).rows[0].paused).toBe(true)
    await as(COLIN, () => db.query(`select public.clear_pause('Colin, after the 30007 review')`))
    // The next send (clean) must not re-trip on the old four.
    const next = await opener(await lead())
    await db.query(`update public.planned_openers set send_status = 'delivered', claim_mode = 'live', claimed_at = now() + interval '1 second' where id = $1`, [next])
    await db.query(`select public.check_filter_rule(now())`)
    const after = (await db.query<{ paused: boolean; pause_cleared_by: string }>(`select paused, pause_cleared_by from public.campaign_control`)).rows[0]
    expect(after).toEqual({ paused: false, pause_cleared_by: 'Colin, after the 30007 review' })
    // Three new filtered texts after the clear still trip it.
    for (let i = 0; i < 3; i++) {
      const id = await opener(await lead())
      await db.query(`update public.planned_openers set send_status = 'undelivered', claim_mode = 'live', claimed_at = now() + make_interval(secs => $2),
                       error_code = '30007' where id = $1`, [id, 2 + i])
    }
    await db.query(`select public.check_filter_rule(now())`)
    expect((await db.query<{ paused: boolean; pause_reason: string }>(`select paused, pause_reason from public.campaign_control`)).rows[0])
      .toEqual({ paused: true, pause_reason: expect.stringMatching(/^3 carrier-filtered texts .* since the last clear$/) })
  })

  it('stamps who and when for a clear made outside the button (e.g. the laptop push)', async () => {
    await db.exec(`update public.campaign_control set paused = true, pause_reason = 'x', pause_cleared_at = null, pause_cleared_by = null`)
    await db.exec(`update public.campaign_control set paused = false`)
    const c = (await db.query<{ cleared: boolean; by: string }>(`select pause_cleared_at is not null as cleared, pause_cleared_by as by from public.campaign_control`)).rows[0]
    expect(c.cleared).toBe(true)
    expect(c.by).toBeTruthy()
  })
})

describe('time', () => {
  it('sends only 10:00-18:15 Central, never on Sunday', async () => {
    await opener(await lead(), { scheduled_at: T('14:00'), window_start: T('14:00') })
    expect(await claim(T('14:59'))).toMatchObject({ outcome: 'idle', reason: 'outside_window' })     // 9:59 CT
    expect(await claim(T('23:15'))).toMatchObject({ outcome: 'idle', reason: 'outside_window' })     // 18:15 CT
    expect(await claim('2026-10-25T16:00:00Z')).toMatchObject({ outcome: 'idle', reason: 'sunday' })
    expect(await claim(T('15:00'))).toMatchObject({ outcome: 'send' })
  })

  it("waits for the scheduled slot and the recipient's own window; never sends another day's plan", async () => {
    const l = await lead()
    const id = await opener(l, { scheduled_at: T('17:00') })
    expect(await claim(T('16:59'))).toMatchObject({ reason: 'nothing_due' })
    await db.query(`update public.planned_openers set scheduled_at = $2, window_start_utc = $3 where id = $1`, [id, T('15:00'), T('18:00')])
    expect(await claim(T('17:00'))).toMatchObject({ reason: 'nothing_due' })        // e.g. a Mountain-time recipient
    await db.query(`update public.planned_openers set plan_date = '2026-10-21' where id = $1`, [id])
    expect(await claim(T('18:30'))).toMatchObject({ reason: 'nothing_due' })
  })

  it('skips an entry pushed without a recipient window (fail closed)', async () => {
    const id = await opener(await lead(), { window_start: null, window_end: null })
    expect(await claim(T('15:05'))).toMatchObject({ outcome: 'skipped', reason: 'no_recipient_window' })
    expect(await status(id)).toEqual({ send_status: 'skipped', send_reason: 'no_recipient_window' })
  })
})

describe('cap and pace', () => {
  it('holds the daily cap across app sends, laptop sends and the reply agent', async () => {
    await db.exec(`update public.campaign_control set daily_cap = 3, external_openers = 1, external_openers_date = '${DAY}'`)
    for (let i = 0; i < 3; i++) await opener(await lead())
    const sentByLaptop = await lead()
    await db.query(`insert into public.messages (lead_id, direction, channel, body, provider_sid, is_opener, sent_at)
                    values ($1, 'out', 'sms', 'hi', 'SMlaptop', true, $2)`, [sentByLaptop.id, T('15:01')])
    expect(await claim(T('15:05'))).toMatchObject({ outcome: 'send' })
    expect(await claim(T('15:06'))).toMatchObject({ outcome: 'idle', reason: 'daily_cap_reached' })
  })

  it("keeps the plan's hourly pace", async () => {
    for (let i = 0; i < 3; i++) await opener(await lead(), { per_hour: 2 })
    expect(await claim(T('15:00'))).toMatchObject({ outcome: 'send' })
    expect(await claim(T('15:01'))).toMatchObject({ outcome: 'send' })
    expect(await claim(T('15:02'))).toMatchObject({ outcome: 'idle', reason: 'hourly_pace_reached' })
    expect(await claim(T('16:01'))).toMatchObject({ outcome: 'send' })
  })
})

describe('per-text checks (each one skips the text for good)', () => {
  const cases: [string, () => Promise<string>, string][] = [
    ['STOP list', async () => { const l = await lead(); await db.query(`insert into public.suppressed_phones (phone10, reason) values ($1, 'stop')`, [l.phone]); return opener(l) }, 'phone_suppressed'],
    ['STOP on another phone of the owner', async () => {
      const l = await lead(); await db.query(`insert into public.contacts (lead_id, kind, value, value_normalized) values ($1, 'phone', '2625550199', '2625550199')`, [l.id])
      await db.query(`insert into public.suppressed_phones (phone10, reason) values ('2625550199', 'stop')`); return opener(l) }, 'owner_opted_out_on_another_phone'],
    ['a reply recorded by WPIE', async () => { const l = await lead(); await db.query(`insert into public.messages (lead_id, direction, channel, body) values ($1, 'in', 'sms', 'who is this')`, [l.id]); return opener(l) }, 'owner_replied'],
    ['a reply the server pulled from Twilio', async () => { const l = await lead(); await db.query(`select public.record_inbound('SMin1', $1, '+12629996513', 'call me', false, now())`, [`+1${l.phone}`]); return opener(l) }, 'owner_replied'],
    ['a positive DNC flag', async () => { const l = await lead(); await db.query(`update public.contacts set dnc_vendor = true where lead_id = $1`, [l.id]); return opener(l) }, 'phone_dnc_positive'],
    ['do-not-contact marked in the app', async () => { const l = await lead(); await db.query(`update public.contacts set dnc_app = true where lead_id = $1`, [l.id]); return opener(l) }, 'phone_dnc_positive'],
    ['a phone marked bad', async () => { const l = await lead(); await db.query(`update public.contacts set status = 'bad' where lead_id = $1`, [l.id]); return opener(l) }, 'phone_marked_bad'],
    ['a phone two owners share', async () => { const l = await lead(); await lead({ phone: l.phone }); return opener(l) }, 'phone_shared'],
    ['the lead moved on in the app', async () => opener(await lead({ stage: 'dead' })), 'lead_stage_dead'],
    ['an owner already texted', async () => {
      const l = await lead(); await db.query(`insert into public.messages (lead_id, direction, channel, body, provider_sid, is_opener, sent_at) values ($1, 'out', 'sms', 'hi', 'SMold', true, '2026-10-01')`, [l.id]); return opener(l) }, 'owner_already_texted'],
    ['wording changed after Python checked it', async () => opener(await lead(), { hashed: 'something else' }), 'body_changed_since_plan'],
    ['no STOP line', async () => opener(await lead(), { body: 'Hi John, any interest in selling?' }), 'template:no_stop_line'],
    ['a dollar sign', async () => opener(await lead(), { body: 'Cash $50k? reply STOP' }), 'template:price_symbol'],
    ['the business name', async () => { await db.exec(`update public.campaign_control set banned_words = '{Merrill Holdings}'`); return opener(await lead(), { body: 'Hi from merrill holdings. reply STOP' }) }, 'template:names_business'],
    ['an invalid phone', async () => opener(await lead(), { phone: '+15555' }), 'phone_invalid'],
  ]
  for (const [name, setup, reason] of cases) {
    it(`skips: ${name}`, async () => {
      const id = await setup()
      expect(await claim(T('15:05'))).toMatchObject({ outcome: 'skipped', reason })
      expect(await status(id)).toEqual({ send_status: 'skipped', send_reason: reason })
      expect(await claim(T('15:06'))).toMatchObject({ outcome: 'idle', reason: 'nothing_due' })
    })
  }

  it('under require_scrub sends only screened phones with a scrub under 31 days old', async () => {
    await db.exec(`update public.campaign_control set dnc_policy = 'require_scrub', scrub_date = '2026-10-01'`)
    const a = await opener(await lead(), { dnc_state: 'unknown' })
    expect(await claim(T('15:05'))).toMatchObject({ outcome: 'skipped', reason: 'dnc_unscreened_under_require_scrub' })
    const l = await lead()
    await db.query(`update public.contacts set dnc_scrub = 'clear' where lead_id = $1`, [l.id])
    await opener(l, { dnc_state: 'screened' })
    await db.exec(`update public.campaign_control set scrub_date = '2026-09-01'`)
    expect(await claim(T('15:06'))).toMatchObject({ outcome: 'skipped', reason: 'dnc_scrub_older_than_31_days' })
    expect((await status(a)).send_status).toBe('skipped')
  })
})

describe('after the Twilio call', () => {
  it('records a send where the app and the WPIE sync both see it', async () => {
    const l = await lead()
    const id = await opener(l)
    await claim(T('15:05'))
    await db.query(`select public.record_send_result($1, 'sent', 'SM123', null, null, $2::timestamptz)`, [id, T('15:05')])
    const m = await db.query(`select source_key, provider_sid, is_opener from public.messages where lead_id = $1`, [l.id])
    expect(m.rows).toEqual([{ source_key: `ledger:${l.owner}:1:opener`, provider_sid: 'SM123', is_opener: true }])
    const st = await db.query<{ stage: string }>(`select stage::text from public.leads where id = $1`, [l.id])
    expect(st.rows[0].stage).toBe('opener_sent')
    const ev = await db.query<{ event: string }>(`select event from public.opener_send_events where opener_id = $1 order by id`, [id])
    expect(ev.rows.map((r) => r.event)).toEqual(['sending', 'sent'])
    await db.query(`select public.record_delivery('SM123', 'delivered', null)`)
    expect((await status(id)).send_status).toBe('delivered')
  })

  it('never retries an ambiguous send', async () => {
    const id = await opener(await lead())
    await claim(T('15:05'))
    await db.query(`select public.record_send_result($1, 'uncertain', null, null, 'timeout')`, [id])
    expect((await status(id)).send_status).toBe('uncertain')
    expect(await claim(T('15:06'))).toMatchObject({ outcome: 'idle', reason: 'nothing_due' })
    const again = await db.query<{ j: { ok: boolean } }>(`select public.record_send_result($1, 'sent', 'SMlate') as j`, [id])
    expect(again.rows[0].j.ok).toBe(false)
  })

  it('pauses on an account / registration error code', async () => {
    await opener(await lead())
    await opener(await lead())
    const id = (await claim(T('15:05'))).opener!.id
    await db.query(`select public.record_send_result($1, 'failed', null, '21606', 'rejected by provider 400 21606')`, [id])
    const c = await db.query<{ paused: boolean }>(`select paused from public.campaign_control`)
    expect(c.rows[0].paused).toBe(true)
    expect(await claim(T('15:06'))).toMatchObject({ outcome: 'idle', reason: 'paused' })
  })

  it('pauses after 3 carrier-filtered texts among the last 50', async () => {
    for (let i = 1; i <= 3; i++) {
      const id = await opener(await lead(), { per_hour: 50 })
      await claim(T(`15:0${i}`))
      await db.query(`select public.record_send_result($1, 'sent', $2)`, [id, `SMf${i}`])
      await db.query(`select public.record_delivery($1, 'undelivered', '30007')`, [`SMf${i}`])
    }
    const c = await db.query<{ paused: boolean; pause_reason: string }>(`select paused, pause_reason from public.campaign_control`)
    expect(c.rows[0]).toMatchObject({ paused: true })
    expect(c.rows[0].pause_reason).toMatch(/3 carrier-filtered/)
  })

  it('puts a STOP pulled from Twilio on the never-text list', async () => {
    const l = await lead()
    await db.query(`select public.record_inbound('SMstop', $1, '+12629996513', 'STOP', true, now())`, [`+1${l.phone}`])
    const s = await db.query(`select reason, source from public.suppressed_phones where phone10 = $1`, [l.phone])
    expect(s.rows).toEqual([{ reason: 'stop_reply', source: 'twilio_inbound' }])
    const c = await db.query<{ suppressed: boolean }>(`select suppressed from public.contacts where lead_id = $1`, [l.id])
    expect(c.rows[0].suppressed).toBe(true)
  })
})

describe("Colin's buttons and who may press them", () => {
  it('approves a whole day except the ticked ones, and withdraws what is left', async () => {
    const a = await opener(await lead(), { decision: 'pending' })
    const b = await opener(await lead(), { decision: 'pending' })
    const c = await opener(await lead(), { decision: 'pending' })
    await expect(as(THALIA, () => db.query(`select public.approve_day($1, '{}')`, [DAY]))).rejects.toThrow(/only Colin/)
    const r = await as(COLIN, () => db.query<{ j: Record<string, number> }>(`select public.approve_day($1, $2::uuid[]) as j`, [DAY, [b]]))
    expect(r.rows[0].j).toEqual({ approved: 2, skipped: 1 })
    const d = await db.query<{ id: string; decision: string }>(`select id, decision::text from public.planned_openers order by scheduled_at, id`)
    expect(Object.fromEntries(d.rows.map((x) => [x.id, x.decision]))).toEqual({ [a]: 'approved', [b]: 'skipped', [c]: 'approved' })
    await claim(T('15:05'))
    const w = await as(COLIN, () => db.query<{ j: Record<string, number> }>(`select public.withdraw_day($1) as j`, [DAY]))
    expect(w.rows[0].j).toEqual({ withdrawn: 2 })      // the one already 'sending' stays
    expect(await claim(T('15:06'))).toMatchObject({ outcome: 'idle', reason: 'nothing_due' })
  })

  it('lets only Colin flip the switch, and nobody in the app can claim or record sends', async () => {
    await db.exec(`update public.campaign_control set sending_enabled = false`)
    await expect(as(THALIA, () => db.query('select public.set_sending(true)'))).rejects.toThrow(/only Colin/)
    await as(COLIN, () => db.query('select public.set_sending(true)'))
    const c = await db.query<{ sending_enabled: boolean; sending_changed_by: string }>(`select sending_enabled, sending_changed_by from public.campaign_control`)
    expect(c.rows[0]).toEqual({ sending_enabled: true, sending_changed_by: 'Colin' })
    await as(COLIN, async () => {
      await expect(db.query(`select public.claim_next_opener(false, now())`)).rejects.toThrow(/permission denied/)
      await expect(db.query(`select public.record_send_result(gen_random_uuid(), 'sent')`)).rejects.toThrow(/permission denied/)
      await expect(db.query(`update public.campaign_control set sending_enabled = false`)).rejects.toThrow(/permission denied/)
      await expect(db.query(`update public.planned_openers set send_status = 'planned'`)).rejects.toThrow(/permission denied/)
      expect((await db.query(`select sending_enabled from public.campaign_control`)).rows.length).toBe(1)
    })
  })
})
