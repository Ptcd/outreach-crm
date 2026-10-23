// @vitest-environment jsdom
// Smoke test: every page renders with sample data (data hooks and auth are mocked).
import { cleanup, fireEvent, render, screen, within } from '@testing-library/react'
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
  call_facts: { motivation: { value: { choices: ['tired_landlord'] }, at: '2026-10-21T19:00:00Z', by: 'Adil' }, timeline: { value: { choices: ['under_30'] }, at: '2026-10-21T19:00:00Z' } },
  notes: null, last_inbound_at: null, created_at: '2026-10-20T00:00:00Z', updated_at: '2026-10-20T00:00:00Z',
}
const ok = <T,>(data: T) => ({ data, error: null, isLoading: false, isPending: false, isSuccess: false })
const mutation = { mutate: vi.fn(), isPending: false, isSuccess: false, error: null }

vi.mock('@/lib/supabaseClient', () => ({ supabase: {}, supabaseConfigured: true }))
vi.mock('@/providers/AuthProvider', () => ({
  useAuth: () => ({
    user: { id: 'u1', email: 'colin@example.com' },
    member: { email: 'colin@example.com', role: 'owner', person: 'colin', display_name: 'Colin' },
    isOwner: true, loading: false, signOut: vi.fn(), recovering: false, signInWithPassword: vi.fn(), sendPasswordLink: vi.fn(), setPassword: vi.fn(),
  }),
}))
vi.mock('@/lib/queries', () => ({
  PAGE_SIZE: 50,
  api: { contractSign: vi.fn(async () => ({ ok: true, view: { contract_id: 'K1', signer_id: 'S1', status: 'sent', form: 'WB-11 10-1-2026', include_recr: true, recr: null,
    buyer_name: 'Colin Merrill', signer: { name: 'Jane Roe', position: 1, signed_at: null }, others: [], offer_url: 'https://x/offer.pdf', final_url: null,
    terms: { street: '100 N Main St', muniName: 'Milwaukee', county: 'Milwaukee', price: 182500, earnestMoney: 1000, earnestHolder: 'Knight Barry Title',
      closing: 'November 20, 2026', bindingDeadline: 'October 24, 2026 at 11:59 p.m.', inspection: true, inspectionDays: 10, proofOfFundsDays: 5 } } })) },
  useWrite: () => mutation,
  usePhoneLookup: (d: string) => ok(d.replace(/\D/g, '').length >= 3 ? [
    { lead_id: 'L1', owner_name: 'JANE ROE', property_address: '100 N MAIN ST', municipality: 'Milwaukee', lane: 'hold', stage: 'colin_call', phone: '4145550101', person_name: null, blocked: false, exact: false },
    { lead_id: 'L9', owner_name: 'BO KIM', property_address: '400 N PINE ST', municipality: 'Milwaukee', lane: 'flip', stage: 'dnc', phone: '2625550101', person_name: null, blocked: true, exact: false }] : []),
  useHotAlerts: () => ok([{ id: 'H1', created_at: '2026-10-22T15:10:00Z', body: 'yes still mine', alert1_at: '2026-10-22T15:10:30Z', alert2_at: null, called_at: null, is_test: false, phone10: '4145550101' }]),
  useContracts: () => ok([{ id: 'K1', lead_id: 'L1', form: 'WB-11 10-1-2026', status: 'sent', created_at: '2026-10-21T19:00:00Z', signed_at: null,
    voided_at: null, void_reason: null, final_path: null, include_recr: true, terms: { price: 182500, closing: 'November 20, 2026', street: '100 N Main St' },
    contract_signers: [{ id: 'S1', position: 1, name: 'Jane Roe', email: null, phone: null, opened_at: '2026-10-21T20:00:00Z', signed_at: null, expires_at: '2026-11-04T19:00:00Z' }] }]),
  useDueTasks: () => ok([{ id: 'T1', lead_id: 'L1', due_at: '2026-10-20T15:00:00Z', kind: 'call', owner: 'colin', done_at: null, note: 'after 5', created_at: '', lead }]),
  useUnseenReplies: () => ok([{ id: 'M1', lead_id: 'L1', direction: 'in', channel: 'sms', body: 'Who is this?', sent_at: '2026-10-21T16:00:00Z', seen_at: null, is_opt_out: false, is_opener: false, status: 'replied', lead }]),
  useFollowupDebt: () => ok([]),
  // the conveyor's pieces (migrations 0029-0032): nothing on the belt in this fixture
  useMyStops: () => ok([]),
  useCardsNoStop: () => ok([]),
  useSellerRecovery: () => ok([]),
  useBeltEvents: () => ok([]),
  useBeltMaxSteps: () => ok({}),
  useBeltHealth: () => ok(null),
  useTouchTemplates: () => ok([]),
  usePipelineCounts: () => ok([{ stage: 'colin_call', lane: 'hold', county: 'Milwaukee', n: 1 }, { stage: 'postcard_mailed', lane: 'flip', county: 'Racine', n: 4999 }]),
  useLeads: () => ok({ rows: [lead], count: 1 }),
  useLead: () => ok({
    lead,
    contacts: [{ id: 'C1', lead_id: 'L1', kind: 'phone', value: '4145550101', value_normalized: '4145550101', person_name: 'JANE ROE', line_type: 'mobile', dnc_vendor: false, dnc_scrub: 'unknown', suppressed: true, dnc_app: false, source: 'fiverr', status: 'ok', note: null }],
    messages: [{ id: 'M1', lead_id: 'L1', direction: 'out', channel: 'sms', body: 'Hi Jane', sent_at: '2026-10-21T15:00:00Z', seen_at: null, is_opt_out: false, is_opener: true, status: 'delivered', from_number: null, to_number: null }],
    tasks: [{ id: 'T9', lead_id: 'L1', due_at: '2026-10-21T16:00:00Z', kind: 'email', owner: 'adil', done_at: null, note: null, created_at: '2026-10-21T16:00:00Z', source: 'reply', title: 'Email them the info they asked for', quote: 'Can you email me at jane@example.com?', email_to: 'jane@example.com', phone10: '4145550101' }], gates: [], milestones: [{ id: 1, lead_id: 'L1', kind: 'connect', at: '2026-10-21T16:00:00Z' }],
    facts: { motivation: 'tired of tenants', timeline: 'by spring', quotes: ['done with it'] },
  }),
  useReplyTasks: () => ok([{ id: 'T9', lead_id: 'L1', due_at: '2026-10-21T16:00:00Z', kind: 'email', owner: 'adil', done_at: null, note: null, created_at: '2026-10-21T16:00:00Z', source: 'reply', title: 'Email them the info they asked for', quote: 'Can you email me at jane@example.com?', email_to: 'jane@example.com', phone10: '4145550101', lead }]),
  useDeals: () => ok([]),
  usePlannedOpeners: () => ok([{ id: 'P1', plan_date: '2026-10-22', wpie_owner_id: 2, attempt: 1, lead_id: 'L1', lane: 'flip', template_lane: 'llc', variant: 'A', phone: '+14145550200', body: 'Hi, this is Colin Merrill with Merrill Holdings.', segments: 2, scheduled_at: '2026-10-22T15:00:00Z', owner_name: 'ACME LLC', property_address: '200 S OAK AV', decision: 'pending', decided_by_name: null, decided_at: null, decision_note: null, send_status: 'planned', send_reason: null, claimed_at: null, sent_at: null, error_code: null }]),
  useOtherDrafts: () => ok([{ id: 'D9', inbound_sid: 'SMd9', phone10: '2625550111', our_number: '+12624180202', lead_id: null,
    inbound_body: 'wrong number', inbound_at: '2026-10-21T17:00:00Z', intent: 'wrong_number', kind: 'routine', outcome: 'wrong_number',
    note: null, body: 'Sorry about that - looks like we had the wrong number.', draft_source: 'fixed_line', status: 'would_send',
    send_after: null, sent_body: null, sent_at: null, decided_by: null, decided_at: null, is_test: true }]),
  useRepliesWaiting: () => ok({ drafts_waiting: 1, routine_would_send: 1, queued: 0, tasks_open: 1 }),
  useWaitingDrafts: () => ok([{ id: 'D1', inbound_sid: 'SMd1', phone10: '4145550300', our_number: '+12629996513', lead_id: 'L2',
    inbound_body: 'Maybe, who is buying?', inbound_at: '2026-10-21T16:00:00Z', intent: 'buyer_check', kind: 'candidate', outcome: 'open',
    note: null, body: 'Good question - I buy them myself. Is the place still yours?', draft_source: 'claude', status: 'awaiting_approval',
    send_after: null, sent_body: null, sent_at: null, decided_by: null, decided_at: null, is_test: false,
    owner_name: 'ANN LEE', property_address: '300 W ELM ST', thread: [{ key: 'o', who: 'us', body: 'Hi Ann, Colin Merrill here.', at: '2026-10-21T15:00:00Z' }] }]),
  useCampaignControl: () => ok({ sending_enabled: false, sending_changed_by: null, sending_changed_at: null, paused: true, pause_reason: '3 carrier-filtered texts', paused_at: '2026-10-22T16:00:00Z', laptop_paused: false, laptop_pause_reason: null, daily_cap: 100, window_start: '10:00:00', window_end: '19:00:00', dnc_policy: 'allow_unknown', routine_enabled: false, routine_changed_by: null, routine_changed_at: null, agent_rules_version: 'r1', redteam_version: 'r1', redteam_passed: 440, redteam_total: 440, redteam_ok: true, redteam_at: '2026-10-22T16:00:00Z', agent_last_run_at: '2026-10-22T16:06:00Z', agent_last_summary: null, test_phones: ['2627770909'], test_owner_name: 'JOHN W PANKIEWICZ JR', test_property_address: '2825 S LOGAN AV, Milwaukee', last_run_at: '2026-10-22T16:05:00Z', last_run_summary: { mode: 'dry', why_dry: 'TWILIO_LIVE_SENDING is not 1', inbound_new: 0, inbound_error: null, sent: 0, would_send: 3, skipped: [], failed: 0, uncertain: 0, stopped: 'nothing_due' } }),
  useInbox: () => ok([
    { opener: { id: 'P2', plan_date: '2026-10-21', wpie_owner_id: 3, attempt: 1, lead_id: 'L2', lane: 'hold', template_lane: 'hold', variant: 'B', phone: '+14145550300', body: 'Hi Ann, Colin Merrill here. reply STOP', segments: 1, scheduled_at: '2026-10-21T15:00:00Z', owner_name: 'ANN LEE', property_address: '300 W ELM ST', decision: 'approved', decided_by_name: 'Colin', decided_at: null, decision_note: null, send_status: 'delivered', send_reason: null, claimed_at: '2026-10-21T15:00:00Z', sent_at: '2026-10-21T15:00:00Z', error_code: null },
      lead: { id: 'L2', owner_name: 'ANN LEE', property_address: '300 W ELM ST', stage: 'reply_received', next_action_at: null, next_action: null, assigned_to: null, dead_reason: null },
      messages: [{ id: 'M5', lead_id: 'L2', direction: 'in', channel: 'sms', body: 'Maybe, who is buying?', sent_at: '2026-10-21T16:00:00Z', seen_at: null, is_opt_out: false, is_opener: false, status: 'replied', from_number: null, to_number: null }],
      thread: { phone10: '4145550300', lead_id: 'L2', intent: 'interested', agent_stage: 'interest', outcome: null, human_owned: true, handoff_flag: null, callback_slot: null, facts: {}, suggested_reply: 'Thanks Ann. Would a quick call with Colin work?', suggestion_note: null, last_inbound_at: null, last_inbound: null },
      inbound: [],
      drafts: [{ id: 'D1', inbound_sid: 'SMd1', phone10: '4145550300', our_number: '+12629996513', lead_id: 'L2', inbound_body: 'Maybe, who is buying?',
        inbound_at: '2026-10-21T16:00:00Z', intent: 'buyer_check', kind: 'candidate', outcome: 'open', note: null,
        body: 'Good question - Colin buys himself. Is the place still yours?', draft_source: 'claude', status: 'awaiting_approval',
        send_after: null, sent_body: null, sent_at: null, decided_by: null, decided_at: null, is_test: false }] },
    { opener: { id: 'P3', plan_date: '2026-10-21', wpie_owner_id: 4, attempt: 1, lead_id: 'L3', lane: 'flip', template_lane: 'flip', variant: 'A', phone: '+14145550400', body: 'Hi Bo. reply STOP', segments: 1, scheduled_at: '2026-10-21T15:05:00Z', owner_name: 'BO KIM', property_address: '400 N PINE ST', decision: 'approved', decided_by_name: 'Colin', decided_at: null, decision_note: null, send_status: 'skipped', send_reason: 'phone_suppressed', claimed_at: null, sent_at: null, error_code: null },
      lead: { id: 'L3', owner_name: 'BO KIM', property_address: '400 N PINE ST', stage: 'dnc', next_action_at: null, next_action: null, assigned_to: null, dead_reason: null },
      messages: [], thread: null, drafts: [], inbound: [{ sid: 'SMx', from10: '4145550400', body: 'STOP', is_opt_out: true, lead_id: 'L3', received_at: '2026-10-21T14:00:00Z' }] },
  ]),
  useScoreboard: () => ok([{ week_start: '2026-10-19', lane: 'all', openers_sent: 100, delivered: 92, replies: 7, opt_outs: 2, connects: 6, contacts: 5, leads: 2, handoffs: 1, handoffs_held: 1, qualifying_calls: 1, walks: 1, contracts: 0, closes: 0, delivery_rate: 0.92, reply_rate: 0.0761, opt_out_rate: 0.0217, contact_rate: 0.8333, leads_per_delivered: 0.0217, handoffs_held_rate: 1, walk_rate: 1, walks_per_contract: null }]),
  useSignalScoreboard: () => ok([{ week_start: '2026-10-19', signal: 'tired landlord', openers_sent: 40, delivered: 37, replies: 3, opt_outs: 1, leads: 1, walks: 0, contracts: 0 }]),
}))

