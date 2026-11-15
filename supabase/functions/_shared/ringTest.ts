// A test call to one person's phone, the way a seller's call reaches it (Colin 2026-11-14: "Test calling me", again
// and again, with the app shut). It does what the phone server does for a real call: buzzes the phone ("Test call is
// calling now", with Answer), then keeps trying the app's softphone every few seconds for the same 45 seconds, buzzing
// once more half way, until it is answered. A shut app has no softphone, so the first tries fail at once; the test
// passes when the person taps the alert, the app opens, and a later try rings it and is answered.
// Nothing here touches a seller, a seller line or a card. This file is only the steps; functions/ring-test wires the
// push and the phone company to it.

export const RING_TEST_WINDOW_MS = 45_000
export const RING_TEST_SECOND_BUZZ_MS = 18_000
export const RING_TEST_TRY_SECONDS = 20         // the longest one try rings an app that is open (the phone server's own)
export const RING_TEST_GAP_MS = 2_000           // between tries at an app that is shut (the phone server's ring is 3 s)

export const RING_TEST_TWIML = '<Response><Pause length="1"/><Say voice="Polly.Joanna">This is a test call. You answered it, ' +
  'so calls can reach this phone. Goodbye.</Say><Pause length="1"/></Response>'

export type TryStatus = 'queued' | 'initiated' | 'ringing' | 'in-progress' | 'completed' | 'busy' | 'no-answer' | 'failed' | 'canceled'
export interface RingTestDeps {
  /** buzz the person's phones; returns how many phones were sent it */
  push: () => Promise<number>
  /** place one try at the softphone, ringing an open app for up to `seconds`; returns the phone company's call id, or
   *  null when it could not be placed */
  place: (seconds: number) => Promise<string | null>
  /** where that try stands, with its length in seconds once it has one */
  status: (sid: string) => Promise<{ status: TryStatus; duration: number }>
  sleep: (ms: number) => Promise<void>
  now: () => number
}
export interface RingTestResult {
  pushed: number
  tries: number
  answered: boolean
  answeredAfterS: number | null
  rang: boolean              // at least one try found the app open and rang it
  refused: boolean           // a try was turned away by the app (busy): the softphone itself said no
  note: string
}

const OVER: TryStatus[] = ['completed', 'busy', 'no-answer', 'failed', 'canceled']

export async function runRingTest(d: RingTestDeps): Promise<RingTestResult> {
  const t0 = d.now()
  const out: RingTestResult = { pushed: 0, tries: 0, answered: false, answeredAfterS: null, rang: false, refused: false, note: '' }
  out.pushed = await d.push().catch(() => 0)
  let buzzedTwice = false
  while (d.now() - t0 < RING_TEST_WINDOW_MS) {
    if (!buzzedTwice && d.now() - t0 >= RING_TEST_SECOND_BUZZ_MS) {
      buzzedTwice = true
      out.pushed += await d.push().catch(() => 0)
    }
    // a try at a shut app fails at once whatever it is given; one that finds the app open rings it for what is left
    const seconds = Math.max(6, Math.min(RING_TEST_TRY_SECONDS, Math.ceil((RING_TEST_WINDOW_MS - (d.now() - t0)) / 1000)))
    const sid = await d.place(seconds).catch(() => null)
    out.tries += 1
    if (!sid) { await d.sleep(RING_TEST_GAP_MS); continue }
    // follow this try until it is over or answered (a try at an open app rings up to RING_TEST_TRY_SECONDS)
    let last: { status: TryStatus; duration: number } = { status: 'queued', duration: 0 }
    const tryStart = d.now()
    while (d.now() - tryStart < (seconds + 6) * 1000) {
      await d.sleep(1000)
      last = await d.status(sid).catch(() => last)
      if (last.status === 'ringing' && d.now() - tryStart >= 2500) out.rang = true
      if (last.status === 'in-progress' || OVER.includes(last.status)) break
    }
    if (last.status === 'in-progress' || (last.status === 'completed' && last.duration > 0)) {
      out.answered = true
      out.rang = true
      out.answeredAfterS = Math.round((tryStart - t0) / 1000)
      break
    }
    if (last.status === 'busy') out.refused = true
    await d.sleep(RING_TEST_GAP_MS)
  }
  out.note = out.answered ? `Answered ${out.answeredAfterS} seconds in, on try ${out.tries}.`
    : out.refused ? 'The app turned the call away (busy). It rang but was declined, or the softphone refused it.'
    : out.rang ? 'The app was open and rang, but nobody answered.'
    : out.pushed > 0 ? 'The phone was buzzed, but the app was never opened: no softphone came up in 45 seconds.'
    : 'No phone took the alert for this person (call alerts are off, or the phone refused it), and no app was open: nothing could ring.'
  return out
}
