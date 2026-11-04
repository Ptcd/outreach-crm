// The Next step control's presets (0170; Colin 2026-11-03: callers manage their own follow-ups). Pure: no browser,
// no network, so the presets are testable. Times are Milwaukee wall-clock, turned into instants by the caller.

export type Preset = { id: string; label: string; at: (now: Date) => Date }

/** 10 AM Central on a day, or the next weekday morning when that day is a Sunday (nobody calls on Sunday). */
export function morningOf(day: Date): Date {
  const d = new Date(day)
  d.setHours(10, 0, 0, 0)
  if (d.getDay() === 0) d.setDate(d.getDate() + 1)
  return d
}

const plusDays = (now: Date, n: number) => { const d = new Date(now); d.setDate(d.getDate() + n); return morningOf(d) }

export const PRESETS: Preset[] = [
  { id: 'later_today', label: 'Later today', at: (now) => { const d = new Date(now); d.setHours(d.getHours() + 3, 0, 0, 0); return d } },
  { id: 'tomorrow', label: 'Tomorrow', at: (now) => plusDays(now, 1) },
  { id: 'in_3_days', label: 'In 3 days', at: (now) => plusDays(now, 3) },
  { id: 'next_week', label: 'Next week', at: (now) => plusDays(now, 7) },
  { id: 'in_2_weeks', label: 'In 2 weeks', at: (now) => plusDays(now, 14) },
  { id: 'next_month', label: 'Next month', at: (now) => { const d = new Date(now); d.setMonth(d.getMonth() + 1); return morningOf(d) } },
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
