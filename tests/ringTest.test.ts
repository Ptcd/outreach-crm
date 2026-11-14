// The test call to one person's phone (supabase/functions/_shared/ringTest.ts): it buzzes the phone and keeps trying
// the softphone for 45 seconds, like a seller's call. Colin 2026-11-14: "Test calling me", with the app shut.
import { describe, expect, it } from 'vitest'
import { RING_TEST_WINDOW_MS, runRingTest, type TryStatus } from '../supabase/functions/_shared/ringTest'

/** A phone whose app comes up `opensAt` ms into the test (never, when null) and is answered `answerAfter` ms into a ring. */
function phone(x: { opensAt: number | null; answerAfter?: number | null; refuses?: boolean; phones?: number }) {
  let now = 0
  const pushes: number[] = []
  const placed: { sid: string; at: number; open: boolean }[] = []
  const deps = {
    now: () => now,
    sleep: async (ms: number) => { now += ms },
    push: async () => { pushes.push(now); return x.phones ?? 1 },
    place: async () => { const c = { sid: `CA${placed.length + 1}`, at: now, open: x.opensAt !== null && now >= x.opensAt }; placed.push(c); return c.sid },
    status: async (sid: string): Promise<{ status: TryStatus; duration: number }> => {
      const c = placed.find((p) => p.sid === sid)!
      const age = now - c.at
      if (!c.open) return { status: 'no-answer', duration: 0 }                        // no softphone: it fails at once
      if (x.refuses) return { status: 'busy', duration: 0 }
      if (x.answerAfter != null && age >= x.answerAfter) return { status: 'in-progress', duration: 0 }
      return age >= 8000 ? { status: 'no-answer', duration: 0 } : { status: 'ringing', duration: 0 }
    },
  }
  return { deps, pushes, placed }
}

describe('a test call to a phone', () => {
  it('app shut, alert tapped at 12 seconds: the phone is buzzed, the tries go on, and a later one is answered', async () => {
    const p = phone({ opensAt: 12_000, answerAfter: 3_000 })
    const r = await runRingTest(p.deps)
    expect(p.pushes[0]).toBe(0)                                  // buzzed first
    expect(r.answered).toBe(true)
    expect(r.tries).toBeGreaterThan(2)                           // the first tries found no app and failed at once
    expect(r.answeredAfterS).toBeGreaterThanOrEqual(12)
    expect(r.answeredAfterS).toBeLessThan(20)
    expect(r.note).toContain('Answered')
  })

  it('never opened: buzzed twice, tried for the whole 45 seconds, and says the app never came up', async () => {
    const p = phone({ opensAt: null })
    const r = await runRingTest(p.deps)
    expect(r.answered).toBe(false)
    expect(p.pushes.length).toBe(2)
    expect(p.pushes[1]).toBeGreaterThanOrEqual(18_000)
    expect(p.placed.at(-1)!.at).toBeLessThan(RING_TEST_WINDOW_MS)
    expect(p.placed.length).toBeGreaterThanOrEqual(8)
    expect(r.note).toBe('The phone was buzzed, but the app was never opened: no softphone came up in 45 seconds.')
  })

  it('app open the whole time and answered at once: one try', async () => {
    const p = phone({ opensAt: 0, answerAfter: 2_000 })
    const r = await runRingTest(p.deps)
    expect(r).toMatchObject({ answered: true, tries: 1, answeredAfterS: 0, rang: true })
  })

  it('app open, rings, nobody answers; and an app that turns the call away is reported as that', async () => {
    const quiet = await runRingTest(phone({ opensAt: 0, answerAfter: null }).deps)
    expect(quiet.answered).toBe(false)
    expect(quiet.rang).toBe(true)
    expect(quiet.note).toBe('The app was open and rang, but nobody answered.')
    const no = await runRingTest(phone({ opensAt: 0, refuses: true }).deps)
    expect(no.refused).toBe(true)
    expect(no.note).toContain('turned the call away')
  })

  it('no phone with alerts on and no app open: says nothing could ring', async () => {
    const r = await runRingTest(phone({ opensAt: null, phones: 0 }).deps)
    expect(r.pushed).toBe(0)
    expect(r.note).toBe('No phone has call alerts turned on for this person, and no app was open: nothing could ring.')
  })
})
