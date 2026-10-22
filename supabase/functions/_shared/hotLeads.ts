// Hot-lead alerts (Colin 2026-10-22: "we need the app to notify my phone"; later that day, on the
// caller's guide saying alerts only reach Colin: "that should be automated").
// A seller reply that shows interest or asks about selling is queued (hot_record); within a minute
// the reply agent alerts the team, once more after 15 minutes if the lead is not marked called, and
// a 7 PM Central list of hot leads not called. Each alert goes out three ways at the same moment:
//   * a text to Colin's cell through pm-phone's PM line (never a seller number);
//   * a text to every team member with an alert_phone on file (alert_recipients, migration 0022),
//     through the same pm-phone route, which only accepts numbers on its own allow-list;
//   * a web push to every phone registered in push_subscriptions, opening the lead card.
// Alerts may quote the seller. Texts about the system itself (ops_claim) go to Colin only.
import type { Rpc } from './sending.ts'
import * as B from './replyBrain.generated.ts'
import type { PushOutcome, PushSubscriptionKeys } from './webpush.ts'

// When is a reply hot (Colin 2026-10-22, on a bare "Yes" that only confirmed ownership: "we don't
// even know that they want to sell")? Only when it shows they would sell:
//   (a) the answer to the pitch question ("Would you ever consider selling that one?") is a yes;
//   (b) the text itself talks selling / interest / price (brain.py _INTEREST_WORDS_RE), at any point;
//   (c) they ask what we'd pay or name a number (price_first and the like: warm).
// A bare yes to the question-only opener is NOT hot: it only says the place is theirs.
const COLD_INTENTS = new Set(['opt_out', 'hostile', 'wrong_number', 'sold', 'not_interested', 'my_home', 'listed', 'signed_other',
  'tenant', 'manager', 'middleman', 'burned', 'bot_question', 'annoyed', 'not_now', 'joke_number'])
const PRICE_INTENTS = new Set(['price_first', 'number_only', 'worth', 'terms', 'wants_call'])
const INTEREST_WORDS = new RegExp(B.INTEREST_WORDS_RE.source, B.INTEREST_WORDS_RE.flags)
const AFFIRM = new RegExp(B.AFFIRM_RE.source, B.AFFIRM_RE.flags)
// "...I'm not looking to sell", "no intention of selling": selling words that say no.
const NOT_SELLING = /\bnot\s+(?:\w+\s+){0,3}sell|\bno\s+(?:interest|intention|plans?)\b|\bnot\s+interested\b/i
/** Our last text was the pitch question. */
export const PITCH_ASKED = /would you ever consider selling/i

export function isHotReply(x: { intent: string; text: string; removal: boolean; afterPitch?: boolean }): boolean {
  const text = x.text ?? ''
  if (x.removal || COLD_INTENTS.has(x.intent) || NOT_SELLING.test(text)) return false
  if (PRICE_INTENTS.has(x.intent)) return true
  if (INTEREST_WORDS.test(text)) return true
  return !!x.afterPitch && (x.intent === 'interested' || AFFIRM.test(text))
}

/** A reply that ends the interest: the lead's open hot alerts stop (no repeat, not on the 7 PM list). */
export function endsInterest(x: { intent: string; removal: boolean; outcome: string }): boolean {
  return x.removal || COLD_INTENTS.has(x.intent) || ['not_interested', 'dnc', 'wrong_number'].includes(x.outcome)
}

const ENTITY = /\b(?:LLC|L\.L\.C|INC|CORP|CO|COMPANY|TRUST|TRUSTEE|ESTATE|PROPERTIES|HOLDINGS|LP|LLP|BANK|CHURCH|CITY|COUNTY)\b/i
export function firstNameOf(owner: string | null | undefined): string | null {
  const w = (owner ?? '').trim().split(/\s+/)[0] ?? ''
  if (!w || ENTITY.test(owner ?? '') || /^TEST\b/i.test(owner ?? '')) return null
  return w.charAt(0).toUpperCase() + w.slice(1).toLowerCase()
}

