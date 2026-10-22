import { describe, expect, it } from 'vitest'
import { callLabel, fmtDuration } from '../src/lib/dialer'

describe('dialer helpers', () => {
  it('names the call after the person and the property', () => {
    expect(callLabel('Laurie', '3424 N Main St')).toBe('Laurie - 3424 N Main St')
    expect(callLabel(null, ' 1 Sample St ')).toBe('1 Sample St')
    expect(callLabel('', '')).toBe('the owner')
  })
  it('shows the timer as m:ss', () => {
    expect(fmtDuration(0)).toBe('0:00')
    expect(fmtDuration(65_000)).toBe('1:05')
  })
})
