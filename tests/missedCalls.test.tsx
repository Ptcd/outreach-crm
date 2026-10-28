// @vitest-environment jsdom
// Today's Missed calls box (0118): a voicemail read as upset or not a seller is never on the team's list; Colin sees it,
// marked "Don't call back", with the reason. A stop or the wrong person shows to nobody.
import { cleanup, render, screen } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter } from 'react-router-dom'
import { afterEach, describe, expect, it, vi } from 'vitest'

const row = (sid: string, owner: string, verdict: string | null, reason: string | null = null) => ({ call_sid: sid, at: '2026-10-28T20:00:00Z', phone: '4145550100',
  status: 'missed', voicemail: true, words: `the voicemail ${sid}`, lead_id: sid, owner_name: owner, property_address: '1 A St', municipality: null, stage: 'opener_sent',
  closed: false, called_back: false, verdict, verdict_reason: reason })
const rows = [row('A', 'REAL SELLER', 'seller'), row('B', 'ANGRY CALLER', 'upset', 'yelled about the texts'), row('C', 'AN AGENT', 'not_seller'),
  row('D', 'STOP CALLER', 'stop'), row('E', 'NOT YET READ', null)]
let colin = false
vi.mock('@/lib/supabaseClient', () => ({ supabase: { rpc: vi.fn(async () => ({ data: rows, error: null })) }, supabaseConfigured: true }))
vi.mock('@/components/OnPhonePicker', () => ({ useColinHere: () => colin }))
import { MissedCalls } from '../src/components/MissedCalls'

const wrap = () => render(<QueryClientProvider client={new QueryClient()}><MemoryRouter><MissedCalls /></MemoryRouter></QueryClientProvider>)
afterEach(() => cleanup())

describe('missed calls', () => {
  it('the team sees only the callers to call back', async () => {
    colin = false
    wrap()
    expect(await screen.findByText(/REAL SELLER/)).toBeTruthy()
    expect(screen.getByText(/NOT YET READ/)).toBeTruthy()
    for (const n of [/ANGRY CALLER/, /AN AGENT/, /STOP CALLER/]) expect(screen.queryByText(n)).toBeNull()
  })
  it("Colin also sees the upset caller and the non-seller, marked don't call back, with why", async () => {
    colin = true
    wrap()
    expect(await screen.findByText(/ANGRY CALLER/)).toBeTruthy()
    expect(screen.getByText(/Upset: Colin decides/)).toBeTruthy()
    expect(screen.getByText(/yelled about the texts/)).toBeTruthy()
    expect(screen.getByText(/AN AGENT/)).toBeTruthy()
    expect(screen.queryByText(/STOP CALLER/)).toBeNull()
  })
})
