// @vitest-environment jsdom
// The call queue (one card, a dispo, the next card) and the Settings page, with the data hooks mocked.
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter } from 'react-router-dom'
import { afterEach, describe, expect, it, vi } from 'vitest'

const leadRow = (id: string, name: string, addr: string) => ({
  id, wpie_owner_id: 1, owner_name: name, owner_type: 'individual', mailing_street: null, mailing_city: null, mailing_state: null, mailing_zip: null,
  lane: 'flip', county: 'Milwaukee', municipality: 'Milwaukee', property_address: addr, property_zip: null, wpie_property_id: null, parcel_id: null,
  property_type: null, units: null, reasons_to_sell: ['tax delinquent 2 years'], score: 300, mailed_on: null, mail_channel: null, stage: 'opener_sent',
  stage_changed_at: '2026-10-21T15:00:00Z', next_action_at: null, next_action: null, assigned_to: 'thalia', dead_reason: null, call_facts: {}, notes: null,
  last_inbound_at: null, created_at: '', updated_at: '',
})
const LEADS: Record<string, ReturnType<typeof leadRow>> = { L1: leadRow('L1', 'JANE ROE', '100 N MAIN ST'), L2: leadRow('L2', 'BO KIM', '400 N PINE ST') }
const tasks = [
  { id: 'T1', lead_id: 'L1', due_at: '2026-10-22T19:00:00Z', kind: 'call', owner: 'thalia', done_at: null, note: 'Got all three texts and never answered. Dial (414) 555-0101', created_at: '', source: 'call_list', title: 'Call: three texts, no reply', lead: { id: 'L1', owner_name: 'JANE ROE', property_address: '100 N MAIN ST', stage: 'opener_sent' } },
  { id: 'T2', lead_id: 'L2', due_at: '2026-10-22T19:00:00Z', kind: 'call', owner: 'thalia', done_at: null, note: 'No mobile on file, only a landline: a first call', created_at: '', source: 'call_list', title: 'Call: landline only', lead: { id: 'L2', owner_name: 'BO KIM', property_address: '400 N PINE ST', stage: 'opener_sent' } },
  { id: 'T3', lead_id: 'L1', due_at: '2026-10-22T19:00:00Z', kind: 'email', owner: 'thalia', done_at: null, note: null, created_at: '', source: 'reply', title: 'Email them', lead: null },
]
const finishTask = vi.fn(async () => ({ data: null, error: null }))
const logCall = vi.fn(async () => ({ data: { ok: true }, error: null }))
const handoff = vi.fn(async () => ({ ok: true, task_id: 'TX' }))
const setMyAlerts = vi.fn(async () => ({ ok: true, phone: '4145550199', email: 'thalia@example.com' }))
const beginHumanCall = vi.fn(async () => ({ data: { ok: true, paused: true, key: 'k' }, error: null }))
const resumeHumanCall = vi.fn(async () => ({ data: { ok: true, paused: false }, error: null }))
const ok = <T,>(data: T) => ({ data, error: null, isLoading: false, isPending: false, isSuccess: false })

