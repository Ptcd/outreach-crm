// Three lines at once (src/lib/lines.ts): which line the caller gets, and what becomes of the other two.
import { describe, expect, it } from 'vitest'
import { LineGroup, SCREEN_MS, lineOutcome, type CallLike, type LineResult, type LineSpec } from '../src/lib/lines'

class FakeCall implements CallLike {
  handlers: Record<string, ((e?: { message?: string; code?: number }) => void)[]> = {}
  muted = false; ended = false
  on(ev: string, fn: (e?: { message?: string; code?: number }) => void) { (this.handlers[ev] ??= []).push(fn); return this }
  emit(ev: string, e?: { message?: string; code?: number }) { for (const f of this.handlers[ev] ?? []) f(e) }
  mute(m = true) { this.muted = m }
  disconnect() { if (this.ended) return; this.ended = true; this.emit('disconnect') }
}

function setup(n = 3) {
  let now = 1_000
  const timers: { fn: () => void; at: number; live: boolean }[] = []
  const log: string[] = []
  const results: LineResult[] = []
  const g = new LineGroup({
    onHear: (s) => log.push(`hear ${s.leadId}`),
    onRinging: (s) => log.push(`ringing ${s.leadId}`),
    onResult: (r) => { results.push(r); log.push(`result ${r.leadId} ${r.outcome}`) },
    onWinnerEnd: (s, e) => log.push(`winner-end ${s.leadId}${e ? ' ' + e : ''}`),
    onAllGone: () => log.push('all-gone'),
    now: () => now,
    setTimer: (fn, ms) => { const t = { fn, at: now + ms, live: true }; timers.push(t); return t },
    clearTimer: (h) => { (h as { live: boolean }).live = false },
  })
  const specs: LineSpec[] = Array.from({ length: n }, (_, i) => ({ leadId: `L${i + 1}`, to: `414555000${i + 1}`, label: `Card ${i + 1}` }))
  const calls = specs.map((s) => { const c = new FakeCall(); g.add(s, c); return c })
  g.settle()
  const advance = (ms: number) => { now += ms; for (const t of timers) if (t.live && t.at <= now) { t.live = false; t.fn() } }
  return { g, calls, specs, log, results, advance }
}

