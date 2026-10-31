// @vitest-environment jsdom
// The "call coming in" bar and the in-call bar for a call that came in, with the dialer stubbed: the bar
// names the matched owner and property, Accept opens the lead card with the call script, Decline leaves
// the cell ringing, and a stranger's call offers the call desk's new-caller card. Pages without a
// DialerProvider render nothing of this.
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter, Route, Routes, useLocation } from 'react-router-dom'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { ActiveCall, IncomingCall } from '../src/lib/dialer'

const dialer = {
  active: null as ActiveCall | null, incoming: null as IncomingCall | null, supported: true, ready: true,
  start: vi.fn(), accept: vi.fn(), decline: vi.fn(), hangUp: vi.fn(), toggleMute: vi.fn(), dismiss: vi.fn(),
}
vi.mock('@/lib/supabaseClient', () => ({ supabase: {}, supabaseConfigured: true }))
vi.mock('@/providers/AuthProvider', () => ({ useAuth: () => ({ member: { display_name: 'Colin' }, signOut: vi.fn() }) }))
vi.mock('@/lib/queries', () => ({
  useRepliesWaiting: () => ({ data: { drafts_waiting: 0, tasks_open: 0 } }),
  useOfferSettings: () => ({ data: null }),
  api: { newCaller: vi.fn(async () => ({ data: { ok: true, lead_id: 'NEW1' }, error: null })), logCall: vi.fn(async () => ({ error: null })) },
}))
vi.mock('@/lib/dialer', async (orig) => ({ ...(await orig<typeof import('../src/lib/dialer')>()), useDialer: () => dialer }))

import { IncomingCallBar } from '../src/components/IncomingCallBar'
import { CallBar } from '../src/components/CallBar'
import { Layout } from '../src/components/Layout'
import { api } from '../src/lib/queries'

function Where() { const l = useLocation(); return <p data-testid="where">{l.pathname}{l.search}</p> }
const mount = (ui: React.ReactNode) => render(
  <MemoryRouter initialEntries={['/today']}>
    <Routes><Route path="*" element={<>{ui}<Where /></>} /></Routes>
  </MemoryRouter>)
const jane = { lead_id: 'L1', owner_name: 'JANE ROE', property_address: '100 N MAIN ST', municipality: 'Milwaukee', lane: 'hold',
  stage: 'colin_call' as const, phone: '4145550101', person_name: null, blocked: false, exact: true }

afterEach(() => { cleanup(); dialer.active = null; dialer.incoming = null; vi.clearAllMocks() })

