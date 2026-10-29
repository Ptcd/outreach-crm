import { describe, expect, it } from 'vitest'
import { poolLineFor } from '@/lib/callAttempt'
describe('poolLineFor (a never-texted phone calls from one of the seller numbers)', () => {
  const pool = ['+12629996513', '+12624180202', '+14144200843', '+14146778472']
  it('spreads phones across the pool, the same phone always the same number', () => {
    const picks = ['4145550101', '4145550102', '4145550103', '4145550104', '4145550105', '4145550106'].map((p) => poolLineFor(pool, p, 'x'))
    expect(new Set(picks).size).toBeGreaterThan(1)
    expect(poolLineFor(pool, '(414) 555-0101', 'x')).toBe(picks[0])
    picks.forEach((n) => expect(pool).toContain(n))
  })
  it('falls back when the pool is empty or malformed', () => {
    expect(poolLineFor([], '4145550101', '+12629996513')).toBe('+12629996513')
    expect(poolLineFor(['414-420-0843'], '4145550101', '+12629996513')).toBe('+12629996513')
  })
})
