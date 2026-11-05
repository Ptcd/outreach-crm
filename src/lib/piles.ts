// My cards (migration 0166; Colin 2026-11-03: "adil and thalia need to see their full crm pipeline and all of their
// leads", "a simple way to organize their stuff and have their piles of leads that need to be followed up with after a
// long time"). The database (my_piles) puts each of the caller's cards in one pile; this file carries the pile words.
// 0186 (Colin 2026-11-04: "build the full shit so the system isnt stupid anymore"): every row says why (the reasons,
// their last words, what the caller promised, what to say next), a Resting pile for cards the caller rested, and a
// search that finds a card by phone or by the words they said.

export type Pile = 'call_now' | 'booked' | 'colin' | 'this_week' | 'later' | 'no_step' | 'tried' | 'not_called' | 'resting' | 'closed'

export interface PileCard {
  lead_id: string
  owner_name: string | null
  address: string | null
  municipality: string | null
  county: string | null
  stage: string
  belt: string | null
  pile: Pile
  next_at: string | null
  next_what: string | null
  last_call_at: string | null
  last_call: string | null
  why: string | null
  locked_to: string | null
  tier: string | null
  task_id: string | null
  task_kind: string | null
  task_source: string | null
  walk_at?: string | null
  named_event?: string | null
  hot_at?: string | null
  // 0186
  lane?: string | null            // the buy-box lane (flip / hold), not the call lane
  say_next?: string | null        // "when you call back, say"
  reasons?: string[] | null       // reasons to sell, from the records
  phones?: string | null          // every phone on the card, space-joined 10-digit, for search
  touches?: number | null         // calls and texts so far
  last_words?: string | null      // their last text
  promise?: string | null         // the caller's open follow-up note
  nudge?: string | null           // an open heads-up for me on this card
  rest_until?: string | null      // rested by the caller until this day (null when awake)
  rest_why?: string | null
  next_plain?: string | null      // what happens next and when, in words
}

export const PILES: { id: Pile; title: string; hint: string; open: boolean }[] = [
  { id: 'call_now', title: 'Call today', hint: 'Your calls and callbacks due today or late. Do these first.', open: true },
  { id: 'booked', title: 'Booked and hot', hint: "Walks and calls on the books, Colin's offers out, and hot replies of the last two weeks. Move a walk, flag a waver, or take it off to a check-back right here.", open: true },
  { id: 'colin', title: 'Waiting on Colin', hint: 'You sent the package; Colin owes a value or a number.', open: true },
  { id: 'this_week', title: 'This week', hint: 'Your next call on these is in the next 7 days.', open: true },
  { id: 'no_step', title: 'Talked, nothing scheduled', hint: 'You reached them but nothing is set. Give each one a next step.', open: true },
  { id: 'later', title: 'Follow up later', hint: 'Not now, waiting on family or an estate, or a call more than a week out. Soonest first.', open: false },
  { id: 'tried', title: 'Tried, never reached', hint: 'Dialed but no one answered yet, and nothing is scheduled.', open: false },
  { id: 'not_called', title: 'Not called yet', hint: 'Your cards nobody has dialed. The texts are working them; the best motivation is on top.', open: false },
  { id: 'resting', title: 'Resting', hint: 'Quiet until the day you set. A text from them, a call from them or a new record on the house wakes it sooner.', open: false },
  { id: 'closed', title: 'Closed', hint: 'Dead, do not contact, or done.', open: false },
]

/** How long ago the caller last talked to them (last_call_at), as a chip. */
export type TalkedWindow = '2w' | '6w' | '3m' | null
export const TALKED_CHIPS: { id: Exclude<TalkedWindow, null>; label: string; days: number }[] = [
  { id: '2w', label: 'Talked to in the last 2 weeks', days: 14 },
  { id: '6w', label: 'Last 6 weeks', days: 42 },
  { id: '3m', label: 'Last 3 months', days: 91 },
]

export interface PileFilter {
  search?: string
  talked?: TalkedWindow
  lane?: 'flip' | 'hold' | null
}

const digits = (s: string) => s.replace(/\D/g, '')

/** Does one card match the search box and the chips? The search finds a name, an address, a town, a phone (any run
 *  of digits), their last words, what the caller promised, or the say-next line. Pure, so it is testable. */
export function cardMatches(c: PileCard, f: PileFilter, now: Date = new Date()): boolean {
  const q = (f.search ?? '').trim().toLowerCase()
  if (q) {
    const qd = digits(q)
    const byPhone = qd.length >= 3 && qd.length === q.replace(/[\s\-().+]/g, '').length && (c.phones ?? '').includes(qd)
    const hay = [c.owner_name, c.address, c.municipality, c.last_words, c.promise, c.say_next, c.next_what, c.last_call, ...(c.reasons ?? [])]
      .filter((x): x is string => !!x).join(' ').toLowerCase()
    if (!byPhone && !hay.includes(q)) return false
  }
  if (f.lane && (c.lane ?? '') !== f.lane) return false
  if (f.talked) {
    const days = TALKED_CHIPS.find((t) => t.id === f.talked)?.days ?? 0
    if (!c.last_call_at) return false
    if (new Date(c.last_call_at).getTime() < now.getTime() - days * 86400_000) return false
  }
  return true
}

export function groupPiles(cards: PileCard[], filter: string | PileFilter = '', now: Date = new Date()): Record<Pile, PileCard[]> {
  const f: PileFilter = typeof filter === 'string' ? { search: filter } : filter
  const out = Object.fromEntries(PILES.map((p) => [p.id, [] as PileCard[]])) as Record<Pile, PileCard[]>
  for (const c of cards) {
    if (!cardMatches(c, f, now)) continue
    ;(out[c.pile] ?? out.no_step).push(c)
  }
  return out
}

/** The row's second line: why this card, in the caller's words. Pure, shared by My cards and Today. */
export function whyParts(c: PileCard): { label: string; text: string }[] {
  const out: { label: string; text: string }[] = []
  if (c.reasons?.length) out.push({ label: 'Why', text: c.reasons.slice(0, 3).join(', ') })
  if (c.last_words) out.push({ label: 'They said', text: `“${c.last_words.replace(/\s+/g, ' ').trim()}”` })
  if (c.promise) out.push({ label: 'You promised', text: c.promise.replace(/\s+/g, ' ').trim() })
  if (c.say_next) out.push({ label: 'Say', text: c.say_next.replace(/\s+/g, ' ').trim() })
  return out
}
