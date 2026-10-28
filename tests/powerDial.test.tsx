// @vitest-environment jsdom
// Power hour: one tap logs the outcome and brings the next card; Dial calls the card's number quietly (the card asks
// the outcome, not the call bar); keys work on a computer (Colin 2026-10-28: "rapid click through").
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { afterEach, describe, expect, it, vi } from 'vitest'

const items = [
  { lead_id: 'L1', task_id: null, source: 'texted_silent', why: null, owner_name: 'JANE Q SAMPLE', address: '100 SAMPLE ST', municipality: 'Milwaukee',
    reasons: ['vacant + distress'], lane: 'flip', texts_sent: 2, first_text_at: '2026-10-20T15:00:00Z', last_text_at: '2026-10-23T15:00:00Z',
    dials_7d: 0, last_dial: null, phone: '4145550101', line_type: 'mobile', phone_person: 'JANE SAMPLE', other_phones: 1 },
  { lead_id: 'L2', task_id: 'T2', source: 'call_list', why: 'Call: landline only', owner_name: 'ROBERT EXAMPLE', address: '200 EXAMPLE AV', municipality: 'West Allis',
    reasons: [], lane: 'flip', texts_sent: 0, first_text_at: null, last_text_at: null, dials_7d: 1, last_dial: null,
    phone: '4145550144', line_type: 'landline', phone_person: null, other_phones: 0 },
]
const logCall = vi.fn(async () => ({ data: { ok: true }, error: null }))
const start = vi.fn(async () => undefined)
vi.mock('@/lib/supabaseClient', () => ({ supabase: { rpc: vi.fn(async () => ({ data: items, error: null })) }, supabaseConfigured: true }))
vi.mock('@/lib/queries', () => ({ api: { logCall: (...a: unknown[]) => logCall(...(a as [])) }, useLead: () => ({ isLoading: true }) }))
vi.mock('@/lib/dialer', () => ({ useDialer: () => ({ active: null, start, dismiss: vi.fn(), hangUp: vi.fn(), supported: true }) }))
vi.mock('@/components/CallScript', () => ({ CallScript: () => null, pickupLine: (c: string) => `Hi, this is ${c}` }))

import { PowerDial } from '@/components/PowerDial'

const wrap = () => render(<QueryClientProvider client={new QueryClient()}><PowerDial caller="thalia" /></QueryClientProvider>)
afterEach(() => { cleanup(); localStorage.clear(); logCall.mockClear(); start.mockClear() })

describe('Power hour', () => {
  it('dials the card quietly, logs a voicemail in one tap, and brings the next card', async () => {
    wrap()
    expect(await screen.findByText('Jane Q Sample')).toBeTruthy()
    fireEvent.click(screen.getByText(/Dial \(414\) 555-0101/))
    expect(start).toHaveBeenCalledWith(expect.objectContaining({ to: '4145550101', leadId: 'L1', quiet: true }))
    fireEvent.click(screen.getByText('Left voicemail'))
    await waitFor(() => expect(logCall).toHaveBeenCalledWith('L1', '4145550101', 'no_answer', 'Left a voicemail (Power hour).', null))
    expect(await screen.findByText('Robert Example')).toBeTruthy()
    expect(screen.getByText(/1 dialed/)).toBeTruthy()
  })

  it('works from the keyboard: 1 logs no answer, S skips to the end', async () => {
    wrap()
    await screen.findByText('Jane Q Sample')
    fireEvent.keyDown(window, { key: 's' })
    expect(await screen.findByText('Robert Example')).toBeTruthy()
    fireEvent.keyDown(window, { key: '1' })
    await waitFor(() => expect(logCall).toHaveBeenCalledWith('L2', '4145550144', 'no_answer', 'No answer (Power hour).', null))
    expect(await screen.findByText('Jane Q Sample')).toBeTruthy()   // the skipped one comes back last
  })
})
