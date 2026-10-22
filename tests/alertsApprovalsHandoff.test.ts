// Migration 0028 on the real migrations (PGlite): a caller sets the email and phone her hot pings go to,
// approves the day's texts and skips a draft, hands a viable card to Colin (task, note, ping), and logs a
// dial that reached nobody. Colin 2026-10-22: "Make a spot in settings to add emails for hot pings",
// "they approve the texts and drafts", "how do they hand me a good viable card?"
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, beforeEach, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'
import { HANDOFF_RE, alertText, type HotAlert } from '../supabase/functions/_shared/hotLeads'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')
const COLIN = { sub: '00000000-0000-0000-0000-00000000000c', email: 'colin@example.com' }
const THALIA = { sub: '00000000-0000-0000-0000-00000000000d', email: 'thalia@example.com' }
const LEAD = '00000000-0000-0000-0000-0000000000a1'

let db: PGlite
async function as<T>(who: { sub: string; email: string }, fn: () => Promise<T>): Promise<T> {
  await db.query(`select set_config('request.jwt.claims', $1, false)`, [JSON.stringify(who)])
  await db.exec('set role authenticated')
  try { return await fn() } finally { await db.exec('reset role') }
}
const rpc = async (fn: string, args: Record<string, unknown>) => {
  const names = Object.keys(args)
  const r = await db.query<{ r: unknown }>(`select public.${fn}(${names.map((n, i) => `${n} => $${i + 1}`).join(', ')}) as r`,
    names.map((n) => { const v = args[n]; return v !== null && typeof v === 'object' ? JSON.stringify(v) : v }))
  return r.rows[0]?.r
}
const one = async <T,>(sql: string, params: unknown[] = []) => (await db.query<T>(sql, params)).rows[0]

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
  await db.exec(`insert into public.team_members (email, role, person, display_name) values
    ('colin@example.com', 'owner', 'colin', 'Colin'), ('thalia@example.com', 'caller', 'thalia', 'Thalia')`)
})

beforeEach(async () => {
  await db.exec(`
    truncate public.hot_alerts, public.tasks, public.reply_drafts, public.opener_send_events, public.twilio_inbound, public.suppressed_phones,
             public.planned_openers, public.messages, public.contacts, public.leads cascade;
    update public.team_members set alert_phone = null, alert_email = null;
    insert into public.leads (id, wpie_owner_id, owner_name, property_address, municipality, stage) values
      ('${LEAD}', 77, 'JANE ROE', '100 N Main St', 'Milwaukee', 'reply_received');
    insert into public.contacts (lead_id, kind, value, value_normalized, status) values ('${LEAD}', 'phone', '4145550177', '4145550177', 'ok');
  `)
})

describe('Settings: where my hot pings go', () => {
  it('a caller sets her own email and phone, and the server lists her for emails', async () => {
    const r = await as(THALIA, () => rpc('set_my_alerts', { p_phone: '(414) 555-0199', p_email: 'Thalia@Example.com ' }))
    expect(r).toEqual({ ok: true, phone: '4145550199', email: 'thalia@example.com' })
    const row = await one<{ alert_phone: string; alert_email: string }>(`select alert_phone, alert_email from public.team_members where person = 'thalia'`)
    expect(row).toEqual({ alert_phone: '4145550199', alert_email: 'thalia@example.com' })
    expect(await rpc('alert_email_recipients', {})).toEqual([{ person: 'thalia', email: 'thalia@example.com' }])
    expect(await rpc('alert_recipients', {})).toEqual([{ person: 'thalia', phone: '+14145550199' }])
  })
  it('refuses a bad number or address and clears a field left blank', async () => {
    expect(await as(THALIA, () => rpc('set_my_alerts', { p_phone: '555', p_email: '' }))).toMatchObject({ ok: false, reason: /10 digits/ })
    expect(await as(THALIA, () => rpc('set_my_alerts', { p_phone: '', p_email: 'nope' }))).toMatchObject({ ok: false, reason: /not an email/ })
    await as(THALIA, () => rpc('set_my_alerts', { p_phone: '4145550199', p_email: 'thalia@example.com' }))
    expect(await as(THALIA, () => rpc('set_my_alerts', { p_phone: '', p_email: '' }))).toEqual({ ok: true, phone: null, email: null })
    expect(await rpc('alert_email_recipients', {})).toEqual([])
  })
})