import Today from '@/pages/Today'
import Pipeline from '@/pages/Pipeline'
import LeadDetail from '@/pages/LeadDetail'
import Approvals from '@/pages/Approvals'
import Inbox from '@/pages/Inbox'
import Scoreboard from '@/pages/Scoreboard'
import SignContract from '@/pages/SignContract'

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
    const required = [
      screen.getByRole('heading', { name: /Tasks from replies/ }),
      screen.getByRole('heading', { name: /New replies/ }),
      screen.getByRole('heading', { name: 'Follow-ups due' }),
      screen.getByRole('heading', { name: /Follow-up debt/ }),
    ]
    expect(required.every((heading, i) => i === 0 || Boolean(required[i - 1].compareDocumentPosition(heading) & Node.DOCUMENT_POSITION_FOLLOWING))).toBe(true)
    expect((screen.getByLabelText('Whose follow-ups') as HTMLSelectElement).value).toBe('colin')
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
    expect(screen.getByText('What the seller told us')).toBeTruthy()
    expect(screen.getByText('tired of tenants')).toBeTruthy()
    expect(screen.getByText(/Can you email me/)).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Send an email' })).toBeTruthy()
    expect(screen.queryByText('Mailed')).toBeNull()
    expect(screen.getByText('Contract (WB-11)')).toBeTruthy()
    expect(screen.getByText('Out for signature')).toBeTruthy()
    expect(screen.getByText(/opened/)).toBeTruthy()
    expect(screen.getByRole('button', { name: 'New signing link' })).toBeTruthy()
  })

  it('the phone lookup lists every owner sharing the last 4 digits', () => {
    at('/inbox', '/inbox', <Inbox />)
    const box = screen.getByLabelText(/last 4 digits/)
    fireEvent.change(box, { target: { value: '0101' } })
    const look = within(box.closest('section')!)
    expect(look.getByText(/2 owners have a number ending in 0101/)).toBeTruthy()
    expect(look.getByRole('link', { name: /JANE ROE/ }).getAttribute('href')).toBe('/lead/L1?call=1&phone=4145550101')
    expect(within(look.getByRole('link', { name: /BO KIM/ })).getByText('Do not contact')).toBeTruthy()
  })

  it('the lead card opens the call script from a lookup: known facts, questions in order, gate ticks, log the call', () => {
    at('/lead/L1?call=1&phone=4145550101', '/lead/:id', <LeadDetail />)
    expect(screen.getByRole('heading', { name: 'Call script' })).toBeTruthy()
    expect(screen.getByText(/Calling from/)).toBeTruthy()
    expect(screen.getByText('What we already know')).toBeTruthy()
    expect(screen.getByText(/Which place is this about, the one on 100 N Main St\?/)).toBeTruthy()   // open question: words to say
    expect(screen.getByText('This is Colin.', { exact: false })).toBeTruthy()
    expect(screen.getByText(/If they say\.\.\. \(22 answers\)/)).toBeTruthy()
    // The card has not decided yet (only the reason is in), so the close is held back: no Walk-through to tap.
    expect(screen.getAllByText('Not decided yet').length).toBeGreaterThan(0)
    expect(screen.getByText('Close: not decided yet')).toBeTruthy()
    expect(screen.queryByText('Close: book the visit')).toBeNull()
    expect(screen.getAllByText(/Still to ask:/).length).toBe(2)                         // on the card and at the close
    expect(screen.getByText(/Tired landlord/)).toBeTruthy()                              // answered on an earlier call
    expect(screen.getByText(/1\. Which property/)).toBeTruthy()
    expect(screen.getByText('Gate items this call settles')).toBeTruthy()
    expect(screen.getByText(/Hot reply/)).toBeTruthy()
    expect(screen.getByText(/Not called yet/)).toBeTruthy()
    expect(screen.getByRole('button', { name: 'I called them' })).toBeTruthy()
    const script = within(document.getElementById('call-script')!)
    expect(script.getByRole('button', { name: 'Do not contact' })).toBeTruthy()
    expect((script.getByRole('button', { name: 'Save the call' }) as HTMLButtonElement).disabled).toBe(true)
    expect(screen.getAllByText(/From the call: 2 - A reason and a date or event/).length).toBeGreaterThan(0)
  })

  it('the seller signing page shows the terms, consent, all 62 condition questions, and locks Sign until done', async () => {
    at('/sign/tok', '/sign/:token', <SignContract />)
    expect(await screen.findByText('$182,500')).toBeTruthy()
    expect(screen.getByText(/No financing contingency/)).toBeTruthy()
    expect(screen.getByRole('link', { name: 'Read the full Offer (PDF)' }).getAttribute('href')).toBe('https://x/offer.pdf')
    expect(screen.getByText(/I agree to use electronic records and signatures/)).toBeTruthy()
    expect(screen.getAllByRole('radiogroup')).toHaveLength(62)
    expect((screen.getByRole('button', { name: 'Accept and sign' }) as HTMLButtonElement).disabled).toBe(true)
    expect(screen.getByText(/Answer every question/)).toBeTruthy()
  })

  it('Approvals shows the switch, the pause, bulk buttons and each text', () => {
    at('/approvals', '/approvals', <Approvals />)
    expect(screen.getByText(/Merrill Holdings/)).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Approve' })).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Skip' })).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Approve all (1)' })).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Withdraw (1)' })).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Turn sending on' })).toBeTruthy()
    expect(screen.getByText(/Sending is paused/)).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Clear pause' })).toBeTruthy()
    expect(screen.getByText(/test run only/)).toBeTruthy()
    expect(screen.getByText('Auto-answer routine replies')).toBeTruthy()
    expect(screen.getByText(/440\/440 passed/)).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Turn routine replies on' })).toBeTruthy()
    expect(screen.getByLabelText('Test phone')).toBeTruthy()
    expect(screen.getByText(/Test phone: \(262\) 777-0909 plays JOHN W PANKIEWICZ JR, 2825 S LOGAN AV/)).toBeTruthy()
  })

  it('Inbox shows each text with its thread, the reply AI and one-tap actions', () => {
    at('/inbox', '/inbox', <Inbox />)
    expect(screen.getAllByText('ANN LEE').length).toBeGreaterThan(0)
    expect(screen.getByText('Needs you')).toBeTruthy()
    const deck = within(screen.getByRole('region', { name: 'Replies waiting for you' }))
    for (const name of ['Approve', 'Edit', 'Skip']) expect(deck.getByRole('button', { name })).toBeTruthy()
    expect(screen.getAllByText('Maybe, who is buying?').length).toBeGreaterThan(0)
    expect(screen.getAllByText(/Read as:/)).toHaveLength(2)
    expect(screen.getAllByRole('button', { name: "Book Colin's call" })).toHaveLength(1)
    expect(screen.getByText(/STOP honored/)).toBeTruthy()
    expect(screen.getByText(/this phone said STOP/)).toBeTruthy()
    expect(screen.getByRole('tab', { name: 'Needs me 1' })).toBeTruthy()
    expect(screen.getByDisplayValue(/Colin buys himself/)).toBeTruthy()             // the drafted reply, editable
    expect(screen.getAllByRole('button', { name: /Approve & send/ })).toHaveLength(2)
    expect(screen.getByText('Texts from numbers not on these plans')).toBeTruthy()
    expect(screen.getByText(/routine replies are off/)).toBeTruthy()
    expect(screen.getByText('TEST - your phone')).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Send a test notification' })).toBeTruthy()
    expect(screen.getByText(/Add to Home screen/)).toBeTruthy()
    expect(screen.getByRole('tab', { name: 'Dead 1' })).toBeTruthy()
  })

  it('Scoreboard shows the weekly numbers', () => {
    at('/scoreboard', '/scoreboard', <Scoreboard />)
    expect(screen.getAllByText('92.0%').length).toBeGreaterThan(0)
    expect(screen.getByText('Walks per contract')).toBeTruthy()
    const caller = within(screen.getByLabelText('Caller scorecard'))
    for (const label of ['Reached', 'Confirmed owners', 'Would sell', 'Booked calls']) expect(caller.getByText(label)).toBeTruthy()
  })
})

describe('login with one app password', () => {
  it('asks only for the app password, never an email', async () => {
    const { default: Login } = await import('@/pages/Login')
    const { container } = render(<Login />)
    expect(screen.getByLabelText('App password')).toBeTruthy()
    expect(container.querySelector('input[type="email"]')).toBeNull()
    expect(screen.getByRole('button', { name: 'Set or reset the app password' })).toBeTruthy()
  })
  it('sets a new password from the email link, at least 12 characters', async () => {
    const { default: SetPassword } = await import('@/pages/SetPassword')
    render(<SetPassword />)
    expect(screen.getByLabelText('New password')).toBeTruthy()
    expect(screen.getByText(/At least 12 characters/)).toBeTruthy()
  })
})
