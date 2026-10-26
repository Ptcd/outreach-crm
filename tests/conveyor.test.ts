// The conveyor on the real migrations (PGlite): the belt table, the caps, never before a named date,
// nothing to dead or DNC, elderly gets phone only, Sunday and quiet-hour sliding, a human text cancels
// a pending automatic text, a logged outcome schedules the next stop, the templates pass the price block,
// the health invariants, the canary and the one-off backfill.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, beforeEach, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'
import { findPriceOrOffer, guardDraft } from '../supabase/functions/_shared/replyGuard'
import { BELT_LABEL, STOP_OUTCOMES, WHO_LABEL, beltLine } from '../src/lib/belts'
import { runConveyor } from '../supabase/functions/_shared/conveyor'
import type { Rpc } from '../supabase/functions/_shared/sending'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')
const THALIA = { sub: '00000000-0000-0000-0000-00000000000a', email: 'thalia@example.com' }
const COLIN = { sub: '00000000-0000-0000-0000-00000000000c', email: 'colin@example.com' }
const A = '00000000-0000-0000-0000-0000000000a1'
const NOW = '2026-10-22T17:00:00Z'               // Thursday, noon Central
let db: PGlite

const one = async <T = Record<string, unknown>>(sql: string, params: unknown[] = []) => (await db.query<T>(sql, params)).rows[0]
const lead = async () => one<{ belt: string | null; belt_step: number; next_stop_who: string | null; next_stop_at: string | null; stage: string
  unanswered_count: number; next_stop_say: string | null; named_date: string | null; next_action: string | null }>(
  `select belt, belt_step, next_stop_who, to_char(next_stop_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') as next_stop_at, stage::text, unanswered_count, next_stop_say,
          to_char(named_date at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') as named_date, next_action from public.leads where id = $1`, [A])
const ev = async (event: string, payload: Record<string, unknown> = {}, at = NOW) =>
  (await one<{ r: Record<string, unknown> }>(`select public.belt_event($1, $2, $3::jsonb, 'test', $4::timestamptz) as r`, [A, event, JSON.stringify(payload), at])).r
const openTasks = async () => (await db.query<{ owner: string; kind: string; due_at: string; title: string; source_key: string }>(
  `select owner::text, kind, to_char(due_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') as due_at, title, source_key from public.tasks where lead_id = $1 and done_at is null order by due_at`, [A])).rows
const drafts = async () => (await db.query<{ status: string; body: string | null; kind: string; draft_source: string | null }>(
  `select status, body, kind, draft_source from public.reply_drafts where lead_id = $1 order by created_at`, [A])).rows
const central = (iso: string) => new Date(iso).toLocaleString('en-US', { timeZone: 'America/Chicago', weekday: 'short', hour: 'numeric', minute: '2-digit', hour12: false })

