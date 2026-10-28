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
const hangUp = vi.fn()
const dialer: { active: null | { status: string; leadId: string; to: string }; incoming: null | { from: string; busy: boolean } } = { active: null, incoming: null }
const history = [{ id: 'm1', direction: 'out', channel: 'sms', body: 'Hi, is this still your place on Sample St?', status: 'delivered', sent_at: '2026-10-20T15:00:00Z' },
  { id: 'm2', direction: 'in', channel: 'sms', body: 'who is this', status: null, sent_at: '2026-10-21T15:00:00Z' }]
const chain = { select: () => chain, eq: () => chain, in: () => chain, order: () => chain, limit: async () => ({ data: [...history].reverse(), error: null }) }
vi.mock('@/lib/supabaseClient', () => ({ supabase: { rpc: vi.fn(async () => ({ data: [...items], error: null })), from: () => chain }, supabaseConfigured: true }))
vi.mock('@/lib/queries', () => ({ api: { logCall: (...a: unknown[]) => logCall(...(a as [])) }, useLead: () => ({ isLoading: true }) }))
vi.mock('@/lib/dialer', () => ({ useDialer: () => ({ active: dialer.active, incoming: dialer.incoming, start, dismiss: vi.fn(), hangUp, supported: true }) }))
vi.mock('@/components/CallScript', () => ({ CallScript: () => null, pickupLine: (c: string, k?: string) => `Hi, this is ${c} (${k ?? "cold"})` }))

import { PowerDial } from '@/components/PowerDial'

