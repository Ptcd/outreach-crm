// Colin's Google Calendar behind the booking (2026-10-26): the open times (his hours, the buffer, the notice, his busy
// events, daylight saving), the sealed tokens, the agent door's three tools, and on the real migrations a booking that
// lands on his calendar and moves the card the way the app's booking does; no double booking; a move or a cancel; and
// Colin's own edits to the event flowing back to the card.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'
import { handleMessage, type DoorDb } from '../supabase/functions/_shared/agentDoor'
import {
  bookSlot, cancelBooking, findSlots, isOpenSlot, openSlots, seal, suggestSlots, syncBookings, unseal, zonedToUtc,
  type Cal, type GEvent, type Google, type Interval, type Rules,
} from '../supabase/functions/_shared/calendar'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')
const COLIN = { sub: '00000000-0000-0000-0000-00000000000c', email: 'colin@example.com' }
const TZ = 'America/Chicago'
const RULES: Rules = { time_zone: TZ, call_hours: { mon: [['09:00', '12:00']], tue: [['09:00', '12:00']] }, visit_hours: { tue: [['13:00', '16:00']] },
  call_minutes: 30, visit_minutes: 60, buffer_minutes: 15, min_notice_minutes: 120, days_ahead: 7 }
const MON_7AM = new Date('2026-10-26T12:00:00Z')      // Monday 7:00 AM Central (CDT, UTC-5)

describe('open times', () => {
  it('his hours, the notice and the buffer around a busy event', () => {
    const busy: Interval[] = [{ start: '2026-10-26T15:00:00Z', end: '2026-10-26T15:30:00Z' }]   // Mon 10:00-10:30 CT
    const mon = openSlots(RULES, 'call', MON_7AM, busy).filter((s) => s.start.startsWith('2026-10-26'))
    expect(mon.map((s) => s.label)).toEqual(['Mon, Oct 26, 9:00 AM', 'Mon, Oct 26, 11:00 AM', 'Mon, Oct 26, 11:30 AM'])
    expect(mon[0]).toMatchObject({ start: '2026-10-26T14:00:00.000Z', end: '2026-10-26T14:30:00.000Z' })
    // 8:30 now + 2 hours of notice: nothing before 10:30
    expect(openSlots(RULES, 'call', new Date('2026-10-26T13:30:00Z'), [])[0].label).toBe('Mon, Oct 26, 10:30 AM')
    // no Wednesday hours, no Sunday hours; visits only Tuesday afternoon, an hour long
    expect(openSlots(RULES, 'visit', MON_7AM, []).map((s) => s.label).slice(0, 4))
      .toEqual(['Tue, Oct 27, 1:00 PM', 'Tue, Oct 27, 1:30 PM', 'Tue, Oct 27, 2:00 PM', 'Tue, Oct 27, 2:30 PM'])
    expect(openSlots(RULES, 'call', MON_7AM, []).every((s) => /^(Mon|Tue)/.test(s.label))).toBe(true)
  })
  it('daylight saving: 9 AM Central is 14:00 UTC before November 1 and 15:00 UTC after', () => {
    expect(zonedToUtc(2026, 10, 26, 9, 0, TZ).toISOString()).toBe('2026-10-26T14:00:00.000Z')
    expect(zonedToUtc(2026, 11, 2, 9, 0, TZ).toISOString()).toBe('2026-11-02T15:00:00.000Z')
    const nextMon = openSlots({ ...RULES, days_ahead: 8 }, 'call', MON_7AM, []).find((s) => s.label.startsWith('Mon, Nov 2'))
    expect(nextMon?.start).toBe('2026-11-02T15:00:00.000Z')
  })
  it('only a start the rules allow is bookable; the offer is spread out', () => {
    expect(isOpenSlot(RULES, 'call', new Date('2026-10-26T14:00:00Z'), MON_7AM, [])).toBe(true)
    expect(isOpenSlot(RULES, 'call', new Date('2026-10-26T14:10:00Z'), MON_7AM, [])).toBe(false)     // off the half hour
    expect(isOpenSlot(RULES, 'call', new Date('2026-10-26T18:00:00Z'), MON_7AM, [])).toBe(false)     // 1 PM: outside his call hours
    const s = suggestSlots(openSlots(RULES, 'call', MON_7AM, []), TZ).map((x) => x.label)
    expect(s).toEqual(['Mon, Oct 26, 9:00 AM', 'Tue, Oct 27, 9:00 AM'])     // the window is 7 days: Mon Nov 2 9:00 is past it
    expect(openSlots(RULES, 'call', MON_7AM, []).at(-1)!.label).toBe('Tue, Oct 27, 11:30 AM')
  })
})

