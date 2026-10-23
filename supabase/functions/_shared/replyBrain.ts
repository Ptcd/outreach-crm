// The reply agent on the server: classify one inbound text and decide whether the system may answer
// it by itself (a routine reply with one of WPIE's fixed lines) or whether Colin must
// approve a drafted reply. Pure functions, no network: tests/reply.test.ts and the
// red-team score below run exactly this code.
//
// Every word list, regex and fixed line comes from WPIE (replyBrain.generated.ts and
// replyRules.generated.ts, written by WPIE tools/export_reply_prompt.py --app-dir).
// The routine set is deliberately narrow; anything else goes to Colin:
//   removal (STOP / plain-language / hostile)  -> the phone is suppressed at once; a
//                                                 confirmation line (none for a bare
//                                                 carrier keyword, Twilio answers those)
//   wrong number, sold, who-is-this (first reply), bot question, not interested
//   (the exit question, then the close line on a second no)
import * as B from './replyBrain.generated.ts'
import { isOptOut } from './sending.ts'
import { reactionKind, reactionMeaning, reactionTail } from './replyGuard.ts'
import type { RegexSpec } from './replyRules.generated.ts'

const re = (spec: RegexSpec, extra = '') => new RegExp(spec.source, spec.flags + extra)
const INTENT_RES = B.INTENTS.map((x) => ({ name: x.name, rx: re(x) }))
const NEGATION_BEFORE = re(B.NEGATION_BEFORE)
const SPANISH_G = re(B.SPANISH, 'g')
const ENGLISH_G = re(B.ENGLISH, 'g')
const SAYS_NO = re(B.SAYS_NO_RE)
const CONDITIONAL = re(B.CONDITIONAL_RE)
// A conditional no whose only condition is price (Colin 2026-10-22, on "If you're looking to overpay ...
// I'm not looking to sell": "I also should not have gotten this email"). Without a number named, it is
// a plain no.
export const PRICE_ONLY_CONDITION = /\b(?:over\s*pay\w*|top\s+dollar|full\s+(?:price|asking|value)|retail|(?:the\s+)?right\s+(?:price|number|money|offer)|pay\s+(?:me\s+)?enough|enough\s+money|(?:crazy|silly|stupid|big)\s+(?:money|offer)|more\s+than\s+(?:it'?s|its)\s+worth|what\s+it'?s\s+worth|market\s+(?:price|value))/i
const NAMES_A_NUMBER = /\$|\d/
/** One question for a real (non-price) condition: what would have to happen, and when (phone script nr1). */
export const NURTURE_LINE = "That's fine, and I'd rather you take your time than feel pushed. What would need to happen for selling to make sense, and roughly when?"
const NOT_ANYMORE = re(B.NOT_ANYMORE_RE)
const AFFIRM = re(B.AFFIRM_RE)
const INTEREST_WORDS = re(B.INTEREST_WORDS_RE)
const NEGATABLE = new Set(B.NEGATABLE)
const CARRIER = new Set(B.CARRIER_KEYWORDS)

/** wpie.reply.rules.fold: accents dropped, case and punctuation kept. */
export function foldKeepCase(text: string): string {
  return (text ?? '').replace(/’/g, "'").normalize('NFKD').replace(/\p{Mn}/gu, '')
}

/** wpie.reply.rules.classify: coarse intent for one inbound line. */
export function classify(text: string): string {
  const raw = (text ?? '').trim()
  const t = reactionTail(raw) || raw      // 'Liked “...” no it isnt mine': the words, never our quoted text
  if (!t) return 'empty'
  if (isOptOut(t)) return 'opt_out'
  const folded = foldKeepCase(t)
  for (const { name, rx } of INTENT_RES) {
    const m = rx.exec(folded)
    if (!m) continue
    if (NEGATABLE.has(name) && NEGATION_BEFORE.test(folded.slice(0, m.index))) continue
    return name
  }
  return 'statement'
}

export function isSpanish(text: string): boolean {
  const t = foldKeepCase(text)
  const es = [...t.matchAll(SPANISH_G)].length
  return es > 0 && es >= [...t.matchAll(ENGLISH_G)].length
}

export function isCarrierKeyword(text: string): boolean {
  return CARRIER.has((text ?? '').toLowerCase().replace(/[^a-z]/g, ''))
}

/** 'W220 N1765 Pewaukee Rd' style street for "on <street>" (brain._street). */
function street(address: string | null | undefined): string {
  const parts = (address ?? '').trim().split(/\s+/).filter(Boolean)
  if (parts.length && /^\d+$/.test(parts[0])) parts.shift()
  return parts.join(' ')
}

export interface ReplyContext {
  inbound: string
  priorInbound: string[]          // their earlier texts in this thread, oldest first
  lastAgentText: string | null    // our most recent text to them (opener or a drafted reply)
  propertyAddress: string | null
  ourTurns?: number               // our replies already sent in this thread (the opener not counted)
  ownerName?: string | null       // for "Hi <first>," on the pitch line
}

export type Kind = 'removal' | 'routine' | 'candidate'
export type Outcome = 'dnc' | 'wrong_number' | 'not_interested' | 'open'

export interface Decision {
  intent: string
  kind: Kind
  removal: boolean                // suppress this phone (and the owner's other phones) now
  reply: string | null            // the fixed line for removal/routine; null = say nothing / Colin drafts
  outcome: Outcome
  note: string
  facts?: Record<string, unknown>  // what this decision learned (e.g. pitched, last_asked)
}

const routine = (intent: string, reply: string, outcome: Outcome, note: string): Decision =>
  ({ intent, kind: 'routine', removal: false, reply, outcome, note })
const toColin = (intent: string, note: string): Decision =>
  ({ intent, kind: 'candidate', removal: false, reply: null, outcome: 'open', note })

/** decideBase, plus Rick's two-tier opener (Colin 2026-10-21: "if we get a text that says yes the
 *  agent can go ahead with the next text without my permission"): a short yes to the question-only
 *  opener, as the first text of a thread matched to a property, is answered with the pitch line on
 *  its own (routine: the switch, the 45-90 s delay and quiet hours apply). Their answer to it, and
 *  anything with selling, interest or price words, stays a draft for Colin. */
export function decide(ctx: ReplyContext): Decision {
  // A phone reaction quotes our own text back (STOP line included): answer what it means, never the
  // quote. 👍 / Liked = yes, 👎 / Disliked = no thanks, anything else is for Colin (WPIE 2026-10-22).
  const tail = reactionTail(ctx.inbound)
  if (tail) ctx = { ...ctx, inbound: tail }
  const react = reactionKind(ctx.inbound)
  if (react === 'neutral') return toColin('reaction', 'phone reaction - Colin reads it')
  if (react) ctx = { ...ctx, inbound: reactionMeaning(react)! }
  const d = decideBase(ctx)
  if (d.kind !== 'candidate' || (d.intent !== 'interested' && d.intent !== 'statement')) return d
  const pitch = pitchReply({ inbound: ctx.inbound, priorInbound: ctx.priorInbound, ourTurns: ctx.ourTurns ?? 0, openerText: ctx.lastAgentText,
    propertyAddress: ctx.propertyAddress, ownerName: ctx.ownerName ?? null })
  if (!pitch) return d
  return { ...routine(d.intent, pitch.reply, 'open', 'yes to the question-only opener - pitch line, one question'), facts: pitch.facts }
}

function decideBase(ctx: ReplyContext): Decision {
  const text = (ctx.inbound ?? '').trim()
  const intent = classify(text)
  const spanish = isSpanish(text)
  const first = ctx.priorInbound.length === 0

  // 1. Removal, always honoured (wpie/sms/webhooks.is_opt_out, the one opt-out list).
  if (intent === 'opt_out') {
    if (isCarrierKeyword(text)) {
      return { intent, kind: 'removal', removal: true, reply: null, outcome: 'dnc', note: 'carrier keyword; Twilio sends the confirmation' }
    }
    return { intent, kind: 'removal', removal: true, reply: spanish ? B.ES_DNC_LINE : B.DNC_LINE, outcome: 'dnc', note: 'removal request' }
  }
  if (intent === 'hostile') {
    return { intent, kind: 'removal', removal: true, reply: spanish ? B.ES_DNC_LINE : B.HOSTILE_LINE, outcome: 'dnc',
      note: 'hostile - removal confirmed, no further contact' }
  }

  // 2. Spanish: only the closing lines are routine; anything else is Colin's.
  if (spanish) {
    if (intent === 'wrong_number') return routine(intent, B.ES_WRONG_LINE, 'wrong_number', 'spanish - wrong number')
    if (intent === 'not_interested' || intent === 'my_home') return routine(intent, B.ES_NO_LINE, 'not_interested', 'spanish - not interested')
    if (intent === 'sold') return routine(intent, B.ES_SOLD_LINE, 'not_interested', 'spanish - already sold')
    return toColin(intent, 'spanish - Colin replies')
  }

  // 3. The routine English cases (wpie.reply.brain.ScriptedGenerator, same lines).
  if (intent === 'wrong_number') return routine(intent, B.WRONG_NUMBER_LINE, 'wrong_number', 'wrong number')
  if (intent === 'sold') {
    if (!first && NOT_ANYMORE.test(text)) return toColin(intent, '"not anymore" answering a question')
    return routine(intent, B.SOLD_LINE, 'not_interested', 'already sold')
  }
  if (intent === 'who_is_this') {
    if (SAYS_NO.test(text)) return routine(intent, B.WHO_NOT_SELLING_LINE, 'not_interested', 'asked who we are and said not selling')
    if (first) {
      const s = street(ctx.propertyAddress)
      return routine(intent, B.WHO_LINE.replace('{where}', s ? ` on ${s}` : ''), 'open', 'identified ourselves')
    }
    return toColin(intent, 'who-is-this mid conversation')
  }
  if (intent === 'bot_question') return routine(intent, B.BOT_LINE, 'open', 'asked if automated - told the truth')
  if (intent === 'not_interested') {
    if (CONDITIONAL.test(text)) {
      // They named their number: a real lead, Colin's call.
      if (NAMES_A_NUMBER.test(text)) return toColin(intent, 'a conditional no that names their number - Colin')
      // Only "if you overpay / top dollar / the right number": a plain no, closed politely, no email.
      if (PRICE_ONLY_CONDITION.test(text)) return routine(intent, B.CLOSE_LINE, 'not_interested', 'a no unless overpaid - closed politely')
      // A real condition (a tenant leaving, the next place, a date, family): one question, check back in 30 days.
      return { ...routine(intent, NURTURE_LINE, 'open', 'a conditional no with a real condition - one question, check back in 30 days'),
        facts: { nurture: true, interest: 'later', condition: text.slice(0, 300) } }
    }
    if (!first && new RegExp(`^(?:${B.BARE_NO_RE.source})$`, B.BARE_NO_RE.flags).test(text)) {
      return toColin(intent, 'a bare "no" mid conversation may answer a question - Colin')
    }
    if (ctx.lastAgentText && ctx.lastAgentText.trim() === B.EXIT_QUESTION) {
      return routine(intent, B.CLOSE_LINE, 'not_interested', 'second no - closed politely')
    }
    return routine(intent, B.EXIT_QUESTION, 'open', 'not interested - the one exit question')
  }
  return toColin(intent, 'a real conversation - drafted for Colin to approve')
}

/** A stable id for the rules this build runs, so the red-team result is tied to them. */
export function rulesVersion(): string {
  const src = JSON.stringify([B.INTENTS, B.NEGATABLE, B.CARRIER_KEYWORDS, B.DNC_LINE, B.HOSTILE_LINE, B.WRONG_NUMBER_LINE,
    B.SOLD_LINE, B.EXIT_QUESTION, B.CLOSE_LINE, B.WHO_LINE, B.WHO_NOT_SELLING_LINE, B.BOT_LINE, B.SAYS_NO_RE,
    B.CONDITIONAL_RE, B.BARE_NO_RE, B.NOT_ANYMORE_RE, decide.toString()])
  let h = 5381
  for (let i = 0; i < src.length; i++) h = ((h * 33) ^ src.charCodeAt(i)) >>> 0
  return `r${h.toString(16)}`
}

// ------------------------------------------------------------------ red team
export interface RedteamRow {
  id: string
  category: string
  text: string
  setup: string[] | null
  position: string
  match: string
  severity: number
  expect: { intents: string[]; outcomes: string[]; removal: boolean; must: string | null; must_not: string | null }
}

export interface RedteamResult {
  version: string
  total: number
  passed: number
  handled_automatically: number
  to_colin: number
  missed_removals: number
  failures: { id: string; why: string; text: string; reply: string | null }[]
  ok: boolean
}

const PERSONA_ADDRESS: Record<string, string> = { dale: '2847 N Burleigh St', rita: 'W220 N1765 Pewaukee Rd' }

/** Score the server's routing against WPIE's red-team fixture.
 *  A row passes when: a removal Python expects is honoured (missing one is severity 1);
 *  no removal happens that the fixture says must not; and when the reply agent answers on its own,
 *  his fixed line meets the row's must / must_not and a closing outcome is one the row
 *  allows. A row routed to Colin passes those content checks by construction (he reads
 *  and approves every such reply). ok = every row passes. */
export function scoreRedteam(rows: RedteamRow[]): RedteamResult {
  const out: RedteamResult = { version: rulesVersion(), total: rows.length, passed: 0, handled_automatically: 0, to_colin: 0,
    missed_removals: 0, failures: [], ok: false }
  for (const r of rows) {
    const d = decide({ inbound: r.text, priorInbound: r.setup ?? [], lastAgentText: null,
      propertyAddress: PERSONA_ADDRESS[r.match] ?? null })
    const why: string[] = []
    if (r.expect.removal && !d.removal) { why.push('missed removal'); out.missed_removals += 1 }
    if (!r.expect.removal && d.removal && !r.expect.outcomes.includes('dnc')) why.push('removal the fixture does not want')
    if (d.kind === 'candidate') out.to_colin += 1
    else {
      out.handled_automatically += 1
      const reply = d.reply ?? ''
      if (reply && r.expect.must && !new RegExp(r.expect.must, 'i').test(reply)) why.push(`missing /${r.expect.must}/`)
      if (reply && r.expect.must_not && new RegExp(r.expect.must_not, 'i').test(reply)) why.push(`has /${r.expect.must_not}/`)
      if (d.outcome !== 'open' && !r.expect.outcomes.includes(d.outcome)) why.push(`closed as ${d.outcome}, fixture allows ${r.expect.outcomes.join('/')}`)
    }
    if (why.length) out.failures.push({ id: r.id, why: why.join('; '), text: r.text, reply: d.reply })
    else out.passed += 1
  }
  out.ok = out.passed === out.total
  return out
}

/** Rick's two-tier opener (wpie.reply.brain, identify stage, agent_turns == 0): the opener only asked
 *  whether the place is still theirs. A short yes to it, on a thread matched to a property, gets the
 *  pitch line with one question; a first reply that already talks selling, interest or price does not
 *  (the drafter takes it). Returns the reply and its facts, or null. decide() makes it routine. */
/** Did our first text already ask about selling (wpie.reply.brain _OPENER_ASKED_SELLING_RE)? */
export const OPENER_ASKED_SELLING = /\bsell|\bbuy\b|as-is|\bcash\b/i
export function openerAskedSelling(opener: string | null | undefined): boolean {
  return !!opener && OPENER_ASKED_SELLING.test(opener)
}

export function pitchReply(x: { inbound: string; priorInbound: string[]; ourTurns: number; propertyAddress: string | null
  ownerName: string | null; openerText?: string | null }): { reply: string; facts: Record<string, unknown> } | null {
  const text = (x.inbound ?? '').trim()
  if (x.priorInbound.length || x.ourTurns > 0 || !x.propertyAddress) return null
  // An old-style opener that already asked about selling: a yes is interest, never pitch twice.
  if (openerAskedSelling(x.openerText)) return null
  if (!AFFIRM.test(text) || INTEREST_WORDS.test(text) || text.split(/\s+/).filter(Boolean).length > 6) return null
  // The opener already said hello and who this is; the pitch does neither again (Colin 2026-10-22: "it
  // shouldn't say Colin twice ... make the responses sound like I or a human actually wrote em").
  return {
    reply: B.PITCH_LINE,
    facts: { identity_confirmed: true, still_owns: true, interest: 'maybe', last_asked: 'interest', pitched: true },
  }
}
