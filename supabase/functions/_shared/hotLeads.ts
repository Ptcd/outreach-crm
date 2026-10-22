// Hot-lead alerts to Colin's cell (Colin 2026-10-22: "we need the app to notify my phone").
// A seller reply that shows interest or asks about selling is queued (hot_record); within a minute
// the reply agent texts Colin through pm-phone's PM line (never a seller number), once more after
// 15 minutes if the lead is not marked called, and a 7 PM Central list of hot leads not called.
// These texts go only to Colin; they may quote the seller.
import type { Rpc } from './sending.ts'

// Intents that mean "talk to this person now" (wpie/reply/rules.py names).
const HOT_INTENTS = new Set(['interested', 'price_first', 'who_is_this', 'buyer_check', 'worth', 'terms', 'firm', 'number_only',
  'wants_call', 'busy', 'think_it_over', 'foreclosure', 'other_property', 'estate'])
// Never hot, whatever the words: removals, wrong numbers, "not for sale" and the like.
const COLD_INTENTS = new Set(['opt_out', 'hostile', 'wrong_number', 'sold', 'not_interested', 'my_home', 'listed', 'signed_other',
  'tenant', 'manager', 'middleman', 'burned', 'bot_question', 'annoyed', 'not_now', 'joke_number'])
// A plain statement that talks selling, price or timing.
const SELLING_TALK = /\b(?:sell|selling|sale|price|offer|how much|worth|cash|value|timeline|when could|move|moving|listing|yes|yeah|yep|sure|maybe|still (?:own|mine|have)|interested)\b/i

export function isHotReply(x: { intent: string; text: string; removal: boolean }): boolean {
  if (x.removal || COLD_INTENTS.has(x.intent)) return false
  if (HOT_INTENTS.has(x.intent)) return true
  return SELLING_TALK.test(x.text ?? '')
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
const trimQuote = (s: string, n = 140) => {
  const t = (s ?? '').replace(/\s+/g, ' ').trim()
  return t.length > n ? `${t.slice(0, n - 1)}...` : t
}

export type HotAlert = { id: string; n: 1 | 2; lead_id: string | null; phone10: string; first_name: string | null; address: string | null
  body: string; is_test: boolean }

export function alertText(a: HotAlert, appUrl: string): string {
  const who = [a.first_name ?? 'Seller', a.address ? titleCase(a.address.replace(/,.*$/, '')) : null].filter(Boolean).join(', ')
  const link = a.lead_id ? ` ${appUrl.replace(/\/$/, '')}/lead/${a.lead_id}?call=1&phone=${a.phone10}` : ''
  const head = `${a.is_test ? 'TEST ' : ''}${a.n === 2 ? 'STILL NOT CALLED (15 min) - HOT' : 'HOT'}`
  return `${head}: ${who} said: "${trimQuote(a.body)}". Call: ${fmtPhone10(a.phone10)}${link}`
}

export function digestText(list: { first_name: string | null; address: string | null; phone10: string }[]): string {
  const items = list.slice(0, 8).map((x) => `${x.first_name ?? 'Seller'}${x.address ? ` (${titleCase(x.address.replace(/,.*$/, ''))})` : ''} ${fmtPhone10(x.phone10)}`)
  const more = list.length > 8 ? ` +${list.length - 8} more in the app` : ''
  return `7 PM: ${list.length} hot lead${list.length === 1 ? '' : 's'} not called yet: ${items.join('; ')}${more}`
}

export type AlertSend = (text: string) => Promise<{ ok: boolean; sid?: string | null; error?: string }>

export interface HotSummary { alerts: number; second_alerts: number; digest: number; errors: string[]; off?: string; ops?: number }

/** Text what is due (first alerts, 15-minute repeats, the 7 PM list). */
export async function runHotAlerts(opts: { rpc: Rpc; send: AlertSend | null; appUrl: string; now?: () => Date }): Promise<HotSummary> {
  const s: HotSummary = { alerts: 0, second_alerts: 0, digest: 0, errors: [] }
  if (!opts.send) { s.off = 'ALERT_SECRET not set'; return s }
  const now = (opts.now ?? (() => new Date()))()
  const c = await opts.rpc('hot_claim', { p_now: now.toISOString(), p_limit: 10 })
  if (c.error) { s.errors.push(c.error.message); return s }
  for (const a of (c.data as HotAlert[] | null) ?? []) {
    const r = await opts.send(alertText(a, opts.appUrl)).catch((e) => ({ ok: false, error: String(e) }))
    await opts.rpc('hot_result', { p_id: a.id, p_sid: r.ok ? (r as { sid?: string | null }).sid ?? null : null,
      p_error: r.ok ? null : String((r as { error?: string }).error ?? 'not sent').slice(0, 200) })
    if (!r.ok) s.errors.push(String((r as { error?: string }).error ?? 'not sent').slice(0, 200))
    else if (a.n === 2) s.second_alerts += 1
    else s.alerts += 1
  }
  // Texts about the system itself (e.g. follow-ups paused by their opt-out brake).
  const ops = await opts.rpc('ops_claim', { p_limit: 5 })
  for (const o of (ops.data as { id: number; text: string }[] | null) ?? []) {
    const r = await opts.send(o.text).catch((e) => ({ ok: false, error: String(e) }))
    await opts.rpc('ops_result', { p_id: o.id, p_sid: r.ok ? (r as { sid?: string | null }).sid ?? null : null,
      p_error: r.ok ? null : String((r as { error?: string }).error ?? 'not sent').slice(0, 200) })
    if (r.ok) s.ops = (s.ops ?? 0) + 1
  }
  const d = await opts.rpc('hot_digest', { p_now: now.toISOString() })
  const list = (d.data as { first_name: string | null; address: string | null; phone10: string }[] | null) ?? null
  if (!d.error && list && list.length) {
    const r = await opts.send(digestText(list)).catch((e) => ({ ok: false, error: String(e) }))
    if (r.ok) s.digest = 1
    else s.errors.push(String((r as { error?: string }).error ?? 'digest not sent').slice(0, 200))
  }
  return s
}

/** pm-phone's /api/alert: sends from the PM line to Colin's forward number. */
export function pmPhoneSender(get: (n: string) => string | undefined, fetchFn: typeof fetch): AlertSend | null {
  const secret = (get('ALERT_SECRET') ?? '').trim()
  if (!secret) return null
  const url = (get('ALERT_URL') ?? '').trim() || 'https://junkcarsmequon.com/api/alert'
  return async (text) => {
    const res = await fetchFn(url, { method: 'POST', headers: { 'content-type': 'application/json', 'x-alert-secret': secret },
      body: JSON.stringify({ text }) })
    const j = (await res.json().catch(() => ({}))) as { ok?: boolean; sid?: string; error?: string }
    return res.ok && j.ok ? { ok: true, sid: j.sid ?? null } : { ok: false, error: `pm-phone ${res.status}: ${j.error ?? 'error'}` }
  }
}
