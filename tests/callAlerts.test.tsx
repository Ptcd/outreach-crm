// @vitest-environment jsdom
// Colin 2026-11-14: "it should ring even if it's not the priority thing open". An app behind another tab, window or
// app can only reach its person through the device's own notifications. So: while a call rings and the app is not in
// front it puts up an alert with Answer on it, again every few seconds; Answer on the alert answers the call without
// loading the page again; and whoever has alerts off is told so, with one button that turns them on.
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter, Route, Routes, useLocation } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { ActiveCall, IncomingCall } from '../src/lib/dialer'

const dialer = {
  active: null as ActiveCall | null, incoming: null as IncomingCall | null, supported: true, ready: true,
  start: vi.fn(), accept: vi.fn(), decline: vi.fn(), hangUp: vi.fn(), toggleMute: vi.fn(), dismiss: vi.fn(),
}
const push = vi.hoisted(() => ({ state: 'off' as string, enable: vi.fn(async () => 'on') }))
vi.mock('@/lib/supabaseClient', () => ({ supabase: {}, supabaseConfigured: true }))
vi.mock('@/lib/dialer', async (orig) => ({ ...(await orig<typeof import('../src/lib/dialer')>()), useDialer: () => dialer }))
vi.mock('@/lib/push', () => ({ pushState: async () => push.state, enablePush: push.enable, isInstalled: () => false }))

import { IncomingCallBar, RING_NOTE_TAG } from '../src/components/IncomingCallBar'
import { CallAlertsNudge } from '../src/components/CallAlertsNudge'

function Where() { const l = useLocation(); return <p data-testid="where">{l.pathname}{l.search}</p> }
const tree = (ui: React.ReactNode) => (
  <MemoryRouter initialEntries={['/today']}><Routes><Route path="*" element={<>{ui}<Where /></>} /></Routes></MemoryRouter>)

const shown: { title: string; options: Record<string, unknown> }[] = []
const closed = vi.fn()
let listeners: ((e: MessageEvent) => void)[] = []
let focused = false
const mic = { ok: true }
const send = (data: unknown) => { const ack = vi.fn(); listeners.forEach((f) => f({ data, ports: [{ postMessage: ack }] } as unknown as MessageEvent)); return ack }

beforeEach(() => {
  shown.length = 0; listeners = []; focused = false; push.state = 'off'
  const reg = {
    showNotification: async (title: string, options: Record<string, unknown>) => { shown.push({ title, options }) },
    getNotifications: async () => [{ close: closed }],
  }
  Object.defineProperty(navigator, 'serviceWorker', { configurable: true, value: {
    getRegistration: async () => reg,
    addEventListener: (_: string, f: (e: MessageEvent) => void) => { listeners.push(f) },
    removeEventListener: (_: string, f: (e: MessageEvent) => void) => { listeners = listeners.filter((x) => x !== f) },
  } })
  ;(globalThis as { Notification?: unknown }).Notification = { permission: 'granted' }
  vi.spyOn(document, 'hasFocus').mockImplementation(() => focused)
  mic.ok = true
  Object.defineProperty(navigator, 'mediaDevices', { configurable: true, value: {
    getUserMedia: async () => { if (!mic.ok) throw new Error('NotAllowedError'); return { getTracks: () => [] } } } })
})
afterEach(() => { cleanup(); dialer.incoming = null; dialer.active = null; vi.clearAllMocks(); vi.restoreAllMocks(); vi.useRealTimers() })

const ring: IncomingCall = { from: '+19209011163', line: '+12623846865', matches: null, lookupError: null, busy: false }

