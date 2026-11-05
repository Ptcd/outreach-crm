// The Next step control's presets (0170; Colin 2026-11-03: callers manage their own follow-ups). Pure: no browser,
// no network, so the presets are testable. Times are Milwaukee wall-clock, turned into instants by the caller.
// 2026-11-04 (Thalia and Adil's walkthrough; Colin: "build the full shit so the system isnt stupid anymore"): the
// presets reach past a month ("call me in spring" was five taps), one "not now" shape serves the close, a stop and the
// Next step control alike, the call lanes are a choice at the close, and a card can rest with a wake date.

export type Preset = { id: string; label: string; at: (now: Date) => Date; far?: boolean }

/** 10 AM Central on a day, or the next weekday morning when that day is a Sunday (nobody calls on Sunday). */
export function morningOf(day: Date): Date {
  const d = new Date(day)
  d.setHours(10, 0, 0, 0)
  if (d.getDay() === 0) d.setDate(d.getDate() + 1)
  return d
}

const plusDays = (now: Date, n: number) => { const d = new Date(now); d.setDate(d.getDate() + n); return morningOf(d) }
const plusMonths = (now: Date, n: number) => { const d = new Date(now); d.setMonth(d.getMonth() + n); return morningOf(d) }

/** The next time a month/day comes round (today counts as past: "spring" on Mar 15 means next year's). */
export function nextOf(now: Date, month: number, day: number): Date {
  const d = new Date(now.getFullYear(), month - 1, day)
  if (d.getTime() <= new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime()) d.setFullYear(d.getFullYear() + 1)
  return morningOf(d)
}

/** "The day after [the event]": a date they named (YYYY-MM-DD), plus one day, at the usual morning hour. */
export function dayAfter(ymd: string): Date | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(ymd)
  if (!m) return null
  return morningOf(new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]) + 1))
}

export const PRESETS: Preset[] = [
  { id: 'later_today', label: 'Later today', at: (now) => { const d = new Date(now); d.setHours(d.getHours() + 3, 0, 0, 0); return d } },
  { id: 'tomorrow', label: 'Tomorrow', at: (now) => plusDays(now, 1) },
  { id: 'in_3_days', label: 'In 3 days', at: (now) => plusDays(now, 3) },
  { id: 'next_week', label: 'Next week', at: (now) => plusDays(now, 7) },
  { id: 'in_2_weeks', label: 'In 2 weeks', at: (now) => plusDays(now, 14) },
  { id: 'next_month', label: 'Next month', at: (now) => plusMonths(now, 1) },
  // the long ones: a seller worked over months (Thalia 2026-11-04: "call me in spring" took five taps)
  { id: 'in_3_months', label: 'In 3 months', at: (now) => plusMonths(now, 3), far: true },
  { id: 'in_6_months', label: 'In 6 months', at: (now) => plusMonths(now, 6), far: true },
  { id: 'spring', label: 'Spring (Mar 15)', at: (now) => nextOf(now, 3, 15), far: true },
  { id: 'after_holidays', label: 'After the holidays (Jan 8)', at: (now) => nextOf(now, 1, 8), far: true },
  { id: 'after_tax_bill', label: 'After the tax bill (Jan 5)', at: (now) => nextOf(now, 1, 5), far: true },
  { id: 'in_a_year', label: 'In a year', at: (now) => plusMonths(now, 12), far: true },
]

/** Resting a card (0186 card_rest): quiet until a day, awake sooner on a text, a call or a new record. */
export const REST_PRESETS: Preset[] = [
  { id: 'rest_1_month', label: '1 month', at: (now) => plusMonths(now, 1) },
  { id: 'rest_3_months', label: '3 months', at: (now) => plusMonths(now, 3) },
  { id: 'rest_6_months', label: '6 months', at: (now) => plusMonths(now, 6) },
  { id: 'rest_spring', label: 'Spring (Mar 15)', at: (now) => nextOf(now, 3, 15) },
  { id: 'rest_after_holidays', label: 'After the holidays (Jan 8)', at: (now) => nextOf(now, 1, 8) },
]

/** The one "not now" shape, everywhere a caller logs one (the close, a belt stop, the Next step control; 0178):
 *  a date they gave is the caller's call; an event with no date, or nothing to go on, is the machine's. */
export type NotNowKind = 'date' | 'condition' | 'nothing'
export const NOT_NOW_KINDS: { id: NotNowKind; label: string; hint: string }[] = [
  { id: 'date', label: 'A specific date', hint: 'The call on that date is yours; one more a week after.' },
  { id: 'condition', label: 'An event, no date', hint: 'Write what has to change. A text names it at 30 days, your call at 90, a text at 180; then quarterly, and a "still yours?" call about a year on.' },
  { id: 'nothing', label: 'Nothing to go on', hint: 'Just curious, or only the right price. No check-back of yours: texts at 30, 90 and 180 days, then quarterly; it comes back to you on a reply or a new record.' },
]

/** The call lanes (docs/pdf "Seller call flow - four steps, three lanes", Colin 2026-11-04): the caller's choice at the
 *  close, saved on the card as call_facts.lane. Lane 1 always allows booking the walk; the card's verdict is advice. */
export type CallLane = '1' | '2' | '3' | 'never'
export const CALL_LANES: { id: CallLane; label: string; hint: string }[] = [
  { id: '1', label: "Lane 1: book Colin's walk", hint: 'Any one of: empty and costing them, a date they must be out by, a hardship with a house to match, or they want the number in person. Book it on this call.' },
  { id: '2', label: "Lane 2: Colin's number through me", hint: 'Interested, not there yet. Send the package; Colin sets a ceiling and you call back with it ("he\'d have to be under X"), never an offer.' },
  { id: '3', label: 'Lane 3: not now', hint: 'A date, an event, or nothing to go on. Log it as Not now; the machine keeps the door open.' },
  { id: 'never', label: 'Never', hint: 'A clear no, not the owner, or asked to be removed: Not interested or Do not contact.' },
]

/** What "Done" means for each kind of follow-up: a belt stop needs an outcome, a callback is just done. */
export const DONE_OUTCOMES: { id: string; label: string }[] = [
  { id: 'reached', label: 'Reached them' },
  { id: 'no_answer', label: 'No answer' },
  { id: 'voicemail', label: 'Left a voicemail' },
  { id: 'done', label: 'Done' },
]

export const isBeltTask = (source: string | null | undefined) => ['belt', 'call_list', 'after_stop'].includes(source ?? '')
export const canDelete = (t: { source?: string | null; kind: string }) => !isBeltTask(t.source) && t.kind !== 'callback'
