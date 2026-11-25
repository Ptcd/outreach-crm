// Double dial in Power hour (Colin 2026-11-25): the same number is called once more at once only when the first call
// shows it never reached them: "shouldn't it only double dial if signs are shown that the first call didn't go through".

/** One call on the card, for double dial: ms from placing it to something answering, and to its end. */
export type CallFacts = { key: string; placedAt: number; answeredAfter: number | null; endedAfter: number | null; errored: boolean }
/** Something picked up this soon (from the moment the call was placed, so about 8 s of ringing): a voicemail that took
 *  it before a person could have, which is what a silenced, declined or spam-filtered call looks like. */
export const FAST_PICKUP_MS = 10_000
/** It ended, unanswered, this soon: declined or rejected, not rung out (Power hour lets a call ring 22 s). */
export const EARLY_END_MS = 18_000
/** Why the call never reached them, in words for the card, or null when it rang through (double dial only then). */
export function didNotReach(f: CallFacts | null): string | null {
  if (!f || f.endedAfter === null || f.errored) return null
  if (f.answeredAfter !== null) return f.answeredAfter <= FAST_PICKUP_MS ? `Voicemail took it after ${Math.round(f.answeredAfter / 1000)} s, before it could ring through.` : null
  return f.endedAfter < EARLY_END_MS ? `It ended after ${Math.round(f.endedAfter / 1000)} s without ringing out (declined or blocked).` : null
}