const wrap = () => render(<QueryClientProvider client={new QueryClient()}><PowerDial caller="thalia" /></QueryClientProvider>)
afterEach(() => { cleanup(); localStorage.clear(); logCall.mockClear(); start.mockClear(); hangUp.mockClear(); dialer.active = null; dialer.incoming = null; vi.useRealTimers() })

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

  it('hangs up a call nobody answered after five rings and logs it as no answer', async () => {
    const view = wrap()
    await screen.findByText('Jane Q Sample')
    vi.useFakeTimers()
    dialer.active = { status: 'ringing', leadId: 'L1', to: '4145550101' }
    view.rerender(<QueryClientProvider client={new QueryClient()}><PowerDial caller="thalia" /></QueryClientProvider>)
    await vi.advanceTimersByTimeAsync(23_000)
    expect(hangUp).toHaveBeenCalled()
    dialer.active = { status: 'ended', leadId: 'L1', to: '4145550101' }
    view.rerender(<QueryClientProvider client={new QueryClient()}><PowerDial caller="thalia" /></QueryClientProvider>)
    vi.useRealTimers()
    await waitFor(() => expect(logCall).toHaveBeenCalledWith('L1', '4145550101', 'no_answer', 'No answer: rang 22 s, hung up (Power hour).', null))
  })

  it('a seller calling in while a call is still ringing out: drops that call, logs it no answer, and waits (2026-10-28)', async () => {
    const view = wrap()
    await screen.findByText('Jane Q Sample')
    const again = () => view.rerender(<QueryClientProvider client={new QueryClient()}><PowerDial caller="thalia" /></QueryClientProvider>)
    dialer.active = { status: 'ringing', leadId: 'L1', to: '4145550101' }
    again()
    dialer.incoming = { from: '+14145550199', busy: true }
    again()
    expect(hangUp).toHaveBeenCalledTimes(1)
    expect(screen.getByText(/A seller is calling in/)).toBeTruthy()
    dialer.active = { status: 'ended', leadId: 'L1', to: '4145550101' }
    again()
    await waitFor(() => expect(logCall).toHaveBeenCalledWith('L1', '4145550101', 'no_answer', 'No answer: hung up while ringing to take a call coming in (Power hour).', null))
    // the keys wait while it rings: D does not dial the next card
    fireEvent.keyDown(window, { key: 'd' })
    expect(start).not.toHaveBeenCalled()
  })

  it('a texter Muse sent over (call_next) comes up next, with their words; the card she dialed stays put (0115)', async () => {
    const replied = { ...items[0], lead_id: 'L3', task_id: 'T3', source: 'replied', reply: 'maybe, depends what you would give', owner_name: 'PAT TEXTER',
      address: '300 REPLY ST', phone: '4145550133', dials_7d: 0, dials_total: 0 }
    const client = new QueryClient()
    render(<QueryClientProvider client={client}><PowerDial caller="thalia" /></QueryClientProvider>)
    await screen.findByText('Jane Q Sample')
    fireEvent.click(screen.getByText(/Dial \(414\) 555-0101/))
    items.unshift(replied as never)
    try {
      await client.refetchQueries({ queryKey: ['power_dial'] })
      // still Jane on screen (she was dialed), with the texter waiting right behind
      expect(screen.getByText('Jane Q Sample')).toBeTruthy()
      expect(await screen.findByText(/Someone just texted back/)).toBeTruthy()
      fireEvent.click(screen.getByText('No answer'))
      expect(await screen.findByText('Pat Texter')).toBeTruthy()
      expect(screen.getByText('Texted back: call now')).toBeTruthy()
      expect(screen.getByText(/maybe, depends what you would give/)).toBeTruthy()
      expect(screen.getByText(/thalia \(hot_text\)/)).toBeTruthy()
    } finally { items.shift() }
  })

  it('a seller who called us and was not reached comes first, with their voicemail and the returning-your-call opener (0117)', async () => {
    const missed = { ...items[0], lead_id: 'L4', task_id: null, source: 'missed_call', missed_at: '2026-10-28T20:22:00Z', voicemail: true,
      voicemail_words: 'I wanna move out of the state, call me back soon', owner_name: 'SAMPLE FAMILY TRUST', address: '400 CALLER RD', phone: '4145550144' }
    items.unshift(missed as never)
    try {
      wrap()
      expect(await screen.findByText('Sample Family Trust')).toBeTruthy()
      expect(screen.getByText('Called us: call back now')).toBeTruthy()
      expect(screen.getByText(/I wanna move out of the state/)).toBeTruthy()
      expect(screen.getByText(/Hi, this is Thalia, returning your call about 400 Caller Rd/)).toBeTruthy()
    } finally { items.shift() }
  })

  it('shows what already happened with the owner, texts both ways, on the card (2026-10-28)', async () => {
    wrap()
    await screen.findByText('Jane Q Sample')
    expect(await screen.findByText('What already happened (2)')).toBeTruthy()
    expect(screen.getByText('who is this')).toBeTruthy()
    expect(screen.getByText(/Hi, is this still your place on Sample St/)).toBeTruthy()
  })

  it('Disconnected (key 6) logs that number as disconnected; a call the network refused offers it (2026-10-28)', async () => {
    wrap()
    await screen.findByText('Jane Q Sample')
    fireEvent.keyDown(window, { key: '6' })
    await waitFor(() => expect(logCall).toHaveBeenCalledWith('L1', '4145550101', 'disconnected', 'Disconnected number (Power hour).', null))
  })

  it('the card she dialed stays on screen even when a refresh no longer lists it (Thalia 2026-10-28)', async () => {
    const client = new QueryClient()
    render(<QueryClientProvider client={client}><PowerDial caller="thalia" /></QueryClientProvider>)
    await screen.findByText('Jane Q Sample')
    fireEvent.click(screen.getByText(/Dial \(414\) 555-0101/))
    const jane = items.shift()!   // a call open on her card: the queue no longer lists it
    try {
      await client.refetchQueries({ queryKey: ['power_dial'] })
      await new Promise((r) => setTimeout(r, 50))
      expect(screen.getByText('Jane Q Sample')).toBeTruthy()
      expect(screen.queryByText('Robert Example')).toBeNull()
      fireEvent.click(screen.getByText('No answer'))
      expect(await screen.findByText('Robert Example')).toBeTruthy()
    } finally { items.unshift(jane) }
  })
})

