// Tell Colin when Sam needs him: ONLY for a real reply waiting for approval (never routine).
// One push per draft plus an email backup, one reminder push after 2 hours, nothing in quiet
// hours (notify_claim, migration 0008, decides all of that and marks each draft as it hands it
// out). The email only OPENS the card in the app: no approve-by-link (mail scanners pre-fetch
// links), and nothing in it can send a text.
import type { Rpc } from './sending.ts'
import type { Mail } from './smtp.ts'
import type { PushOutcome, PushSubscriptionKeys } from './webpush.ts'

export interface ClaimedDraft {
  id: string
  kind: 'first' | 'reminder'
  is_test: boolean
  phone10: string
  inbound_body: string | null
  intent: string | null
  note: string | null
  body: string | null
  owner_name: string | null
  property_address: string | null
  thread: { who: 'us' | 'them'; body: string; at: string }[]
}

export interface NotifyDeps {
  rpc: Rpc
  subscriptions: () => Promise<PushSubscriptionKeys[]>
  push: ((sub: PushSubscriptionKeys, message: object) => Promise<PushOutcome>) | null
  email: ((m: Omit<Mail, 'from'>) => Promise<void>) | null
  emailTo: string | null
  appUrl: string
  now?: () => Date
}

export interface NotifySummary { drafts: number; reminders: number; pushes_ok: number; pushes_failed: number; emails: number; email_errors: string[] }

const ENTITY = /\b(LLC|L\.L\.C|INC|CORP|CO|COMPANY|TRUST|TRUSTEE|ESTATE|PROPERTIES|HOLDINGS|LP|LLP|BANK|CHURCH|CITY|COUNTY)\b/i

export function fmtPhone(p: string): string {
  const d = (p ?? '').replace(/\D/g, '').slice(-10)
  return d.length === 10 ? `(${d.slice(0, 3)}) ${d.slice(3, 6)}-${d.slice(6)}` : p
}

/** "John" for JOHN DOE; the whole name for a company or trust; the phone when we have no name. */
export function firstName(owner: string | null, phone10: string): string {
  const n = (owner ?? '').trim()
  if (!n) return fmtPhone(phone10)
  if (ENTITY.test(n) || n.startsWith('TEST')) return n
  const w = n.split(/\s+/)[0]
  return w.charAt(0).toUpperCase() + w.slice(1).toLowerCase()
}

export function snippet(s: string | null, n = 60): string {
  const t = (s ?? '').replace(/\s+/g, ' ').trim()
  return t.length > n ? t.slice(0, n - 1).trimEnd() + '…' : t
}

export function pushMessage(d: ClaimedDraft, appUrl: string) {
  const where = d.property_address ? `, ${d.property_address}` : ''
  return {
    title: d.kind === 'reminder' ? 'Still waiting: reply needs you' : 'Reply needs you',
    body: `${firstName(d.owner_name, d.phone10)}${where}: ${snippet(d.inbound_body)}`,
    url: `${appUrl.replace(/\/$/, '')}/inbox#draft-${d.id}`,
    tag: `draft-${d.id}`,
  }
}

function esc(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')
}

