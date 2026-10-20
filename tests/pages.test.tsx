// @vitest-environment jsdom
// Smoke test: every page renders with sample data (data hooks and auth are mocked).
import { cleanup, render, screen } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { ReactNode } from 'react'

const lead = {
  id: 'L1', wpie_owner_id: 100561, owner_name: 'JANE ROE', owner_type: 'individual', mailing_street: '1 A ST',
  mailing_city: 'MILWAUKEE', mailing_state: 'WI', mailing_zip: '53202', lane: 'hold', county: 'Milwaukee',
  municipality: 'Milwaukee', property_address: '100 N MAIN ST', property_zip: '53202', wpie_property_id: 11,
  parcel_id: 'P-11', property_type: 'residential', units: 4, reasons_to_sell: ['tired landlord'], score: 412.5,
  mailed_on: '2026-10-20', mail_channel: 'postcard', stage: 'colin_call', stage_changed_at: '2026-10-21T15:00:00Z',
  next_action_at: '2026-10-22T15:00:00Z', next_action: 'call back', assigned_to: 'colin', dead_reason: null,
  notes: null, last_inbound_at: null, created_at: '2026-10-20T00:00:00Z', updated_at: '2026-10-20T00:00:00Z',
}
const ok = <T,>(data: T) => ({ data, error: null, isLoading: false, isPending: false, isSuccess: false })
const mutation = { mutate: vi.fn(), isPending: false, isSuccess: false, error: null }

vi.mock('@/lib/supabaseClient', () => ({ supabase: {}, supabaseConfigured: true }))
vi.mock('@/providers/AuthProvider', () => ({
  useAuth: () => ({
    user: { id: 'u1', email: 'colin@example.com' },
    member: { email: 'colin@example.com', role: 'owner', person: 'colin', display_name: 'Colin' },
    isOwner: true, loading: false, signOut: vi.fn(), sendMagicLink: vi.fn(),
  }),
}))
vi.mock('@/lib/queries', () => ({
  PAGE_SIZE: 50,
  api: {},
  useWrite: () => mutation,
  useDueTasks: () => ok([{ id: 'T1', lead_id: 'L1', due_at: '2026-10-20T15:00:00Z', kind: 'call', owner: 'colin', done_at: null, note: 'after 5', created_at: '', lead }]),
  useUnseenReplies: () => ok([{ id: 'M1', lead_id: 'L1', direction: 'in', channel: 'sms', body: 'Who is this?', sent_at: '2026-10-21T16:00:00Z', seen_at: null, is_opt_out: false, is_opener: false, status: 'replied', lead }]),
  useFollowupDebt: () => ok([]),
  usePipelineCounts: () => ok([{ stage: 'colin_call', lane: 'hold', county: 'Milwaukee', n: 1 }, { stage: 'postcard_mailed', lane: 'flip', county: 'Racine', n: 4999 }]),
  useLeads: () => ok({ rows: [lead], count: 1 }),
  useLead: () => ok({
    lead,
    contacts: [{ id: 'C1', lead_id: 'L1', kind: 'phone', value: '4145550101', value_normalized: '4145550101', person_name: 'JANE ROE', line_type: 'mobile', dnc_vendor: false, dnc_scrub: 'unknown', suppressed: true, dnc_app: false, source: 'fiverr', status: 'ok', note: null }],
    messages: [{ id: 'M1', lead_id: 'L1', direction: 'out', channel: 'sms', body: 'Hi Jane', sent_at: '2026-10-21T15:00:00Z', seen_at: null, is_opt_out: false, is_opener: true, status: 'delivered', from_number: null, to_number: null }],
    tasks: [], gates: [], milestones: [{ id: 1, lead_id: 'L1', kind: 'connect', at: '2026-10-21T16:00:00Z' }],
  }),
  useDeals: () => ok([]),
  usePlannedOpeners: () => ok([{ id: 'P1', plan_date: '2026-10-22', wpie_owner_id: 2, attempt: 1, lead_id: 'L1', lane: 'flip', template_lane: 'llc', variant: 'A', phone: '+14145550200', body: 'Hi, this is Colin Merrill with Merrill Holdings.', segments: 2, scheduled_at: '2026-10-22T15:00:00Z', owner_name: 'ACME LLC', property_address: '200 S OAK AV', decision: 'pending', decided_by_name: null, decided_at: null, decision_note: null }]),
  useScoreboard: () => ok([{ week_start: '2026-10-19', lane: 'all', openers_sent: 100, delivered: 92, replies: 7, opt_outs: 2, connects: 6, contacts: 5, leads: 2, handoffs: 1, handoffs_held: 1, qualifying_calls: 1, walks: 1, contracts: 0, closes: 0, delivery_rate: 0.92, reply_rate: 0.0761, opt_out_rate: 0.0217, contact_rate: 0.8333, leads_per_delivered: 0.0217, handoffs_held_rate: 1, walk_rate: 1, walks_per_contract: null }]),
  useSignalScoreboard: () => ok([{ week_start: '2026-10-19', signal: 'tired landlord', openers_sent: 40, delivered: 37, replies: 3, opt_outs: 1, leads: 1, walks: 0, contracts: 0 }]),
}))

import Today from '@/pages/Today'
import Pipeline from '@/pages/Pipeline'
import LeadDetail from '@/pages/LeadDetail'
import Approvals from '@/pages/Approvals'
import Scoreboard from '@/pages/Scoreboard'

afterEach(cleanup)

function at(path: string, route: string, el: ReactNode) {
  return render(
    <QueryClientProvider client={new QueryClient()}>
      <MemoryRouter initialEntries={[path]}>
        <Routes>
          <Route path={route} element={el} />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>,
  )
}

describe('pages render', () => {
  it('Today shows replies and due follow-ups', () => {
    at('/today', '/today', <Today />)
    expect(screen.getByText('Who is this?')).toBeTruthy()
    expect(screen.getByText('after 5', { exact: false })).toBeTruthy()
  })

  it('Pipeline shows stage counts and the lead', () => {
    at('/pipeline', '/pipeline', <Pipeline />)
    expect(screen.getByText('JANE ROE')).toBeTruthy()
    expect(screen.getByRole('button', { name: /Being worked 1/ })).toBeTruthy()
  })

  it('Lead detail shows facts, DNC flags, history, gate and the deal box', () => {
    at('/lead/L1', '/lead/:id', <LeadDetail />)
    expect(screen.getByText('tired landlord')).toBeTruthy()
    expect(screen.getByText('Texted STOP')).toBeTruthy()
    expect(screen.getByText('Hi Jane')).toBeTruthy()
    expect(screen.getAllByRole('radiogroup')).toHaveLength(6)
    expect(screen.getByText('Deal (Colin only)')).toBeTruthy()
    expect(screen.getByText(/never suggests an offer/)).toBeTruthy()
  })

  it('Approvals shows the planned text with Approve and Skip', () => {
    at('/approvals', '/approvals', <Approvals />)
    expect(screen.getByText(/Merrill Holdings/)).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Approve' })).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Skip' })).toBeTruthy()
  })

  it('Scoreboard shows the weekly numbers', () => {
    at('/scoreboard', '/scoreboard', <Scoreboard />)
    expect(screen.getByText('92.0%')).toBeTruthy()
    expect(screen.getByText('Walks per contract')).toBeTruthy()
  })
})
