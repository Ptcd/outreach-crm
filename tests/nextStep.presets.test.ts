// The long follow-up presets and the pure helpers behind "call me in spring" (2026-11-04: Thalia and Adil's walkthrough).
import { describe, expect, it } from 'vitest'
import { PRESETS, REST_PRESETS, dayAfter, morningOf, nextOf, NOT_NOW_KINDS, CALL_LANES } from '../src/lib/nextStep'

const at = (id: string, now: Date) => PRESETS.find((p) => p.id === id)!.at(now)
const ymd = (d: Date) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`

describe('the long presets', () => {
  const nov4 = new Date(2026, 10, 4, 15, 30)   // Wed Nov 4 2026, 3:30 PM local

  it('keeps the six short ones and adds the long ones, all at 10 AM', () => {
    expect(PRESETS.map((p) => p.id)).toEqual(['later_today', 'tomorrow', 'in_3_days', 'next_week', 'in_2_weeks', 'next_month',
      'in_3_months', 'in_6_months', 'spring', 'after_holidays', 'after_tax_bill', 'in_a_year'])
    for (const p of PRESETS.filter((x) => x.far)) {
      const d = p.at(nov4)
      expect(d.getHours()).toBe(10)
      expect(d.getMinutes()).toBe(0)
      expect(d.getDay()).not.toBe(0)   // never a Sunday
    }
  })

  it('3 and 6 months and a year count in months', () => {
    expect(ymd(at('in_3_months', nov4))).toBe('2027-02-04')
    expect(ymd(at('in_6_months', nov4))).toBe('2027-05-04')
    expect(ymd(at('in_a_year', nov4))).toBe('2027-11-04')
  })

  it('spring, the holidays and the tax bill are the next time that day comes round', () => {
    expect(ymd(at('spring', nov4))).toBe('2027-03-15')
    expect(ymd(at('after_holidays', nov4))).toBe('2027-01-08')
    expect(ymd(at('after_tax_bill', nov4))).toBe('2027-01-05')
    // on Mar 15 itself, spring means next year's
    expect(ymd(nextOf(new Date(2027, 2, 15, 9), 3, 15))).toBe('2028-03-15')
    // the day before, it is tomorrow
    expect(ymd(nextOf(new Date(2027, 2, 14, 9), 3, 15))).toBe('2027-03-15')
  })

  it('a Sunday rolls to Monday morning', () => {
    // Jan 8 2028 is a Saturday; Mar 15 2026 is a Sunday
    expect(morningOf(new Date(2026, 2, 15)).getDay()).toBe(1)
    expect(ymd(morningOf(new Date(2026, 2, 15)))).toBe('2026-03-16')
  })

  it('the day after a named date is the next morning', () => {
    expect(ymd(dayAfter('2027-04-30')!)).toBe('2027-05-01')
    expect(dayAfter('2027-05-01')!.getHours()).toBe(10)
    expect(dayAfter('next spring')).toBeNull()
  })

  it('rest presets exist and land in the future', () => {
    expect(REST_PRESETS.map((p) => p.id)).toEqual(['rest_1_month', 'rest_3_months', 'rest_6_months', 'rest_spring', 'rest_after_holidays'])
    for (const p of REST_PRESETS) expect(p.at(nov4).getTime()).toBeGreaterThan(nov4.getTime())
  })

  it('one not-now shape and four lanes', () => {
    expect(NOT_NOW_KINDS.map((k) => k.id)).toEqual(['date', 'condition', 'nothing'])
    expect(CALL_LANES.map((l) => l.id)).toEqual(['1', '2', '3', 'never'])
  })
})