describe('callers approve the texts and the drafts', () => {
  it('a caller approves the day and skips a draft', async () => {
    await db.exec(`insert into public.planned_openers (plan_date, wpie_owner_id, attempt, lead_id, lane, template_lane, variant, phone, body, segments, scheduled_at, decision, send_status)
      values ('2026-10-23', 77, 1, '${LEAD}', 'flip', 'flip', 'A', '+14145550177', 'Hi Jane, Colin Merrill here. Still yours? Reply STOP', 1, '2026-10-23T15:00:00Z', 'pending', 'planned')`)
    const r = await as(THALIA, () => rpc('approve_day', { p_date: '2026-10-23', p_except: '{}' }))
    expect(r).toEqual({ approved: 1, skipped: 0 })
    expect(await one<{ decided_by_name: string }>(`select decided_by_name from public.planned_openers`)).toEqual({ decided_by_name: 'Thalia' })
    await db.exec(`insert into public.twilio_inbound (sid, from10, to_number, body, received_at) values ('SMq', '4145550177', '+12629996513', 'Maybe', '2026-10-22T16:00:00Z');
      insert into public.reply_drafts (inbound_sid, phone10, our_number, lead_id, inbound_body, inbound_at, intent, kind, outcome, status, draft_source, created_at, updated_at)
      values ('SMq', '4145550177', '+12629996513', '${LEAD}', 'Maybe', '2026-10-22T16:00:00Z', 'interested', 'candidate', 'open', 'awaiting_approval', 'claude', now(), now())`)
    const draftId = (await one<{ id: string }>(`select id from public.reply_drafts`)).id
    await as(THALIA, () => rpc('skip_reply', { p_id: draftId }))
    expect(await one<{ status: string; decided_by: string }>(`select status, decided_by from public.reply_drafts`)).toEqual({ status: 'skipped', decided_by: 'Thalia' })
  })
})

