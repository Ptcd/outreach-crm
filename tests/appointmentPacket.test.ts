import { describe, expect, it } from 'vitest'
import { buildAppointmentPacket } from '../src/lib/appointmentPacket'
import { localInputToIso } from '../src/lib/format'
import type { CallFacts } from '../src/lib/callGate'
import type { GateScore, Lead } from '../src/lib/types'

const lead = {
  id: 'L1', owner_name: 'JANE ROE', property_address: '100 N MAIN ST', municipality: 'Milwaukee', property_zip: '53202',
  property_type: 'duplex', units: 2, named_date: '2026-11-02T18:00:00Z', next_action_at: '2026-11-02T18:00:00Z',
} as Lead
const fact = (value: unknown) => ({ value, at: '2026-10-23T12:00:00Z', by: 'Thalia' })

describe('booked-visit appointment packet', () => {
  it('uses only saved facts and lists every unresolved field as unknown', () => {
    const callFacts = {
      motivation: fact({ choices: ['moving'], text: 'moving near family' }),
      price: fact({ number: '185000' }),
      decision_makers: fact({ choices: ['spouse'], text: 'Jane and Pat' }),
    } as CallFacts
    const gate = { decision: 'walk', total: 10, hard_stops: [], at: '2026-10-23T12:30:00Z', decided_by_name: 'Colin' } as GateScore
    const packet = buildAppointmentPacket(lead, callFacts, {
      condition: { value: 'roof is old', at: '2026-10-22T16:00:00Z', by: 'seller reply' },
      timeline: 'before winter',
    }, gate)
    expect(packet.appointment).toContain('Monday, November 2, 2026')
    expect(packet.rows.find((r) => r.id === 'property')?.value).toBe('100 N MAIN ST, Milwaukee, 53202')
    expect(packet.rows.find((r) => r.id === 'motivation')?.value).toContain('moving near family')
    expect(packet.rows.find((r) => r.id === 'condition')?.value).toBe('roof is old')
    expect(packet.rows.find((r) => r.id === 'asking_price')?.value).toBe('$185000')
    expect(packet.rows.find((r) => r.id === 'motivation')?.provenance).toEqual({
      source: 'Call script', recordedAt: '2026-10-23T12:00:00Z', recordedBy: 'Thalia',
    })
    expect(packet.rows.find((r) => r.id === 'condition')?.provenance).toEqual({
      source: 'Seller text reply', recordedAt: '2026-10-22T16:00:00Z', recordedBy: 'seller reply',
    })
    expect(packet.rows.find((r) => r.id === 'property')?.provenance).toEqual({ source: 'WPIE lead record', recordedAt: null, recordedBy: null })
    expect(packet.unresolved).toEqual(expect.arrayContaining(['Who is speaking', 'Occupancy / access']))
    expect(packet.rows.filter((r) => !r.known).every((r) => r.value === 'Unknown — ask and record')).toBe(true)
    expect(packet.gate).toBe('walk (10/12)')
    expect(packet.gateProvenance).toEqual({ source: 'Booking gate score', recordedAt: '2026-10-23T12:30:00Z', recordedBy: 'Colin' })
  })

  it('does not invent a price, condition, timing, signers, or visit time', () => {
    const packet = buildAppointmentPacket({ ...lead, named_date: null, next_action_at: null } as Lead)
    expect(packet.appointment).toBe('Unknown — confirm the visit time')
    for (const id of ['condition', 'asking_price', 'timing', 'decision_makers']) {
      expect(packet.rows.find((r) => r.id === id)).toMatchObject({ known: false, value: 'Unknown — ask and record' })
      expect(packet.rows.find((r) => r.id === id)?.provenance.source).toBe('Not recorded')
    }
    expect(packet.gate).toBe('Not scored')
  })
})

describe('exact Milwaukee date conversion', () => {
  it('keeps noon on the requested calendar date across both DST offsets', () => {
    expect(localInputToIso('2026-03-09T12:00')).toBe('2026-03-09T17:00:00.000Z') // CDT
    expect(localInputToIso('2026-11-02T12:00')).toBe('2026-11-02T18:00:00.000Z') // CST
  })
})
