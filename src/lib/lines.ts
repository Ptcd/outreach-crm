// Three lines at once (Colin 2026-11-13: "Make our dialer a triple line dialer"). Power hour rings the card on screen
// and the next two together; the first PERSON to pick up is the caller's call, and the other lines are dropped.
//
// Each line is its own call through the same per-call safety check as a single call (begin_human_call in the app,
// claim_human_call_provider on the phone server): nothing about who may be called changes. What is new is deciding
// which line the caller gets:
//   - a line that answers is HEARD at once (the caller can say hello straight away) while the others keep ringing;
//   - the phone server screens each line for a machine and hangs a voicemail up within a few seconds, so a line that
//     ends inside the listen was a machine (or someone who hung up at once) and the round goes on;
//   - a line still up after the listen is a person: it WINS and the other lines are hung up;
//   - a second person who answers while the first is being listened to waits, muted, and is heard next if the first
//     turns out to be a machine; if the first is a person, the second is cut off. That is the cost of three lines: it
//     is counted (dropped_after_pickup) and the card is called back first.
//
// This file is only the deciding. It knows nothing of Twilio: lib/dialer hands it call objects.

/** How long an answered line is listened to before it is taken for a person. The phone server gives its machine
 *  verdict in at most five seconds and hangs a machine up. */
export const SCREEN_MS = 5500

export type LineOutcome = 'won' | 'machine' | 'no_answer' | 'other_line_answered' | 'dropped_after_pickup' | 'failed'

export interface LineSpec { to: string; label: string; leadId: string }
export interface LineResult extends LineSpec { outcome: Exclude<LineOutcome, 'won'>; error: string | null; rang: boolean }

/** What is written on the card for a line that did not become the call. A failed line is not logged: nobody rang. */
export const LINE_NOTE: Record<Exclude<LineOutcome, 'won' | 'failed'>, string> = {
  machine: 'No answer: voicemail picked up, no message left (three lines, Power hour).',
  no_answer: 'No answer: rang, nobody picked up (three lines, Power hour).',
  other_line_answered: 'No answer: hung up while ringing because another line picked up (three lines, Power hour).',
  dropped_after_pickup: 'They picked up while another line was being answered and were cut off. Call them back first (three lines, Power hour).',
}

/** The parts of a Twilio call this needs. */
export interface CallLike {
  disconnect(): void
  mute(shouldMute?: boolean): void
  on(event: string, fn: (e?: { message?: string; code?: number }) => void): unknown
  getRemoteStream?: () => MediaStream | undefined | null
}

export function lineOutcome(l: { answeredAt: number | null; rang: boolean; error: string | null; hungUpByUs: boolean }, isWinner: boolean, someoneWon: boolean): LineOutcome {
  if (isWinner) return 'won'
  if (l.answeredAt !== null) {
    if (l.hungUpByUs) return someoneWon ? 'dropped_after_pickup' : 'no_answer'     // the caller hung up during the listen
    return 'machine'                                                               // it ended by itself inside the listen
  }
  if (l.error && !l.rang) return 'failed'
  return someoneWon && l.hungUpByUs ? 'other_line_answered' : 'no_answer'
}

type Member = { spec: LineSpec; call: CallLike; up: boolean; answeredAt: number | null; rang: boolean; error: string | null; hungUpByUs: boolean }

export interface LineGroupHooks {
  /** the caller now hears this line (it answered); `call` is the one to mute or hang up */
  onHear(spec: LineSpec, call: CallLike): void
  /** nobody is being heard: lines are ringing (after a machine was dropped, or at the start) */
  onRinging(spec: LineSpec): void
  /** a line ended without becoming the call */
  onResult(r: LineResult): void
  /** the winning call ended */
  onWinnerEnd(spec: LineSpec, error: string | null): void
  /** every line is gone and nobody won */
  onAllGone(): void
  onCount?(up: number): void
  now?: () => number
  setTimer?: (fn: () => void, ms: number) => unknown
  clearTimer?: (h: unknown) => void
}

export class LineGroup {
  private members: Member[] = []
  private heard: Member | null = null
  private winner: Member | null = null
  private timer: unknown = null
  private closed = false
  private over = false
  private h: LineGroupHooks

  constructor(hooks: LineGroupHooks) { this.h = hooks }

  private now() { return (this.h.now ?? Date.now)() }
  private upCount() { return this.members.filter((m) => m.up).length }
  private silence(m: Member, on: boolean) {
    try { m.call.getRemoteStream?.()?.getAudioTracks().forEach((t) => { t.enabled = !on }) } catch { /* a line with no audio yet */ }
  }
  private hang(m: Member) {
    if (!m.up) return
    m.hungUpByUs = true
    try { m.call.disconnect() } catch { /* already gone */ }
  }