describe('the sealed tokens', () => {
  it('seal and unseal; the stored text is not the token; another key cannot open it', async () => {
    const k = Buffer.from(new Uint8Array(32).fill(7)).toString('base64')
    const other = Buffer.from(new Uint8Array(32).fill(8)).toString('base64')
    const sealed = await seal('1//refresh-token-sample', k)
    expect(sealed).toMatch(/^v1:/)
    expect(sealed).not.toContain('refresh')
    expect(await unseal(sealed, k)).toBe('1//refresh-token-sample')
    await expect(unseal(sealed, other)).rejects.toThrow()
  })
})

/** A Google Calendar in memory: events with times, free/busy from them, delete marks cancelled. */
function fakeGoogle() {
  const events = new Map<string, GEvent & { body?: Record<string, unknown> }>()
  const external: Interval[] = []
  let n = 0
  const g: Google = {
    freeBusy: async () => [...external, ...[...events.values()].filter((e) => e.status !== 'cancelled')
      .map((e) => ({ start: e.start!.dateTime!, end: e.end!.dateTime! }))],
    insertEvent: async (_cal, body) => {
      const id = `ev${++n}`
      const e = { id, status: 'confirmed', htmlLink: `https://calendar.google.com/event?eid=${id}`, start: body.start as GEvent['start'], end: body.end as GEvent['end'], body }
      events.set(id, e)
      return e
    },
    getEvent: async (_cal, id) => events.get(id) ?? null,
    deleteEvent: async (_cal, id) => { const e = events.get(id); if (e) e.status = 'cancelled' },
    listCalendars: async () => [{ id: 'primary', summary: 'Colin', primary: true, accessRole: 'owner' }],
  }
  return { g, events, external }
}

describe('the agent door', () => {
  const sender = { id: 'k2', name: 'Muse sender', role: 'sender' as const }
  const intake = { id: 'k1', name: 'Muse intake', role: 'intake' as const }
  const list = async (a: typeof sender | typeof intake) => ((await handleMessage({ jsonrpc: '2.0', id: 2, method: 'tools/list' }, a, {} as DoorDb)) as
    { result: { tools: { name: string }[] } }).result.tools.map((t) => t.name)
  it('the sender key sees open_slots, book_slot and cancel_booking; the intake key does not', async () => {
    expect(await list(sender)).toEqual(expect.arrayContaining(['open_slots', 'book_slot', 'cancel_booking']))
    expect(await list(intake)).not.toContain('book_slot')
  })
  it('routes to the calendar, and a refusal comes back as an error result', async () => {
    const seen: unknown[] = []
    const db = { calendar: {
      slots: async (a: unknown) => { seen.push(a); return { suggest: ['Tue 2:00 PM'] } },
      book: async () => ({ status: 'refused', reason: 'that time was just taken' }),
      cancel: async () => ({ status: 'cancelled' }),
    } } as unknown as DoorDb
    const call = async (name: string, args: unknown) => (await handleMessage({ jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name, arguments: args } }, sender, db) as
      { result: { isError: boolean; content: { text: string }[] } }).result
    expect(JSON.parse((await call('open_slots', { kind: 'visit' })).content[0].text)).toEqual({ suggest: ['Tue 2:00 PM'] })
    expect(seen[0]).toMatchObject({ kind: 'visit' })
    expect((await call('book_slot', { lead_id: 'L', start: '2026-10-27T19:00:00Z' })).isError).toBe(true)
    expect((await call('cancel_booking', { lead_id: 'L' })).isError).toBe(false)
    const intakeTry = await handleMessage({ jsonrpc: '2.0', id: 4, method: 'tools/call', params: { name: 'book_slot', arguments: {} } }, intake, db) as
      { result: { isError: boolean } }
    expect(intakeTry.result.isError).toBe(true)
  })
})

