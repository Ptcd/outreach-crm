// Migration 0194 on the real migrations (PGlite): call time, Saturday to Friday, per caller. Colin sees both callers,
// a caller only herself; any date names its week; talk time counts answered calls only.
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import type { PGlite } from '@electric-sql/pglite'
import { ADIL, COLIN, THALIA, as, dayDb, rpc } from './dayInLifeHarness'

let db: PGlite
type Day = { day: string; dials: number; connected: number; talk_s: number; first_at: string | null; last_at: string | null; span_s: number }
type Week = { week_start: string; week_end: string; people: { person: string; days: Day[] }[] }

beforeAll(async () => {
  db = await dayDb()
  // Thu Nov 5 2026 Central: Adil dialed 8:00-9:00 PM (02:00-03:00Z Nov 6); Thalia dialed Mon Nov 2 and Fri Nov 6
  await db.exec(`insert into public.call_legs (call_sid, caller, phone10, started_at, duration_s, status) values
    ('CA1', 'adil', '4145550101', '2026-11-06T02:00:00Z', 16, 'completed'),
    ('CA2', 'adil', '4145550102', '2026-11-06T02:20:00Z', 0, 'no-answer'),
    ('CA3', 'adil', '4145550103', '2026-11-06T03:00:00Z', 44, 'completed'),
    ('CA4', 'thalia', '4145550104', '2026-11-02T21:11:00Z', 120, 'completed'),
    ('CA5', 'thalia', '4145550105', '2026-11-06T23:18:00Z', 0, 'busy'),
    ('CA6', 'thalia', '4145550106', '2026-10-30T20:00:00Z', 600, 'completed')`)   // the week before
}, 120_000)

afterAll(async () => { await db?.close() })

const week = (who: { sub: string; email: string }, start: string | null) =>
  as(db, who, () => rpc<Week>(db, 'call_time_week', { p_week_start: start }))

describe('call time (0194)', () => {
  it('Colin sees both callers, Saturday to Friday, talk time from answered calls only', async () => {
    const w = await week(COLIN, '2026-11-04')   // a Wednesday names its week
    expect(w.week_start).toBe('2026-10-31')
    expect(w.week_end).toBe('2026-11-06')
    expect(w.people.map((p) => p.person)).toEqual(['thalia', 'adil'])
    const adil = w.people[1].days
    expect(adil).toHaveLength(7)
    const thu = adil.find((d) => d.day === '2026-11-05')!
    expect(thu.dials).toBe(3)
    expect(thu.connected).toBe(2)
    expect(thu.talk_s).toBe(60)
    expect(thu.span_s).toBe(3600)
    expect(adil.filter((d) => d.dials).map((d) => d.day)).toEqual(['2026-11-05'])
    const thalia = w.people[0].days
    expect(thalia.filter((d) => d.dials).map((d) => [d.day, d.dials, d.talk_s])).toEqual([['2026-11-02', 1, 120], ['2026-11-06', 1, 0]])
  })

  it('a caller sees only herself', async () => {
    const w = await week(ADIL, '2026-10-31')
    expect(w.people.map((p) => p.person)).toEqual(['adil'])
    const t = await week(THALIA, '2026-11-06')
    expect(t.people.map((p) => p.person)).toEqual(['thalia'])
  })

  it('the week before holds the earlier call, and a Saturday names its own week', async () => {
    const w = await week(COLIN, '2026-10-24')
    expect(w.week_start).toBe('2026-10-24')
    expect(w.people[0].days.find((d) => d.day === '2026-10-30')!.talk_s).toBe(600)
  })
})
