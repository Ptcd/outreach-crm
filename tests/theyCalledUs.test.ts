// Migration 0063 on the real migrations (PGlite): a call from a phone on a card to one of our seller lines is logged on
// the card; a missed one moves the card to "they called us" (yes_unbooked) with a call-back task due now for whoever
// is on shift, and the voicemail's words land in the task note and on the card only.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, beforeEach, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATIONS = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')
const LEAD = '00000000-0000-0000-0000-0000000000c1'
const OTHER = '00000000-0000-0000-0000-0000000000c2'
const PHONE = '2625550101'
const LINE = '+12624180202'
const SID = (n: number) => `CA${String(n).padStart(32, '0')}`
// 2026-10-27 is a Tuesday; Central is UTC-5 until Nov 1.
const TUE_10AM = '2026-10-27T15:00:00Z'
const TUE_6PM = '2026-10-27T23:00:00Z'
const SAT_3PM = '2026-10-31T20:00:00Z'
const SUN_9PM = '2026-11-02T03:00:00Z'
const WORDS = 'Hi this is Donald, 123 Elm Street, call me back at 262 555 0101'

let db: PGlite
const one = async <T = Record<string, unknown>>(sql: string, params: unknown[] = []) => (await db.query<T>(sql, params)).rows[0]
const all = async <T = Record<string, unknown>>(sql: string, params: unknown[] = []) => (await db.query<T>(sql, params)).rows
const log = async (sid: string, event: string, at = TUE_10AM, extra: { from?: string; duration?: number; transcript?: string } = {}) =>
  (await one<{ r: Record<string, unknown> }>(
    `select public.inbound_call_log($1, $2, $3, $4, $5, $6, $7::timestamptz) r`,
    [sid, extra.from ?? `+1${PHONE}`, LINE, event, extra.duration ?? null, extra.transcript ?? null, at])).r

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATIONS)
})

beforeEach(async () => {
  await db.exec(`
    truncate public.inbound_calls, public.belt_events, public.hot_alerts, public.tasks, public.reply_drafts, public.reply_threads,
      public.twilio_inbound, public.suppressed_phones, public.messages, public.contacts, public.leads cascade;
    insert into public.leads (id, wpie_owner_id, owner_name, property_address, municipality, mailing_state, lane, stage, belt, belt_step)
      values ('${LEAD}', 961, 'DONALD LEMKE', '123 ELM ST', 'Waukesha', 'WI', 'flip', 'opener_sent', 'cold_texts', 2),
             ('${OTHER}', 962, 'DONALD LEMKE', '9 OAK ST', 'Waukesha', 'WI', 'flip', 'opener_sent', null, 0);
    insert into public.contacts (lead_id, kind, value, value_normalized, line_type)
      values ('${LEAD}', 'phone', '${PHONE}', '${PHONE}', 'mobile'), ('${OTHER}', 'phone', '${PHONE}', '${PHONE}', 'mobile');
    insert into public.twilio_inbound (sid, from10, to_number, body, lead_id, received_at)
      values ('SM${'1'.repeat(32)}', '${PHONE}', '${LINE}', 'Yes', '${LEAD}', '2026-10-25T15:00:00Z');
  `)
})