describe('a call rings while the app is not in front', () => {
  it('puts up an alert with Answer on it, and takes it down when the ringing stops', async () => {
    dialer.incoming = ring
    const r = render(tree(<IncomingCallBar />))
    await waitFor(() => expect(shown.length).toBe(1))
    expect(shown[0].title).toBe('(920) 901-1163 is calling now')
    expect(shown[0].options.tag).toBe(RING_NOTE_TAG)
    expect(shown[0].options.requireInteraction).toBe(true)
    expect(shown[0].options.actions).toEqual([{ action: 'answer', title: 'Answer' }])
    expect((shown[0].options.data as { ring: boolean }).ring).toBe(true)
    dialer.incoming = null
    r.rerender(tree(<IncomingCallBar />))
    await waitFor(() => expect(closed).toHaveBeenCalled())
  })

  it('buzzes again every few seconds like a phone, and stops once the app is in front', async () => {
    vi.useFakeTimers()
    dialer.incoming = ring
    render(tree(<IncomingCallBar />))
    await act(async () => { await vi.advanceTimersByTimeAsync(100) })
    expect(shown.length).toBe(1)
    await act(async () => { await vi.advanceTimersByTimeAsync(10_000) })
    expect(shown.length).toBe(3)
    focused = true
    await act(async () => { await vi.advanceTimersByTimeAsync(10_000) })
    expect(shown.length).toBe(3)
    expect(closed).toHaveBeenCalled()
  })

  it('shows no alert while the app is in front: the screen already says Answer', async () => {
    focused = true
    dialer.incoming = ring
    render(tree(<IncomingCallBar />))
    await act(async () => { await new Promise((r) => setTimeout(r, 20)) })
    expect(shown.length).toBe(0)
    expect(screen.getByRole('button', { name: 'Answer' })).toBeTruthy()
  })

  it('Answer on the alert answers the call and opens the card, without loading the page again', async () => {
    dialer.incoming = ring
    dialer.accept.mockResolvedValue({ leadId: 'L1', phone: '9209011163' })
    render(tree(<IncomingCallBar />))
    let ack!: ReturnType<typeof vi.fn>
    await act(async () => { ack = send({ type: 'wpie-answer', url: 'https://app.example/today' }) })
    expect(ack).toHaveBeenCalledWith('ok')            // the service worker hears it: it never navigates the page
    await waitFor(() => expect(dialer.accept).toHaveBeenCalledTimes(1))
    await waitFor(() => expect(screen.getByTestId('where').textContent).toBe('/lead/L1?call=1&phone=9209011163'))
  })

  it('Answer tapped before the call reached the app answers it when it arrives', async () => {
    dialer.accept.mockResolvedValue({ leadId: null, phone: '9209011163' })
    const r = render(tree(<IncomingCallBar />))
    await act(async () => { send({ type: 'wpie-answer', url: 'https://app.example/today' }) })
    expect(dialer.accept).not.toHaveBeenCalled()
    dialer.incoming = ring
    await act(async () => { r.rerender(tree(<IncomingCallBar />)) })
    await waitFor(() => expect(dialer.accept).toHaveBeenCalledTimes(1))
  })

  it('Answer on the alert never drops the call when the microphone cannot open: it stays ringing with Answer on screen', async () => {
    mic.ok = false
    dialer.incoming = ring
    render(tree(<IncomingCallBar />))
    await act(async () => { send({ type: 'wpie-answer', url: 'https://app.example/today' }) })
    await act(async () => { await new Promise((r) => setTimeout(r, 30)) })
    expect(dialer.accept).not.toHaveBeenCalled()
    expect(dialer.decline).not.toHaveBeenCalled()
    expect(screen.getByRole('button', { name: 'Answer' })).toBeTruthy()
  })

  it('a tapped alert for anything else goes to its page inside the app, but nothing moves while a call rings', async () => {
    const r = render(tree(<IncomingCallBar />))
    await act(async () => { send({ type: 'wpie-open', url: `${window.location.origin}/lead/L7#ring-CA1` }) })
    expect(screen.getByTestId('where').textContent).toBe('/lead/L7')
    dialer.incoming = ring
    await act(async () => { r.rerender(tree(<IncomingCallBar />)) })
    await act(async () => { send({ type: 'wpie-open', url: `${window.location.origin}/inbox` }) })
    expect(screen.getByTestId('where').textContent).toBe('/lead/L7')
  })
})

describe('whoever has alerts off is told, with one button', () => {
  it('says a call cannot alert them, and Turn on call alerts turns them on', async () => {
    render(<CallAlertsNudge />)
    await waitFor(() => expect(screen.getByRole('status').textContent).toContain("cannot alert you when this app is not in front"))
    fireEvent.click(screen.getByRole('button', { name: 'Turn on call alerts' }))
    expect(push.enable).toHaveBeenCalledTimes(1)
    await waitFor(() => expect(screen.queryByRole('status')).toBeNull())
  })

  it('says nothing once alerts are on, and says how to unblock them when the browser has them blocked', async () => {
    push.state = 'on'
    const r = render(<CallAlertsNudge />)
    await act(async () => { await Promise.resolve() })
    expect(screen.queryByRole('status')).toBeNull()
    r.unmount()
    push.state = 'denied'
    render(<CallAlertsNudge />)
    await waitFor(() => expect(screen.getByRole('status').textContent).toContain('blocked'))
    expect(screen.queryByRole('button')).toBeNull()
  })
})
