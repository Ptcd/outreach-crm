// @vitest-environment jsdom
// "Who's on this phone?" on the shared login (2026-10-22 evening): the phone's answer decides whose list the
// Calls page shows and whether Colin's own controls appear.
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ownerFilterFor, workerFor } from '@/lib/onPhone'

const useDueTasks = vi.fn(() => ({ data: [], error: null, isLoading: false }))
vi.mock('@/lib/supabaseClient', () => ({ supabase: {}, supabaseConfigured: true }))
vi.mock('@/providers/AuthProvider', () => ({
  // the one shared login: Colin's team row, the owner role
  useAuth: () => ({ user: { id: 'u1', email: 'app@example.com' }, member: { email: 'app@example.com', role: 'owner', person: 'colin', display_name: 'Colin' },
    isOwner: true, loading: false, signOut: vi.fn() }),
}))
vi.mock('@/lib/queries', () => ({
  api: {},
  useWrite: () => ({ mutate: vi.fn(), isPending: false, isSuccess: false, error: null }),
  useDueTasks: (...a: unknown[]) => useDueTasks(...a),
  useLead: () => ({ data: null, error: null, isLoading: false }),
}))

import CallQueue from '@/pages/CallQueue'
import { OnPhonePrompt, useColinHere } from '@/components/OnPhonePicker'

const mount = (el: React.ReactNode) => render(<QueryClientProvider client={new QueryClient()}><MemoryRouter>{el}</MemoryRouter></QueryClientProvider>)
function ColinOnly() { return <p>{useColinHere() ? 'colin controls' : 'caller view'}</p> }

beforeEach(() => { localStorage.clear(); useDueTasks.mockClear() })
afterEach(cleanup)

describe('who is working this phone', () => {
  it('a caller login is always that caller; the shared login is whoever picked', () => {
    expect(workerFor({ role: 'caller', person: 'adil' }, 'colin')).toBe('adil')
    expect(workerFor({ role: 'owner', person: 'colin' }, 'thalia')).toBe('thalia')
    expect(workerFor({ role: 'owner', person: 'colin' }, null)).toBeNull()
    expect(ownerFilterFor('colin')).toBe('colin')
    expect(ownerFilterFor('thalia')).toBe('callers')
    expect(ownerFilterFor('adil')).toBe('callers')   // Adil covers the callers' list at the weekend
    expect(ownerFilterFor(null)).toBe('callers')
    expect(ownerFilterFor(null, 'colin')).toBe('colin')        // the shared login before the phone answers: as before
    expect(ownerFilterFor('thalia', 'colin')).toBe('callers')
  })

  it('asks once, remembers the answer, and hides Colin\'s controls for a caller', () => {
    mount(<><OnPhonePrompt /><ColinOnly /></>)
    expect(screen.getByTestId('on-phone-prompt')).toBeTruthy()
    expect(screen.getByText('colin controls')).toBeTruthy()           // not answered yet: as before the picker
    fireEvent.click(screen.getByRole('button', { name: 'Thalia' }))
    expect(localStorage.getItem('wpie.on_phone')).toBe('thalia')
    expect(screen.queryByTestId('on-phone-prompt')).toBeNull()
    expect(screen.getByText('caller view')).toBeTruthy()
  })

  it("the Calls page shows the callers' list to Thalia or Adil, and Colin's own to Colin", () => {
    localStorage.setItem('wpie.on_phone', 'adil')
    mount(<CallQueue />)
    expect(useDueTasks.mock.calls.at(-1)?.[1]).toBe('callers')
    cleanup()
    localStorage.setItem('wpie.on_phone', 'colin')
    mount(<CallQueue />)
    expect(useDueTasks.mock.calls.at(-1)?.[1]).toBe('colin')
  })
})
