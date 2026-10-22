// The booking decision. The card makes it from the call's tapped answers and what the seller already said
// by text, in Rick's terms (WPIE docs/RICK_PLAYBOOK.md) as Thalia's guide section 7 states them, so the
// caller never has to judge whether a visit is earned (Colin 2026-10-22: "in our property card and in
// Thalia's guide we must must must have those things make the decision for us if we go for the
// appointment"). Four answers:
//   book       every pillar is in: a reason with a date or event behind it, every signer lined up, a number
//              on the table they'd hear under (or one resting on a real need), who lives there and what's
//              wrong in their words, and no stop
//   call_back  one piece is missing that another call can get: a signer not reached, a reason with no
//              date, no number after two asks, wants to think, the family or the estate's signer not on yet
//   no         a hard stop or a dead pillar: only "the right price", a market number held firm, not the
//              owner, listed or signed elsewhere, a sale inside 14 days, asked to be removed
//   open       a question still to ask before the card can say
// Colin's own number never enters this: whether their number is close enough stays his call, and only
// once the visit is earned.
import { answerOf, stopsFromCall, type CallFacts, type CallValue } from './callGate'
import { callScript } from './callScript'

export type Verdict = 'book' | 'call_back' | 'no' | 'open'
export type BookingVerdict = {
  verdict: Verdict
  headline: string
  because: string[]   // what settled it: the pillars in (book), what's missing (call_back) or wrong (no)
  still: string[]     // what the call still has to ask (open), in the script's words
  next: string        // what to do now
}

export const VERDICT_HEADLINE: Record<Verdict, string> = {
  book: 'Book the visit', call_back: 'One more call first', no: "Don't book", open: 'Not decided yet',
}

const STOP_WHY: Record<string, string> = {
  listed_active: 'Listed, or signed with another buyer',
  sheriff_inside_14_days: "A sale date inside 14 days: there isn't time for a sale to help",
  dnc_or_no_contact: 'Asked to be removed',
}

const LABEL: Record<string, string> = Object.fromEntries(callScript().flatMap((q) => (q.choices ?? []).map((c) => [c.id, c.label])))
const said = (reply: Record<string, unknown> | null | undefined, k: string) => {
  const v = reply?.[k]
  return typeof v === 'string' && v.trim() && v !== 'null' ? v.trim() : null
}
const has = (v: CallValue | null, ids: string[]) => !!v?.choices?.some((c) => ids.includes(c))
const text = (v: CallValue | null) => v?.text?.trim() || ''
const picked = (v: CallValue | null) => (v?.choices ?? []).map((c) => LABEL[c] ?? c).join(', ')

