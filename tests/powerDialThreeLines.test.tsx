// @vitest-environment jsdom
// Power hour with three lines (Colin 2026-11-13): Dial rings the card on screen and the next two cold cards together;
// the card of whoever picks up comes up; the lines that did not become the call are logged by themselves. A callback
// or someone who texted back is always dialed alone, and with the switch off nothing changes.
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { afterEach, describe, expect, it, vi } from 'vitest'

const card = (n: number, source = 'call_list') => ({ lead_id: `L${n}`, task_id: null, source, why: null, owner_name: `OWNER NUMBER${n}`, address: `${n}00 SAMPLE ST`,
  municipality: 'Milwaukee', reasons: [], lane: 'flip', texts_sent: 0, first_text_at: null, last_text_at: null, dials_7d: 0, last_dial: null,
  phone: `414555010${n}`, line_type: 'mobile', phone_person: null, other_phones: 0 })
let items = [card(1), card(2), card(3), card(4)]
const logCall = vi.fn(async () => ({ data: { ok: true }, error: null }))
const start = vi.fn(async () => undefined)
const startLines = vi.fn(async () => undefined)
const hangUp = vi.fn()
const dismiss = vi.fn()
type Result = { leadId: string; to: string; label: string; outcome: string; error: string | null; rang: boolean }
const dialer: { active: null | { status: string; leadId: string; to: string; answered?: boolean }; incoming: null; lineResults: Result[] } = { active: null, incoming: null, lineResults: [] }
const takeLineResults = vi.fn(() => { const r = dialer.lineResults; dialer.lineResults = []; return r })
const rpc = vi.fn(async (fn: string) => (fn === 'power_dial_queue' ? { data: [...items], error: null } : { data: { ok: true }, error: null }))
const chain = { select: () => chain, eq: () => chain, in: () => chain, order: () => chain, limit: async () => ({ data: [], error: null }) }
vi.mock('@/lib/supabaseClient', () => ({ supabase: { rpc: (...a: unknown[]) => rpc(...(a as [string])), from: () => chain }, supabaseConfigured: true }))
vi.mock('@/lib/queries', () => ({ api: { logCall: (...a: unknown[]) => logCall(...(a as [])) }, useLead: () => ({ isLoading: true }), useOfferSettings: () => ({ data: null }) }))
vi.mock('@/lib/dialer', () => ({ useDialer: () => ({ active: dialer.active, incoming: dialer.incoming, start, startLines, lineResults: dialer.lineResults, takeLineResults, dismiss, hangUp, supported: true }) }))
vi.mock('@/components/CallScript', () => ({ CallScript: () => null, pickupLine: () => 'Hi' }))

import { PowerDial } from '@/components/PowerDial'

const ui = () => <QueryClientProvider client={new QueryClient()}><PowerDial caller="adil" /></QueryClientProvider>
afterEach(() => { cleanup(); localStorage.clear(); for (const f of [logCall, start, startLines, hangUp, dismiss, takeLineResults, rpc]) f.mockClear()
  dialer.active = null; dialer.lineResults = []; items = [card(1), card(2), card(3), card(4)] })

