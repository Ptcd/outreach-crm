import { describe, expect, it } from 'vitest'
import { callLabel, callerDigits, fmtDuration, inboundLabel, pickInbound } from '../src/lib/dialer'
import { humanCallAuthorized } from '../src/lib/callAttempt'
import type { PhoneMatch } from '../src/lib/queries'

const match = (x: Partial<PhoneMatch>): PhoneMatch => ({
  lead_id: 'L1', owner_name: 'JANE ROE', property_address: '100 N MAIN ST', municipality: 'Milwaukee', lane: 'hold', stage: 'colin_call',
  phone: '4145550101', person_name: null, blocked: false, exact: true, ...x,
})

describe('dialer helpers', () => {
  it('requires an active database pause before any client starts a call', () => {
    expect(humanCallAuthorized({ ok: true, paused: true })).toBe(true)
    expect(humanCallAuthorized({ ok: true, duplicate: true, paused: false })).toBe(false)
    expect(humanCallAuthorized({ ok: true })).toBe(false)
    expect(humanCallAuthorized(null)).toBe(false)
  })
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

describe('a call coming in', () => {
  it('reads the ten digits off the caller id, and nothing off a withheld number', () => {
    expect(callerDigits('+14145550101')).toBe('4145550101')
    expect(callerDigits('4145550101')).toBe('4145550101')
    expect(callerDigits('anonymous')).toBe('')
    expect(callerDigits('+266696687')).toBe('')
    expect(callerDigits(null)).toBe('')
  })
  it('picks the exact-number match first, else the call desk\'s first row, else nobody', () => {
    const a = match({ lead_id: 'A', exact: false })
    const b = match({ lead_id: 'B', exact: true })
    expect(pickInbound([a, b])?.lead_id).toBe('B')
    expect(pickInbound([a])?.lead_id).toBe('A')
    expect(pickInbound([])).toBeNull()
    expect(pickInbound(null)).toBeNull()
  })
  it('labels the bar with the owner and property, or just the number for a stranger', () => {
    expect(inboundLabel('+14145550101', [match({})])).toBe('JANE ROE - 100 N MAIN ST, Milwaukee')
    expect(inboundLabel('+14145550101', [match({ property_address: null, municipality: null })])).toBe('JANE ROE')
    expect(inboundLabel('+14145550101', [])).toBe('(414) 555-0101')
    expect(inboundLabel('anonymous', null)).toBe('anonymous')
  })
})
