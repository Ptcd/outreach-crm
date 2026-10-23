// Scores the reply library (WPIE tests/fixtures/reply_library.jsonl, exported as replyLibrary.generated.json):
// ~1,000 everyday seller replies, each labelled with what should happen (Colin 2026-10-23, after a "Yes ... not ready
// to think about selling, but I'll keep you in mind" fired a hot alert: "make a wide variety of other stuff like this
// like 1000 other possible common responses and how to treat them"). Each reply goes through the same decide() and
// isHotReply() the live reply agent runs, without Claude: this measures the word rules on their own.
import { decide } from '../supabase/functions/_shared/replyBrain'
import { isHotReply } from '../supabase/functions/_shared/hotLeads'
import { reactionKind, reactionMeaning, reactionTail } from '../supabase/functions/_shared/replyGuard'

export type LibraryRow = { id: string; text: string; after: 'opener' | 'pitch'; treat: string; hot: boolean; why?: string
  known_miss?: string[] }

export const OPENER = 'Hi Linda, this is Colin Merrill. Is 2847 N Burleigh St still yours? Reply STOP to opt out.'
export const PITCH = 'Thanks for getting back to me. I buy a few houses a year around here myself, as-is and on your timeline. Would you ever consider selling that one? No pressure either way.'

/** The rule intents that count as each treatment (the label says what should happen; several intents do it). */
export const TREAT_INTENTS: Record<string, string[]> = {
  stop: ['opt_out', 'hostile'],
  wrong_number: ['wrong_number'],
  owns_only: ['interested', 'statement'],
  interested: ['interested', 'statement', 'think_it_over', 'wants_call', 'other_property', 'price_first', 'worth', 'terms'],
  price: ['price_first', 'number_only', 'worth', 'terms', 'firm', 'other_buyer'],
  wants_call: ['wants_call', 'busy', 'interested'],
  not_now: ['not_now', 'think_it_over'],
  no: ['not_interested', 'my_home', 'joke_number', 'burned', 'annoyed'],
  sold: ['sold'],
  listed: ['listed', 'signed_other'],
  who: ['who_is_this', 'bot_question', 'buyer_check', 'middleman', 'reaction'],   // a 'Questioned' reaction goes to Colin to read
  family: ['relative', 'estate', 'elderly'],
  tenant: ['tenant', 'manager'],
  distress: ['foreclosure'],
  other_property: ['other_property'],
  busy: ['busy', 'prefer_text'],
  chit_chat: ['statement', 'interested', 'reaction'],
}

const COLD = new Set(['opt_out', 'hostile', 'wrong_number', 'sold', 'not_interested', 'my_home', 'listed', 'signed_other', 'tenant',
  'manager', 'middleman', 'burned', 'bot_question', 'annoyed', 'not_now', 'joke_number', 'think_it_over'])

export type Miss = 'stop' | 'false_stop' | 'hot' | 'not_hot' | 'treat'
export type Scored = { row: LibraryRow; intent: string; removal: boolean; hot: boolean; later: boolean; misses: Miss[] }

export function scoreRow(row: LibraryRow): Scored {
  const afterPitch = row.after === 'pitch'
  const d = decide({ inbound: row.text, priorInbound: [], lastAgentText: afterPitch ? PITCH : OPENER,
    propertyAddress: '2847 N BURLEIGH ST', ownerName: 'LINDA M SAMPLE', ourTurns: afterPitch ? 1 : 0 })
  const react = reactionKind(row.text)
  const meaning = reactionTail(row.text) || ((react ? reactionMeaning(react) : null) ?? row.text)
  const hot = isHotReply({ intent: d.intent, text: meaning, removal: d.removal, afterPitch })
  // A conditional no with a real condition is a not now (decide's nurture: a check-in in 30 days).
  const later = d.facts?.nurture === true
  const misses: Miss[] = []
  if (row.treat === 'stop' && !d.removal) misses.push('stop')
  if (row.treat !== 'stop' && d.removal) misses.push('false_stop')
  if (row.hot && !hot) misses.push('not_hot')
  if (!row.hot && hot) misses.push('hot')
  // A hot reply only has to stay off the dead and removal paths; the hot check above is what matters for it.
  const ok = row.hot ? !COLD.has(d.intent) : (TREAT_INTENTS[row.treat] ?? []).includes(d.intent) || (row.treat === 'not_now' && later)
  if (!ok && row.treat !== 'stop') misses.push('treat')
  return { row, intent: d.intent, removal: d.removal, hot, later, misses }
}
