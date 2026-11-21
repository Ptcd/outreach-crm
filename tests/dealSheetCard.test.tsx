// @vitest-environment jsdom
// The deal sheet on the card (0270): one number at a time, the next step only after the first is turned down, no
// number when the other signer is not on the line, nothing of ours (the ceiling) on a caller's screen, and nothing at
// all for a login the sheet is not switched on for.
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { afterEach, describe, expect, it, vi } from 'vitest'

let owner = false
let current: Record<string, unknown> | null = null
const rpc = vi.fn(async (fn: string, args: Record<string, unknown>) => {
  if (fn === 'deal_sheet_get') return { data: current, error: null }
  if (fn === 'deal_sheet_said') {
    current = { ...current!, said: [...(current!.said as unknown[]), { at: 'now', by: 'adil', number: args.p_number, response: args.p_response, words: args.p_words, counter: args.p_counter }] }
    return { data: { ok: true, sheet: current }, error: null }
  }
  if (fn === 'deal_sheet_fact') {
    current = { ...current!, facts: { ...(current!.facts as object), [args.p_key as string]: args.p_value } }
    return { data: { ok: true, sheet: current }, error: null }
  }
  return { data: { ok: true, sheet: current }, error: null }
})
vi.mock('@/lib/supabaseClient', () => ({ supabase: { rpc: (fn: string, args: Record<string, unknown>) => rpc(fn, args) }, supabaseConfigured: true }))
vi.mock('@/providers/AuthProvider', () => ({ useAuth: () => ({ user: { id: 'u2' }, member: { person: owner ? 'colin' : 'adil', role: owner ? 'owner' : 'caller' }, isOwner: owner }) }))

import { DealSheet } from '@/components/DealSheet'

const base = (over: Record<string, unknown> = {}) => ({
  lead_id: 'L1', mode: 'on', owner: false, stage: 'ready', kind: 'nothing_left', why: null, source: 'math', missing: [], property_kind: 'site_built',
  math: { finished: 200000, needs: 20000, needs_for: 'Inside heavy', needs_assumed: true, selling_costs: 20000, to_clear: 34000, other_owed: 194000, walk_away: -68000,
    owed_known: true, open_owed: [], cost_words: '6% to an agent, 2% closing, 4 months of taxes and upkeep' },
  rows: [{ i: 0, inside: 'Inside light', repairs: 12000, basis: 'paint', no_offer: false }, { i: 1, inside: 'Inside heavy', repairs: 20000, basis: 'kitchen', no_offer: false }],
  inside: 1, comps: [{ address: '11 Near St', sold_price: 200000, sold_date: '2026-05-15' }, { address: '10 Near St', sold_price: 195000, sold_date: '2026-04-15' }], sold_comps: 3,
  owed: [{ kind: 'mortgage', creditor: 'the lender', amount: 34000, basis: 'the seller said', follows_house: 'yes' },
    { kind: 'estate_claim', creditor: 'a hospital', amount: 194000, basis: 'court record', follows_house: 'no' }],
  brief_ready: true, number: 39000, steps: [39000, 59000, 79500], limit: 79500, theirs: { number: 300000, floor: null, owed_said: null }, facts: {}, said: [],
  colin: { open: null, top: null, note: null, pass: false, at: null, asked_at: null, asked_words: null }, owner_name: 'ESTATE OF TEST', address: '991 TEST ST', caller: 'adil', ...over,
})
const show = () => render(<QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}><DealSheet leadId="L1" /></QueryClientProvider>)
afterEach(() => { cleanup(); rpc.mockClear(); owner = false; current = null })