describe('Power hour, three lines', () => {
  it('is off until switched on, and then Dial rings this card and the next two together', async () => {
    render(ui())
    await screen.findByText('Owner Number1')
    expect(screen.getByText(/Dial \(414\) 555-0101/)).toBeTruthy()
    fireEvent.click(screen.getByTestId('three-lines'))
    expect(localStorage.getItem('power:lines')).toBe('3')
    fireEvent.click(await screen.findByText('Dial 3 lines'))
    await waitFor(() => expect(startLines).toHaveBeenCalled())
    expect(startLines.mock.calls[0][0]).toEqual([
      expect.objectContaining({ leadId: 'L1', to: '4145550101' }), expect.objectContaining({ leadId: 'L2', to: '4145550102' }), expect.objectContaining({ leadId: 'L3', to: '4145550103' })])
    expect(start).not.toHaveBeenCalled()
    expect(rpc).toHaveBeenCalledWith('power_claim', { p_lead_id: 'L2' })       // the other two cards are held for this caller
    expect(await screen.findByText(/3 dialed/)).toBeTruthy()
  })

  it('the card of whoever picked up comes up, and the other lines are logged by themselves', async () => {
    localStorage.setItem('power:lines', '3')
    const view = render(ui())
    await screen.findByText('Owner Number1')
    fireEvent.click(screen.getByText('Dial 3 lines'))
    await waitFor(() => expect(startLines).toHaveBeenCalled())
    dialer.active = { status: 'in_call', leadId: 'L3', to: '4145550103', answered: true }
    dialer.lineResults = [
      { leadId: 'L1', to: '4145550101', label: 'x', outcome: 'machine', error: null, rang: true },
      { leadId: 'L2', to: '4145550102', label: 'x', outcome: 'other_line_answered', error: null, rang: true }]
    view.rerender(ui())
    expect(await screen.findByText('Owner Number3')).toBeTruthy()
    await waitFor(() => expect(logCall).toHaveBeenCalledTimes(2))
    expect(logCall).toHaveBeenCalledWith('L1', '4145550101', 'no_answer', expect.stringContaining('voicemail picked up'), null)
    expect(logCall).toHaveBeenCalledWith('L2', '4145550102', 'no_answer', expect.stringContaining('another line picked up'), null)
    expect(await screen.findByText(/1 voicemails/)).toBeTruthy()
  })

  it('a round nobody answered logs all three and brings the next card; a line that never rang is not logged', async () => {
    localStorage.setItem('power:lines', '3')
    const view = render(ui())
    await screen.findByText('Owner Number1')
    fireEvent.click(screen.getByText('Dial 3 lines'))
    await waitFor(() => expect(startLines).toHaveBeenCalled())
    dialer.active = { status: 'ended', leadId: 'L1', to: '4145550101', answered: false }
    dialer.lineResults = [
      { leadId: 'L1', to: '4145550101', label: 'x', outcome: 'no_answer', error: null, rang: true },
      { leadId: 'L2', to: '4145550102', label: 'x', outcome: 'failed', error: 'this card is closed or do-not-contact', rang: false },
      { leadId: 'L3', to: '4145550103', label: 'x', outcome: 'no_answer', error: null, rang: true }]
    view.rerender(ui())
    await waitFor(() => expect(logCall).toHaveBeenCalledTimes(2))
    expect(logCall).not.toHaveBeenCalledWith('L2', expect.anything(), expect.anything(), expect.anything(), null)
    expect(dismiss).toHaveBeenCalled()
    dialer.active = null
    view.rerender(ui())
    expect(await screen.findByText('Owner Number4')).toBeTruthy()
  })

  it('someone who was cut off stays on the list to be called back', async () => {
    localStorage.setItem('power:lines', '3')
    const view = render(ui())
    await screen.findByText('Owner Number1')
    fireEvent.click(screen.getByText('Dial 3 lines'))
    await waitFor(() => expect(startLines).toHaveBeenCalled())
    dialer.active = { status: 'in_call', leadId: 'L1', to: '4145550101', answered: true }
    dialer.lineResults = [{ leadId: 'L2', to: '4145550102', label: 'x', outcome: 'dropped_after_pickup', error: null, rang: true }]
    view.rerender(ui())
    await waitFor(() => expect(logCall).toHaveBeenCalledWith('L2', '4145550102', 'no_answer', expect.stringContaining('Call them back first'), null))
    expect(screen.getByText(/4 left/)).toBeTruthy()          // still on the list
  })

  it('a callback is dialed alone even with three lines on', async () => {
    localStorage.setItem('power:lines', '3')
    items = [card(1, 'callback'), card(2), card(3)]
    render(ui())
    await screen.findByText('Owner Number1')
    fireEvent.click(screen.getByText(/Dial \(414\) 555-0101/))
    expect(start).toHaveBeenCalledWith(expect.objectContaining({ leadId: 'L1' }))
    expect(startLines).not.toHaveBeenCalled()
  })
})
