// @vitest-environment jsdom
// 2026-10-21: Adil signed in on a phone and saw "This account is not on the WPIE team" because the
// app showed that screen while the team lookup was still in flight (and again if it failed).
import { act, cleanup, render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

type Lookup = { data: unknown; error: { message: string } | null }
const state = vi.hoisted(() => ({
  session: null as unknown,
  lookups: [] as (() => Promise<{ data: unknown; error: { message: string } | null }>)[],
  calls: 0,
  listener: null as null | ((event: string, s: unknown) => void),
}))

vi.mock('@/lib/supabaseClient', () => ({
  supabaseConfigured: true,
  appLoginEmail: 'owner@example.com',
  supabase: {
    auth: {
      getSession: async () => ({ data: { session: state.session } }),
      onAuthStateChange: (f: (e: string, s: unknown) => void) => { state.listener = f; return { data: { subscription: { unsubscribe() {} } } } },
      signOut: async () => {},
    },
    from: () => ({
      select: () => ({ eq: () => ({ maybeSingle: () => { state.calls += 1; return (state.lookups.shift() ?? (async () => ({ data: null, error: null })))() } }) }),
    }),
  },
}))
vi.mock('@/components/Layout', () => ({ Layout: ({ children }: { children: React.ReactNode }) => <div>APP SHELL{children}</div> }))
vi.mock('@/pages/Today', () => ({ default: () => <div>TODAY PAGE</div> }))

import { AuthProvider } from '@/providers/AuthProvider'
import App from '@/App'

const SESSION = { user: { id: 'u', email: 'owner@example.com' } }
const COLIN = { email: 'owner@example.com', role: 'owner', person: 'colin', display_name: 'Colin' }
const tick = (ms = 0) => act(() => new Promise((r) => setTimeout(r, ms)))

function mount() {
  return render(<MemoryRouter initialEntries={['/today']}><AuthProvider><App /></AuthProvider></MemoryRouter>)
}

beforeEach(() => { state.session = SESSION; state.lookups = []; state.calls = 0 })
afterEach(cleanup)

describe('team check after sign-in', () => {
  it('says "Signing you in" while the lookup is in flight, never "not on the team"', async () => {
    let finish!: (v: Lookup) => void
    state.lookups.push(() => new Promise<Lookup>((r) => { finish = r }))
    mount()
    await tick()
    expect(screen.getByText('Signing you in...')).toBeTruthy()
    expect(screen.queryByText(/not on the/i)).toBeNull()
    await act(async () => finish({ data: COLIN, error: null }))
    await tick()
    expect(screen.getByText('TODAY PAGE')).toBeTruthy()
  })

  it('retries a failed lookup, then shows what went wrong with Try again', async () => {
    for (let i = 0; i < 3; i++) state.lookups.push(async () => ({ data: null, error: { message: 'Failed to fetch' } }))
    mount()
    await tick(3000)
    expect(state.calls).toBe(3)
    expect(screen.getByText(/could not load your access/)).toBeTruthy()
    expect(screen.getByText(/Failed to fetch/)).toBeTruthy()
    expect(screen.queryByText(/not on the WPIE team list/)).toBeNull()
    state.lookups.push(async () => ({ data: COLIN, error: null }))
    await act(async () => screen.getByRole('button', { name: 'Try again' }).click())
    await tick()
    expect(screen.getByText('TODAY PAGE')).toBeTruthy()
  })

  it('does not re-check (or flash anything) on the hourly token refresh', async () => {
    state.lookups.push(async () => ({ data: COLIN, error: null }))
    mount()
    await tick()
    expect(screen.getByText('TODAY PAGE')).toBeTruthy()
    await act(async () => state.listener!('TOKEN_REFRESHED', SESSION))
    await tick()
    expect(state.calls).toBe(1)
    expect(screen.getByText('TODAY PAGE')).toBeTruthy()
  })

  it('only a real "no such member" answer says the login is not on the list', async () => {
    state.lookups.push(async () => ({ data: null, error: null }))
    mount()
    await tick()
    expect(screen.getByText('This login is not on the WPIE team list')).toBeTruthy()
  })
})