describe('the deal sheet on the card', () => {
  it('renders nothing for a login it is not switched on for', async () => {
    current = null
    const { container } = show()
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('deal_sheet_get', { p_lead_id: 'L1' }))
    expect(container.textContent).toBe('')
  })

  it('a caller sees the five steps, the seller\'s math and one number, and nothing of our ceiling', async () => {
    current = base()
    show()
    expect((await screen.findByLabelText('The number to say')).textContent).toBe('$39,000')
    expect(screen.getByText('Say this, once')).toBeTruthy()
    for (const t of ['Their number, and where it came from', 'The finished price, kindly', 'What is owed, asked first', 'What the records show, added after', 'The plain conclusion, then the way out'])
      expect(screen.getByText(t)).toBeTruthy()
    const math = screen.getByLabelText("The seller's math").textContent!
    expect(math).toContain('What it sells for finished$200,000')
    expect(math).toContain('What they would walk away withNothing')
    expect(screen.getByText(/11 Near St sold for \$200,000 in May 2026/)).toBeTruthy()
    expect(screen.getByText(/I don't see how selling it puts money in your pocket/)).toBeTruthy()
    expect(document.body.textContent).not.toMatch(/most we can pay|\$59,000|\$79,500|Yours only/)
  })

  it('the next step shows only after the first number is turned down; a yes goes straight to paper', async () => {
    current = base()
    show()
    await screen.findByLabelText('The number to say')
    fireEvent.click(screen.getByText('They name a number of their own'))
    fireEvent.change(screen.getByLabelText('The number they named'), { target: { value: '90,000' } })
    fireEvent.change(screen.getByLabelText('What they said'), { target: { value: 'we were told three hundred' } })
    fireEvent.click(screen.getByText('Save what they said'))
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('deal_sheet_said', { p_lead_id: 'L1', p_number: 39000, p_response: 'counter', p_words: 'we were told three hundred', p_counter: 90000 }))
    await waitFor(() => expect(screen.getByLabelText('The number to say').textContent).toBe('$59,000'))
    expect(screen.getByText('Next step, once')).toBeTruthy()
    fireEvent.click(screen.getByText('They said yes'))
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('deal_sheet_said', { p_lead_id: 'L1', p_number: 59000, p_response: 'yes', p_words: null, p_counter: null }))
    expect(await screen.findByText('They said yes to $59,000.')).toBeTruthy()
    expect(screen.getByText(/Open your email, the agreement is on its way/)).toBeTruthy()
  })

  it('no number while the other signer is not on the line', async () => {
    current = base()
    show()
    await screen.findByLabelText('The number to say')
    fireEvent.click(screen.getByText('Someone else, not here'))
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('deal_sheet_fact', { p_lead_id: 'L1', p_key: 'decides', p_value: 'absent' }))
    await waitFor(() => expect(screen.queryByLabelText('The number to say')).toBeNull())
    expect(screen.getByText(/Book the call with both on the line/)).toBeTruthy()
  })

  it('a card the formula does not fit: no number for the caller, one box to ask Colin', async () => {
    current = base({ stage: 'colin_prices', number: null, steps: [], limit: null, kind: null, why: 'No formula number: it is a manufactured home.' })
    show()
    expect(await screen.findByText(/Colin prices this one\./)).toBeTruthy()
    expect(screen.queryByLabelText('The number to say')).toBeNull()
    fireEvent.change(screen.getByLabelText('What to ask Colin'), { target: { value: 'he wants a number today' } })
    fireEvent.click(screen.getByText('Send to Colin'))
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('deal_sheet_ask_colin', { p_lead_id: 'L1', p_words: 'he wants a number today' }))
  })

  it('Colin sees the ceiling, why there is no formula number, and sets his own', async () => {
    owner = true
    current = base({ owner: true, mode: 'owner', stage: 'colin_prices', number: null, steps: [], limit: null, kind: null, why: 'No formula number: it is a manufactured home.',
      ceiling: 49000, rule_opening: 38500, gap: null, gate: ['it is a manufactured home', 'there is no street picture of it'],
      colin: { open: null, top: null, note: null, pass: false, at: null, asked_at: 'now', asked_words: 'he wants a number today' } })
    show()
    expect(await screen.findByText('Only you see this')).toBeTruthy()
    expect(screen.getByText('$49,000')).toBeTruthy()
    expect(screen.getByText(/it is a manufactured home; there is no street picture of it/)).toBeTruthy()
    expect(screen.getByText('he wants a number today')).toBeTruthy()
    fireEvent.change(screen.getByLabelText("Colin's number"), { target: { value: '30000' } })
    fireEvent.change(screen.getByLabelText("Colin's top"), { target: { value: '35000' } })
    fireEvent.change(screen.getByLabelText('The reason'), { target: { value: 'a double-wide on piers' } })
    fireEvent.click(screen.getByText('Set my number'))
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('deal_sheet_colin', { p_lead_id: 'L1', p_open: 30000, p_top: 35000, p_note: 'a double-wide on piers', p_pass: false }))
  })
})
