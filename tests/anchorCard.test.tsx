// @vitest-environment jsdom
// The exit anchor on the call script (migration 0149; Colin 2026-10-30): folded until the seller refuses a number or
// is leaving, then the one figure the database handed over, and what the seller said back is logged.
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter } from 'react-router-dom'
import { afterEach, describe, expect, it, vi } from 'vitest'

let mode: 'off' | 'exit_only' | 'live' = 'exit_only'
const offerShoot = vi.fn(async () => ({ data: { ok: true, mode, number: 32000, say: "I can't give you a firm number on a place we haven't seen. Rough, and going off what you've told me and what the county shows, we'd be somewhere around $32,000. Is that even in the conversation?",
  value: 105000, value_basis: "the county's estimated market value", sqft: 1000, sqft_basis: 'county records', tier: 'heavy', tier_basis: 'roof, structure, systems or damage, as they said',
  repairs: 50000, pct: 0.7, mao: 38500, lao: 32725 }, error: null }))
const offerSaid = vi.fn(async () => ({ data: { ok: true }, error: null }))
vi.mock('@/lib/supabaseClient', () => ({ supabase: {}, supabaseConfigured: true }))
vi.mock('@/providers/AuthProvider', () => ({ useAuth: () => ({ user: { id: 'u2' }, member: { person: 'thalia', role: 'caller', display_name: 'Thalia', email: 't@example.com' }, isOwner: false }) }))
vi.mock('@/lib/queries', () => ({
  api: { logCall: vi.fn(async () => ({ data: { ok: true }, error: null })), callAnswer: vi.fn(async () => ({ data: { ok: true }, error: null })),
    offerShoot: (...a: unknown[]) => offerShoot(...(a as [])), offerSaid: (...a: unknown[]) => offerSaid(...(a as [])) },
  useOfferSettings: () => ({ data: { mode } }),
  useWrite: () => ({ mutate: vi.fn(), isPending: false, error: null }),
}))

import { CallScript } from '@/components/CallScript'

afterEach(() => { cleanup(); offerShoot.mockClear(); offerSaid.mockClear() })
const lead = (facts: Record<string, unknown>) => ({
  id: 'L1', wpie_owner_id: 1, owner_name: 'JANE ROE', owner_type: null, mailing_street: null, mailing_city: null, mailing_state: null, mailing_zip: null,
  lane: 'flip', county: 'Milwaukee', municipality: 'Milwaukee', property_address: '100 N MAIN ST', property_zip: null, wpie_property_id: 9001, parcel_id: null,
  property_type: null, units: null, reasons_to_sell: [], score: null, mailed_on: null, mail_channel: null, stage: 'colin_call', stage_changed_at: '',
  next_action_at: null, next_action: null, assigned_to: 'thalia', dead_reason: null, notes: null, last_inbound_at: null, created_at: '', updated_at: '', call_facts: facts,
} as never)
const contact = { id: 'C1', lead_id: 'L1', kind: 'phone', value: '4145550101', value_normalized: '4145550101', person_name: null, line_type: 'mobile',
  dnc_vendor: false, dnc_scrub: 'unknown', suppressed: false, dnc_app: false, source: null, status: 'ok', note: null } as never
const show = (facts: Record<string, unknown>) => render(<QueryClientProvider client={new QueryClient()}><MemoryRouter>
  <CallScript lead={lead(facts)} contacts={[contact]} messages={[]} replyFacts={{}} latestGate={null} phone="4145550101" startOpen />
</MemoryRouter></QueryClientProvider>)

describe('the exit anchor on the call script', () => {
  it('off: nothing about a number anywhere', () => {
    mode = 'off'
    show({})
    expect(screen.queryByRole('button', { name: /Open the anchor/ })).toBeNull()
    expect(screen.queryByText(/The anchor: one low number/)).toBeNull()
    expect(offerShoot).not.toHaveBeenCalled()
  })

  it('exit only: folded, and no figure is fetched, until the seller has refused; then the one number and the line to say', async () => {
    mode = 'exit_only'
    show({})
    expect(screen.getByRole('button', { name: /won.t say a number, or they.re leaving\? Open the anchor/ })).toBeTruthy()
    expect(offerShoot).not.toHaveBeenCalled()
    cleanup()
    show({ price: { value: { choices: ['refused'] }, at: '2026-10-30T22:00:00Z' } })
    await waitFor(() => expect(offerShoot).toHaveBeenCalledWith('L1'))
    await screen.findByText(/somewhere around \$32,000/)
    expect(screen.getByText(/Say only \$32,000, and say it is rough/)).toBeTruthy()
    // logging needs what they said back; a counter needs their number
    const log = screen.getByRole('button', { name: /I said it/ }) as HTMLButtonElement
    expect(log.disabled).toBe(true)
    fireEvent.click(screen.getByRole('button', { name: 'They said a number' }))
    expect(log.disabled).toBe(true)
    fireEvent.change(screen.getByPlaceholderText(/Their number \(\$\), as said/), { target: { value: '60,000' } })
    expect(log.disabled).toBe(false)
    fireEvent.click(log)
    await waitFor(() => expect(offerSaid).toHaveBeenCalledWith('L1', 32000, 'gave_number', 60000, null))
    // the card now shows it was said, and what they said
    await screen.findByText(/Around \$32,000, non-firm\. They: They said a number, \$60,000/)
  })

  it('already said on this card: shown as said, nothing fetched again', () => {
    mode = 'exit_only'
    show({ our_number: { value: { number: '32000', choices: ['open'] }, at: '2026-10-30T22:00:00Z', by: 'Thalia' } })
    expect(screen.getByText(/Around \$32,000, non-firm\. They: Open to it/)).toBeTruthy()
    expect(offerShoot).not.toHaveBeenCalled()
  })

  it('live: open on every call', async () => {
    mode = 'live'
    show({})
    await waitFor(() => expect(offerShoot).toHaveBeenCalled())
    await screen.findByText(/somewhere around \$32,000/)
  })
})