describe('on the real migrations', () => {
  let db: PGlite
  const one = async <T = Record<string, unknown>>(sql: string, params: unknown[] = []) => (await db.query<T>(sql, params)).rows[0]
  const rpc = async (fn: string, args: Record<string, unknown>) => {
    const k = Object.keys(args)
    const sql = `select public.${fn}(${k.map((x, i) => `${x} => $${i + 1}`).join(', ')}) as r`
    return (await one<{ r: unknown }>(sql, k.map((x) => { const v = args[x]; return v !== null && typeof v === 'object' ? JSON.stringify(v) : v }))).r
  }
  const card = async (name: string, phone: string, street: string) => (await rpc('agent_add_prospect', {
    p: { owner_name: name, address: street, city: 'Waukesha', zip: '53186', phones: [{ number: phone, type: 'mobile' }] }, p_agent: 'Muse intake' }) as { lead_id: string }).lead_id
  const lead = (id: string) => one<{ belt: string; stage: string; named_date: Date | null; named_event: string | null; notes: string | null }>(
    `select belt, stage::text, named_date, named_event, notes from public.leads where id = $1`, [id])
  let google: ReturnType<typeof fakeGoogle>
  let cal: Cal
  const APP = 'https://deals.example.com'

  beforeAll(async () => {
    db = new PGlite()
    await db.exec(SUPABASE_STUB)
    await db.exec(MIGRATION)
    await db.exec(`insert into public.team_members (email, role, person, display_name) values ('colin@example.com', 'owner', 'colin', 'Colin'),
      ('thalia@example.com', 'caller', 'thalia', 'Thalia')`)
    await db.exec(`update public.calendar_rules set call_hours = '${JSON.stringify(RULES.call_hours)}', visit_hours = '${JSON.stringify(RULES.visit_hours)}', days_ahead = 7`)
    google = fakeGoogle()
    const rt = await rpc('calendar_runtime', {}) as Cal['rt']
    cal = { google: google.g, rt }
  })

  it('the tokens live where only the server reads them; Colin sets the hours, nobody else', async () => {
    await db.query(`select set_config('request.jwt.claims', $1, false)`, [JSON.stringify(COLIN)])
    await db.exec('set role authenticated')
    await expect(db.query(`select refresh_token_enc from public.calendar_link`)).rejects.toThrow(/permission/)
    await expect(db.query(`select public.calendar_runtime()`)).rejects.toThrow(/permission/)
    const s = (await one<{ s: { connected: boolean; rules: { call_minutes: number } } }>(`select public.calendar_settings() as s`)).s
    expect(s).toMatchObject({ connected: false, client_ready: false, rules: { call_minutes: 30 } })
    expect(JSON.stringify(s)).not.toMatch(/secret_enc|refresh_token_enc/)
    await expect(db.query(`select public.calendar_set_rules('{"call_hours": {"mon": [["17:00", "09:00"]]}}')`)).rejects.toThrow(/start before its end/)
    const after = (await one<{ s: { rules: { buffer_minutes: number } } }>(`select public.calendar_set_rules('{"buffer_minutes": 10}') as s`)).s
    expect(after.rules.buffer_minutes).toBe(10)
    await db.query(`select set_config('request.jwt.claims', $1, false)`, [JSON.stringify({ sub: '00000000-0000-0000-0000-0000000000a1', email: 'thalia@example.com' })])
    await expect(db.query(`select public.calendar_set_rules('{"buffer_minutes": 0}')`)).rejects.toThrow(/only Colin/)
    await db.exec('reset role')
    await db.exec(`update public.calendar_rules set buffer_minutes = 15`)
    cal.rt = await rpc('calendar_runtime', {}) as Cal['rt']
  })

  it('a booking: the event has the seller, the phone, the address, the pillars and the card link; the card is call_booked at the slot', async () => {
    const lid = await card('Pat Sample', '4145550142', '12 Maple St')
    const offer = await findSlots(rpc, cal, { kind: 'call' }, MON_7AM)
    expect(offer.suggest[0]).toBe('Mon, Oct 26, 9:00 AM')
    const tue9 = offer.slots.find((s) => s.label === 'Tue, Oct 27, 9:00 AM')!
    const r = await bookSlot(rpc, cal, { lead_id: lid, start: tue9.start, pillars: { why: 'moving for work', condition: 'needs a roof',
      timeline: 'by January', their_number: 'about 150, what she owes', who_signs: 'just her' } }, 'Muse (Muse sender)', APP, MON_7AM)
    expect(r).toMatchObject({ status: 'booked', kind: 'call', start: '2026-10-27T14:00:00.000Z', belt: 'call_booked', label: 'Tue, Oct 27, 9:00 AM' })
    const ev = [...google.events.values()][0]
    expect(ev.body!.summary).toBe('Seller call: Pat Sample (414) 555-0142 - 12 Maple St')
    const d = String(ev.body!.description)
    for (const x of ['Phone: (414) 555-0142', 'Property: 12 Maple St, Waukesha, 53186', 'Why selling: moving for work', 'Condition: needs a roof',
      'Timeline: by January', 'Their number: about 150, what she owes', 'Who signs: just her', `Card: ${APP}/lead/${lid}`]) expect(d).toContain(x)
    const l = await lead(lid)
    expect(l).toMatchObject({ belt: 'call_booked', named_event: 'call' })
    expect(l.named_date!.toISOString()).toBe('2026-10-27T14:00:00.000Z')
    expect(l.notes).toContain("booked Colin's call for Tue Oct 27 9:00 AM")
    expect(await one(`select status, google_event_id from public.calendar_bookings where lead_id = $1`, [lid])).toEqual({ status: 'booked', google_event_id: ev.id })
  })

  it('never a double booking: a taken slot is refused with fresh times, a busy event on his calendar too, and a live hold blocks the other agent', async () => {
    const other = await card('Ann Other', '4145550150', '9 Oak St')
    const r = await bookSlot(rpc, cal, { lead_id: other, start: '2026-10-27T14:00:00Z' }, 'Muse (b)', APP, MON_7AM) as { status: string; alternatives: { start: string }[] }
    expect(r.status).toBe('refused')
    expect(r.alternatives.length).toBeGreaterThan(0)
    expect(r.alternatives.map((s) => s.start)).not.toContain('2026-10-27T14:00:00.000Z')
    // 9:30 sits inside the 15-minute buffer after the 9:00 call: refused too
    expect((await bookSlot(rpc, cal, { lead_id: other, start: '2026-10-27T14:30:00Z' }, 'Muse (b)', APP, MON_7AM)).status).toBe('refused')
    // Colin's dentist at Tue 10:30: refused
    google.external.push({ start: '2026-10-27T15:30:00Z', end: '2026-10-27T16:00:00Z' })
    expect((await bookSlot(rpc, cal, { lead_id: other, start: '2026-10-27T15:30:00Z' }, 'Muse (b)', APP, MON_7AM)).status).toBe('refused')
    // a hold another agent has right now (not on Google yet) blocks the slot at the database
    const third = await card('Hal Holder', '4145550151', '10 Elm St')
    expect(await rpc('calendar_hold', { p_lead_id: third, p_kind: 'call', p_start: '2026-10-27T16:30:00Z', p_end: '2026-10-27T17:00:00Z', p_by: 'x',
      p_now: MON_7AM.toISOString() })).toMatchObject({ ok: true })
    expect(await rpc('calendar_hold', { p_lead_id: other, p_kind: 'call', p_start: '2026-10-27T16:30:00Z', p_end: '2026-10-27T17:00:00Z', p_by: 'y',
      p_now: MON_7AM.toISOString() })).toEqual({ ok: false, reason: 'that time was just taken' })
    expect((await findSlots(rpc, cal, { kind: 'call' }, MON_7AM)).slots.map((s) => s.start)).not.toContain('2026-10-27T16:30:00.000Z')
    expect(await one(`select count(*)::int n from public.calendar_bookings where lead_id = $1 and status = 'booked'`, [other])).toEqual({ n: 0 })
  })

  it('a closed card or an older owner is not booked', async () => {
    const dead = await card('Dee Dead', '4145550152', '11 Elm St')
    await db.query(`update public.leads set stage = 'dead', belt = 'dead' where id = $1`, [dead])
    expect(await bookSlot(rpc, cal, { lead_id: dead, start: '2026-10-27T16:00:00Z' }, 'Muse', APP, MON_7AM)).toMatchObject({ status: 'refused', reason: expect.stringContaining('closed') })
    const old = await card('Ollie Elder', '4145550153', '12 Elm St')
    await db.query(`update public.leads set elderly_or_ill = true where id = $1`, [old])
    expect(await bookSlot(rpc, cal, { lead_id: old, start: '2026-10-27T16:00:00Z' }, 'Muse', APP, MON_7AM)).toMatchObject({ status: 'refused', reason: expect.stringContaining('the team calls') })
  })

  it('a visit is visit_booked with the walk-through stage; booking the same card again moves it, the old event comes off', async () => {
    const lid = await card('Vic Visit', '4145550160', '5 Pine St')
    const r = await bookSlot(rpc, cal, { lead_id: lid, start: '2026-10-27T18:00:00Z', kind: 'visit' }, 'Muse', APP, MON_7AM)
    expect(r).toMatchObject({ status: 'booked', kind: 'visit', belt: 'visit_booked', stage: 'walkthrough_booked', end: '2026-10-27T19:00:00.000Z' })
    const first = [...google.events.values()].find((e) => String(e.body!.summary).includes('5 Pine St'))!
    expect(first.body).toMatchObject({ summary: 'Visit: 5 Pine St (Vic Visit)', location: '5 Pine St, Waukesha, 53186' })
    const moved = await bookSlot(rpc, cal, { lead_id: lid, start: '2026-10-27T18:30:00Z', kind: 'visit' }, 'Muse', APP, MON_7AM)
    expect(moved).toMatchObject({ status: 'booked', moved_from: expect.anything() })
    expect(first.status).toBe('cancelled')
    expect((await db.query(`select status from public.calendar_bookings where lead_id = $1 order by created_at`, [lid])).rows.map((x) => (x as { status: string }).status))
      .toEqual(['cancelled', 'booked'])
    expect((await lead(lid)).named_date!.toISOString()).toBe('2026-10-27T18:30:00.000Z')
  })

  it('Colin moves the event: the card follows; he deletes it: the card goes back to "said yes, not booked"', async () => {
    const pat = (await one<{ id: string }>(`select id from public.leads where owner_name = 'Pat Sample'`)).id
    const ev = [...google.events.values()].find((e) => String(e.body!.summary).includes('Pat Sample'))!
    ev.start = { dateTime: '2026-10-28T19:00:00Z' }; ev.end = { dateTime: '2026-10-28T19:30:00Z' }
    const s1 = await syncBookings(rpc, cal, MON_7AM)
    expect(s1).toMatchObject({ moved: 1, cancelled: 0, errors: [] })
    expect(await lead(pat)).toMatchObject({ belt: 'call_booked' })
    expect((await lead(pat)).named_date!.toISOString()).toBe('2026-10-28T19:00:00.000Z')
    google.events.delete(ev.id)                                          // gone from Google altogether (a 404)
    expect(await syncBookings(rpc, cal, MON_7AM)).toMatchObject({ cancelled: 1 })
    expect(await lead(pat)).toMatchObject({ belt: 'yes_unbooked', named_date: null })
    expect(await one(`select status, cancelled_reason from public.calendar_bookings where lead_id = $1 and status <> 'failed' order by created_at desc limit 1`, [pat]))
      .toEqual({ status: 'cancelled', cancelled_reason: "taken off Colin's calendar" })
    expect((await syncBookings(rpc, cal, MON_7AM)).checked).toBe(1)  // only Vic's visit is still live
  })

  it('the agent cancels: the event comes off and the card goes back to "said yes, not booked"', async () => {
    const vic = (await one<{ id: string }>(`select id from public.leads where owner_name = 'Vic Visit'`)).id
    const r = await cancelBooking(rpc, cal, { lead_id: vic, reason: 'her sister is in the hospital' }, 'Muse', MON_7AM)
    expect(r).toMatchObject({ status: 'cancelled', belt: 'yes_unbooked', card_moved: true })
    expect([...google.events.values()].filter((e) => e.status !== 'cancelled' && String(e.body!.summary).includes('Vic'))).toEqual([])
    expect(await cancelBooking(rpc, cal, { lead_id: vic }, 'Muse', MON_7AM)).toMatchObject({ status: 'none' })
  })
})