describe('they called us', () => {
  it('who is on shift: Thalia weekdays 9-5, Adil weekdays 5-6 (0140) and weekends 8-8, Colin otherwise (Central)', async () => {
    const at = async (t: string) => (await one<{ p: string }>(`select public.on_shift_person($1::timestamptz)::text p`, [t])).p
    expect(await at(TUE_10AM)).toBe('thalia')
    expect(await at('2026-10-27T13:59:00Z')).toBe('colin')   // 8:59 AM Tue
    expect(await at('2026-10-27T14:00:00Z')).toBe('thalia')  // 9:00 AM Tue
    expect(await at('2026-10-27T22:00:00Z')).toBe('adil')    // 5:00 PM Tue: Adil's weekday hour (0140)
    expect(await at('2026-10-27T22:59:00Z')).toBe('adil')    // 5:59 PM Tue
    expect(await at(TUE_6PM)).toBe('colin')
    expect(await at(SAT_3PM)).toBe('adil')
    expect(await at('2026-10-31T13:00:00Z')).toBe('adil')    // 8:00 AM Sat
    expect(await at('2026-11-01T02:00:00Z')).toBe('colin')   // 8:00 PM Sat (CDT -> CST night)
    expect(await at(SUN_9PM)).toBe('colin')
  })

  it('a missed call moves the card they texted from to "they called us" with a call-back due now for Thalia', async () => {
    const r = await log(SID(1), 'missed')
    expect(r).toMatchObject({ ok: true, matched: true, lead_id: LEAD, status: 'missed', owner: 'thalia' })
    const lead = await one(`select belt, belt_step, next_stop_at, next_stop_who, assigned_to::text a from public.leads where id = $1`, [LEAD])
    expect(lead).toMatchObject({ belt: 'yes_unbooked', belt_step: 1, next_stop_who: 'thalia_call', a: 'thalia' })
    expect(new Date(lead.next_stop_at as string).toISOString()).toBe(new Date(TUE_10AM).toISOString())
    const tasks = await all(`select owner::text o, due_at, kind, source, title, note, phone10, done_at from public.tasks where lead_id = $1 and done_at is null`, [LEAD])
    expect(tasks).toHaveLength(1)
    expect(tasks[0]).toMatchObject({ o: 'thalia', kind: 'call', source: 'belt', title: 'They called us: call back', phone10: PHONE })
    expect(new Date(tasks[0].due_at as string).toISOString()).toBe(new Date(TUE_10AM).toISOString())
    expect(tasks[0].note).toContain('(262) 555-0101 called our (262) 418-0202')
    expect(tasks[0].note).toContain('9 OAK ST')   // the other card with the same number is named, not tasked
    expect(await all(`select 1 from public.tasks where lead_id = $1`, [OTHER])).toHaveLength(0)
    const msg = await all(`select direction::text d, channel::text c, status, body from public.messages where lead_id = $1`, [LEAD])
    expect(msg).toEqual([expect.objectContaining({ d: 'in', c: 'call', status: 'inbound_missed' })])
    expect(msg[0].body).toContain('Missed call')
    // the belt shows its stop as a call on the callers' list
    expect(await all(`select person from public.belt_stops where lead_id = $1 and done_at is null`, [LEAD])).toEqual([{ person: 'thalia' }])
  })

  it('weekend calls go to Adil, nights to Colin', async () => {
    expect(await log(SID(2), 'missed', SAT_3PM)).toMatchObject({ owner: 'adil' })
    await db.exec(`truncate public.inbound_calls, public.tasks, public.belt_events, public.messages cascade;
                   update public.leads set belt = 'cold_texts', belt_step = 2`)
    expect(await log(SID(3), 'missed', SUN_9PM)).toMatchObject({ owner: 'colin' })
    expect(await one(`select next_stop_who from public.leads where id = $1`, [LEAD])).toEqual({ next_stop_who: 'colin_call' })
    const t = await one<{ due_at: string }>(`select due_at from public.tasks where lead_id = $1 and done_at is null`, [LEAD])
    expect(new Date(t.due_at).toISOString()).toBe(new Date(SUN_9PM).toISOString())  // due now, not slid to Monday
  })

  it('voicemail and its transcription go into the task note and the card entry, and nowhere else', async () => {
    await log(SID(4), 'missed')
    await log(SID(4), 'voicemail', TUE_10AM, { duration: 23 })
    await log(SID(4), 'transcript', TUE_10AM, { transcript: WORDS })
    await log(SID(4), 'transcript', TUE_10AM, { transcript: WORDS })   // Twilio retry
    const t = await one<{ note: string }>(`select note from public.tasks where lead_id = $1 and done_at is null`, [LEAD])
    expect(t.note).toContain('Left a voicemail (23 s).')
    expect(t.note).toContain(`Voicemail: "${WORDS}"`)
    expect(t.note.split('Voicemail: "').length).toBe(2)
    const m = await one<{ body: string }>(`select body from public.messages where lead_id = $1`, [LEAD])
    expect(m.body).toContain(`Voicemail: "${WORDS}"`)
    const events = await all<{ payload: unknown }>(`select payload from public.belt_events`)
    expect(JSON.stringify(events)).not.toContain('Donald, 123 Elm')
    expect(JSON.stringify(await all(`select * from public.inbound_calls`))).not.toContain('Donald, 123 Elm')
    expect(await one(`select voicemail, transcribed from public.inbound_calls where call_sid = $1`, [SID(4)])).toEqual({ voicemail: true, transcribed: true })
  })

  it('a voicemail whose missed-call report never arrived still opens the card and the task', async () => {
    await log(SID(5), 'voicemail', TUE_10AM, { duration: 9 })
    expect(await one(`select belt from public.leads where id = $1`, [LEAD])).toEqual({ belt: 'yes_unbooked' })
    expect(await one(`select count(*)::int n from public.tasks where lead_id = $1 and done_at is null`, [LEAD])).toEqual({ n: 1 })
  })

  it('repeated callbacks for one call write once', async () => {
    await log(SID(6), 'missed')
    await log(SID(6), 'missed')
    expect(await one(`select count(*)::int n from public.messages`)).toEqual({ n: 1 })
    expect(await one(`select count(*)::int n from public.tasks where done_at is null`)).toEqual({ n: 1 })
    expect(await one(`select count(*)::int n from public.belt_events where event = 'they_called'`)).toEqual({ n: 1 })
  })

  it('an answered call is logged on the card and moves nothing', async () => {
    expect(await log(SID(7), 'answered', TUE_10AM, { duration: 125 })).toMatchObject({ matched: true, status: 'answered', task_id: null })
    expect(await one(`select belt, belt_step from public.leads where id = $1`, [LEAD])).toEqual({ belt: 'cold_texts', belt_step: 2 })
    expect(await one(`select count(*)::int n from public.tasks`)).toEqual({ n: 0 })
    expect(await one(`select status, body from public.messages`)).toMatchObject({ status: 'inbound_answered', body: expect.stringContaining('answered (2 min 5 s)') })
  })

  it('a STOP / suppressed number never reopens a closed card', async () => {
    await db.exec(`update public.leads set belt = 'dead', stage = 'dead' where id = '${LEAD}';
                   insert into public.suppressed_phones (phone10, reason, source) values ('${PHONE}', 'stop', 'sms')`)
    const r = await log(SID(8), 'missed')
    expect(r).toMatchObject({ matched: true, status: 'blocked', task_id: null })
    await log(SID(8), 'transcript', TUE_10AM, { transcript: WORDS })
    expect(await one(`select belt, stage::text s from public.leads where id = $1`, [LEAD])).toEqual({ belt: 'dead', s: 'dead' })
    expect(await one(`select count(*)::int n from public.tasks`)).toEqual({ n: 0 })
    const m = await one<{ body: string }>(`select body from public.messages where lead_id = $1`, [LEAD])
    expect(m.body).toContain('Not called back')
  })

  it('a seller who said no and then calls us (no STOP) is back on "they called us"', async () => {
    await db.exec(`update public.leads set belt = 'dead', stage = 'dead', dead_reason = 'not_interested' where id = '${LEAD}'`)
    expect(await log(SID(13), 'missed')).toMatchObject({ status: 'missed', owner: 'thalia' })
    expect(await one(`select belt from public.leads where id = $1`, [LEAD])).toEqual({ belt: 'yes_unbooked' })
  })

  it('a DNC card stays DNC', async () => {
    await db.exec(`update public.leads set belt = 'dnc', stage = 'dnc' where id = '${LEAD}'`)
    expect(await log(SID(9), 'missed')).toMatchObject({ status: 'blocked' })
    expect(await one(`select belt from public.leads where id = $1`, [LEAD])).toEqual({ belt: 'dnc' })
    expect(await one(`select count(*)::int n from public.tasks`)).toEqual({ n: 0 })
  })

  it('a card with a call booked keeps its belt; the call-back is a task of its own', async () => {
    await db.exec(`update public.leads set belt = 'call_booked', belt_step = 1 where id = '${LEAD}'`)
    expect(await log(SID(10), 'missed', SAT_3PM)).toMatchObject({ status: 'missed', owner: 'adil' })
    expect(await one(`select belt from public.leads where id = $1`, [LEAD])).toEqual({ belt: 'call_booked' })
    expect(await one(`select source, title from public.tasks where lead_id = $1`, [LEAD])).toEqual({ source: 'inbound_call', title: 'They called us: call back' })
  })

  it('an unknown caller writes nothing', async () => {
    expect(await log(SID(11), 'missed', TUE_10AM, { from: '+14145559999' })).toEqual({ ok: true, matched: false })
    expect(await one(`select (select count(*) from public.messages)::int m, (select count(*) from public.tasks)::int t,
                             (select count(*) from public.inbound_calls)::int c`)).toEqual({ m: 0, t: 0, c: 0 })
  })

  it('refuses a bad call id and is not callable from the app login', async () => {
    expect(await log('not-a-sid', 'missed')).toMatchObject({ ok: false, reason: 'bad call id' })
    await db.exec('set role authenticated')
    try {
      await expect(db.query(`select public.inbound_call_log($1, $2, $3, 'missed')`, [SID(12), PHONE, LINE])).rejects.toThrow(/permission denied/)
    } finally {
      await db.exec('reset role')
    }
  })
})
