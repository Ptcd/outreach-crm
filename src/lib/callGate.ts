// Call answers -> the walk gate. Each answer from the call script (leads.call_facts) and what the
// seller already said by text (the reply agent's facts) suggests a score for the gate items it
// settles, with the reason. Colin still saves the gate himself; "numbers close" is never
// suggested: it needs his own number, which the app never holds.
import type { GateScores } from './wpie'

export type CallValue = { choices?: string[]; text?: string; number?: string; when?: string; kind?: string; at?: string }
export type CallFacts = Record<string, { value: CallValue | string; at: string; by?: string | null }>
export type GateHint = { score: 0 | 1 | 2; why: string }
export type GateHints = Partial<Record<keyof GateScores, GateHint>>

export function answerOf(f: CallFacts | null | undefined, id: string): CallValue | null {
  const v = f?.[id]?.value
  if (!v || typeof v !== 'object') return null
  const has = (v.choices?.length ?? 0) > 0 || !!v.text?.trim() || !!v.number?.trim() || !!v.when
  return has ? v : null
}
const said = (reply: Record<string, unknown> | null | undefined, k: string) => {
  const v = reply?.[k]
  return typeof v === 'string' && v.trim() && v !== 'null' ? v.trim() : null
}
const anyOf = (v: CallValue | null, ids: string[]) => !!v?.choices?.some((c) => ids.includes(c))

export function gateFromCall(facts: CallFacts | null | undefined, reply?: Record<string, unknown> | null): GateHints {
  const out: GateHints = {}
  const motivation = answerOf(facts, 'motivation')
  const timeline = answerOf(facts, 'timeline')
  const reason = (motivation && (motivation.text?.trim() || motivation.choices?.some((c) => c !== 'just_price'))) || said(reply, 'motivation')
  const clock = (timeline && (timeline.text?.trim() || anyOf(timeline, ['asap', 'under_30', 'one_to_three', 'three_to_six']))) || said(reply, 'timeline')
  // q11: "are you in a spot to say yes or no, with everyone who'd need to sign there?" (or the older all_at_walk)
  const ready = answerOf(facts, 'ready') ?? answerOf(facts, 'all_at_walk')
  if (motivation || timeline || said(reply, 'motivation') || said(reply, 'timeline')) {
    out.reason_and_clock = reason && clock ? { score: 2, why: 'A reason and a date or event' }
      : reason ? { score: 1, why: 'A reason, but no date yet' }
      : clock ? { score: 1, why: 'A date, but no reason yet' }
      : { score: 0, why: 'Only "the right price"' }
  }

  const dm = answerOf(facts, 'decision_makers')
  if (dm || ready || said(reply, 'decision_makers')) {
    out.decision_makers = anyOf(ready, ['yes']) && (dm || said(reply, 'decision_makers')) ? { score: 2, why: 'Every signer named and can be there' }
      : dm || said(reply, 'decision_makers') ? { score: 1, why: 'Signers named; not all lined up yet' }
      : { score: 0, why: 'Not yet known who signs' }
  }

  const price = answerOf(facts, 'price')
  const anchor = answerOf(facts, 'anchor') ?? price
  const needAnchor = anyOf(anchor, ['own_need', 'paid', 'next_place'])
  if (price || answerOf(facts, 'anchor') || said(reply, 'price_expectation')) {
    out.number_and_anchor = !price?.number?.trim() && anyOf(price, ['refused']) && !said(reply, 'price_expectation') ? { score: 0, why: 'Refused after two asks' }
      : needAnchor ? { score: 2, why: 'Their number rests on their own need, payoff or what they paid' }
      : anyOf(anchor, ['online', 'bank', 'listing', 'neighbor', 'offers']) ? { score: 1, why: 'Their number rests on an estimate, a neighbor or other offers' }
      : { score: 1, why: 'A number; where it came from not asked yet' }
  }
  const flex = answerOf(facts, 'flexibility')
  if (flex) {
    out.flexibility = anyOf(flex, ['moved', 'open']) ? { score: 2, why: 'Open to hearing a number under theirs' }
      : anyOf(flex, ['terms', 'depends']) ? { score: 1, why: 'Price held, open on terms or it depends' }
      : needAnchor ? { score: 1, why: 'Firm, but the floor rests on a real need' }
      : { score: 0, why: 'Held firm on a market number' }
  }

  const occ = answerOf(facts, 'occupancy') || (said(reply, 'occupancy') ? {} : null)
  const cond = answerOf(facts, 'condition') || answerOf(facts, 'work_list') || answerOf(facts, 'happened') || (said(reply, 'condition') ? {} : null)
  if (occ || cond) {
    out.condition = occ && cond ? { score: 2, why: 'Who lives there and the main problems, in their words' }
      : { score: 1, why: occ ? 'Occupancy known, condition not yet' : 'Condition known, occupancy not yet' }
  }
  return out
}

/** Hard stops the call turned up. */
export function stopsFromCall(facts: CallFacts | null | undefined): string[] {
  const out: string[] = []
  if (anyOf(answerOf(facts, 'other_buyer'), ['listed', 'signed']) || anyOf(answerOf(facts, 'identity'), ['agent'])) out.push('listed_active')
  if (anyOf(answerOf(facts, 'behind'), ['sale_14'])) out.push('sheriff_inside_14_days')
  if (facts?.last_call && (facts.last_call.value === 'dnc')) out.push('dnc_or_no_contact')
  return out
}

/** A one-line summary of an answer, for the "already known" list. */
export function answerText(v: CallValue | null, labels: Record<string, string>): string {
  if (!v) return ''
  return [
    v.choices?.map((c) => labels[c] ?? c).join(', '),
    v.number?.trim() ? `$${v.number.trim()}` : '',
    v.when ? new Date(v.when).toLocaleString('en-US', { timeZone: 'America/Chicago', weekday: 'short', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }) : '',
    v.text?.trim() ? `"${v.text.trim()}"` : '',
  ].filter(Boolean).join(' - ')
}
