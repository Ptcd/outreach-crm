// The phone's alert for a call that is ringing (public/sw.js), run here against a stand-in for the browser's service
// worker. Colin 2026-11-14: "make it so it rings a notification on our devices even when the app isn't open". The
// alert buzzes again like a phone until it is tapped, the call is answered, or the app is on screen; tapping it never
// reloads an open app (a reload hangs up the softphone and ends the seller's call); Answer asks the app to answer.
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

type Note = { title: string; options: Record<string, unknown>; closed: boolean; close: () => void }
type Win = { url: string; focused: boolean; visibilityState: string; focus: () => Promise<Win>; navigate: ReturnType<typeof vi.fn>; postMessage: (m: unknown, ports?: { postMessage: (x: unknown) => void }[]) => void; heard: unknown[]; answers: boolean }

function worker() {
  const listeners: Record<string, (e: unknown) => void> = {}
  const notes: Note[] = []
  const shown: Note[] = []
  const windows: Win[] = []
  const opened: string[] = []
  const self = {
    location: { origin: 'https://app.example' },
    addEventListener: (ev: string, f: (e: unknown) => void) => { listeners[ev] = f },
    skipWaiting: () => undefined,
    registration: {
      showNotification: async (title: string, options: Record<string, unknown>) => {
        for (const n of notes) if (n.options.tag && n.options.tag === options.tag) n.closed = true   // the same tag replaces
        const n: Note = { title, options, closed: false, close() { this.closed = true } }
        notes.push(n); shown.push(n)
      },
      getNotifications: async (q: { tag?: string }) => notes.filter((n) => !n.closed && (!q?.tag || n.options.tag === q.tag)),
    },
    clients: { matchAll: async () => windows, openWindow: async (u: string) => { opened.push(u) }, claim: async () => undefined },
  }
  class Channel {
    port1: { onmessage: ((e: unknown) => void) | null } = { onmessage: null }
    port2 = { postMessage: (x: unknown) => { this.port1.onmessage?.({ data: x }) } }
  }
  const src = readFileSync(join(__dirname, '..', 'public', 'sw.js'), 'utf8')
  new Function('self', 'caches', 'fetch', 'MessageChannel', src)(self, { open: async () => ({ addAll: async () => undefined }), keys: async () => [] }, async () => new Response(''), Channel)
  const fire = (ev: string, e: Record<string, unknown>) => {
    let done: Promise<unknown> = Promise.resolve()
    listeners[ev]({ ...e, waitUntil: (p: Promise<unknown>) => { done = p } })
    return done
  }
  const win = (x: Partial<Win> = {}): Win => {
    const w: Win = { url: 'https://app.example/today', focused: false, visibilityState: 'hidden', heard: [], answers: true, navigate: vi.fn(async () => undefined),
      focus: async () => { w.focused = true; w.visibilityState = 'visible'; return w },
      postMessage: (m, ports) => { w.heard.push(m); if (w.answers) ports?.[0]?.postMessage('ok') }, ...x }
    windows.push(w)
    return w
  }
  const push = (data: Record<string, unknown>) => fire('push', { data: { json: () => data } })
  return { fire, push, win, notes, shown, opened }
}

const RING = { title: 'ADAM HUSS is calling now', body: '2415 Hayes Street · (920) 901-1163. Tap Answer.', url: 'https://app.example/lead/L1#ring-CA1', tag: 'followup:x' }

beforeEach(() => { vi.useFakeTimers() })
afterEach(() => { vi.useRealTimers() })