vi.mock('@/components/PowerDial', () => ({ PowerDial: () => <div data-testid="power-dial">power</div> }))
vi.mock('@/lib/supabaseClient', () => ({ supabase: {}, supabaseConfigured: true }))
vi.mock('@/providers/AuthProvider', () => ({
  useAuth: () => ({ user: { id: 'u2', email: 'thalia@example.com' }, member: { email: 'thalia@example.com', role: 'caller', person: 'thalia', display_name: 'Thalia' },
    isOwner: false, loading: false, signOut: vi.fn() }),
}))
vi.mock('@/lib/apiExtra', () => ({
  personAlerts: async () => ({ alert_phone: null, alert_email: null }),
  setPersonAlerts: (who: string, p: string, e: string) => setMyAlerts(who, p, e),
  handoffToColin: (id: string, note: string) => handoff(id, note),
}))
vi.mock('@/lib/queries', () => ({
  api: { finishTask: (id: string) => finishTask(id), logCall: (...a: unknown[]) => logCall(...a), callAnswer: vi.fn(async () => ({ data: { ok: true }, error: null })),
    beginHumanCall: (...a: unknown[]) => beginHumanCall(...a), resumeHumanCall: (...a: unknown[]) => resumeHumanCall(...a) },
  useWrite: (fn: (x: unknown) => Promise<unknown>) => ({ mutate: (x: unknown) => { void fn(x) }, isPending: false, isSuccess: false, error: null }),
  useDueTasks: () => ok(tasks),
  useOfferSettings: () => ({ data: null }),
  useLead: (id: string) => ok({
    lead: LEADS[id], gates: [], milestones: [], tasks: [], facts: {},
    contacts: id === 'L1'
      ? [{ id: 'C-L1', lead_id: id, kind: 'phone', value: '4145550101', value_normalized: '4145550101', person_name: null, line_type: 'mobile', dnc_vendor: false, dnc_scrub: 'unknown', suppressed: false, dnc_app: false, source: null, status: 'ok', note: null }]
      : [
          { id: 'C-L2-vendor', lead_id: id, kind: 'phone', value: '2625550102', value_normalized: '2625550102', person_name: null, line_type: 'landline', dnc_vendor: true, dnc_scrub: 'unknown', suppressed: false, dnc_app: false, source: null, status: 'ok', note: null },
          { id: 'C-L2-scrub', lead_id: id, kind: 'phone', value: '2625550103', value_normalized: '2625550103', person_name: null, line_type: 'landline', dnc_vendor: false, dnc_scrub: 'dnc', suppressed: false, dnc_app: false, source: null, status: 'ok', note: null },
        ],
    messages: id === 'L1' ? [{ id: 'M1', lead_id: 'L1', direction: 'out', channel: 'sms', body: 'Hi Jane, still yours?', sent_at: '2026-10-21T15:00:00Z', seen_at: null, is_opt_out: false, is_opener: true, status: 'delivered', from_number: null, to_number: null }] : [],
  }),
}))

import CallQueue from '@/pages/CallQueue'
import Settings from '@/pages/Settings'

afterEach(cleanup)
const mount = (el: React.ReactNode) => render(<QueryClientProvider client={new QueryClient()}><MemoryRouter>{el}</MemoryRouter></QueryClientProvider>)

