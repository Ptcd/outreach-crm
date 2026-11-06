// @vitest-environment jsdom
// Power hour holds an interested seller's card until the package goes (Adil 2026-11-06, the Webers on Phlox Drive:
// logging Interested brought the next card, the package form under the script went with it, and Colin never got the
// package). Any other outcome from the script still brings the next card at once.
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { afterEach, describe, expect, it, vi } from 'vitest'

const items = [
  { lead_id: 'L1', task_id: null, source: 'call_list', why: null, owner_name: 'COLLEEN A WEBER', address: '1 SAMPLE DR', municipality: 'Bloomfield',
    reasons: ['pre-foreclosure'], lane: 'flip', texts_sent: 0, first_text_at: null, last_text_at: null,
    dials_7d: 0, last_dial: null, phone: '4145550101', line_type: 'mobile', phone_person: null, other_phones: 0 },
  { lead_id: 'L2', task_id: null, source: 'call_list', why: null, owner_name: 'ROBERT EXAMPLE', address: '200 EXAMPLE AV', municipality: 'West Allis',
    reasons: [], lane: 'flip', texts_sent: 0, first_text_at: null, last_text_at: null, dials_7d: 0, last_dial: null,
    phone: '4145550144', line_type: 'mobile', phone_person: null, other_phones: 0 },
]
const chain = { select: () => chain, eq: () => chain, in: () => chain, gte: () => chain, order: () => chain, limit: async () => ({ data: [], error: null }) }
vi.mock('@/lib/supabaseClient', () => ({ supabase: { rpc: vi.fn(async () => ({ data: [...items], error: null })), from: () => chain }, supabaseConfigured: true }))
vi.mock('@/lib/queries', () => ({
  api: { logCall: vi.fn(async () => ({ data: { ok: true }, error: null })) },
  useLead: (id: string) => ({ isLoading: false, error: null, data: { lead: { id, call_facts: {} }, contacts: [], messages: [], gates: [], facts: {} } }),
  useOfferSettings: () => ({ data: null }),
}))
vi.mock('@/lib/dialer', () => ({ useDialer: () => ({ active: null, incoming: null, start: vi.fn(), dismiss: vi.fn(), hangUp: vi.fn(), supported: true }) }))
vi.mock('@/components/CallScript', () => ({
  CallScript: ({ onLogged }: { onLogged?: (o: string) => void }) => (
    <div>
      <button onClick={() => onLogged?.('interested')}>script: interested</button>
      <button onClick={() => onLogged?.('not_interested')}>script: not interested</button>
    </div>
  ),
  pickupLine: (c: string) => `Hi, this is ${c}`,
}))
vi.mock('@/components/DealPackage', () => ({ DealPackage: ({ lead }: { lead: { id: string } }) => <div>package form for {lead.id}</div> }))

import { PowerDial } from '@/components/PowerDial'

const wrap = () => render(<QueryClientProvider client={new QueryClient()}><PowerDial caller="adil" /></QueryClientProvider>)
afterEach(() => { cleanup(); localStorage.clear() })

describe('Power hour and the package', () => {
  it('an interested seller stays on screen with the package form until Next card', async () => {
    wrap()
    expect(await screen.findByText('Colleen A Weber')).toBeTruthy()
    fireEvent.click(screen.getByText(/We talked: script/))
    fireEvent.click(await screen.findByText('script: interested'))
    expect(await screen.findByText(/Logged as interested/)).toBeTruthy()
    expect(screen.getByText('package form for L1')).toBeTruthy()
    expect(screen.getByText('Colleen A Weber')).toBeTruthy()
    fireEvent.click(screen.getByText('Next card'))
    expect(await screen.findByText('Robert Example')).toBeTruthy()
    expect(screen.queryByText(/Logged as interested/)).toBeNull()
  })

  it('any other outcome from the script brings the next card at once', async () => {
    wrap()
    expect(await screen.findByText('Colleen A Weber')).toBeTruthy()
    fireEvent.click(screen.getByText(/We talked: script/))
    fireEvent.click(await screen.findByText('script: not interested'))
    expect(await screen.findByText('Robert Example')).toBeTruthy()
    expect(screen.queryByText(/Logged as interested/)).toBeNull()
  })
})