  get winnerSpec(): LineSpec | null { return this.winner?.spec ?? null }
  get heardCall(): CallLike | null { return this.heard?.call ?? null }

  /** A line that was placed. */
  add(spec: LineSpec, call: CallLike) {
    const m: Member = { spec, call, up: true, answeredAt: null, rang: false, error: null, hungUpByUs: false }
    this.members.push(m)
    call.on('ringing', () => { m.rang = true; if (!this.heard && !this.winner && m.up) this.h.onRinging(this.firstUp()?.spec ?? spec) })
    call.on('accept', () => this.answered(m))
    call.on('disconnect', () => this.ended(m))
    call.on('cancel', () => this.ended(m))
    call.on('reject', () => this.ended(m))
    call.on('error', (e) => { m.error = `${e?.message ?? 'Call failed'}${e?.code ? ` (Twilio ${e.code})` : ''}`; this.ended(m) })
    this.h.onCount?.(this.upCount())
    if (this.closed) this.hang(m)           // the caller hung up while this line was still being placed
    else if (this.winner) this.hang(m)
  }

  /** A line that could not be placed at all (the safety check refused it, the device failed). */
  fail(spec: LineSpec, error: string) {
    this.h.onResult({ ...spec, outcome: 'failed', error, rang: false })
  }

  /** Every line has been placed or has failed: if none is up and nobody won, the round is over. */
  settle() { this.maybeOver() }

  private firstUp(): Member | undefined { return this.members.find((m) => m.up) }

  private answered(m: Member) {
    if (!m.up || m.answeredAt !== null) return
    m.answeredAt = this.now()
    m.rang = true
    if (this.winner) { this.hang(m); return }             // a person already has the caller: this one is cut off
    if (this.heard) { try { m.call.mute(true) } catch { /* */ } this.silence(m, true); return }   // waits, muted, in case the first is a machine
    this.hear(m)
  }

  private hear(m: Member) {
    this.heard = m
    try { m.call.mute(false) } catch { /* */ }
    this.silence(m, false)
    for (const o of this.members) if (o !== m && o.up) { if (o.answeredAt !== null) { try { o.call.mute(true) } catch { /* */ } } this.silence(o, true) }
    this.h.onHear(m.spec, m.call)
    const left = Math.max(0, SCREEN_MS - (this.now() - (m.answeredAt ?? this.now())))
    this.timer = (this.h.setTimer ?? ((fn, ms) => setTimeout(fn, ms)))(() => this.confirm(m), left)
  }

  /** The line being heard is still up after the listen: a person. It is the call; the rest are dropped. */
  private confirm(m: Member) {
    this.timer = null
    if (!m.up || this.winner || this.heard !== m) return
    this.winner = m
    for (const o of this.members) if (o !== m) this.hang(o)
  }

  private ended(m: Member) {
    if (!m.up) return
    m.up = false
    this.h.onCount?.(this.upCount())
    if (m === this.winner) { this.over = true; this.h.onWinnerEnd(m.spec, m.error); return }
    this.h.onResult({ ...m.spec, outcome: lineOutcome(m, false, !!this.winner) as Exclude<LineOutcome, 'won'>, error: m.error, rang: m.rang })
    if (m === this.heard) {
      this.heard = null
      if (this.timer !== null) { (this.h.clearTimer ?? ((h) => clearTimeout(h as ReturnType<typeof setTimeout>)))(this.timer); this.timer = null }
      if (!this.closed) {
        const next = this.members.filter((x) => x.up && x.answeredAt !== null).sort((a, b) => (a.answeredAt ?? 0) - (b.answeredAt ?? 0))[0]
        if (next) { this.hear(next); return }
        const ringing = this.firstUp()
        if (ringing) { for (const o of this.members) if (o.up) this.silence(o, false); this.h.onRinging(ringing.spec); return }
      }
    }
    this.maybeOver()
  }

  private maybeOver() {
    if (this.over || this.winner || this.upCount() > 0) return
    this.over = true
    this.h.onAllGone()
  }

  /** The caller's Hang up: ends the call she is on, or the whole round when nobody has been confirmed yet. */
  hangUp() {
    if (this.winner) { this.hang(this.winner); return }
    this.closed = true
    if (this.timer !== null) { (this.h.clearTimer ?? ((h) => clearTimeout(h as ReturnType<typeof setTimeout>)))(this.timer); this.timer = null }
    const answeredHeard = this.heard
    for (const m of this.members) {
      if (!m.up) continue
      if (m === answeredHeard) m.hungUpByUs = true
      try { m.call.disconnect() } catch { /* already gone */ }
    }
    this.maybeOver()
  }
}
