// My cards (migration 0166; Colin 2026-11-03: "adil and thalia need to see their full crm pipeline and all of their
// leads", "a simple way to organize their stuff and have their piles of leads that need to be followed up with after a
// long time"). The database (my_piles) puts each of the caller's cards in one pile; this file carries the pile words.

export type Pile = 'call_now' | 'booked' | 'colin' | 'this_week' | 'later' | 'no_step' | 'tried' | 'closed'

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
}

export const PILES: { id: Pile; title: string; hint: string; open: boolean }[] = [
  { id: 'call_now', title: 'Call today', hint: 'Your calls and callbacks due today or late. Do these first.', open: true },
  { id: 'booked', title: 'Booked', hint: "A call or walk is set, or Colin's offer is out.", open: true },
  { id: 'colin', title: 'Waiting on Colin', hint: 'You sent the package; Colin owes a value or a number.', open: true },
  { id: 'this_week', title: 'This week', hint: 'Your next call on these is in the next 7 days.', open: true },
  { id: 'no_step', title: 'Talked, nothing scheduled', hint: 'You reached them but nothing is set. Give each one a next step.', open: true },
  { id: 'later', title: 'Follow up later', hint: 'Not now, waiting on family or an estate, or a call more than a week out. Soonest first.', open: false },
  { id: 'tried', title: 'Tried, never reached', hint: 'Dialed but no one answered yet, and nothing is scheduled.', open: false },
  { id: 'closed', title: 'Closed', hint: 'Dead, do not contact, or done.', open: false },
]

export function groupPiles(cards: PileCard[], search = ''): Record<Pile, PileCard[]> {
  const out = Object.fromEntries(PILES.map((p) => [p.id, [] as PileCard[]])) as Record<Pile, PileCard[]>
  const q = search.trim().toLowerCase()
  for (const c of cards) {
    if (q && !`${c.owner_name ?? ''} ${c.address ?? ''} ${c.municipality ?? ''}`.toLowerCase().includes(q)) continue
    ;(out[c.pile] ?? out.no_step).push(c)
  }
  return out
}
