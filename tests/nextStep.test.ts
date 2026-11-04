import { describe, expect, it } from 'vitest'
import { PRESETS, morningOf, canDelete, isBeltTask } from '../src/lib/nextStep'

const at = (id: string, now: Date) => PRESETS.find((p) => p.id === id)!.at(now)

describe('next step presets', () => {
  it('lands on 10 AM and skips Sunday', () => {
    const sat = new Date(2026, 10, 7, 15, 30)                 // Sat Nov 7 2026
    expect(at('tomorrow', sat).getDay()).toBe(1)              // Sunday -> Monday
    expect(at('tomorrow', sat).getHours()).toBe(10)
    expect(morningOf(new Date(2026, 10, 8)).getDate()).toBe(9)
  })
  it('counts days from now, next month keeps the day', () => {
    const now = new Date(2026, 10, 3, 17, 0)
    expect(at('in_3_days', now).getDate()).toBe(6)
    expect(at('next_week', now).getDate()).toBe(10)
    expect(at('next_month', now).getMonth()).toBe(11)
    expect(at('later_today', now).getHours()).toBe(20)
  })
  it('knows which follow-ups may be deleted', () => {
    expect(isBeltTask('belt')).toBe(true)
    expect(canDelete({ source: 'belt', kind: 'call' })).toBe(false)
    expect(canDelete({ source: null, kind: 'callback' })).toBe(false)
    expect(canDelete({ source: 'mine', kind: 'call' })).toBe(true)
  })
})
