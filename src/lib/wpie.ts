// WPIE vocab in plain words: pipeline stages (wpie/reply/qualification.yaml), the
// walk gate (docs/SELLER_QUALIFICATION_LOGIC.md section b) and follow-up kinds.
// Nothing here computes or suggests an offer, value or price.
import type { GateDecision, LeadStage, MilestoneKind } from './types'

export interface StageInfo {
  id: LeadStage
  label: string
  who: 'system' | 'ai' | 'colin'
  group: 'automatic' | 'working' | 'closed'
}

export const STAGES: StageInfo[] = [
  { id: 'postcard_mailed', label: 'Not texted yet', who: 'system', group: 'automatic' },
  { id: 'opener_queued', label: 'Text planned', who: 'colin', group: 'automatic' },
  { id: 'opener_sent', label: 'Text sent', who: 'system', group: 'automatic' },
  { id: 'reply_received', label: 'Replied', who: 'ai', group: 'working' },
  { id: 'ai_qualifying', label: 'Qualifying by text', who: 'ai', group: 'working' },
  { id: 'handoff', label: 'Ready for Colin', who: 'system', group: 'working' },
  { id: 'colin_call', label: "Colin's call", who: 'colin', group: 'working' },
  { id: 'walk_decision', label: 'Walk decision', who: 'colin', group: 'working' },
  { id: 'walkthrough_booked', label: 'Walk booked', who: 'colin', group: 'working' },
  { id: 'offer', label: 'Offer', who: 'colin', group: 'working' },
  { id: 'follow_up', label: 'Follow up later', who: 'colin', group: 'working' },
  { id: 'under_contract', label: 'Under contract', who: 'colin', group: 'working' },
  { id: 'human_owned', label: 'Colin texting', who: 'colin', group: 'working' },
  { id: 'data_fix', label: 'Wrong number', who: 'system', group: 'working' },
  { id: 'closed_won', label: 'Closed', who: 'colin', group: 'closed' },
  { id: 'mail_only', label: "Can't text", who: 'system', group: 'closed' },
  { id: 'dead', label: 'Dead', who: 'system', group: 'closed' },
  { id: 'closed_no_contact', label: 'No reply / no contact', who: 'system', group: 'closed' },
  { id: 'dnc', label: 'Do not contact', who: 'system', group: 'closed' },
]

export const STAGE_LABEL: Record<LeadStage, string> = Object.fromEntries(
  STAGES.map((s) => [s.id, s.label]),
) as Record<LeadStage, string>

export const WORKING_STAGES = STAGES.filter((s) => s.group === 'working').map((s) => s.id)

export interface GateItem {
  id: 'reason_and_clock' | 'decision_makers' | 'number_and_anchor' | 'flexibility' | 'condition' | 'numbers_close'
  label: string
  scale: [string, string, string] // text for 0, 1, 2
}

export const GATE_ITEMS: GateItem[] = [
  {
    id: 'reason_and_clock',
    label: 'Reason + clock',
    scale: [
      'Nothing beyond "the right price"',
      'A reason with no date, or a date with no reason',
      'A reason tied to selling AND a date or event forcing timing',
    ],
  },
  {
    id: 'decision_makers',
    label: 'Decision makers',
    scale: [
      'Unknown who signs',
      'Everyone named, not all available or agreed',
      'Every signer named and at the visit or agreed to it',
    ],
  },
  {
    id: 'number_and_anchor',
    label: 'Their number + why',
    scale: [
      'No number, even on your call',
      'Number rests on a listing, online estimate, neighbour sale or other offers',
      'Number rests on their own need, payoff or what they paid',
    ],
  },
  {
    id: 'flexibility',
    label: 'Flexibility',
    scale: [
      'Held firm on a market number, or never tested',
      'Price held, but open on terms or timing you will use, or a firm floor resting on a real need (payoff plus arrears)',
      'Moved, or clearly open to hearing well under their number',
    ],
  },
  {
    id: 'condition',
    label: 'Condition',
    scale: [
      'Unknown, or "just paint" with a near-retail number',
      'Vague ("needs some work")',
      'Occupancy, main problems in their words, access known (hold: rent roll, big items)',
    ],
  },
  {
    id: 'numbers_close',
    label: 'Numbers close',
    scale: [
      'Their number is beyond the gap you will close',
      'Above your own number, inside the gap you will close on site',
      'Their number after the flexibility test is at or under your own number',
    ],
  },
]