async function as<T>(who: { sub: string; email: string }, fn: () => Promise<T>): Promise<T> {
  await db.query(`select set_config('request.jwt.claims', $1, false)`, [JSON.stringify(who)])
  await db.exec('set role authenticated')
  try { return await fn() } finally { await db.exec('reset role'); await db.query(`select set_config('request.jwt.claims', '', false)`) }
}
const rpc: Rpc = async (fn, args) => {
  const names = Object.keys(args)
  const params = names.map((n) => { const v = args[n]; return v !== null && typeof v === 'object' ? JSON.stringify(v) : v })
  const call = `public.${fn}(${names.map((n, i) => `${n} => $${i + 1}`).join(', ')})`
  try {
    if (fn === 'belt_due_texts') return { data: (await db.query(`select * from ${call}`, params)).rows, error: null }   // a set, as PostgREST returns it
    const r = await db.query<{ r: unknown }>(`select ${call} as r`, params)
    return { data: r.rows[0]?.r, error: null }
  } catch (e) { return { data: null, error: { message: String(e) } } }
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
    truncate public.belt_events, public.belt_direct_writes, public.belt_health, public.belt_alerts_sent, public.hot_alerts, public.tasks,
             public.reply_drafts, public.reply_threads, public.twilio_inbound, public.suppressed_phones, public.planned_openers, public.messages,
             public.contacts, public.leads cascade;
    update public.touch_templates set enabled = false;
    update public.campaign_control set test_phones = '{2627770909}';
    insert into public.leads (id, wpie_owner_id, owner_name, property_address, municipality, mailing_state, lane, stage) values
      ('${A}', 77, 'JANE ROE', '100 N MAIN ST, Milwaukee', 'Milwaukee', 'WI', 'flip', 'opener_sent');
    insert into public.contacts (lead_id, kind, value, value_normalized, line_type) values ('${A}', 'phone', '4145550177', '4145550177', 'mobile');
  `)
})

describe('the belt table', () => {
  it('every belt with stops has a ladder no longer than its cap, and every text stop names a template', async () => {
    const belts = (await db.query<{ belt: string; max_unanswered: number; then_belt: string | null; stage: string | null; n: number }>(
      `select r.belt, r.max_unanswered, r.then_belt, r.stage::text, (select count(*)::int from public.belt_steps s where s.belt = r.belt) as n
         from public.belt_rules r order by r.belt`)).rows
    expect(belts.map((b) => b.belt).sort()).toEqual(['after_call_quiet', 'after_visit_quiet', 'call_booked', 'call_missed', 'cold_texts', 'dead', 'dnc', 'dormant',
      'elderly', 'estate_waiting', 'hold_not_now', 'needs_family', 'not_now_condition', 'not_now_dated', 'offer_out', 'questions_quiet', 'replied_quiet',
      'too_high_or_listed', 'visit_booked', 'visit_missed', 'yes_unbooked'])
    for (const b of belts) {
      if (['dead', 'dnc', 'too_high_or_listed'].includes(b.belt)) expect(b.n).toBe(0)
      else expect(b.n).toBeGreaterThan(0)
      expect(b.n).toBeLessThanOrEqual(Math.max(b.max_unanswered, 2))
    }
    expect(belts.find((b) => b.belt === 'yes_unbooked')!.max_unanswered).toBe(4)      // the one belt allowed four
    expect(belts.find((b) => b.belt === 'replied_quiet')!.max_unanswered).toBe(3)
    const texts = (await db.query<{ belt: string; step: number; template_key: string | null; key: string | null }>(
      `select s.belt, s.step, s.template_key, t.key from public.belt_steps s left join public.touch_templates t on t.key = s.template_key
        where s.who in ('auto_text', 'draft_text') and s.belt <> 'cold_texts'`)).rows
    expect(texts.every((t) => t.key)).toBe(true)
    // the channel changes before a repeat: no belt has two texts in a row (cold texts are WPIE's and excepted)
    const steps = (await db.query<{ belt: string; step: number; who: string }>(`select belt, step, who from public.belt_steps where belt not in ('cold_texts', 'dormant') order by belt, step`)).rows
    for (let i = 1; i < steps.length; i++) {
      if (steps[i].belt !== steps[i - 1].belt) continue
      const text = (w: string) => w === 'auto_text' || w === 'draft_text'
      expect(text(steps[i].who) && text(steps[i - 1].who)).toBe(false)
    }
    // elderly never gets a text
    expect(steps.filter((s) => s.belt === 'elderly').every((s) => s.who === 'colin_call')).toBe(true)
    expect(BELT_LABEL.yes_unbooked).toBe('Said yes, not booked')
    expect(Object.keys(WHO_LABEL).sort()).toEqual(['auto_text', 'colin_call', 'colin_visit', 'draft_text', 'thalia_call'])
    expect(STOP_OUTCOMES.map((o) => o.id)).toContain('no_answer')
  })

  it('every template is Colin in the first person with the STOP line and passes the price block', async () => {
    const rows = (await db.query<{ key: string; wording: string; enabled: boolean }>(`select key, wording, enabled from public.touch_templates`)).rows
    expect(rows.length).toBeGreaterThanOrEqual(14)
    for (const r of rows) {
      expect(r.enabled).toBe(false)                                        // every switch starts OFF
      const t = r.wording.replace('{street}', 'N Main St').replace('{time}', '2:00 PM').replace('{event}', 'the tenant moving out')
        .replace('{condition}', 'the tenant moving out').replace('{name}', 'your sister').replace('{said}', 'the roof quote')
      expect(t).toMatch(/STOP/)
      expect(t).toMatch(/Colin/)
      expect(t).not.toMatch(/\b(cash|offer|investor|contract|Merrill Holdings|Sam|postcard|urgent|last chance|deadline)\b/i)
      expect(findPriceOrOffer(t)).toEqual([])
      const g = guardDraft(t, { companyName: 'Merrill Holdings', maxChars: 480 })
      expect(g.violations.filter((v) => v !== 'too_long')).toEqual([])
      expect(t.length).toBeLessThanOrEqual(300)
    }
  })
})

describe('sliding', () => {
  const slide = async (at: string, kind: 'text' | 'call', hour: number | null = null) =>
    (await one<{ r: string }>(`select public.belt_slide($1::timestamptz, 'America/Chicago', $2, $3) as r`, [at, kind, hour])).r
  it('never Sunday, never before 8am (texts 9am), never after 8pm, never earlier', async () => {
    expect(central(await slide('2026-10-25T18:00:00Z', 'text'))).toBe('Mon 09:00')       // Sunday 1 PM -> Monday 9 AM
    expect(central(await slide('2026-10-24T20:30:00Z', 'text'))).toBe('Sat 15:30')       // Saturday 3:30 PM stays
    expect(central(await slide('2026-10-25T02:30:00Z', 'text'))).toBe('Mon 09:00')       // Saturday 9:30 PM -> Monday (Sunday skipped)
    expect(central(await slide('2026-10-22T11:30:00Z', 'call'))).toBe('Thu 08:00')       // 6:30 AM -> 8 AM
    expect(central(await slide('2026-10-22T11:30:00Z', 'call', 14))).toBe('Thu 14:00')   // a day-anchored call at 2 PM
    expect(central(await slide('2026-10-25T11:30:00Z', 'call', 9))).toBe('Mon 09:00')    // Sunday 9 AM -> Monday 9 AM
  })
})

describe('the belts move cards', () => {
  it('interest puts the card on "said yes, not booked" with Thalia\'s call now, and a text in resets the unanswered count', async () => {
    await db.query(`update public.leads set unanswered_count = 2 where id = $1`, [A])
    const r = await ev('inbound_text', { intent: 'interested', kind: 'candidate', outcome: 'open', said: 'yes call me', interest: true })
    expect(r).toMatchObject({ ok: true, belt: 'yes_unbooked', step: 1, next_stop_who: 'thalia_call' })
    const l = await lead()
    expect(l).toMatchObject({ belt: 'yes_unbooked', belt_step: 1, unanswered_count: 0, stage: 'reply_received' })
    expect(l.next_stop_say).toBe('You asked for a call about 100 N Main St')
    expect(beltLine({ belt: 'yes_unbooked', belt_step: 1, next_stop_who: 'thalia_call', next_stop_at: l.next_stop_at, next_stop_say: l.next_stop_say }, 4))
      .toMatch(/^On belt: Said yes, not booked · stop 1 of 4 · next: Thalia or Adil calls .* · say: "You asked for a call about 100 N Main St"$/)
    const t = await openTasks()
    expect(t).toHaveLength(1)
    expect(t[0]).toMatchObject({ owner: 'thalia', kind: 'call', title: 'Said yes, not booked: stop 1 of 4' })
    expect(t[0].source_key).toBe(`belt:${A}:yes_unbooked:1:1`)
  })

  it('a logged outcome schedules the next stop: no answer -> the "just tried you" text an hour later; then a call at another hour band; then dormant', async () => {
    await ev('inbound_text', { intent: 'interested', interest: true })
    const [t1] = await openTasks()
    const t1id = (await one<{ id: string }>(`select id from public.tasks where source_key = $1`, [t1.source_key])).id
    const done = await as(THALIA, () => one<{ r: Record<string, unknown> }>(`select public.belt_stop_done($1, 'no_answer', 'rang out') as r`, [t1id]))
    expect(done.r).toMatchObject({ ok: true, belt: 'yes_unbooked', step: 2, next_stop_who: 'auto_text' })
    expect((await db.query(`select 1 from public.messages where lead_id = $1 and channel = 'call' and status = 'no_answer'`, [A])).rows).toHaveLength(1)
    // the same at a fixed clock: the text is one hour after the no-answer
    await db.query(`update public.leads set belt_step = 1 where id = $1`, [A])
    await ev('stop_done', { outcome: 'no_answer' })
    let l = await lead()
    expect(l.unanswered_count).toBe(2)
    expect(new Date(l.next_stop_at!).getTime() - new Date(NOW).getTime()).toBe(3600_000)
    await db.query(`update public.leads set unanswered_count = 1 where id = $1`, [A])      // the repeat above was the same stop
    // the text goes (dry; the switch is forced as the canary does), then stop 3 is a call at the other band
    const c = (await one<{ r: Record<string, unknown> }>(`select public.belt_claim_text($1, true, true, $2::timestamptz) as r`, [A, l.next_stop_at])).r
    expect(c).toMatchObject({ outcome: 'dry_sent' })
    expect(String(c.body)).toMatch(/^Colin here, we just tried calling you about 100 N Main St\./)
    l = await lead()
    expect(l).toMatchObject({ belt: 'yes_unbooked', belt_step: 3, next_stop_who: 'thalia_call', unanswered_count: 2 })
    const [t3] = await openTasks()
    expect(central(t3.due_at)).toMatch(/Sat (10|15):00/)   // +2 days, a different band than the noon call
    // no answer again -> the +14 door-open text; a fourth silence -> dormant (cap of four)
    await ev('stop_done', { outcome: 'voicemail', task_id: (await one<{ id: string }>(`select id from public.tasks where source_key = $1`, [t3.source_key])).id })
    l = await lead()
    expect(l).toMatchObject({ belt: 'yes_unbooked', belt_step: 4, next_stop_who: 'auto_text', unanswered_count: 3 })
    await ev('auto_text_sent', {})
    l = await lead()
    expect(l).toMatchObject({ belt: 'dormant', belt_step: 1, next_stop_who: 'draft_text', unanswered_count: 0 })
    expect(new Date(l.next_stop_at!).getTime() - new Date(NOW).getTime()).toBeGreaterThanOrEqual(90 * 86400_000)
    const events = (await db.query<{ event: string; to_belt: string }>(`select event, to_belt from public.belt_events where lead_id = $1 order by id`, [A])).rows
    expect(events.map((e) => e.event)).toEqual(['inbound_text', 'stop_done', 'stop_done', 'auto_text_sent', 'stop_done', 'stops_ran_out', 'stops_ran_out'])
  })

  it('a booked call gets a morning-of reminder and the call at the slot; a miss goes to the missed ladder; a second miss goes dormant', async () => {
    const slot = '2026-10-23T19:00:00Z'                                     // Friday 2 PM Central
    const r = await as(THALIA, () => one<{ r: Record<string, unknown> }>(`select public.call_answer($1, 'next_step', '{"kind":"callback","at":"${slot}"}') as r`, [A]))
    expect(r.r).toMatchObject({ ok: true, belt: 'call_booked' })
    let l = await lead()
    expect(l).toMatchObject({ belt: 'call_booked', belt_step: 1, next_stop_who: 'auto_text', stage: 'colin_call', next_action: 'Call booked' })
    expect(central(l.next_stop_at!)).toBe('Fri 08:30')
    expect(l.named_date).toBeTruthy()
    expect((await openTasks()).map((t) => `${t.kind} ${t.owner} ${t.title}`)).toEqual(['call thalia Call booked: stop 2 of 2'])
    // the reminder went: step 2 is the call at the slot, Thalia's (the card is hers)
    await ev('auto_text_sent', {}, '2026-10-23T13:31:00Z')
    l = await lead()
    expect(l).toMatchObject({ belt: 'call_booked', belt_step: 2, next_stop_who: 'thalia_call' })
    expect(l.next_stop_at).toBe('2026-10-23T19:00:00Z')
    // missed at the slot: one more try in 45 minutes, then the "missed each other" text an hour after
    await ev('stop_done', { outcome: 'no_answer' }, slot)
    l = await lead()
    expect(l).toMatchObject({ belt: 'call_missed', belt_step: 1, next_stop_who: 'thalia_call' })
    expect(new Date(l.next_stop_at!).getTime() - new Date(slot).getTime()).toBe(45 * 60_000)
    await ev('stop_done', { outcome: 'no_answer' }, '2026-10-23T19:45:00Z')
    l = await lead()
    expect(l).toMatchObject({ belt: 'call_missed', belt_step: 2, next_stop_who: 'auto_text' })
    // they rebook, then miss again: straight to dormant
    await ev('next_step', { kind: 'callback', at: '2026-10-26T19:00:00Z' }, '2026-10-23T21:00:00Z')
    await ev('auto_text_sent', {}, '2026-10-26T13:31:00Z')
    await ev('stop_done', { outcome: 'no_answer' }, '2026-10-26T19:00:00Z')
    expect((await lead()).belt).toBe('dormant')
  })

  it('a walk-through booked is Colin\'s visit; the visit kept moves to "after the visit"; a verdict of don\'t book routes by its reason', async () => {
    await as(COLIN, () => one(`select public.call_answer($1, 'next_step', '{"kind":"walk","at":"2026-10-24T18:00:00Z"}') as r`, [A]))
    let l = await lead()
    expect(l).toMatchObject({ belt: 'visit_booked', stage: 'walkthrough_booked', next_action: 'Walk-through', next_stop_who: 'auto_text' })
    // the reminder's switch is off: it is skipped, never a draft, and the visit itself is the stop
    expect((await one<{ r: Record<string, unknown> }>(`select public.belt_claim_text($1, true, false, $2::timestamptz) as r`, [A, l.next_stop_at])).r)
      .toMatchObject({ outcome: 'skipped', reason: 'reminder switch is off' })
    const t = await openTasks()
    expect(t.map((x) => x.kind)).toEqual(['visit'])
    expect(t[0].owner).toBe('colin')
    await ev('stop_done', { outcome: 'reached', said: 'wants to think about the roof' }, '2026-10-24T18:40:00Z')
    l = await lead()
    expect(l).toMatchObject({ belt: 'after_visit_quiet', belt_step: 1, next_stop_who: 'colin_call' })
    expect(l.next_stop_say).toMatch(/think 100 N Main St over/)
    await as(THALIA, () => one(`select public.verdict_no($1, 'market_firm', 'Zillow number, will not hear under') as r`, [A]))
    l = await lead()
    expect(l).toMatchObject({ belt: 'too_high_or_listed', next_stop_at: null, next_stop_who: null, stage: 'follow_up' })
    expect(await openTasks()).toEqual([])
  })

  it('not now with a date: no seller contact before the exact date, then one +7 retry', async () => {
    const r = await as(THALIA, () => one<{ r: Record<string, unknown> }>(
      `select public.log_call($1, '4145550177', 'not_now', 'after the tenant moves out, mid November') as r`, [A]))
    expect(r.r).toMatchObject({ ok: true })
    expect((await lead()).belt).toBe('not_now_condition')                                 // no date given: a condition
    await ev('named_date', { named_date: '2026-11-16T18:00:00Z', named_event: 'the tenant moving out' })
    let l = await lead()
    expect(l).toMatchObject({ belt: 'not_now_dated', belt_step: 1, next_stop_who: 'colin_call' })
    expect(new Date(l.next_stop_at!).getTime()).toBeGreaterThanOrEqual(new Date('2026-11-16T18:00:00Z').getTime())
    expect(l.next_stop_say).toBe('You mentioned the tenant moving out for 100 N Main St; how did it go?')
    await ev('stop_done', { outcome: 'no_answer' }, '2026-11-16T20:00:00Z')
    l = await lead()
    expect(l.belt_step).toBe(2)
    expect(l.next_stop_at!.slice(0, 10)).toBe('2026-11-23')
    // A near date follows the same quiet rule: the first and only initial stop is the call.
    await db.query(`update public.leads set belt = null, belt_step = 0 where id = $1`, [A])
    await ev('named_date', { named_date: '2026-10-24T18:00:00Z', named_event: 'the closing' }, NOW)
    l = await lead()
    expect(l).toMatchObject({ belt: 'not_now_dated', belt_step: 1, next_stop_who: 'colin_call' })
    expect(new Date(l.next_stop_at!).getTime()).toBeGreaterThanOrEqual(new Date('2026-10-24T18:00:00Z').getTime())
  })

  it('STOP is final: nothing moves a DNC card, no text is ever claimed for it, and dead gets no text either', async () => {
    await ev('inbound_text', { intent: 'interested', interest: true })
    await ev('stop', { said: 'STOP' })
    let l = await lead()
    expect(l).toMatchObject({ belt: 'dnc', stage: 'dnc', next_stop_at: null })
    expect(await openTasks()).toEqual([])
    expect((await ev('inbound_text', { intent: 'interested', interest: true }))).toMatchObject({ belt: 'dnc', ignored: true })
    expect((await ev('hot_reply', {}))).toMatchObject({ belt: 'dnc', ignored: true })
    l = await lead()
    expect(l.belt).toBe('dnc')
    await db.query(`update public.leads set next_stop_who = 'auto_text', next_stop_at = $2, belt_step = 1 where id = $1`, [A, NOW])
    const c = (await one<{ r: Record<string, unknown> }>(`select public.belt_claim_text($1, true, true, $2::timestamptz) as r`, [A, NOW])).r
    expect(c.outcome).toBe('skipped')
    expect(await drafts()).toEqual([])
    await db.query(`update public.leads set belt = 'dead', stage = 'dead', next_stop_who = 'auto_text', next_stop_at = $2, belt_step = 1 where id = $1`, [A, NOW])
    expect((await one<{ r: Record<string, unknown> }>(`select public.belt_claim_text($1, true, true, $2::timestamptz) as r`, [A, NOW])).r.outcome).toBe('skipped')
    expect(await drafts()).toEqual([])
  })

  it('an elderly, ill or grieving owner gets Colin only, by phone, mornings; every pending text is cancelled', async () => {
    await ev('inbound_text', { intent: 'interested', interest: true })
    await ev('stop_done', { outcome: 'no_answer' })
    expect((await lead()).next_stop_who).toBe('auto_text')
    const r = await as(THALIA, () => one<{ r: Record<string, unknown> }>(`select public.lead_move($1, null, 'her son says she is unwell', null, null, true, null) as r`, [A]))
    expect(r.r).toMatchObject({ ok: true, belt: 'elderly', next_stop_who: 'colin_call' })
    const l = await lead()
    expect(central(l.next_stop_at!)).toMatch(/09:00$/)
    expect(await drafts()).toEqual([])
    const t = await openTasks()
    expect(t).toHaveLength(1)
    expect(t[0].owner).toBe('colin')
    await db.query(`update public.leads set next_stop_who = 'auto_text' where id = $1`, [A])
    expect((await one<{ r: Record<string, unknown> }>(`select public.belt_claim_text($1, true, true, $2::timestamptz) as r`, [A, NOW])).r)
      .toMatchObject({ outcome: 'skipped', reason: 'no texts to an elderly, ill or grieving owner' })
    // the steps are phone only and the card never gets a text stop again
    expect((await lead()).next_stop_who).toBe('colin_call')
  })

  it('a human text cancels the pending automatic text and the card moves on to its next stop', async () => {
    await ev('inbound_text', { intent: 'maybe', kind: 'candidate', outcome: 'open', said: 'depends' })
    let l = await lead()
    expect(l).toMatchObject({ belt: 'replied_quiet', belt_step: 1, next_stop_who: 'auto_text' })
    // the conveyor would make it a draft (switch off): a row waiting for a tap, and a task saying so
    const c = (await one<{ r: Record<string, unknown> }>(`select public.belt_claim_text($1, true, false, $2::timestamptz) as r`, [A, l.next_stop_at])).r
    expect(c.outcome).toBe('awaiting_approval')
    expect((await drafts())[0]).toMatchObject({ status: 'awaiting_approval', kind: 'belt', draft_source: 'belt_draft' })
    expect((await openTasks())[0].title).toMatch(/tap to send/)
    // Colin texts from the app himself: the draft is superseded, the card goes to stop 2 (Thalia's call)
    await db.query(`select public.log_email($1, null, 'jane@example.com', 'About N Main St', 'Hi Jane, here is the info', 'Colin')`, [A])
    expect((await drafts())[0].status).toBe('superseded')
    l = await lead()
    expect(l).toMatchObject({ belt: 'replied_quiet', belt_step: 2, next_stop_who: 'thalia_call' })
  })

  it('a text from them since the stop was set skips the stop; the switch on sends it (dry) through the conveyor', async () => {
    await ev('inbound_text', { intent: 'maybe', kind: 'candidate', outcome: 'open' })
    const l = await lead()
    await db.query(`insert into public.twilio_inbound (sid, from10, to_number, body, lead_id, received_at) values ('SMlate', '4145550177', '+12629996513', 'actually yes', $1, $2)`,
      [A, new Date(new Date(NOW).getTime() + 60_000).toISOString()])
    expect((await one<{ r: Record<string, unknown> }>(`select public.belt_claim_text($1, true, false, $2::timestamptz) as r`, [A, l.next_stop_at])).r)
      .toMatchObject({ outcome: 'skipped', reason: 'they wrote since this stop was set' })
    // a fresh card with the switch on: the conveyor records a dry send and the belt steps on
    await db.query(`delete from public.twilio_inbound`)
    await db.query(`update public.touch_templates set enabled = true where key = 'replied_reask'`)
    await ev('inbound_text', { intent: 'maybe', kind: 'candidate', outcome: 'open' })
    const due = (await lead()).next_stop_at!
    const s = await runConveyor({ rpc, live: false, twilio: null, canary: false, now: () => new Date(new Date(due).getTime() + 60_000) })
    if (s.texts.dry_sent !== 1) console.log(JSON.stringify(s))
    expect(s.texts).toMatchObject({ dry_sent: 1 })
    expect(s.health.ok).toBe(false)                                          // the canary has not run yet
    expect(await lead()).toMatchObject({ belt: 'replied_quiet', belt_step: 2, next_stop_who: 'thalia_call', unanswered_count: 1 })
    const d = await drafts()
    expect(d[d.length - 1]).toMatchObject({ status: 'dry_sent', draft_source: 'belt_auto' })
  })

  it('a call logged from the script moves the card through its call row: no answer counts, reached with no decision plants Colin\'s +3 call', async () => {
    await ev('inbound_text', { intent: 'interested', interest: true })
    // log_call (0013 / 0028) writes one call row with status = the outcome; the belt hooks that row
    const log = (o: string) => as(THALIA, () => one<{ r: Record<string, unknown> }>(`select public.log_call($1, '4145550177', $2, null) as r`, [A, o]))
    const row = (o: string) => db.query(`insert into public.messages (lead_id, direction, channel, body, from_number, sent_at, seen_at, status)
      values ($1, 'in', 'call', 'Call (Thalia) from 4145550177: ' || $2, '+14145550177', now(), now(), $2)`, [A, o])
    await row('no_answer')
    expect((await lead())).toMatchObject({ belt: 'yes_unbooked', belt_step: 2, unanswered_count: 1 })
    expect((await db.query(`select 1 from public.belt_direct_writes`)).rows).toHaveLength(0)
    await row('reached_no_decision')
    expect((await lead())).toMatchObject({ belt: 'after_call_quiet', next_stop_who: 'colin_call', unanswered_count: 0, stage: 'follow_up' })
    expect((await log('interested')).r).toMatchObject({ ok: true })
    expect((await lead())).toMatchObject({ belt: 'yes_unbooked', stage: 'colin_call' })
    expect((await log('not_now')).r).toMatchObject({ ok: true })
    expect((await lead())).toMatchObject({ belt: 'not_now_condition', stage: 'follow_up' })
    expect((await log('wrong_number')).r).toMatchObject({ ok: true })
    expect((await lead())).toMatchObject({ belt: null, stage: 'data_fix', next_stop_at: null })
    expect((await log('dnc')).r).toMatchObject({ ok: true })
    expect((await lead())).toMatchObject({ belt: 'dnc', stage: 'dnc' })
    // log_call's own stage writes in that transaction are the belt's doing, never flagged
    expect((await db.query(`select 1 from public.belt_direct_writes`)).rows).toHaveLength(0)
  })

  it('the reply agent\'s rows move the card through triggers: a draft, a nurture, a hot reply, a synced thread, a STOP', async () => {
    await db.query(`insert into public.twilio_inbound (sid, from10, to_number, body, lead_id, received_at) values ('SM1', '4145550177', '+12629996513', 'maybe', $1, $2)`, [A, NOW])
    await db.query(`insert into public.reply_drafts (inbound_sid, phone10, our_number, lead_id, inbound_body, inbound_at, intent, kind, outcome, body, draft_source, status)
      values ('SM1', '4145550177', '+12629996513', $1, 'maybe', $2, 'statement', 'candidate', 'open', 'Thanks', 'claude', 'awaiting_approval')`, [A, NOW])
    expect(await lead()).toMatchObject({ belt: 'replied_quiet', belt_step: 1, stage: 'reply_received' })
    // the drafter's facts arrive: a conditional no becomes "not now, with a condition"
    await db.query(`update public.reply_drafts set facts = '{"nurture": true, "condition": "once my tenant is out"}' where inbound_sid = 'SM1'`)
    expect(await lead()).toMatchObject({ belt: 'not_now_condition', belt_step: 1, next_stop_who: 'draft_text' })
    expect((await lead()).next_stop_say).toBe('You mentioned once my tenant is out for 100 N Main St; any movement?')
    // a hot reply
    await db.query(`insert into public.hot_alerts (inbound_sid, lead_id, phone10, body) values ('SM1', $1, '4145550177', 'yes what would you pay')`, [A])
    expect(await lead()).toMatchObject({ belt: 'yes_unbooked', next_stop_who: 'thalia_call' })
    // the laptop's thread says the owner booked a slot
    await db.query(`insert into public.reply_threads (phone10, lead_id, wpie_owner_id, agent_stage, outcome, callback_slot, last_inbound_at, last_inbound)
      values ('4145550177', $1, 77, 'book', 'handoff', '2026-10-23T20:00:00Z', $2, 'tomorrow 3pm')`, [A, NOW])
    expect(await lead()).toMatchObject({ belt: 'call_booked', belt_step: 1 })
    // a synced STOP
    await db.query(`insert into public.messages (lead_id, direction, channel, body, is_opt_out, sent_at, source_key) values ($1, 'in', 'sms', 'STOP', true, now(), 'ledger:77:1:opted_out')`, [A])
    expect(await lead()).toMatchObject({ belt: 'dnc', stage: 'dnc' })
  })

  it('a new WPIE record re-enters a dormant card with one Colin call that references the conversation, never the record; a live card is left alone', async () => {
    await ev('move', { belt: 'dormant' })
    const r = (await one<{ r: Record<string, unknown> }>(`select public.belt_wpie_event(77, 'tax_delinquent', '2026 delinquent', 'ev-1') as r`)).r
    expect(r).toMatchObject({ ok: true, belt: 'after_call_quiet', next_stop_who: 'colin_call' })
    expect((await lead()).next_stop_say).toMatch(/We spoke before about 100 N Main St/)
    expect((await openTasks())[0].title).toMatch(/After the call/)
    expect((await one<{ r: Record<string, unknown> }>(`select public.belt_wpie_event(77, 'tax_delinquent', '2026 delinquent', 'ev-1') as r`)).r).toMatchObject({ duplicate: true })
    expect((await one<{ r: Record<string, unknown> }>(`select public.belt_wpie_event(77, 'code_violation', 'raze', 'ev-2') as r`)).r).toMatchObject({ belt: 'after_call_quiet', step: 1 })
    expect((await db.query(`select 1 from public.belt_events where lead_id = $1 and payload->>'note' like 'card is live%'`, [A])).rows).toHaveLength(1)
  })

  it('cold texts are mirrored from the laptop and the call-list task is the fourth stop; a stage written by hand is flagged', async () => {
    const m = (await one<{ r: Record<string, unknown> }>(`select public.belt_mirror_cold(77, 2, $1::timestamptz, $2::timestamptz) as r`, [NOW, '2026-11-05T16:00:00Z'])).r
    expect(m).toMatchObject({ ok: true, belt: 'cold_texts', step: 2 })
    expect((await lead())).toMatchObject({ belt: 'cold_texts', next_stop_who: 'auto_text', stage: 'opener_sent' })
    expect((await db.query(`select 1 from public.cards_no_stop`)).rows).toHaveLength(0)
    await db.query(`insert into public.tasks (lead_id, due_at, kind, owner, note, source, source_key) values ($1, $2, 'call', 'thalia', 'from the call list', 'call_list', 'calls:2026-10-22:77')`, [A, NOW])
    const t = await one<{ id: string }>(`select id from public.tasks where source_key = 'calls:2026-10-22:77'`)
    await as(THALIA, () => one(`select public.belt_stop_done($1, 'reached', 'owner, wants Colin to call') as r`, [t.id]))
    expect(await lead()).toMatchObject({ belt: 'yes_unbooked', belt_step: 1 })
    await as(COLIN, () => db.query(`update public.leads set stage = 'dead', dead_reason = 'moved by hand' where id = $1`, [A]))
    expect((await db.query<{ changed: string[] }>(`select changed from public.belt_direct_writes`)).rows).toEqual([{ changed: ['stage'] }])
    expect((await lead()).belt).toBe('dead')                                 // the belt follows the stage anyway
  })
})

describe('health', () => {
  it('flags a live card with no next stop, an unlogged stop, a stuck text and a missing canary; is green after the canary', async () => {
    await db.query(`update public.leads set belt = 'yes_unbooked', belt_step = 1, stage = 'colin_call', next_stop_at = null, synced_at = $2 where id = $1`, [A, NOW])
    let h = (await one<{ r: { ok: boolean; checks: Record<string, unknown>; summary: string } }>(`select public.belt_health_check($1::timestamptz) as r`, [NOW])).r
    expect(h.ok).toBe(false)
    expect(h.checks.no_stop).toBe(1)
    expect(h.summary).toMatch(/1 live card\(s\) have no next stop/)
    expect(h.summary).toMatch(/canary has not run/)
    await db.query(`insert into public.tasks (lead_id, due_at, kind, owner, source, source_key) values ($1, $2, 'call', 'thalia', 'belt', 'belt:x')`, [A, '2026-10-20T17:00:00Z'])
    await db.query(`insert into public.reply_drafts (phone10, lead_id, inbound_at, intent, kind, outcome, body, draft_source, status, belt_stop_key, created_at)
      values ('4145550177', $1, $2, 'belt', 'belt', 'door_open', 'x', 'belt_auto', 'queued', 'belt:y', $3)`, [A, NOW, '2026-10-22T14:00:00Z'])
    h = (await one<{ r: { ok: boolean; summary: string } }>(`select public.belt_health_check($1::timestamptz) as r`, [NOW])).r
    expect(h.summary).toMatch(/1 stop\(s\) sit unlogged/)
    expect(h.summary).toMatch(/stuck in the queue/)
    // the watchdog texts Colin once per issue per day, through ops_alerts
    await db.query(`delete from public.belt_health`)
    const w = (await one<{ r: { alerted: string[] } }>(`select public.belt_watch($1::timestamptz) as r`, [NOW])).r
    expect(w.alerted).toContain('heartbeat')
    expect((await one<{ r: { alerted: string[] } }>(`select public.belt_watch($1::timestamptz) as r`, [NOW])).r.alerted).toEqual([])
    expect((await db.query<{ text: string }>(`select text from public.ops_alerts`)).rows[0].text).toMatch(/^Belt health: the conveyor has not run/)
    // clean up and run the canary: green
    await db.query(`truncate public.tasks, public.reply_drafts, public.belt_health cascade`)
    await ev('inbound_text', { intent: 'interested', interest: true })
    const c = (await one<{ r: { ok: boolean; why: string | null; steps: { step: string; ok: boolean; detail: string }[] } }>(`select public.belt_canary($1::timestamptz) as r`, [NOW])).r
    if (!c.ok) console.log(JSON.stringify(c.steps))
    expect(c.steps.map((s) => `${s.step}:${s.ok}`)).toEqual(['yes_unbooked:true', 'thalia_task:true', 'no_answer:true', 'task_logged:true', 'dry_text:true', 'after_text:true',
      'call_booked:true', 'visit_booked:true', 'dnc_final:true'])
    expect(c.ok).toBe(true)
    expect((await db.query(`select 1 from public.leads where owner_name like 'BELT CANARY%'`)).rows).toHaveLength(0)
    h = (await one<{ r: { ok: boolean; summary: string } }>(`select public.belt_health_check($1::timestamptz) as r`, [NOW])).r
    expect(h.ok).toBe(true)
    expect(h.summary).toMatch(/^All belts moving/)
  })

  it('the backfill puts every card on a belt from its stage, and reports where they landed', async () => {
    await db.query(`
      insert into public.leads (wpie_owner_id, owner_name, property_address, mailing_state, stage, next_action_at, hot_at) values
        (1, 'A', '1 A ST', 'WI', 'opener_sent', null, null), (2, 'B', '2 B ST', 'WI', 'ai_qualifying', null, null),
        (3, 'C', '3 C ST', 'WI', 'colin_call', '2026-10-30T19:00:00Z', null), (4, 'D', '4 D ST', 'WI', 'dnc', null, null),
        (5, 'E', '5 E ST', 'WI', 'closed_no_contact', null, null), (6, 'F', '6 F ST', 'WI', 'postcard_mailed', null, null),
        (7, 'G', '7 G ST', 'WI', 'reply_received', null, $1)`, [NOW])
    const r = (await one<{ r: { placed: Record<string, number>; no_stop: number } }>(`select public.belt_backfill($1::timestamptz) as r`, [NOW])).r
    expect(r.placed).toEqual({ cold_texts: 2, questions_quiet: 1, call_booked: 1, dnc: 1, dead: 1, '(none: postcard_mailed)': 1, yes_unbooked: 1 })
    expect(r.no_stop).toBe(0)
    expect((await one<{ belt: string; named_date: string }>(`select belt, named_date::text from public.leads where wpie_owner_id = 3`)).belt).toBe('call_booked')
  })
})
