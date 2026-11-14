// @vitest-environment jsdom
// 2026-11-14, Colin: "The system is not allowing Tyler to answer calls". The phone company's record: every call to
// Tyler's and Thalia's own lines that week reached the app and was turned away as busy inside a second, both rings.
// The app started a softphone for every sign-in answer that came back while the first was still fetching its pass
// (three on a normal load), all registered under the caller's name; the seller's call rang all three, and the second
// and third rejected it as "one already ringing", which ends the call for all of them. One softphone, and a second
// ring is left alone, never rejected.
import { act, cleanup, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const state = vi.hoisted(() => ({
  member: { person: 'adil', display_name: 'Tyler' } as { person: string; display_name: string } | null,
  tokens: 0,
  micOk: true,
  tokenFails: 0,
  release: [] as (() => void)[],
  devices: [] as { handlers: Record<string, (x?: unknown) => void>; registered: number; state: string }[],
}))

vi.mock('@twilio/voice-sdk', () => ({
  Device: class {
    handlers: Record<string, (x?: unknown) => void> = {}
    registered = 0
    state = 'unregistered'
    constructor() { state.devices.push(this) }
    on(ev: string, f: (x?: unknown) => void) { this.handlers[ev] = f }
    async register() { this.registered += 1; this.state = 'registered'; this.handlers.registered?.() }
    updateToken() {}
    destroy() {}
  },
}))
vi.mock('@/lib/supabaseClient', () => ({
  supabaseConfigured: true,
  supabase: {
    functions: {
      // the pass takes a moment: every caller that asks meanwhile must share the one softphone
      invoke: () => new Promise((resolve) => {
        state.tokens += 1
        const fail = state.tokenFails > 0
        if (fail) state.tokenFails -= 1
        state.release.push(() => resolve(fail ? { data: null, error: { message: 'no signal' } } : { data: { token: 'tok' }, error: null }))
      }),
    },
    rpc: async () => ({ data: [], error: null }),
  },
}))
vi.mock('@/providers/AuthProvider', () => ({ useAuth: () => ({ member: state.member }) }))
vi.mock('@tanstack/react-query', () => ({ useQueryClient: () => ({ invalidateQueries: vi.fn() }) }))

import { DialerProvider, useDialer } from '../src/lib/dialer'

function Show() {
  const { incoming, ready, active, accept } = useDialer()
  return (<>
    <p data-testid="s">{ready ? 'ready' : 'not ready'}|{incoming ? `ringing ${incoming.from}` : 'quiet'}|{incoming?.micError ? 'mic blocked' : 'mic fine'}|{active?.status ?? 'no call'}</p>
    <button onClick={() => void accept()}>answer</button>
  </>)
}
const call = (from: string) => {
  const on: Record<string, () => void> = {}
  return { parameters: { From: from }, customParameters: new Map([['line', '+12623846865']]), on: (ev: string, f: () => void) => { on[ev] = f },
    reject: vi.fn(), ignore: vi.fn(), accept: vi.fn(), fire: (ev: string) => on[ev]?.() }
}
const releaseAll = async () => { await act(async () => { state.release.splice(0).forEach((f) => f()); await Promise.resolve() }) }

beforeEach(() => {
  state.member = { person: 'adil', display_name: 'Tyler' }
  state.tokens = 0; state.tokenFails = 0; state.release = []; state.devices = []
  state.micOk = true
  Object.defineProperty(navigator, 'mediaDevices', { value: { getUserMedia: async () => { if (!state.micOk) throw new Error('NotAllowedError'); return { getTracks: () => [] } } }, configurable: true })
  ;(globalThis as { RTCPeerConnection?: unknown }).RTCPeerConnection = class {}
})
afterEach(() => cleanup())

describe('the softphone', () => {
  it('is started once, however many sign-in answers arrive while its pass is being fetched', async () => {
    const r = render(<DialerProvider><Show /></DialerProvider>)
    // the same person, answered twice more before the first pass is back (a new object each time, as the app gets it)
    state.member = { person: 'adil', display_name: 'Tyler' }
    r.rerender(<DialerProvider><Show /></DialerProvider>)
    state.member = { person: 'adil', display_name: 'Tyler' }
    r.rerender(<DialerProvider><Show /></DialerProvider>)
    await releaseAll()
    await waitFor(() => expect(screen.getByTestId('s').textContent).toContain('ready'))
    expect(state.tokens).toBe(1)
    expect(state.devices.length).toBe(1)
    expect(state.devices[0].registered).toBe(1)
  })

  it('asks again after a pass that could not be fetched, and still ends with one softphone', async () => {
    state.tokenFails = 1
    render(<DialerProvider><Show /></DialerProvider>)
    await releaseAll()
    expect(state.devices.length).toBe(0)
    await act(async () => { window.dispatchEvent(new Event('online')) })   // nothing to re-register yet
    state.member = { person: 'adil', display_name: 'Tyler' }
    cleanup()
    render(<DialerProvider><Show /></DialerProvider>)
    await releaseAll()
    await waitFor(() => expect(state.devices.length).toBe(1))
    expect(state.tokens).toBe(2)
  })

  it('never rejects a second ring while one is showing: a reject ends the seller\'s call for every softphone', async () => {
    render(<DialerProvider><Show /></DialerProvider>)
    await releaseAll()
    await waitFor(() => expect(state.devices.length).toBe(1))
    const first = call('+19209011163')
    const second = call('+19209011163')
    await act(async () => { state.devices[0].handlers.incoming(first) })
    await act(async () => { state.devices[0].handlers.incoming(second) })
    expect(screen.getByTestId('s').textContent).toContain('ringing +19209011163')
    expect(second.ignore).toHaveBeenCalledTimes(1)
    expect(second.reject).not.toHaveBeenCalled()
    expect(first.reject).not.toHaveBeenCalled()
    expect(first.ignore).not.toHaveBeenCalled()
    // the seller hangs up: the bar goes, and the next call rings
    await act(async () => { first.fire('cancel') })
    expect(screen.getByTestId('s').textContent).toContain('quiet')
    const third = call('+14148996979')
    await act(async () => { state.devices[0].handlers.incoming(third) })
    expect(screen.getByTestId('s').textContent).toContain('ringing +14148996979')
  })

  it('Answer opens the microphone first: a blocked microphone leaves the call ringing and says so, never drops it', async () => {
    render(<DialerProvider><Show /></DialerProvider>)
    await releaseAll()
    await waitFor(() => expect(state.devices.length).toBe(1))
    const ring = call('+19209011163')
    await act(async () => { state.devices[0].handlers.incoming(ring) })
    state.micOk = false
    await act(async () => { screen.getByRole('button', { name: 'answer' }).click() })
    expect(ring.accept).not.toHaveBeenCalled()
    expect(ring.reject).not.toHaveBeenCalled()
    expect(screen.getByTestId('s').textContent).toContain('ringing +19209011163|mic blocked')
    // allowed now: the same tap answers
    state.micOk = true
    await act(async () => { screen.getByRole('button', { name: 'answer' }).click() })
    expect(ring.accept).toHaveBeenCalledTimes(1)
    expect(screen.getByTestId('s').textContent).toContain('quiet')
    expect(screen.getByTestId('s').textContent).toContain('in_call')
  })
})