export const HARD_STOPS: { id: string; label: string }[] = [
  { id: 'dnc_or_no_contact', label: 'Asked to be removed, or hostile' },
  { id: 'listed_active', label: 'Listed, or signed anything with another buyer (no written cancellation)' },
  { id: 'no_authority', label: 'Estate or company with nobody who can sign' },
  { id: 'elderly_without_family', label: 'Older, seriously ill or any memory trouble, and named family not invited' },
  { id: 'sheriff_inside_14_days', label: 'Behind on payments: sale less than 14 days out' },
  { id: 'payoff_above_number', label: 'Behind on payments: payoff plus arrears above my number' },
  { id: 'hold_lane_no_financials', label: 'Hold lane: no written rent roll for 5+ units (2-4 units: rent list on my call is enough)' },
]

export type GateScores = Record<GateItem['id'], number>

export const DECISION_LABEL: Record<GateDecision, string> = {
  walk: 'Walk it',
  one_more_call: 'One more call first',
  no_walk: "Don't walk",
}

export function gateTotal(s: GateScores): number {
  return GATE_ITEMS.reduce((sum, item) => sum + (s[item.id] ?? 0), 0)
}

/** The written pass rule, the same as public.gate_suggestion() in the migration. */
export function gateSuggestion(s: GateScores, hardStops: string[]): GateDecision {
  const total = gateTotal(s)
  if (hardStops.length > 0) return 'no_walk'
  if (s.numbers_close === 0) return 'no_walk'
  if (
    s.decision_makers === 2 &&
    s.numbers_close >= 1 &&
    (s.flexibility >= 1 || s.numbers_close === 2) &&
    (total >= 9 || (s.numbers_close === 2 && total >= 7))
  )
    return 'walk'
  if (total >= 7) return 'one_more_call'
  return 'no_walk'
}

/** After a "don't walk": follow up if there is any reason, else dead. */
export function noWalkRoute(s: GateScores): LeadStage {
  return s.reason_and_clock >= 1 ? 'follow_up' : 'dead'
}

export const MILESTONES: { id: MilestoneKind; label: string; hint: string }[] = [
  { id: 'connect', label: 'Reached a person', hint: 'Anyone answered or replied' },
  { id: 'contact', label: 'Confirmed owner', hint: 'The owner, or someone with authority' },
  { id: 'lead', label: 'Would sell, gave a reason', hint: 'Would consider selling and said why' },
  { id: 'handoff', label: 'Call booked for Colin', hint: 'Must-know facts captured and a call time set' },
  { id: 'handoff_held', label: 'Booked call happened', hint: 'Connected at the booked time' },
  { id: 'qualifying_call', label: 'Qualifying call done', hint: "Colin's call completed" },
  { id: 'walk', label: 'Walked the property', hint: 'Walkthrough done' },
]

