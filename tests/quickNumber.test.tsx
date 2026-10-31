// @vitest-environment jsdom
// The quick number on the Power hour card (0154): hidden while the anchor is off, folded in exit-only mode, four taps
// save the repair answers on the card, the database's figure and the line to say show, "anything big" means walk first.
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { afterEach, describe, expect, it, vi } from 'vitest'

let mode: 'off' | 'exit_only' | 'live' = 'exit_only'
let shot: Record<string, unknown> = { ok: true, number: 63000, say: "I can't give you a firm number on a place we haven't seen. Rough, and going off what you've told me and what the county shows, we'd be somewhere around $63,000. Is that even in the conversation?",
  value: 150000, value_basis: "the county's estimated market value", repairs: 30000, mao: 90000, off: 0.3,
  lines: [{ item: 'Base refresh (paint, floors, fixtures)', amount: 12000, why: '1000 sq ft, county records' }, { item: 'Roof', amount: 12000, why: 'not asked: counted' }] }
const offerShoot = vi.fn(async () => ({ data: shot, error: null }))
const callAnswer = vi.fn(async () => ({ data: { ok: true }, error: null }))
const offerSaid = vi.fn(async () => ({ data: { ok: true }, error: null }))
vi.mock('@/lib/supabaseClient', () => ({ supabase: { from: () => ({ select: () => ({ eq: () => ({ maybeSingle: async () => ({ data: { call_facts: { quick_kb: { value: { choices: ['updated'] } } } } }) }) }) }) } }))
vi.mock('@/lib/queries', () => ({
  api: { offerShoot: (...a: unknown[]) => offerShoot(...(a as [])), callAnswer: (...a: unknown[]) => callAnswer(...(a as [])), offerSaid: (...a: unknown[]) => offerSaid(...(a as [])) },
  useOfferSettings: () => ({ data: { mode } }),
}))

import { QuickNumber } from '@/components/QuickNumber'

afterEach(() => { cleanup(); offerShoot.mockClear(); callAnswer.mockClear(); offerSaid.mockClear() })
const show = () => render(<QueryClientProvider client={new QueryClient()}><QuickNumber leadId="L1" /></QueryClientProvider>)

describe('the quick number in Power hour', () => {
  it('anchor off: nothing shows', () => {
    mode = 'off'
    const { container } = show()
    expect(container.textContent).toBe('')
    expect(offerShoot).not.toHaveBeenCalled()
  })

  it('exit only: one button until she opens it; then the number, the line, and the earlier answer shown as picked', async () => {
    mode = 'exit_only'
    show()
    expect(offerShoot).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole('button', { name: /Quick number/ }))
    await screen.findByText('$63,000')
    expect(document.body.textContent).toContain('somewhere around $63,000')
    await waitFor(() => expect(screen.getByRole('button', { name: 'Updated' }).getAttribute('aria-pressed')).toBe('true'))
  })

  it('a tap saves the answer on the card and the number is worked out again', async () => {
    mode = 'live'
    show()
    await screen.findByText('$63,000')
    const before = offerShoot.mock.calls.length
    fireEvent.click(screen.getByRole('button', { name: 'Older / not sure' }))
    await waitFor(() => expect(callAnswer).toHaveBeenCalledWith('L1', 'quick_roof', { choices: ['old'] }))
    await waitFor(() => expect(offerShoot.mock.calls.length).toBeGreaterThan(before))
    // what they said back is logged against the database's own figure
    fireEvent.click(screen.getByRole('button', { name: 'Said a number' }))
    fireEvent.change(screen.getByPlaceholderText('Their number ($)'), { target: { value: '80,000' } })
    fireEvent.click(screen.getByRole('button', { name: 'I said it' }))
    await waitFor(() => expect(offerSaid).toHaveBeenCalledWith('L1', 63000, 'gave_number', 80000, null))
    await screen.findByText(/Said \$63,000; they: Said a number \$80,000/)
  })

  it('no size on file: a bedrooms tap appears and saves; with a size on file it does not (0158)', async () => {
    mode = 'live'
    shot = { ...shot, ok: true, number: 63000, size_known: false }
    show()
    await screen.findByText(/How many bedrooms/)
    fireEvent.click(screen.getByRole('button', { name: '2 beds' }))
    await waitFor(() => expect(callAnswer).toHaveBeenCalledWith('L1', 'quick_beds', { choices: ['2'] }))
    cleanup()
    shot = { ...shot, size_known: true }
    show()
    await screen.findByText('$63,000')
    expect(screen.queryByText(/How many bedrooms/)).toBeNull()
  })

  it('water, foundation or fire: no number, Colin walks it first', async () => {
    mode = 'live'
    shot = { ok: false, walk_first: true, reason: 'water, foundation, fire or a code order: no number on the phone, Colin walks it first' }
    show()
    await screen.findByText(/Colin walks this one first/)
    expect(screen.queryByText('$63,000')).toBeNull()
  })
})
