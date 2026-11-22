// The top of a card, for a person about to pick up the phone (Colin 2026-11-22: "Do you see how bad of a mess the cards
// are", then "Figure out the best ux and way to fix it"). Three things the page could not say at a glance: who to ask
// for (the county's "THOMPSON, RUSSEL J / HUTH, RACHAEL L" is not a name to say), why they might sell, in a line,
// and which of sixteen numbers to dial. Pure functions; the page (LeadDetail, CallPanel) only lays them out.
import type { Contact, Message } from './types'
import { isOwnersPhone, phoneBlocked } from './phoneOrder'

const COMPANY = /\b(LLC|L\.L\.C|INC|CORP|CO|COMPANY|HOLDINGS|PROPERTIES|INVESTMENTS?|GROUP|PARTNERS|REALTY|MANAGEMENT|BANK|CHURCH|TRUST|ESTATE|LP|LLP)\b/i
const KEEP_UPPER = /^(LLC|INC|LP|LLP|II|III|IV|JR|SR|PO)$/i
const cap = (w: string) => (KEEP_UPPER.test(w) ? w.toUpperCase().replace(/^JR$/, 'Jr').replace(/^SR$/, 'Sr')
  : w.split(/([-'])/).map((p) => (p.length > 1 || /[a-z]/i.test(p) ? p[0].toUpperCase() + p.slice(1).toLowerCase() : p)).join(''))
const title = (s: string) => s.split(/\s+/).filter(Boolean).map(cap).join(' ')

/** What a county roll prints when it gives no owner (Kenosha's "NOT AVAILABLE"): not a name to show or to say. */
export const NO_NAME = /^(not available|unavailable|unknown|unknown owner|owner unknown|current owner|current resident|n\/?a|none|no name)$/i

/** The owner as a person would say it: "THOMPSON, RUSSEL J / HUTH, RACHAEL L" -> "Russel J Thompson and Rachael L Huth".
 *  A name with no comma keeps its order (a roll's "BLAISDELL KAREN" may be either way round); a company keeps its words. */
export function displayOwner(owner: string | null | undefined): string {
  const s = (owner ?? '').trim()
  if (!s || NO_NAME.test(s)) return ''
  if (COMPANY.test(s) && !/,/.test(s)) return title(s)
  const people = s.split(/\s*(?:\/|&|\band\b|;)\s*/i).map((p) => p.trim()).filter(Boolean)
  const said = people.map((p) => {
    const m = p.match(/^([^,]+),\s*(.+)$/)
    return title(m ? `${m[2]} ${m[1]}` : p)
  })
  return said.length <= 1 ? (said[0] ?? '') : `${said.slice(0, -1).join(', ')} and ${said[said.length - 1]}`
}

const WHY: [RegExp, string][] = [
  [/sheriff/i, 'Sheriff sale'],
  [/foreclos/i, 'Foreclosure'],
  [/probate|estate|inherit|owner died|deceased/i, 'Estate'],
  [/tax warrant/i, 'State tax warrant'],
  [/tax/i, 'Behind on taxes'],
  [/bankrupt/i, 'Bankruptcy'],
  [/evict/i, 'Evicting a tenant'],
  [/judgment|court debt|lien/i, 'Court judgment'],
  [/raze|condemn/i, 'Raze or condemn order'],
  [/code|nuisance|violation/i, 'Code case'],
  [/vacan/i, 'Vacant'],
  [/divorce/i, 'Divorce'],
  [/fire/i, 'Fire'],
  [/utility|water/i, 'Unpaid utilities'],
  [/absentee|out of state/i, 'Owner lives elsewhere'],
  [/landlord|rental/i, 'Landlord'],
]

/** Why they might sell, each kind once, the heaviest first: "Foreclosure · Estate · Behind on taxes". */
export function whyLine(reasons: string[] | null | undefined, max = 4): string[] {
  const out: string[] = []
  const rest: string[] = []
  for (const r of reasons ?? []) {
    const hit = WHY.find(([re]) => re.test(r))
    if (hit) { if (!out.includes(hit[1])) out.push(hit[1]) } else if (r.trim() && !rest.includes(r.trim())) rest.push(r.trim())
  }
  const order = WHY.map(([, w]) => w)
  out.sort((a, b) => order.indexOf(a) - order.indexOf(b))
  return [...out, ...rest.map((r) => (r.length > 40 ? `${r.slice(0, 38)}...` : r))].slice(0, max)
}

const ten = (s: string | null | undefined) => (s ?? '').replace(/\D/g, '').slice(-10)
const REACHED = new Set(['interested', 'not_interested', 'reached', 'reached_no_decision', 'not_now', 'booked', 'inbound_answered', 'callback', 'ai_answered'])

/** A task note an agent wrote for a list, as a person reads it: no agent stamp, no list bookkeeping, no number to dial
 *  (the call panel has it), no repeat of the reasons (the top of the card has them). */
export function plainTaskNote(note: string | null | undefined): string {
  return (note ?? '')
    .replace(/^\s*(Muse( 2)?|Grok|Desk)\s*(\([^)]*\))?\s*\d{4}-\d{2}-\d{2}\s*:\s*/i, '')
    .replace(/A logged call closes this task\.*/gi, '')
    .replace(/STORY:[\s\S]*?read them before you dial\.?/i, '')
    .replace(/\bCall(?:\s*\(?\d{3}\)?[ .-]?\d{3}[ .-]?\d{4}\s*(?:\([a-z ]+\))?[,.]?)+/gi, '')
    .replace(/\bSay:\s*/g, '')
    .replace(/call list \(#\d+\)/gi, '')
    .replace(/Dial \(?\d{3}\)?[ .-]?\d{3}[ .-]?\d{4}\.?/gi, '')
    .replace(/(Estate \/ owner died|Foreclosure|Back taxes|Probate \/ estate|Sheriff sale|Code case|Eviction|Judgment)\s*:[^.;]*[.;]?/gi, '')
    .replace(/\s+/g, ' ').replace(/\s+([.;,])/g, '$1').replace(/[.;,]\s*[.;,]+/g, '.').trim()
}

export type RankedPhone = Contact & { owners: boolean; blocked: boolean; note: string; score: number }

/** The card's phones, the one to dial first at the top, each with what happened on it. A number they texted or
 *  answered on comes first; then the owner's own mobile; a number whose text bounced or that was a wrong number goes
 *  to the bottom, above only the blocked ones. */
export function rankPhones(contacts: Contact[], ownerName: string | null | undefined, messages: Message[] | undefined,
  inbound: { from10: string }[] | undefined): RankedPhone[] {
  const texted = new Set((inbound ?? []).map((t) => t.from10))
  const seen: Record<string, { reached: number; noAnswer: number; wrong: number; delivered: number; bounced: number }> = {}
  const at = (n: string) => (seen[n] ??= { reached: 0, noAnswer: 0, wrong: 0, delivered: 0, bounced: 0 })
  for (const m of messages ?? []) {
    if (m.channel === 'call') {
      const n = ten(m.from_number) || ten(m.to_number)
      if (!n) continue
      const s = m.status ?? ''
      if (REACHED.has(s)) at(n).reached++
      else if (s === 'wrong_number') at(n).wrong++
      else if (s === 'no_answer' || s === 'voicemail' || s === 'busy') at(n).noAnswer++
    } else if (m.channel === 'sms' && m.direction === 'out') {
      const n = ten(m.to_number)
      if (!n) continue
      if (m.status === 'delivered') at(n).delivered++
      else if (m.status === 'undelivered' || m.status === 'failed') at(n).bounced++
    }
  }
  return contacts.filter((c) => c.kind === 'phone').map((c) => {
    const n = ten(c.value_normalized ?? c.value)
    const h = seen[n] ?? { reached: 0, noAnswer: 0, wrong: 0, delivered: 0, bounced: 0 }
    const owners = isOwnersPhone(c, ownerName)
    const blocked = phoneBlocked(c)
    const dead = h.wrong > 0 || (h.bounced > 0 && h.delivered === 0)
    // a number someone on the team typed in (the seller gave it): right under the one they texted from
    const given = /added by/i.test(c.source ?? '')
    const score = (blocked ? 1000 : 0) + (dead ? 300 : 0)
      + (texted.has(n) ? -200 : 0) + (h.reached > 0 ? -150 : 0) + (h.delivered > 0 ? -20 : 0) + (given ? -120 : 0)
      + (owners ? 0 : 40) + (c.line_type === 'mobile' ? 0 : c.line_type === 'landline' ? 15 : 8)
      + Math.min(h.noAnswer, 4) * 3
    const note = blocked ? 'Blocked: do not call or text'
      : texted.has(n) ? 'They texted us from this number'
        : h.reached > 0 ? 'They picked up on this number'
          : h.wrong > 0 ? 'Wrong number'
            : h.bounced > 0 && h.delivered === 0 ? 'Our text did not go through'
              : h.noAnswer > 0 ? `No answer ${h.noAnswer === 1 ? 'once' : `${h.noAnswer} times`}${h.delivered > 0 ? ', text delivered' : ''}`
                : h.delivered > 0 ? 'Text delivered, no reply' : given ? 'A number they gave us, not tried yet' : 'Not tried yet'
    return { ...c, owners, blocked, note, score }
  }).sort((a, b) => a.score - b.score)
    // one row a number: a card can hold the same number twice (two traces, two names); the better row stands
    .filter((p, i, all) => all.findIndex((q) => ten(q.value_normalized ?? q.value) === ten(p.value_normalized ?? p.value)) === i)
}

/** Notes as entries a person can scan: the ' | ' the system joins them with, each with its first line. */
export function noteEntries(notes: string | null | undefined): { head: string; rest: string }[] {
  return (notes ?? '').split(' | ').map((p) => p.trim()).filter(Boolean).map((p) => {
    const [first, ...more] = p.split('\n')
    if (first.length > 220 && more.length === 0) return { head: `${first.slice(0, 200)}...`, rest: first }
    return { head: first, rest: more.join('\n').trim() }
  })
}

export type CardPerson = { name: string; kind?: string | null; role?: string | null; status?: string | null }
const nameKey = (s: string) => displayOwner(s).toLowerCase().replace(/[^a-z ]/g, ' ').split(/\s+/).filter((w) => w.length > 1)
const same = (a: string, b: string) => { const x = nameKey(a); const y = new Set(nameKey(b)); return x.length > 0 && x[0] !== undefined && y.has(x[0]) && y.has(x[x.length - 1]) }

/** Who to ask for (2026-11-22: a card said "Call Russel" and three texts opened "Hi Russel" while its own probate note
 *  named Russel as the one who died). The living people on the card, a person marked deceased never among them; a
 *  county name that joins two owners ("THOMPSON, RUSSEL J / HUTH, RACHAEL L") is split and the dead one left out. */
export function whoToAskFor(people: CardPerson[] | null | undefined, ownerName: string | null | undefined): { living: string[]; died: string[]; askFor: string } {
  const ps = (Array.isArray(people) ? people : []).filter((p) => p && p.name && (p.kind ?? 'person') === 'person')
  const died = [...new Set(ps.filter((p) => p.status === 'deceased').map((p) => displayOwner(p.name)))]
  const out = (n: string) => died.some((d) => same(n, d) || same(d, n))
  const parts = (s: string) => s.split(/\s*(?:\/|&|;)\s*/).map((x) => x.trim()).filter(Boolean)
  const living: string[] = []
  const add = (n: string) => { const d = displayOwner(n); if (d && !out(d) && !living.some((l) => same(l, d) || same(d, l))) living.push(d) }
  const REPS = ['personal_representative', 'special_administrator', 'trustee', 'heir', 'spouse', 'co_owner']
  for (const p of [...ps].sort((a, b) => (REPS.includes(a.role ?? '') ? 0 : 1) - (REPS.includes(b.role ?? '') ? 0 : 1))) {
    if (p.status && p.status !== 'active') continue
    for (const n of parts(p.name)) add(n)
  }
  if (!living.length) for (const n of parts(ownerName ?? '')) add(n)
  const first = living[0]?.split(' ')[0] ?? ''
  return { living, died, askFor: first }
}

/** Phone numbers in a text of theirs that are not on the card yet, each with the name the text gives for it, if any
 *  ("Name: Ellie Tel: 1 (920) 728-1490", "call my son Mark at 920-555-0100"). The name is a guess the caller can fix. */
export function phonesInText(body: string | null | undefined, onCard: Iterable<string>): { phone10: string; name: string | null }[] {
  if (!body) return []
  const have = new Set([...onCard].map((p) => ten(p)))
  const out: { phone10: string; name: string | null }[] = []
  const re = /(?:\+?1[\s.-]*)?\(?([2-9]\d{2})\)?[\s.-]*(\d{3})[\s.-]*(\d{4})(?!\d)/g
  for (const m of body.matchAll(re)) {
    const phone10 = `${m[1]}${m[2]}${m[3]}`
    if (have.has(phone10) || out.some((o) => o.phone10 === phone10)) continue
    const before = body.slice(0, m.index ?? 0)
    const named = before.match(/name\s*(?:is|:|-)?\s*([A-Z][A-Za-z'.-]+(?:[ \t]+(?!tel\b|phone\b|cell\b|number\b|mobile\b|at\b)[A-Z][A-Za-z'.-]+)?)[^A-Za-z]*(?:tel|phone|cell|number|#|at|:|\s)*$/i)
      ?? before.match(/(?:call|text|reach|contact|ask for|talk to|speak (?:to|with)|try)\s+(?:my\s+[a-z-]+\s+)?([A-Z][a-z'.-]+(?:\s+[A-Z][a-z'.-]+)?)\b[^.!?\n]{0,25}$/)
      ?? before.match(/([A-Z][a-z'.-]+)(?:'s)?\s+(?:number|cell|phone)\s*(?:is|:|-)?\s*$/)
    const name = named?.[1]?.trim().replace(/['’]s$/i, '') ?? null
    out.push({ phone10, name: name && !/^(Tel|Phone|Cell|Number|Call|Text|My|The|Is|At)$/i.test(name) ? name : null })
  }
  return out
}