export function fmtPhone10(p: string): string {
  const d = (p ?? '').replace(/\D/g, '').slice(-10)
  return d.length === 10 ? `(${d.slice(0, 3)}) ${d.slice(3, 6)}-${d.slice(6)}` : p
}
const titleCase = (s: string) => s.toLowerCase().replace(/\b([a-z])/g, (m) => m.toUpperCase())
const street = (address: string | null) => (address ? titleCase(address.replace(/,.*$/, '')) : null)
const trimQuote = (s: string, n = 140) => {
  const t = (s ?? '').replace(/\s+/g, ' ').trim()
  return t.length > n ? `${t.slice(0, n - 1)}...` : t
}

export type HotAlert = { id: string; n: 1 | 2; lead_id: string | null; phone10: string; first_name: string | null; address: string | null
  body: string; is_test: boolean }

function leadLink(a: { lead_id: string | null; phone10: string }, appUrl: string): string {
  return a.lead_id ? `${appUrl.replace(/\/$/, '')}/lead/${a.lead_id}?call=1&phone=${a.phone10}` : `${appUrl.replace(/\/$/, '')}/inbox`
}

export function alertText(a: HotAlert, appUrl: string): string {
  const who = [a.first_name ?? 'Seller', street(a.address)].filter(Boolean).join(', ')
  const link = a.lead_id ? ` ${leadLink(a, appUrl)}` : ''
  if (HANDOFF_RE.test(a.body)) {
    // "Thalia hands off: motivated, lease ends in December" -> HANDED TO YOU: Jane, N Main St. Thalia: motivated...
    const [, caller, note] = a.body.match(/^(\S+) hands off: ([\s\S]*)$/) ?? [null, 'The team', a.body]
    const call = /^\d{10}$/.test(a.phone10) ? ` Call: ${fmtPhone10(a.phone10)}` : ''
    return `${a.is_test ? 'TEST ' : ''}${a.n === 2 ? 'STILL WAITING (15 min) - ' : ''}HANDED TO YOU: ${who}. ${caller}: "${trimQuote(note ?? '')}".${call}${link}`
  }
  const head = `${a.is_test ? 'TEST ' : ''}${a.n === 2 ? 'STILL NOT CALLED (15 min) - HOT' : 'HOT'}`
  return `${head}: ${who} said: "${trimQuote(a.body)}". Call: ${fmtPhone10(a.phone10)}${link}`
}

export type PushMessage = { title: string; body: string; url: string; tag: string }

/** The phone notification for one alert: "Hot lead: John, 2825 S Logan Av", tap opens the lead card. */
export function alertPush(a: HotAlert, appUrl: string): PushMessage {
  const who = [a.first_name ?? 'Seller', street(a.address)].filter(Boolean).join(', ')
  const head = a.n === 2 ? 'Still not called (15 min)' : 'Hot lead'
  return {
    title: `${a.is_test ? 'TEST ' : ''}${head}: ${who}`.slice(0, 90),
    body: `"${trimQuote(a.body, 90)}" Call ${fmtPhone10(a.phone10)}`,
    url: leadLink(a, appUrl),
    tag: `hot-${a.id}`,
  }
}

export type DigestRow = { first_name: string | null; address: string | null; phone10: string; lead_id?: string | null }

export function digestText(list: DigestRow[]): string {
  const items = list.slice(0, 8).map((x) => `${x.first_name ?? 'Seller'}${x.address ? ` (${street(x.address)})` : ''} ${fmtPhone10(x.phone10)}`)
  const more = list.length > 8 ? ` +${list.length - 8} more in the app` : ''
  return `7 PM: ${list.length} hot lead${list.length === 1 ? '' : 's'} not called yet: ${items.join('; ')}${more}`
}