// Follow-up kinds from qualification.yaml (followups) plus everyday ones.
export const TASK_KINDS: { id: string; label: string }[] = [
  { id: 'call', label: 'Call' },
  { id: 'text', label: 'Text (inside their thread only)' },
  { id: 'confirm_walk', label: 'Confirm walk' },
  { id: 'offer_thinking', label: 'Offer: thinking it over' },
  { id: 'missed_callback', label: 'Missed callback' },
  { id: 'talk_to_spouse', label: 'Talk to spouse' },
  { id: 'family_call', label: 'Family call' },
  { id: 'not_now_with_date', label: 'Not now, with a date' },
  { id: 'not_now_no_date', label: 'Not now, no date' },
  { id: 'listed', label: 'Listed: check after expiry' },
  { id: 'other_buyer', label: 'Other buyer: backup check' },
  { id: 'too_high_with_reason', label: 'Too high, with a reason' },
  { id: 'estate_letters_pending', label: 'Estate: letters pending' },
  { id: 'hold_lane_not_now', label: 'Hold lane: not now' },
  { id: 'under_contract', label: 'Under contract check-in' },
  { id: 'other', label: 'Other' },
]

export const TASK_KIND_LABEL: Record<string, string> = Object.fromEntries(TASK_KINDS.map((k) => [k.id, k.label]))

export const DEAL_STATUS_LABEL = { offer: 'Offer made', contract: 'Under contract', closed: 'Closed', dead: 'Dead' }

/** Who can own a task. Adil works the tasks and bookings (Colin 2026-10-21). */
export const PEOPLE: { id: 'colin' | 'adil' | 'thalia'; label: string }[] = [
  { id: 'adil', label: 'Adil' },
  { id: 'colin', label: 'Colin' },
  { id: 'thalia', label: 'Thalia' },
]
export function personLabel(p: string | null | undefined): string {
  return PEOPLE.find((x) => x.id === p)?.label ?? (p || '')
}

/** Work the reply agent hands to a person (supabase/functions/_shared/needsWork.ts). */
export const REPLY_TASK_LABEL: Record<string, string> = {
  email: 'Email',
  send_docs: 'Send something',
  records: 'Records / proof',
  contact_other: 'Contact someone else',
  appointment: 'Set up a visit',
}

/** Email templates for a tap-sent email (never AI-sent). {first} {address} are filled in. */
export const EMAIL_TEMPLATES: { id: string; label: string; subject: string; body: string }[] = [
  { id: 'info', label: 'The info you asked for', subject: 'About {address}',
    body: 'Hi {first},\n\nThanks for getting back to me about {address}. \n\nAny questions, just reply here or text me at (262) 999-6513.\n\nColin Merrill' },
  { id: 'photos', label: 'Photos or paperwork', subject: 'Photos for {address}',
    body: 'Hi {first},\n\nThanks for offering to send photos of {address}. You can reply to this email with them, or text them to (262) 999-6513.\n\nColin Merrill' },
  { id: 'followup', label: 'Following up', subject: 'Following up on {address}',
    body: 'Hi {first},\n\nFollowing up on our conversation about {address}. \n\nColin Merrill\n(262) 999-6513' },
]

/** The facts the reply agent pulls from a text thread, in the order Colin reads them. */
export const SELLER_FACTS: { id: string; label: string }[] = [
  { id: 'motivation', label: 'Reason' },
  { id: 'timeline', label: 'Clock' },
  { id: 'decision_makers', label: 'Who signs' },
  { id: 'price_expectation', label: 'Their number' },
  { id: 'price_confirmed', label: 'Number confirmed' },
  { id: 'flexibility', label: 'Willing to move?' },
  { id: 'condition', label: 'Condition' },
  { id: 'occupancy', label: 'Who lives there' },
  { id: 'known_debt', label: 'Debt' },
  { id: 'terms', label: 'Besides price' },
  { id: 'interest', label: 'Interest' },
  { id: 'callback_slot', label: 'Call time' },
  { id: 'best_number', label: 'Better number' },
  { id: 'handoff_flag', label: 'Flag' },
  { id: 'signed_with_other', label: 'Signed with someone' },
  { id: 'thinking_over', label: 'Thinking over' },
  { id: 'buyer_check', label: 'Asked who is buying' },
  { id: 'other_property', label: 'Other property' },
  { id: 'quotes', label: 'In their words' },
]