export function bookingVerdict(facts: CallFacts | null | undefined, reply?: Record<string, unknown> | null, lead?: { stage?: string } | null): BookingVerdict {
  const no: string[] = []
  const back: string[] = []
  const still: string[] = []
  const ok: string[] = []

  // Stops first: Rick disqualifies before he qualifies.
  if (lead?.stage === 'dnc') no.push('Asked to be removed (every phone blocked)')
  for (const s of stopsFromCall(facts)) if (!no.includes(STOP_WHY[s] ?? s)) no.push(STOP_WHY[s] ?? s)
  const identity = answerOf(facts, 'identity')
  if (has(identity, ['tenant'])) no.push("They're the tenant, not the owner")
  if (has(identity, ['wholesaler'])) no.push("They're a wholesaler, not the owner")
  if (has(identity, ['manager'])) back.push('The owner, not the manager, has to be on the call')

  // 1. A reason, and a date or event behind it.
  const motivation = answerOf(facts, 'motivation')
  const reasonSaid = said(reply, 'motivation')
  if (motivation || reasonSaid) {
    const realReason = motivation ? (text(motivation) || motivation.choices?.some((c) => c !== 'just_price')) : true
    if (!realReason) no.push('No reason to sell beyond "the right price"')
    else ok.push(`A reason: ${motivation ? (picked(motivation) || text(motivation)) : reasonSaid}`)
  } else still.push("why they're selling")
  const timeline = answerOf(facts, 'timeline')
  const clockSaid = said(reply, 'timeline')
  if (timeline || clockSaid) {
    if (timeline && has(timeline, ['no_plan']) && !text(timeline)) back.push('A reason, but no date or event behind it yet')
    else ok.push(`A clock: ${timeline ? (picked(timeline) || text(timeline)) : clockSaid}`)
  } else still.push("where they're headed, and when")

  // 2. Every signer named and lined up.
  const dm = answerOf(facts, 'decision_makers')
  const dmSaid = said(reply, 'decision_makers')
  const ready = answerOf(facts, 'ready') ?? answerOf(facts, 'all_at_walk')
  const others = dm ? !!dm.choices?.some((c) => c !== 'only_them') : !!dmSaid
  const signer = text(dm) || (dm ? picked(dm) : dmSaid) || 'the other signer'
  const family = has(motivation, ['health']) && others
  if (has(ready, ['think'])) back.push('Wants to think it over')
  else if (!dm && !dmSaid) still.push('who else would weigh in')
  else if (has(ready, ['yes'])) ok.push(others ? `Every signer lined up: ${signer}` : 'Just them to sign')
  else if (!others && !has(ready, ['spouse'])) ok.push('Just them to sign')
  else if (family) back.push(`Health or age: ${signer} on the line before any visit`)
  else if (has(dm, ['estate'])) back.push('Whoever signs for the estate, court papers in hand, has to be on the call')
  else if (has(dm, ['company'])) back.push('Whoever signs for the company has to be on the call')
  else if (ready) back.push(`${signer} has to be on the next call or at the visit`)
  else still.push('whether every signer can be at the visit')

  // 3. A number on the table that they'd hear under, or one resting on a real need.
  const price = answerOf(facts, 'price')
  const anchor = answerOf(facts, 'anchor')
  const flex = answerOf(facts, 'flexibility')
  const number = price?.number?.trim() || said(reply, 'price_confirmed') || said(reply, 'price_expectation')
  if (number) {
    const need = has(anchor, ['own_need', 'paid', 'next_place'])
    const market = has(anchor, ['online', 'bank', 'listing', 'neighbor', 'offers'])
    if (has(flex, ['moved', 'open', 'depends', 'terms'])) ok.push('A number on the table, and open to hearing one under it')
    else if (has(flex, ['firm'])) {
      if (need) ok.push('Firm, but the number rests on a real need')
      else if (market) no.push("A market number they won't hear under")
      else still.push('where their number came from')
    } else if (need) ok.push('Their number rests on a real need')
    else still.push("whether they'd hear a number under theirs")
  } else if (has(price, ['refused'])) back.push('No number after two asks')
  else still.push('their number')

  // 4. Who lives there and what's wrong, in their words.
  const occ = answerOf(facts, 'occupancy') || said(reply, 'occupancy')
  const cond = answerOf(facts, 'condition') || answerOf(facts, 'work_list') || answerOf(facts, 'happened') || said(reply, 'condition')
  if (occ && cond) ok.push("Who lives there and what's wrong, in their words")
  else {
    if (!occ) still.push('who lives there')
    if (!cond) still.push('the condition, in their words')
  }

  if (no.length) {
    const dnc = no.some((w) => /removed/.test(w))
    return { verdict: 'no', headline: VERDICT_HEADLINE.no, because: no, still: [],
      next: dnc ? 'Nothing more. Save the call as Do not contact.'
        : "Use the not-ready close, then log it: Not now with a date if there's a reason, Not interested if there isn't." }
  }
  if (still.length) return { verdict: 'open', headline: VERDICT_HEADLINE.open, because: back, still, next: `Still to ask: ${still.join('; ')}.` }
  if (back.length) return { verdict: 'call_back', headline: VERDICT_HEADLINE.call_back, because: back, still: [],
    next: 'Book a call back inside two days for that one thing. No visit yet.' }
  return { verdict: 'book', headline: VERDICT_HEADLINE.book, because: ok, still: [],
    next: '"When\'s a good time for us to come by and see it?" Inside 48 hours, then set the Walk-through below.' }
}