export function digestPush(list: DigestRow[], appUrl: string): PushMessage {
  const names = list.slice(0, 4).map((x) => x.first_name ?? 'Seller').join(', ')
  return {
    title: `7 PM: ${list.length} hot lead${list.length === 1 ? '' : 's'} not called`,
    body: `${names}${list.length > 4 ? ` +${list.length - 4} more` : ''}. Open the Inbox.`,
    url: `${appUrl.replace(/\/$/, '')}/inbox`,
    tag: 'hot-digest',
  }
}

/** Sends one text. `to` names a team member's phone (pm-phone allows only its own list); absent = Colin. */
export type AlertSend = (text: string, to?: string) => Promise<{ ok: boolean; sid?: string | null; error?: string }>

export interface HotPush {
  subscriptions: () => Promise<PushSubscriptionKeys[]>
  push: (sub: PushSubscriptionKeys, message: object) => Promise<PushOutcome>
}

export interface HotSummary { alerts: number; second_alerts: number; digest: number; errors: string[]; off?: string; ops?: number
  member_texts: number; pushes_ok: number; pushes_failed: number; emails?: number }

type Member = { person: string; phone: string }
type EmailMember = { person: string; email: string }

/** The email half (Colin 2026-10-22: "a spot in settings to add emails for hot pings"): every member with an
 * alert email on file (alert_email_recipients, migration 0028) gets the same alert as an email. */
export interface HotEmail {
  recipients: () => Promise<EmailMember[]>
  send: (m: { to: string; subject: string; text: string; html: string }) => Promise<void>
}

/** A caller handing a card to Colin (handoff_to_colin, migration 0028) rides the hot-alert path; the text
 * goes to Colin's cell and the pushes and emails to everyone, but no member text: it was their own hand-off. */
export const HANDOFF_RE = /^\S+ hands off: /

export function alertEmail(text: string, message: PushMessage): { subject: string; text: string; html: string } {
  const esc = (x: string) => x.replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c] as string))
  return {
    subject: message.title,
    text: `${text}\n\nOpen the card: ${message.url}`,
    html: `<p>${esc(text)}</p><p><a href="${message.url}">Open the card</a></p>`,
  }
}

/** Alert what is due (first alerts, 15-minute repeats, the 7 PM list): texts to Colin and to every
 * member with a phone on file, a push to every registered phone, and an email to every member with an
 * alert email, at the same moments. */