describe('three lines', () => {
  it('the first person to pick up is the call; the others are hung up and logged as no answer', () => {
    const { g, calls, log, results, advance } = setup()
    calls.forEach((c) => c.emit('ringing'))
    advance(6000)
    calls[1].emit('accept')
    expect(log.at(-1)).toBe('hear L2')
    expect(calls[0].ended).toBe(false)                 // the others ring on while she listens
    advance(SCREEN_MS)
    expect(g.winnerSpec?.leadId).toBe('L2')
    expect([calls[0].ended, calls[1].ended, calls[2].ended]).toEqual([true, false, true])
    expect(results.map((r) => [r.leadId, r.outcome])).toEqual([['L1', 'other_line_answered'], ['L3', 'other_line_answered']])
    calls[1].disconnect()
    expect(log.at(-1)).toBe('winner-end L2')
  })

  it('a voicemail that answers is dropped by the phone server and the round goes on to a real person', () => {
    const { g, calls, log, results, advance } = setup()
    calls.forEach((c) => c.emit('ringing'))
    advance(3000)
    calls[0].emit('accept')                            // a phone that is off: voicemail at once
    advance(3500)
    calls[0].emit('disconnect')                        // the phone server hung the machine up inside the listen
    expect(results).toEqual([expect.objectContaining({ leadId: 'L1', outcome: 'machine' })])
    expect(log.at(-1)).toBe('ringing L2')
    expect(calls[1].ended || calls[2].ended).toBe(false)
    advance(4000)
    calls[2].emit('accept')
    advance(SCREEN_MS)
    expect(g.winnerSpec?.leadId).toBe('L3')
    expect(results.map((r) => r.outcome)).toEqual(['machine', 'other_line_answered'])
  })

  it('a second person who answers during the listen waits muted, and is cut off once the first is a person', () => {
    const { calls, results, advance } = setup()
    calls.forEach((c) => c.emit('ringing'))
    advance(5000)
    calls[0].emit('accept')
    advance(2000)
    calls[1].emit('accept')
    expect(calls[1].muted).toBe(true)
    expect(calls[1].ended).toBe(false)
    advance(SCREEN_MS)
    expect(calls[1].ended).toBe(true)
    expect(results.find((r) => r.leadId === 'L2')?.outcome).toBe('dropped_after_pickup')
    expect(results.find((r) => r.leadId === 'L3')?.outcome).toBe('other_line_answered')
  })

  it('but if the first was a machine, the second person is heard next and becomes the call', () => {
    const { g, calls, log, advance } = setup()
    calls.forEach((c) => c.emit('ringing'))
    advance(3000)
    calls[0].emit('accept')
    advance(1500)
    calls[1].emit('accept')
    advance(1500)
    calls[0].emit('disconnect')                        // machine
    expect(log.at(-1)).toBe('hear L2')
    expect(calls[1].muted).toBe(false)
    advance(SCREEN_MS)
    expect(g.winnerSpec?.leadId).toBe('L2')
  })

  it('nobody answers: the caller hangs up and all three are plain no answers', () => {
    const { g, calls, log, results } = setup()
    calls.forEach((c) => c.emit('ringing'))
    g.hangUp()
    expect(results.map((r) => r.outcome)).toEqual(['no_answer', 'no_answer', 'no_answer'])
    expect(results.every((r) => r.rang)).toBe(true)
    expect(log.at(-1)).toBe('all-gone')
  })

  it('a line the safety check refused is reported as failed and never logged as a call', () => {
    const { g, calls, results, log } = setup(2)
    g.fail({ leadId: 'L9', to: '4145550009', label: 'Card 9' }, 'this card is closed or do-not-contact')
    expect(results.at(-1)).toMatchObject({ leadId: 'L9', outcome: 'failed', rang: false })
    calls[0].emit('error', { message: 'gateway in HANGUP', code: 31005 })
    expect(results.at(-1)).toMatchObject({ leadId: 'L1', outcome: 'failed' })
    calls[1].emit('ringing'); calls[1].disconnect()
    expect(log.at(-1)).toBe('all-gone')
  })

  it('a line placed after the caller hung up is dropped at once', () => {
    const { g, calls, results } = setup(1)
    g.hangUp()
    const late = new FakeCall()
    g.add({ leadId: 'L5', to: '4145550005', label: 'Card 5' }, late)
    expect(late.ended).toBe(true)
    expect(calls[0].ended).toBe(true)
    expect(results.find((r) => r.leadId === 'L5')).toMatchObject({ outcome: 'no_answer', rang: false })
  })

  it('names each ending', () => {
    const base = { answeredAt: null, rang: true, error: null, hungUpByUs: false }
    expect(lineOutcome(base, true, true)).toBe('won')
    expect(lineOutcome(base, false, false)).toBe('no_answer')
    expect(lineOutcome({ ...base, hungUpByUs: true }, false, true)).toBe('other_line_answered')
    expect(lineOutcome({ ...base, answeredAt: 5 }, false, false)).toBe('machine')
    expect(lineOutcome({ ...base, answeredAt: 5, hungUpByUs: true }, false, true)).toBe('dropped_after_pickup')
    expect(lineOutcome({ ...base, rang: false, error: 'x' }, false, false)).toBe('failed')
  })
})