describe('the call queue', () => {
  it('shows one card with the context, logs a dispo, and brings the next', async () => {
    mount(<CallQueue />)
    expect(screen.getByTestId('queue-count').textContent).toBe('1 of 2')
    expect(screen.getByRole('heading', { name: 'JANE ROE' })).toBeTruthy()
    expect(screen.getByText(/Why this call/)).toBeTruthy()
    expect(screen.getByText(/Got all three texts and never answered/)).toBeTruthy()
    expect(screen.getAllByText(/never say this to them/).length).toBeGreaterThan(0)
    expect(screen.getAllByText(/\(414\) 555-0101/).length).toBeGreaterThan(0)
    expect(screen.getByRole('heading', { name: 'Call script' })).toBeTruthy()      // open already
    expect(screen.getByRole('button', { name: 'No answer' })).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: 'No answer' }))
    fireEvent.click(screen.getByRole('button', { name: 'Save the call' }))
    await waitFor(() => expect(logCall).toHaveBeenCalledWith('L1', '4145550101', 'no_answer', null, null))
    // the server closes the stop off the logged call; the queue never marks it Done by hand
    expect(finishTask).not.toHaveBeenCalled()
    expect(await screen.findByRole('heading', { name: 'BO KIM' })).toBeTruthy()
    expect(screen.getByTestId('queue-count').textContent).toBe('2 of 2')
    expect(screen.queryByRole('button', { name: 'Call' })).toBeNull()               // vendor DNC: never expose the dial button
  })

  it("Today's Power hour button lands on /calls?mode=power and opens Power hour; switching back clears it", async () => {
    try { localStorage.removeItem('calls:mode') } catch { /* fine */ }
    render(<QueryClientProvider client={new QueryClient()}><MemoryRouter initialEntries={['/calls?mode=power']}><CallQueue /></MemoryRouter></QueryClientProvider>)
    expect(screen.getByRole('tab', { name: 'Power hour' }).getAttribute('aria-selected')).toBe('true')
    expect(screen.getByTestId('power-dial')).toBeTruthy()
    expect(localStorage.getItem('calls:mode')).toBe('power')
    fireEvent.click(screen.getByRole('tab', { name: "Today's list" }))
    expect(screen.getByRole('tab', { name: "Today's list" }).getAttribute('aria-selected')).toBe('true')
    expect(localStorage.getItem('calls:mode')).toBe('list')
  })

  it('skip moves the card to the end; hand to Colin needs a line, then finishes the task', async () => {
    mount(<CallQueue />)
    fireEvent.click(screen.getByRole('button', { name: 'Skip for now' }))
    expect(screen.getByRole('heading', { name: 'BO KIM' })).toBeTruthy()
    expect(screen.getByTestId('queue-count').textContent).toBe('1 of 2, 1 skipped for now')
    fireEvent.click(screen.getByRole('button', { name: 'Hand to Colin' }))
    const send = screen.getByRole('button', { name: 'Send to Colin' }) as HTMLButtonElement
    expect(send.disabled).toBe(true)
    fireEvent.change(screen.getByPlaceholderText(/One line for Colin/), { target: { value: 'Would sell, lease ends Dec, just him' } })
    fireEvent.click(screen.getByRole('button', { name: 'Send to Colin' }))
    await waitFor(() => expect(handoff).toHaveBeenCalledWith('L2', 'Would sell, lease ends Dec, just him'))
    expect(finishTask).not.toHaveBeenCalled()
    expect(await screen.findByRole('heading', { name: 'JANE ROE' })).toBeTruthy()     // the skipped one comes back last
  })

  it('a call from your own phone pauses the texts from the list, and a call that never connected is undone there', async () => {
    mount(<CallQueue />)
    fireEvent.click(screen.getByRole('button', { name: 'Calling on personal phone' }))
    await waitFor(() => expect(beginHumanCall).toHaveBeenCalledWith('L1', '4145550101', 'personal', expect.any(String)))
    expect(await screen.findByText(/Automated follow-ups paused/)).toBeTruthy()
    cleanup()
    // the card comes back paused (a browser call that never connected looks the same)
    const was = { ...LEADS.L1 }
    Object.assign(LEADS.L1, { human_takeover_at: '2026-10-23T14:00:00Z', human_takeover_by: 'Thalia', human_takeover_phone: '4145550101', human_takeover_key: 'key-123' })
    try {
      mount(<CallQueue />)
      expect(screen.getByText(/A call is open on this card/)).toBeTruthy()
      fireEvent.click(screen.getByRole('button', { name: 'Call did not happen — resume' }))
      await waitFor(() => expect(resumeHumanCall).toHaveBeenCalledWith('L1', 'key-123'))
    } finally {
      for (const k of Object.keys(LEADS.L1)) if (!(k in was)) delete (LEADS.L1 as Record<string, unknown>)[k]
      Object.assign(LEADS.L1, was)
    }
    // a do-not-contact number gets neither button
    cleanup()
    mount(<CallQueue />)
    fireEvent.click(screen.getByRole('button', { name: 'Skip for now' }))
    expect(screen.getByRole('heading', { name: 'BO KIM' })).toBeTruthy()
    expect(screen.queryByRole('button', { name: 'Calling on personal phone' })).toBeNull()
  })
})

describe('Settings', () => {
  it('saves my alert email and phone', async () => {
    mount(<Settings />)
    const email = await screen.findByLabelText('Email for hot pings') as HTMLInputElement
    await waitFor(() => expect(email.disabled).toBe(false))
    fireEvent.change(email, { target: { value: 'thalia@example.com' } })
    fireEvent.change(screen.getByLabelText(/Phone for text pings/), { target: { value: '414 555 0199' } })
    fireEvent.click(screen.getByRole('button', { name: 'Save' }))
    await waitFor(() => expect(setMyAlerts).toHaveBeenCalledWith('thalia', '414 555 0199', 'thalia@example.com'))
    expect(await screen.findByText(/Saved\. Pings now go to that phone and that email\./)).toBeTruthy()
    expect(screen.getByText(/tell him when you set or change this/)).toBeTruthy()
    expect(screen.getByText(/On a computer, Chrome can show pings while the browser is running/)).toBeTruthy()
  })
})