describe('a call coming in', () => {
  it('shows nothing while no call rings, and the ready dot when registered', () => {
    mount(<Layout><p>page</p></Layout>)
    expect(screen.queryByRole('alert')).toBeNull()
    expect(screen.getByText('Ready for calls')).toBeTruthy()
  })

  it('names the matched owner and property while ringing; Accept opens the card with the call script', async () => {
    dialer.incoming = { from: '+14145550101', line: '+12624180202', matches: [jane], lookupError: null, busy: false }
    dialer.accept.mockResolvedValue({ leadId: 'L1', phone: '4145550101' })
    mount(<IncomingCallBar />)
    const bar = screen.getByRole('alert')
    expect(bar.textContent).toContain('Call coming in on (262) 418-0202')
    expect(bar.textContent).toContain('JANE ROE - 100 N MAIN ST, Milwaukee')
    expect(bar.textContent).toContain('(414) 555-0101')
    fireEvent.click(screen.getByRole('button', { name: 'Accept' }))
    expect(dialer.accept).toHaveBeenCalledTimes(1)
    await waitFor(() => expect(screen.getByTestId('where').textContent).toBe('/lead/L1?call=1&phone=4145550101'))
  })

  it('says it is still looking, then that a stranger is calling; Decline only rejects here', () => {
    dialer.incoming = { from: '+14145550199', line: null, matches: null, lookupError: null, busy: false }
    const r = mount(<IncomingCallBar />)
    expect(screen.getByRole('alert').textContent).toContain('Looking them up...')
    r.unmount()
    dialer.incoming = { from: '+14145550199', line: null, matches: [], lookupError: null, busy: false }
    mount(<IncomingCallBar />)
    expect(screen.getByRole('alert').textContent).toContain('Not in the list - a new caller')
    fireEvent.click(screen.getByRole('button', { name: 'Decline' }))
    expect(dialer.decline).toHaveBeenCalledTimes(1)
    expect(dialer.accept).not.toHaveBeenCalled()
  })

  it('rings in while she is on a call: says so, and Accept reads "Hang up and answer" (2026-10-28)', () => {
    dialer.active = { status: 'in_call', to: '4145550101', label: 'JANE ROE', leadId: 'L9', startedAt: Date.now(), muted: false,
      error: null, answered: true, inbound: false, line: null }
    dialer.incoming = { from: '+14145550101', line: '+12624180202', matches: [jane], lookupError: null, busy: true }
    mount(<IncomingCallBar />)
    expect(screen.getByRole('alert').textContent).toContain('while you are on a call: take it')
    expect(screen.getByRole('button', { name: 'Hang up and answer' })).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Let it go to Colin' })).toBeTruthy()
  })

  it('a stranger on the line gets a New caller card from the in-call bar, which opens with the script', async () => {
    dialer.active = { status: 'in_call', to: '+14145550199', label: '(414) 555-0199', leadId: null, startedAt: Date.now(), muted: false,
      error: null, answered: true, inbound: true, line: '+12624180202' }
    mount(<CallBar />)
    expect(screen.getByRole('status').textContent).toContain('calling in from (414) 555-0199 on (262) 418-0202')
    fireEvent.click(screen.getByRole('button', { name: 'New caller' }))
    expect(api.newCaller).toHaveBeenCalledWith('4145550199')
    await waitFor(() => expect(screen.getByTestId('where').textContent).toBe('/lead/NEW1?call=1&phone=4145550199'))
  })

  it('a matched caller gets Open card during the call and Log the call after it; an outbound call is unchanged', () => {
    dialer.active = { status: 'in_call', to: '+14145550101', label: 'JANE ROE - 100 N MAIN ST', leadId: 'L1', startedAt: Date.now(), muted: false,
      error: null, answered: true, inbound: true, line: null }
    const r = mount(<CallBar />)
    expect(screen.getByRole('link', { name: 'Open card' }).getAttribute('href')).toBe('/lead/L1?call=1&phone=4145550101')
    expect(screen.queryByRole('button', { name: 'New caller' })).toBeNull()
    r.unmount()
    dialer.active = { ...dialer.active, status: 'ended' }
    mount(<CallBar />)
    expect(screen.getByRole('link', { name: 'Log the call' }).getAttribute('href')).toBe('/lead/L1?call=1#call-script')
    cleanup()
    dialer.active = { status: 'ringing', to: '+14145550101', label: 'JANE ROE - 100 N MAIN ST', leadId: 'L1', startedAt: null, muted: false,
      error: null, answered: false, inbound: false, line: null }
    mount(<CallBar />)
    expect(screen.getByRole('status').textContent).toContain('Ringing... from (414) 555-0101')
    expect(screen.queryByRole('button', { name: 'New caller' })).toBeNull()
  })

  it('a finished outbound call asks how it went: No answer logs in one tap, We talked opens the script', async () => {
    const { api } = await import('@/lib/queries')
    dialer.active = { status: 'ended', to: '+17158965632', label: 'DONALD - 109 W 3RD ST', leadId: 'L2', startedAt: null, muted: false,
      error: null, answered: true, inbound: false, line: null }
    mount(<CallBar />)
    expect(screen.getByText('How did it go?')).toBeTruthy()
    expect(screen.getByRole('link', { name: 'We talked: log it' }).getAttribute('href')).toBe('/lead/L2?call=1#call-script')
    screen.getByRole('button', { name: "Couldn't hear" }).click()
    await new Promise((r) => setTimeout(r, 0))
    expect(api.logCall).toHaveBeenCalledWith('L2', '7158965632', 'no_answer', expect.stringContaining("couldn't hear"))
    expect(dialer.dismiss).toHaveBeenCalled()
  })
})
