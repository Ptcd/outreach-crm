// @vitest-environment jsdom
// "Not now" on Log this call carries the date they gave (Codex's day-in-the-life walk, 2026-10-22, step 5).
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter } from 'react-router-dom'
import { afterEach, describe, expect, it, vi } from 'vitest'

const logCall = vi.fn(async () => ({ data: { ok: true }, error: null }))
vi.mock('@/lib/supabaseClient', () => ({ supabase: {}, supabaseConfigured: true }))
vi.mock('@/providers/AuthProvider', () => ({ useAuth: () => ({ user: { id: 'u2' }, member: { person: 'thalia', role: 'caller', display_name: 'Thalia', email: 't@example.com' }, isOwner: false }) }))
vi.mock('@/lib/queries', () => ({
  api: { logCall: (...a: unknown[]) => logCall(...a), callAnswer: vi.fn(async () => ({ data: { ok: true }, error: null })) },
  useWrite: () => ({ mutate: vi.fn(), isPending: false, error: null }),
}))

import { CallScript } from '@/components/CallScript'

afterEach(cleanup)
const lead = {
  id: 'L1', wpie_owner_id: 1, owner_name: 'JANE ROE', owner_type: null, mailing_street: null, mailing_city: null, mailing_state: null, mailing_zip: null,
  lane: 'flip', county: 'Milwaukee', municipality: 'Milwaukee', property_address: '100 N MAIN ST', property_zip: null, wpie_property_id: null, parcel_id: null,
  property_type: null, units: null, reasons_to_sell: [], score: null, mailed_on: null, mail_channel: null, stage: 'colin_call', stage_changed_at: '',
  next_action_at: null, next_action: null, assigned_to: 'thalia', dead_reason: null, notes: null, last_inbound_at: null, created_at: '', updated_at: '', call_facts: {},
} as never
const contact = { id: 'C1', lead_id: 'L1', kind: 'phone', value: '4145550101', value_normalized: '4145550101', person_name: null, line_type: 'mobile',
  dnc_vendor: false, dnc_scrub: 'unknown', suppressed: false, dnc_app: false, source: null, status: 'ok', note: null } as never

describe('Log this call: Not now', () => {
  it('shows a check-back date only for Not now, and saves that exact date', async () => {
    render(<QueryClientProvider client={new QueryClient()}><MemoryRouter>
      <CallScript lead={lead} contacts={[contact]} messages={[]} replyFacts={{}} latestGate={null} phone="4145550101" startOpen />
    </MemoryRouter></QueryClientProvider>)
    expect(screen.queryByLabelText(/Check back on/)).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: 'Not now' }))
    const date = screen.getByLabelText(/Check back on/) as HTMLInputElement
    expect(date.value).toBe('')
    expect((screen.getByRole('button', { name: 'Save the call' }) as HTMLButtonElement).disabled).toBe(true)
    fireEvent.change(date, { target: { value: '2026-11-05' } })
    fireEvent.click(screen.getByRole('button', { name: 'Save the call' }))
    await waitFor(() => expect(logCall).toHaveBeenCalled())
    const [id, phone, outcome, note, until] = logCall.mock.calls[0] as unknown[]
    expect([id, phone, outcome, note]).toEqual(['L1', '4145550101', 'not_now', null])
    // Noon Central is only an unambiguous date carrier. The database resolves the configured call hour.
    expect(until).toBe('2026-11-05T18:00:00.000Z')
    // other outcomes carry no date
    fireEvent.click(screen.getByRole('button', { name: 'No answer' }))
    fireEvent.click(screen.getByRole('button', { name: 'Save the call' }))
    await waitFor(() => expect(logCall).toHaveBeenCalledTimes(2))
    expect((logCall.mock.calls[1] as unknown[])[4]).toBeNull()
  })
})