describe('handing Colin a viable card', () => {
  it('assigns him, opens his task with her line, notes the thread, and queues a ping that reads as a hand-off', async () => {
    const r = await as(THALIA, () => rpc('handoff_to_colin', { p_lead_id: LEAD, p_note: 'Motivated: job in Madison in 30 days, just her, number rests on the payoff' })) as { ok: boolean; task_id: string }
    expect(r.ok).toBe(true)
    const lead = await one<{ assigned_to: string; stage: string; belt: string; next_stop_who: string }>(`select assigned_to::text, stage::text, belt, next_stop_who from public.leads where id = '${LEAD}'`)
    expect(lead).toMatchObject({ assigned_to: 'colin', belt: 'call_booked', next_stop_who: 'colin_call' })
    expect(['colin_call', 'handoff', 'reply_received']).toContain(lead.stage)
    // one open stop, Colin's, titled with her line; no stop left for the caller
    const tasks = (await db.query<{ owner: string; kind: string; source: string; title: string; note: string; done_at: string | null }>(
      `select owner::text, kind, source, title, note, done_at from public.tasks order by created_at`)).rows
    const open = tasks.filter((t) => !t.done_at)
    expect(open).toHaveLength(1)
    expect(open[0]).toMatchObject({ owner: 'colin', kind: 'call', source: 'belt', title: 'From Thalia: worth a look' })
    expect(open[0].note).toContain('Thalia says: Motivated: job in Madison')
    expect(await one<{ body: string; seen: boolean }>(`select body, seen_at is not null as seen from public.messages where channel = 'note'`))
      .toMatchObject({ body: 'Handed to Colin by Thalia: Motivated: job in Madison in 30 days, just her, number rests on the payoff', seen: true })
    const hot = await one<{ body: string; first_name: string; address: string; phone10: string }>(`select body, first_name, address, phone10 from public.hot_alerts`)
    expect(hot).toMatchObject({ first_name: 'Jane', address: '100 N Main St', phone10: '4145550177' })
    expect(HANDOFF_RE.test(hot.body)).toBe(true)
    const text = alertText({ id: 'x', n: 1, lead_id: LEAD, phone10: hot.phone10, first_name: hot.first_name, address: hot.address, body: hot.body, is_test: false } as HotAlert,
      'https://deals.junkcarsmequon.com')
    expect(text).toMatch(/^HANDED TO YOU: Jane, 100 N Main St\. Thalia: "Motivated/)
    expect(text).toContain('Call: (414) 555-0177')
    expect(text).toContain(`/lead/${LEAD}?call=1`)
  })
  it('needs one line; a second hand-off of the same card pings again and leaves one open stop, not an error', async () => {
    expect(await as(THALIA, () => rpc('handoff_to_colin', { p_lead_id: LEAD, p_note: '  ' }))).toMatchObject({ ok: false })
    await as(THALIA, () => rpc('handoff_to_colin', { p_lead_id: LEAD, p_note: 'first', p_now: '2026-10-22T20:00:00Z' }))
    await as(THALIA, () => rpc('handoff_to_colin', { p_lead_id: LEAD, p_note: 'second', p_now: '2026-10-22T21:00:00Z' }))
    expect((await db.query(`select 1 from public.hot_alerts`)).rows.length).toBe(2)
    expect((await db.query(`select 1 from public.tasks where done_at is null and owner = 'colin'`)).rows.length).toBe(1)
    // the caller's own open stop on that card is closed by the hand-off, not counted against her
    await db.query(`insert into public.tasks (lead_id, due_at, kind, owner, source, source_key, note) values ('${LEAD}', now(), 'call', 'thalia', 'call_list', 'calls:x', 'dial')`)
    await as(THALIA, () => rpc('handoff_to_colin', { p_lead_id: LEAD, p_note: 'third', p_now: '2026-10-22T22:00:00Z' }))
    expect(await one<{ note: string }>(`select note from public.tasks where source_key = 'calls:x' and done_at is not null`)).toMatchObject({ note: 'dial [handed to Colin]' })
  })
})

describe('logging a dial', () => {
  it('no answer logs the call and leaves the card where it was; reached with no decision parks it on Colin', async () => {
    expect(await as(THALIA, () => rpc('log_call', { p_lead_id: LEAD, p_phone: '4145550177', p_outcome: 'no_answer', p_note: 'voicemail left' }))).toEqual({ ok: true, outcome: 'no_answer' })
    // log_call itself leaves the stage alone on a no-answer; the belt (0031) may advance the card a rung, never close it
    expect(['reply_received', 'colin_call', 'ai_qualifying']).toContain((await one<{ stage: string }>(`select stage::text from public.leads`)).stage)
    expect(await one<{ body: string; status: string }>(`select body, status from public.messages where channel = 'call'`))
      .toEqual({ body: 'Call (Thalia) from 4145550177: No answer\nvoicemail left', status: 'no_answer' })
    expect(await as(THALIA, () => rpc('log_call', { p_lead_id: LEAD, p_phone: null, p_outcome: 'reached_no_decision', p_note: null }))).toEqual({ ok: true, outcome: 'reached_no_decision' })
    expect(await one<{ stage: string }>(`select stage::text from public.leads`)).toEqual({ stage: 'colin_call' })
    expect(await as(THALIA, () => rpc('log_call', { p_lead_id: LEAD, p_phone: null, p_outcome: 'busy', p_note: null }))).toMatchObject({ ok: false })
  })
})