export function emailFor(d: ClaimedDraft, appUrl: string): { subject: string; text: string; html: string } {
  const name = d.owner_name?.trim() || fmtPhone(d.phone10)
  const url = `${appUrl.replace(/\/$/, '')}/inbox#draft-${d.id}`
  const why = [d.intent ? `read as "${d.intent.replace(/_/g, ' ')}"` : '', d.note ?? ''].filter(Boolean).join(' - ')
  const lines = (d.thread.length ? d.thread : [{ who: 'them' as const, body: d.inbound_body ?? '', at: '' }])
    .map((t) => `${t.who === 'us' ? 'You' : 'Them'}: ${t.body}`)
  const subject = `Reply needs you: ${name}${d.property_address ? `, ${d.property_address}` : ''}${d.is_test ? ' (TEST)' : ''}`
  const text = [
    `${name}${d.property_address ? ` - ${d.property_address}` : ''} (${fmtPhone(d.phone10)})`, '',
    ...lines, '',
    `Suggested reply: ${d.body ?? '(no draft - write the reply in the app)'}`,
    why ? `Why it needs you: ${why}` : '', '',
    `Review in the app (approve, edit or skip there): ${url}`,
    'Nothing is sent from this email.',
  ].join('\n')
  const html = `<div style="font-family:Arial,sans-serif;font-size:15px;max-width:560px">
<p><b>${esc(name)}</b>${d.property_address ? ` - ${esc(d.property_address)}` : ''} (${esc(fmtPhone(d.phone10))})${d.is_test ? ' <b style="color:#b91c1c">TEST</b>' : ''}</p>
${lines.map((l) => `<p style="margin:4px 0">${esc(l)}</p>`).join('\n')}
<p style="background:#fef3c7;padding:8px;border-radius:6px"><b>Suggested reply:</b> ${esc(d.body ?? '(no draft - write the reply in the app)')}</p>
${why ? `<p style="color:#555">Why it needs you: ${esc(why)}</p>` : ''}
<p><a href="${esc(url)}" style="display:inline-block;background:#111827;color:#fff;padding:10px 16px;border-radius:6px;text-decoration:none">Review in app</a></p>
<p style="color:#777;font-size:12px">Approve, edit or skip in the app. Nothing is sent from this email.</p></div>`
  return { subject, text, html }
}

async function pushAll(deps: NotifyDeps, message: object, s: NotifySummary) {
  if (!deps.push) return
  for (const sub of await deps.subscriptions()) {
    const r = await deps.push(sub, message)
    if (r.ok) s.pushes_ok += 1
    else s.pushes_failed += 1
    await deps.rpc('push_result', { p_endpoint: sub.endpoint, p_ok: r.ok, p_gone: r.gone })
  }
}

export async function runNotifications(deps: NotifyDeps): Promise<NotifySummary> {
  const now = deps.now ?? (() => new Date())
  const s: NotifySummary = { drafts: 0, reminders: 0, pushes_ok: 0, pushes_failed: 0, emails: 0, email_errors: [] }
  // Nothing that could reach Colin yet (no phone registered, no email): leave the drafts unclaimed,
  // so they are announced as soon as he turns notifications on.
  const subs = deps.push ? await deps.subscriptions() : []
  if (!subs.length && !(deps.email && deps.emailTo)) return s
  deps = { ...deps, subscriptions: async () => subs }
  for (const kind of ['first', 'reminder'] as const) {
    const r = await deps.rpc('notify_claim', { p_kind: kind, p_now: now().toISOString() })
    if (r.error) throw new Error(r.error.message)
    for (const d of (r.data as ClaimedDraft[]) ?? []) {
      if (kind === 'first') s.drafts += 1
      else s.reminders += 1
      await pushAll(deps, pushMessage(d, deps.appUrl), s)
      if (kind === 'first' && deps.email && deps.emailTo) {
        try {
          await deps.email({ to: deps.emailTo, ...emailFor(d, deps.appUrl) })
          s.emails += 1
        } catch (e) {
          s.email_errors.push(String(e instanceof Error ? e.message : e).slice(0, 160))
        }
      }
    }
  }
  return s
}

/** "Send a test notification": one push to every registered phone and one email. */
export async function testNotification(deps: NotifyDeps): Promise<NotifySummary> {
  const s: NotifySummary = { drafts: 0, reminders: 0, pushes_ok: 0, pushes_failed: 0, emails: 0, email_errors: [] }
  await pushAll(deps, { title: 'WPIE test', body: 'Notifications work. You will get a ping when a reply needs you.',
    url: `${deps.appUrl.replace(/\/$/, '')}/inbox`, tag: 'test' }, s)
  if (deps.email && deps.emailTo) {
    try {
      await deps.email({ to: deps.emailTo, subject: 'WPIE test: notifications work',
        text: `This is a test from WPIE. When a seller's reply needs you, you get an email like this and a ping on your phone.\n\n${deps.appUrl}/inbox`,
        html: `<p>This is a test from WPIE. When a seller's reply needs you, you get an email like this and a ping on your phone.</p><p><a href="${esc(deps.appUrl)}/inbox">Open the Inbox</a></p>` })
      s.emails += 1
    } catch (e) {
      s.email_errors.push(String(e instanceof Error ? e.message : e).slice(0, 160))
    }
  }
  return s
}
