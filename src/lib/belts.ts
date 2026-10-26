// The conveyor's vocabulary for the pages (migrations 0029-0032). The belts, their labels and ladders live in
// the database (belt_rules, belt_steps); this file carries the words the pages show and the outcome buttons.
import { fmtDateTime } from './format'

export type Belt =
  | 'cold_texts' | 'replied_quiet' | 'questions_quiet' | 'yes_unbooked' | 'call_booked' | 'call_missed' | 'visit_booked'
  | 'visit_missed' | 'after_call_quiet' | 'after_visit_quiet' | 'offer_out' | 'not_now_dated' | 'not_now_condition'
  | 'needs_family' | 'elderly' | 'estate_waiting' | 'hold_not_now' | 'too_high_or_listed' | 'dormant' | 'dead' | 'dnc'
export type StopWho = 'auto_text' | 'draft_text' | 'thalia_call' | 'colin_call' | 'colin_visit'

export const BELT_LABEL: Record<Belt, string> = {
  cold_texts: 'Cold texts', replied_quiet: 'Replied, went quiet', questions_quiet: 'Mid-questions, quiet', yes_unbooked: 'Said yes, not booked',
  call_booked: 'Call booked', call_missed: 'Call missed', visit_booked: 'Visit booked', visit_missed: 'Visit missed',
  after_call_quiet: 'After the call, no next step', after_visit_quiet: 'After the visit, quiet', offer_out: 'Offer out',
  not_now_dated: 'Not now, with a date', not_now_condition: 'Not now, with a condition', needs_family: 'Needs spouse or family',
  elderly: 'Elderly, ill or grieving', estate_waiting: 'Estate, waiting on papers', hold_not_now: 'Hold lane, not now',
  too_high_or_listed: 'Too high or listed', dormant: 'Dormant', dead: 'Dead', dnc: 'Do not contact',
}
export const BELTS = Object.keys(BELT_LABEL) as Belt[]
/** Belts that rest by design (no next stop is not debt). */
export const RESTING_BELTS: Belt[] = ['too_high_or_listed', 'dead', 'dnc']

export const WHO_LABEL: Record<StopWho, string> = {
  auto_text: 'a text goes on its own', draft_text: 'a draft for Colin\'s tap', thalia_call: 'Thalia or Adil calls', colin_call: 'Colin calls', colin_visit: 'Colin visits',
}

/** The one line under the card's header: belt, stop, who and when, and what to say. */
export function beltLine(l: { belt: string | null; belt_step: number; next_stop_who: string | null; next_stop_at: string | null; next_stop_say: string | null }, maxStep?: number | null): string {
  if (!l.belt) return 'Not on a belt yet'
  const label = BELT_LABEL[l.belt as Belt] ?? l.belt
  const parts = [`On belt: ${label}`]
  if (l.belt_step > 0 && maxStep) parts.push(`stop ${l.belt_step} of ${maxStep}`)
  if (l.next_stop_who && l.next_stop_at) {
    const who = WHO_LABEL[l.next_stop_who as StopWho] ?? l.next_stop_who
    parts.push(`next: ${who.charAt(0).toUpperCase() + who.slice(1)} ${fmtDateTime(l.next_stop_at)}`)
  } else if (l.belt === 'cold_texts') parts.push('next: WPIE\'s texts')
  else parts.push(RESTING_BELTS.includes(l.belt as Belt) || l.belt === 'dormant' ? 'resting: no next stop' : 'NO NEXT STOP')
  if (l.next_stop_say) parts.push(`say: "${l.next_stop_say}"`)
  return parts.join(' · ')
}

/** Today's outcome buttons on a stop. `needs` asks for one more thing before it is logged. */
export const STOP_OUTCOMES: { id: string; label: string; hint: string; needs?: 'slot' | 'date'; tone?: 'bad' }[] = [
  { id: 'reached', label: 'Reached', hint: 'Talked to them; the card plants the next call in 3 days unless you book below' },
  { id: 'no_answer', label: 'No answer', hint: 'Rang out; the next stop on the ladder follows' },
  { id: 'voicemail', label: 'Voicemail', hint: 'Left your name and the street; counts as unanswered' },
  { id: 'booked', label: 'Booked', hint: 'A call back or a visit: pick the day and time', needs: 'slot' },
  { id: 'not_now', label: 'Not now', hint: 'With a date if they gave one, else the thing that has to change', needs: 'date' },
  { id: 'no', label: 'No', hint: 'A clear no: dead, nothing more', tone: 'bad' },
  { id: 'wrong_number', label: 'Wrong number', hint: 'That phone was never them; WPIE re-plans', tone: 'bad' },
  { id: 'dnc', label: 'Do not contact', hint: 'Every phone blocked, like a texted STOP', tone: 'bad' },
]

/** The booking verdict's "don't book" reasons, as the card routes them. */
export const VERDICT_NO_REASONS: { id: string; label: string; belt: Belt }[] = [
  { id: 'just_price', label: 'Nothing beyond the right price', belt: 'dead' },
  { id: 'market_firm', label: 'A market number they will not hear under', belt: 'too_high_or_listed' },
  { id: 'listed', label: 'Listed with an agent', belt: 'too_high_or_listed' },
  { id: 'signed_other', label: 'Signed with another buyer', belt: 'too_high_or_listed' },
  { id: 'tenant', label: 'A tenant, not the owner', belt: 'dead' },
  { id: 'wholesaler', label: 'A wholesaler on the line', belt: 'dead' },
  { id: 'sheriff_14', label: 'A sale date inside 14 days', belt: 'dead' },
  { id: 'elderly_no_family', label: 'Older or ill, family not on the line', belt: 'elderly' },
  { id: 'estate_no_signer', label: 'Estate, no signer with papers yet', belt: 'estate_waiting' },
  { id: 'spouse', label: 'A signer not on board yet', belt: 'needs_family' },
  { id: 'dnc', label: 'Asked to be removed', belt: 'dnc' },
]

export function verdictReasonFor(because: string[]): string {
  const text = because.join(' ').toLowerCase()
  if (/removed/.test(text)) return 'dnc'
  if (/listed/.test(text) && /signed/.test(text)) return 'listed'
  if (/listed/.test(text)) return 'listed'
  if (/inside 14 days/.test(text)) return 'sheriff_14'
  if (/tenant/.test(text)) return 'tenant'
  if (/wholesaler/.test(text)) return 'wholesaler'
  if (/market number/.test(text)) return 'market_firm'
  if (/right price/.test(text)) return 'just_price'
  return 'just_price'
}