export async function runHotAlerts(opts: { rpc: Rpc; send: AlertSend | null; appUrl: string; now?: () => Date; push?: HotPush | null
  email?: HotEmail | null }): Promise<HotSummary> {
  const s: HotSummary = { alerts: 0, second_alerts: 0, digest: 0, errors: [], member_texts: 0, pushes_ok: 0, pushes_failed: 0, emails: 0 }
  const push = opts.push ?? null
  // Nothing that could reach anyone: leave the alerts unclaimed so they go out once a channel exists.
  const subs = push ? await push.subscriptions().catch(() => [] as PushSubscriptionKeys[]) : []
  const mails: EmailMember[] = opts.email ? await opts.email.recipients().catch(() => [] as EmailMember[]) : []
  if (!opts.send && !subs.length && !mails.length) { s.off = push ? 'ALERT_SECRET not set and no phone registered' : 'ALERT_SECRET not set'; return s }
  const now = (opts.now ?? (() => new Date()))()
  const members: Member[] = opts.send ? await membersWithPhones(opts.rpc) : []
  const err = (r: { error?: string }, fallback: string) => String(r.error ?? fallback).slice(0, 200)

  const fanOut = async (text: string, message: PushMessage, memberTexts = true) => {
    if (memberTexts) {
      for (const m of members) {
        const r = await opts.send!(text, m.phone).catch((e) => ({ ok: false, error: String(e) }))
        if (r.ok) s.member_texts += 1
        else s.errors.push(`${m.person}: ${err(r, 'not sent')}`)
      }
    }
    if (opts.email) {
      const mail = alertEmail(text, message)
      for (const m of mails) {
        try {
          await opts.email.send({ to: m.email, ...mail })
          s.emails = (s.emails ?? 0) + 1
        } catch (e) {
          s.errors.push(`${m.person} email: ${String(e).slice(0, 160)}`)
        }
      }
    }
    if (push) {
      for (const sub of subs) {
        const r = await push.push(sub, message).catch(() => ({ ok: false, gone: false, status: null }))
        if (r.ok) s.pushes_ok += 1
        else s.pushes_failed += 1
        await opts.rpc('push_result', { p_endpoint: sub.endpoint, p_ok: r.ok, p_gone: r.gone })
      }
    }
  }

  const c = await opts.rpc('hot_claim', { p_now: now.toISOString(), p_limit: 10 })
  if (c.error) { s.errors.push(c.error.message); return s }
  for (const a of (c.data as HotAlert[] | null) ?? []) {
    const text = alertText(a, opts.appUrl)
    if (opts.send) {
      const r = await opts.send(text).catch((e) => ({ ok: false, error: String(e) }))
      await opts.rpc('hot_result', { p_id: a.id, p_sid: r.ok ? (r as { sid?: string | null }).sid ?? null : null,
        p_error: r.ok ? null : err(r, 'not sent') })
      if (!r.ok) s.errors.push(err(r, 'not sent'))
      else if (a.n === 2) s.second_alerts += 1
      else s.alerts += 1
    } else {
      await opts.rpc('hot_result', { p_id: a.id, p_sid: null, p_error: 'push only (no ALERT_SECRET)' })
      if (a.n === 2) s.second_alerts += 1
      else s.alerts += 1
    }
    await fanOut(text, alertPush(a, opts.appUrl), !HANDOFF_RE.test(a.body))
  }
  // Texts about the system itself (e.g. follow-ups paused by their opt-out brake): Colin only.
  if (opts.send) {
    const ops = await opts.rpc('ops_claim', { p_limit: 5 })
    for (const o of (ops.data as { id: number; text: string }[] | null) ?? []) {
      const r = await opts.send(o.text).catch((e) => ({ ok: false, error: String(e) }))
      await opts.rpc('ops_result', { p_id: o.id, p_sid: r.ok ? (r as { sid?: string | null }).sid ?? null : null,
        p_error: r.ok ? null : err(r, 'not sent') })
      if (r.ok) s.ops = (s.ops ?? 0) + 1
    }
  }
  const d = await opts.rpc('hot_digest', { p_now: now.toISOString() })
  const list = (d.data as DigestRow[] | null) ?? null
  if (!d.error && list && list.length) {
    const text = digestText(list)
    if (opts.send) {
      const r = await opts.send(text).catch((e) => ({ ok: false, error: String(e) }))
      if (r.ok) s.digest = 1
      else s.errors.push(err(r, 'digest not sent'))
    } else s.digest = 1
    await fanOut(text, digestPush(list, opts.appUrl))
  }
  return s
}

async function membersWithPhones(rpc: Rpc): Promise<Member[]> {
  const r = await rpc('alert_recipients', {})
  if (r.error || !Array.isArray(r.data)) return []
  return (r.data as Member[]).filter((m) => /^\+1\d{10}$/.test(m.phone ?? ''))
}

/** pm-phone's /api/alert: sends from the PM line to Colin's forward number, or to a listed member's `to`. */
export function pmPhoneSender(get: (n: string) => string | undefined, fetchFn: typeof fetch): AlertSend | null {
  const secret = (get('ALERT_SECRET') ?? '').trim()
  if (!secret) return null
  const url = (get('ALERT_URL') ?? '').trim() || 'https://junkcarsmequon.com/api/alert'
  return async (text, to) => {
    const res = await fetchFn(url, { method: 'POST', headers: { 'content-type': 'application/json', 'x-alert-secret': secret },
      body: JSON.stringify(to ? { text, to } : { text }) })
    const j = (await res.json().catch(() => ({}))) as { ok?: boolean; sid?: string; error?: string }
    return res.ok && j.ok ? { ok: true, sid: j.sid ?? null } : { ok: false, error: `pm-phone ${res.status}: ${j.error ?? 'error'}` }
  }
}