describe("the phone's alert for a call that is ringing", () => {
  it('stays up, buzzes, carries Answer, and buzzes again every four seconds for about twenty', async () => {
    const w = worker()
    const done = w.push(RING)
    await vi.advanceTimersByTimeAsync(10)
    expect(w.shown.length).toBe(1)
    expect(w.shown[0].title).toBe('ADAM HUSS is calling now')
    expect(w.shown[0].options).toMatchObject({ tag: 'wpie-call-coming-in', renotify: true, requireInteraction: true, actions: [{ action: 'answer', title: 'Answer' }] })
    expect((w.shown[0].options.vibrate as number[]).length).toBeGreaterThan(3)
    await vi.advanceTimersByTimeAsync(8_100)
    expect(w.shown.length).toBe(3)
    await vi.advanceTimersByTimeAsync(30_000)
    await done
    expect(w.shown.length).toBe(6)                       // the first and five more, then it rests
    expect(w.notes.filter((n) => !n.closed).length).toBe(1)   // one alert on the phone, never a stack
  })

  it('stops buzzing once the app says the call was answered or is over, and takes the alert down', async () => {
    const w = worker()
    const done = w.push(RING)
    await vi.advanceTimersByTimeAsync(4_100)
    expect(w.shown.length).toBe(2)
    await w.fire('message', { data: { type: 'wpie-ring-stop' } })
    await vi.advanceTimersByTimeAsync(30_000)
    await done
    expect(w.shown.length).toBe(2)
    expect(w.notes.filter((n) => !n.closed).length).toBe(0)
  })

  it('stops buzzing when it is swiped away, and when the app is on screen with its own Answer', async () => {
    const w = worker()
    const done = w.push(RING)
    await vi.advanceTimersByTimeAsync(100)
    w.notes.forEach((n) => n.close())
    await vi.advanceTimersByTimeAsync(30_000)
    await done
    expect(w.shown.length).toBe(1)
    const v = worker()
    v.win({ focused: true, visibilityState: 'visible' })
    const d2 = v.push(RING)
    await vi.advanceTimersByTimeAsync(30_000)
    await d2
    expect(v.shown.length).toBe(1)
  })

  it('any other alert is shown once, as before', async () => {
    const w = worker()
    await w.push({ title: 'Reply needs you', body: 'x', url: 'https://app.example/inbox', tag: 'reply:1' })
    await vi.advanceTimersByTimeAsync(30_000)
    expect(w.shown.length).toBe(1)
    expect(w.shown[0].options.tag).toBe('reply:1')
    expect(w.shown[0].options.requireInteraction).toBeUndefined()
  })
})

describe('tapping an alert', () => {
  const click = (w: ReturnType<typeof worker>, action: string, data: Record<string, unknown>) =>
    w.fire('notificationclick', { action, notification: { close: () => undefined, data } })

  it('Answer brings the open app forward and asks it to answer; the page is never loaded again', async () => {
    const w = worker()
    const app = w.win()
    const done = click(w, 'answer', { url: RING.url, ring: true })
    await vi.advanceTimersByTimeAsync(10)
    await done
    expect(app.focused).toBe(true)
    expect(app.heard).toEqual([{ type: 'wpie-answer', url: RING.url }])
    expect(app.navigate).not.toHaveBeenCalled()
    expect(w.opened).toEqual([])
  })

  it('a ringing call never reloads the app, even an older copy that does not answer the service worker', async () => {
    const w = worker()
    const app = w.win({ answers: false })
    const done = click(w, '', { url: RING.url })
    await vi.advanceTimersByTimeAsync(1_000)
    await done
    expect(app.focused).toBe(true)
    expect(app.navigate).not.toHaveBeenCalled()
  })

  it('with the app shut it opens the app on the card; any other alert still goes to its page', async () => {
    const w = worker()
    await click(w, 'answer', { url: RING.url, ring: true })
    expect(w.opened).toEqual([RING.url])
    const v = worker()
    const old = v.win({ answers: false })
    const done = click(v, '', { url: 'https://app.example/inbox' })
    await vi.advanceTimersByTimeAsync(1_000)
    await done
    expect(old.navigate).toHaveBeenCalledWith('https://app.example/inbox')     // an older copy of the app: the old way
    const x = worker()
    const cur = x.win()
    const d3 = click(x, '', { url: 'https://app.example/inbox' })
    await vi.advanceTimersByTimeAsync(10)
    await d3
    expect(cur.heard).toEqual([{ type: 'wpie-open', url: 'https://app.example/inbox' }])
    expect(cur.navigate).not.toHaveBeenCalled()
  })
})
