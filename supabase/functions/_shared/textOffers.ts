// Offers by text (migration 0223): tell Colin when a number is waiting for his OK (a push and an email, once; one more
// push when it has waited past its time) and when a seller said yes and the written offer is his to send.
import type { NotifyDeps, NotifySummary } from './notify.ts'
import { pushAll } from './notify.ts'

type Rpc = (fn: string, args: Record<string, unknown>) => Promise<{ data: unknown; error: { message: string } | null }>
type Ping = { kind: 'ask' | 'reminder' | 'written'; offer_id: string; lead_id: string; address: string | null; owner_name: string | null
  number: number | null; ask_kind?: string | null; note?: string | null; arv?: number | null; repairs?: number | null; repairs_basis?: string | null
  most?: number | null; their_number?: number | null; sold_comps?: number | null; signers?: string | null; seller_email?: string | null }

const usd = (n: number | null | undefined) => (n === null || n === undefined ? '?' : `$${Math.round(Number(n)).toLocaleString('en-US')}`)
const esc = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')

export function offerPingMessage(p: Ping, appUrl: string): { title: string; body: string; url: string; tag: string } {
  const base = appUrl.replace(/\/$/, '')
  const where = p.address ?? 'a card'
  if (p.kind === 'written') {
    return { title: `They said yes to ${usd(p.number)}: ${where}`, body: 'Send the written offer from the card.', url: `${base}/lead/${p.lead_id}`, tag: `offer-yes-${p.offer_id}` }
  }
  const what = p.ask_kind === 'counter' ? 'Their counter' : 'Number to OK'
  return { title: `${p.kind === 'reminder' ? 'Still waiting: ' : ''}${what} ${usd(p.number)}: ${where}`,
    body: p.kind === 'reminder' ? 'The seller is waiting on a number. OK it, change it or pass.' : 'Muse texts nothing with a figure until you OK it.',
    url: `${base}/approvals`, tag: `offer-ask-${p.offer_id}` }
}

export function offerPingEmail(p: Ping, appUrl: string): { subject: string; text: string; html: string } {
  const m = offerPingMessage(p, appUrl)
  const lines = p.kind === 'written'
    ? [`${p.owner_name ?? ''}, ${p.address ?? ''}`, `They said yes to ${usd(p.number)}.`, `Who signs: ${p.signers ?? '?'}`, `Email for the papers: ${p.seller_email ?? '?'}`]
    : [`${p.owner_name ?? ''}, ${p.address ?? ''}`, `Number: ${usd(p.number)}${p.ask_kind === 'counter' ? ' (their counter)' : p.ask_kind === 'their_number' ? ' (their own number, under the rule)' : ''}`,
      `Worth fixed up: ${usd(p.arv)} from ${p.sold_comps ?? 0} sold comps`, `Repairs: ${usd(p.repairs)} (${p.repairs_basis ?? ''})`, `The most the rule allows: ${usd(p.most)}`,
      ...(p.their_number ? [`Their number: ${usd(p.their_number)}`] : []), ...(p.note ? [p.note] : [])]
  const text = `${lines.join('\n')}\n\n${m.url}`
  const html = `<div style="font-family:system-ui,sans-serif;font-size:15px;color:#102a43">${lines.map((l) => `<p style="margin:4px 0">${esc(l)}</p>`).join('')}
<p style="margin-top:14px"><a href="${esc(m.url)}" style="display:inline-block;background:#c77d10;color:#fff;padding:10px 16px;border-radius:6px;text-decoration:none;font-weight:600">${p.kind === 'written' ? 'Open the card' : 'OK it, change it or pass'}</a></p>
<p style="color:#52606d;font-size:12px">Nothing is sent from this email.</p></div>`
  return { subject: m.title, text, html }
}

export async function runOfferPings(deps: NotifyDeps, rpc: Rpc): Promise<{ asks: number; reminders: number; written: number; emails: number; error?: string }> {
  const out = { asks: 0, reminders: 0, written: 0, emails: 0 }
  const r = await rpc('text_offer_ping_claim', {})
  if (r.error) return { ...out, error: r.error.message.slice(0, 200) }
  for (const p of ((r.data as Ping[] | null) ?? [])) {
    const s: NotifySummary = { drafts: 0, reminders: 0, tasks: 0, pushes_ok: 0, pushes_failed: 0, emails: 0, email_errors: [] }
    await pushAll(deps, offerPingMessage(p, deps.appUrl), s).catch(() => null)
    if (p.kind !== 'reminder' && deps.email && deps.emailTo) {
      try { await deps.email({ to: deps.emailTo, ...offerPingEmail(p, deps.appUrl) }); out.emails++ } catch { /* the push and the screen still carry it */ }
    }
    if (p.kind === 'ask') out.asks++
    else if (p.kind === 'reminder') out.reminders++
    else out.written++
  }
  return out
}
