// The weekly digest (0187): Monday 8:00-8:10 AM Central, once per caller per week, a push and an email with the week's
// calls (first three names and their reasons), the resting cards waking, the heads-ups waiting and the cards talked to
// with nothing scheduled. The ledger (digest_mark) decides who sends; a retry in the same window skips.
import { describe, expect, it } from 'vitest'
import { digestDue, digestMessage, runWeeklyDigest, type WeeklyDigest } from '../supabase/functions/_shared/followupAlerts'

// 2026-11-09 is a Monday. 8:03 AM Central (CST, UTC-6) is 14:03Z.
const monday803 = new Date('2026-11-09T14:03:00Z')

const digest = (over: Partial<WeeklyDigest> = {}): WeeklyDigest => ({
  person: 'thalia', week_start: '2026-11-09', email: 'thalia@example.com', display_name: 'Thalia', calls: 2,
  first_three: [
    { name: 'JANE ROE', address: '12 OAK ST', when: '2026-11-10T16:00:00Z', reasons: ['behind on taxes', 'code / nuisance'], say: 'ask about the roof' },
    { name: 'JOHN DOE', address: '9 ELM ST', when: '2026-11-12T15:00:00Z', reasons: null, say: null },
  ],
  resting_waking: 1, nudges: 3, no_step: 4, ...over })

function fakeDb(d: WeeklyDigest, already = false) {
  const marked: string[] = []
  const rpc = async (fn: string, args: Record<string, unknown>) => {
    if (fn === 'weekly_digest') return { data: { ...d, person: String(args.p_person) }, error: null }
    if (fn === 'digest_mark') { marked.push(`${args.p_person}:${args.p_week_start}`); return { data: !already, error: null } }
    return { data: null, error: { message: 'unknown ' + fn } }
  }
  return { rpc, marked }
}

describe('when the digest is due', () => {
  it('is the Monday 8:00-8:10 AM Central window, and names that Monday', () => {
    expect(digestDue(monday803)).toBe('2026-11-09')
    expect(digestDue(new Date('2026-11-09T14:00:00Z'))).toBe('2026-11-09')
    expect(digestDue(new Date('2026-11-09T14:09:59Z'))).toBe('2026-11-09')
  })
  it('is not due at 8:10, at 7:59, on a Tuesday, or on Sunday evening', () => {
    expect(digestDue(new Date('2026-11-09T14:10:00Z'))).toBeNull()
    expect(digestDue(new Date('2026-11-09T13:59:00Z'))).toBeNull()
    expect(digestDue(new Date('2026-11-10T14:03:00Z'))).toBeNull()
    expect(digestDue(new Date('2026-11-09T01:03:00Z'))).toBeNull()   // Sunday 7:03 PM Central
  })
  it('follows Central time through daylight saving (CDT in summer: 13:03Z)', () => {
    expect(digestDue(new Date('2026-07-06T13:03:00Z'))).toBe('2026-07-06')
    expect(digestDue(new Date('2026-07-06T14:03:00Z'))).toBeNull()
  })
})

describe('the digest message', () => {
  it('says the week in four lines with the first names and their reasons, and links My cards', () => {
    const m = digestMessage(digest(), 'https://app.example/')
    expect(m.title).toBe('This week, Thalia: 2 calls, 4 with nothing scheduled')
    expect(m.body).toContain('2 calls this week: JANE ROE (Tue 10:00 AM: behind on taxes, code / nuisance); JOHN DOE (Thu 9:00 AM)')
    expect(m.body).toContain('1 resting card waking this week')
    expect(m.body).toContain('3 heads-ups waiting')
    expect(m.body).toContain('4 cards talked to with nothing scheduled')
    expect(m.url).toBe('https://app.example/mine')
    expect(m.html).toContain('<li>')
  })
})

describe('sending it', () => {
  it('pushes and emails each caller once, in the window, and marks the week first', async () => {
    const db = fakeDb(digest())
    const pushed: string[] = []; const mailed: string[] = []
    const s = await runWeeklyDigest({ rpc: db.rpc, appUrl: 'https://app.example', now: () => monday803,
      push: async (person) => { pushed.push(person); return 1 }, email: async (m) => { mailed.push(m.to) } })
    expect(pushed).toEqual(['thalia', 'adil'])
    expect(mailed).toEqual(['thalia@example.com', 'thalia@example.com'])   // the fake returns the same address for both
    expect(db.marked).toEqual(['thalia:2026-11-09', 'adil:2026-11-09'])
    expect(s).toMatchObject({ sent: ['thalia', 'adil'], skipped: [], errors: [] })
  })
  it('skips a caller whose week is already marked (a second run in the same window)', async () => {
    const db = fakeDb(digest(), true)
    const pushed: string[] = []
    const s = await runWeeklyDigest({ rpc: db.rpc, appUrl: 'https://app.example', now: () => monday803, push: async (p) => { pushed.push(p); return 1 }, email: null })
    expect(pushed).toEqual([]); expect(s.skipped).toEqual(['thalia', 'adil'])
  })
  it('does nothing outside the window, and says so', async () => {
    const db = fakeDb(digest())
    const s = await runWeeklyDigest({ rpc: db.rpc, appUrl: 'https://app.example', now: () => new Date('2026-11-10T14:03:00Z'), push: async () => 1, email: null })
    expect(s.off).toMatch(/Monday/); expect(db.marked).toEqual([])
  })
  it('is off with neither channel, before marking anything', async () => {
    const db = fakeDb(digest())
    const s = await runWeeklyDigest({ rpc: db.rpc, appUrl: 'https://app.example', now: () => monday803, push: null, email: null })
    expect(s.off).toMatch(/neither/); expect(db.marked).toEqual([])
  })
})
