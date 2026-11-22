// The card's caller is told when a said-yes card is ready to call (0269; Colin 2026-11-21: Muse does the work when a
// yes is live, "then push it to you and then you ping our team member with the card"). Every minute the reply agent asks
// yes_ready_claim for the cards whose prices or story just landed and pushes the phones registered under that caller's
// login and emails their alert address. A card with no caller goes to the owners. One alert per card for the prices and
// one for the story; both in the same minute are one alert. Nothing in quiet hours. Nothing here touches a seller, and
// no dollar figure is in the alert: the numbers are on the card.
import { firstName } from './notify.ts'

type Rpc = (fn: string, args: Record<string, unknown>) => Promise<{ data: unknown; error: { message: string } | null }>
export type PushTo = (person: string, message: { title: string; body: string; url: string }) => Promise<number>

export interface YesReady {
  alert_ids: string[]; lead_id: string; person: string; email: string | null; owner_name: string | null; address: string | null
  municipality: string | null; landed: string[]; prices: boolean; brief: boolean; has_caller: boolean
  asked?: boolean   // 0283: asked for from the card's button, not a seller's yes
}
export interface YesReadySummary { cards: number; pushes: number; emails: number; nothing: number; errors: string[]; off?: string }

const esc = (x: string) => x.replace(/[&<>]/g, (ch) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[ch] as string))

export function yesReadyMessage(t: YesReady, appUrl: string): { title: string; body: string; url: string; subject: string; text: string; html: string } {
  const who = firstName(t.owner_name, '').replace(/[,;]+$/, '') || 'A seller'
  const where = [t.address, t.municipality].filter(Boolean).join(', ')
  const url = `${appUrl.replace(/\/+$/, '')}/lead/${t.lead_id}`
  const title = `${t.prices ? 'Ready to call' : 'Story is in'}: ${who}${t.address ? `, ${t.address}` : ''}${t.has_caller ? '' : ' (no caller on this card)'}`
  const body = t.asked
    ? (t.prices && t.brief ? 'Your comps, the angles and the script are on the card. Read it and call.'
      : t.prices ? 'Your comps and prices are on the card; the script is still being written.'
      : 'The story, the angles and the script are on the card. No prices yet: give no number.')
    : t.prices && t.brief ? 'They said yes. The value, the prices and the script are on the card. Read it and call.'
    : t.prices ? 'They said yes. The value and the prices are on the card; the story is still being written. Call now.'
    : 'They said yes. The story and the script are on the card. No prices yet: give no number.'
  return {
    title, body, url, subject: title,
    text: `${title}\n${where}\n\n${body}\n\nOpen the card: ${url}\nNothing is sent from this email.`,
    html: `<p><strong>${esc(title)}</strong></p><p>${esc(where)}</p><p>${esc(body)}</p><p><a href="${url}">Open the card</a></p>`
      + `<p style="color:#777;font-size:12px">Nothing is sent from this email.</p>`,
  }
}

export async function runYesReadyAlerts(opts: { rpc: Rpc; push: PushTo | null
  email: ((m: { to: string; subject: string; text: string; html: string }) => Promise<void>) | null; appUrl: string; now?: () => Date }): Promise<YesReadySummary> {
  const s: YesReadySummary = { cards: 0, pushes: 0, emails: 0, nothing: 0, errors: [] }
  // nowhere to send anything: claim nothing, so the cards are announced once alerts are set up
  if (!opts.push && !opts.email) { s.off = 'neither push (VAPID) nor email (SMTP) is set up'; return s }
  const r = await opts.rpc('yes_ready_claim', { p_now: (opts.now ?? (() => new Date()))().toISOString() })
  if (r.error) { s.errors.push(r.error.message.slice(0, 200)); return s }
  for (const t of (Array.isArray(r.data) ? r.data : []) as YesReady[]) {
    s.cards += 1
    const m = yesReadyMessage(t, opts.appUrl)
    let reached = 0
    if (opts.push) {
      try { const n = await opts.push(t.person, { title: m.title, body: m.body, url: m.url }); s.pushes += n; reached += n }
      catch (e) { s.errors.push(`${t.person} push ${t.lead_id.slice(-6)}: ${String(e).slice(0, 160)}`) }
    }
    const mailTo = opts.email && t.email && /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(t.email) ? t.email : null
    if (mailTo) {
      try { await opts.email!({ to: mailTo, subject: m.subject, text: m.text, html: m.html }); s.emails += 1; reached += 1 }
      catch (e) { s.errors.push(`${t.person} email ${t.lead_id.slice(-6)}: ${String(e).slice(0, 160)}`) }
    }
    if (reached === 0) s.nothing += 1
    await opts.rpc('yes_ready_alerted', { p_ids: t.alert_ids, p_reached: reached,
      p_note: reached === 0 ? `no phone registered and no alert email on file for ${t.person}` : null })
  }
  return s
}