// Colin 2026-11-14: "it calls all 3 and connected all 3 to our caller instead of just 1". The caller is only ever
// connected to one line: one line in her ear, her microphone open to that line alone.
describe('three lines: one ear, one mouth', () => {
  class Line extends FakeCall {
    track: { enabled: boolean } | null = null                       // the line's sound; null until it arrives
    getRemoteStream() { return this.track ? ({ getAudioTracks: () => [this.track] } as unknown as MediaStream) : null }
    sound() { this.track = { enabled: true } }
    get heardByHer() { return !!this.track && this.track.enabled }
    get hearsHer() { return !this.muted }
  }
  function round() {
    let now = 1_000
    const timers: { fn: () => void; at: number; live: boolean }[] = []
    const g = new LineGroup({
      onHear: () => undefined, onRinging: () => undefined, onResult: () => undefined, onWinnerEnd: () => undefined, onAllGone: () => undefined,
      now: () => now,
      setTimer: (fn, ms) => { const t = { fn, at: now + ms, live: true }; timers.push(t); return t },
      clearTimer: (h) => { (h as { live: boolean }).live = false },
    })
    const calls = [1, 2, 3].map((i) => { const c = new Line(); g.add({ leadId: `L${i}`, to: `414555000${i}`, label: `Card ${i}` }, c); return c })
    g.settle()
    const advance = (ms: number) => { now += ms; for (const t of timers) if (t.live && t.at <= now) { t.live = false; t.fn() } }
    return { g, calls, advance }
  }
  const ears = (calls: { heardByHer: boolean }[]) => calls.map((c) => c.heardByHer)
  const mouths = (calls: { hearsHer: boolean }[]) => calls.map((c) => c.hearsHer)

  it('while all three ring she hears none of the lines (the app plays one ring of its own) and her microphone is shut to all', () => {
    const { g, calls } = round()
    expect(mouths(calls)).toEqual([false, false, false])            // shut from the moment each line is placed
    calls.forEach((c) => { c.sound(); c.emit('ringing') })          // each line's ringing arrives after it was placed
    g.enforce()
    expect(ears(calls)).toEqual([false, false, false])              // not three phones ringing on top of each other
    expect(mouths(calls)).toEqual([false, false, false])
    calls[0].emit('disconnect')
    expect(ears(calls.slice(1))).toEqual([false, false])
  })

  it('the line that answers is the only one she hears and the only one that hears her', () => {
    const { calls } = round()
    calls.forEach((c) => { c.sound(); c.emit('ringing') })
    calls[1].emit('accept')
    expect(ears(calls)).toEqual([false, true, false])
    expect(mouths(calls)).toEqual([false, true, false])
  })

  it('a second and third person who pick up during the listen never hear her and are never heard, then are hung up', () => {
    const { g, calls, advance } = round()
    calls.forEach((c) => { c.sound(); c.emit('ringing') })
    calls[1].emit('accept')
    advance(1000); calls[0].emit('accept')
    advance(1000); calls[2].emit('accept')
    expect(ears(calls)).toEqual([false, true, false])
    expect(mouths(calls)).toEqual([false, true, false])
    advance(SCREEN_MS)
    expect(g.winnerSpec?.leadId).toBe('L2')
    expect(calls.map((c) => c.ended)).toEqual([true, false, true])
  })

  it('a line whose sound arrives after another line was answered is silenced the next time the rule is applied', () => {
    const { g, calls } = round()
    calls[1].sound(); calls[1].emit('ringing')
    calls[1].emit('accept')                                         // line 2 is being heard; lines 1 and 3 have no sound yet
    calls[0].sound(); calls[2].sound()                              // their ringing (then a voice) arrives now
    expect(ears(calls)).toEqual([true, true, true])                 // what used to happen: all three in her ear
    g.enforce()                                                     // lib/dialer does this five times a second
    expect(ears(calls)).toEqual([false, true, false])
    expect(mouths(calls)).toEqual([false, true, false])
  })

  it('once a call is confirmed her own Mute is hers: the rule never opens her microphone again', () => {
    const { g, calls, advance } = round()
    calls.forEach((c) => { c.sound(); c.emit('ringing') })
    calls[0].emit('accept')
    advance(SCREEN_MS)
    calls[0].mute(true)                                             // she taps Mute to cough
    g.enforce(); g.enforce()
    expect(calls[0].muted).toBe(true)
    expect(calls[0].heardByHer).toBe(true)
  })

  it('a voicemail hung up inside the listen: the next person who had picked up is heard and can hear her', () => {
    const { calls, advance } = round()
    calls.forEach((c) => { c.sound(); c.emit('ringing') })
    calls[0].emit('accept')                                         // a voicemail
    advance(1500); calls[2].emit('accept')                          // a person, waiting unheard
    expect(ears(calls)).toEqual([true, false, false])
    advance(2000); calls[0].emit('disconnect')                      // the phone server hung the machine up
    expect(calls[2].heardByHer).toBe(true)
    expect(calls[2].hearsHer).toBe(true)
    expect(calls[1].heardByHer).toBe(false)
    expect(calls[1].hearsHer).toBe(false)
  })
})

