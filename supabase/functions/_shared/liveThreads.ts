// A caller is told when a seller on their card is texting back and forth right now (0246; Colin 2026-11-16: "when there
// are active conversations going on back and forth for thalia and Tyler they get notifications"). Every minute the reply
// agent asks live_threads_claim for the threads that are live and whose caller has not been told in the last hour,
// pushes the phones registered under that person's login and emails their alert address. If the card's caller is marked
// off today, the other caller is told and the alert says whose card it is. Nothing here touches a seller.
import { firstName, snippet } from './notify.ts'

type Rpc = (fn: string, args: Record<string, unknown>) => Promise<{ data: unknown; error: { message: string } | null }>
export type PushTo = (person: string, message: { title: string; body: string; url: string }) => Promise<number>

export interface LiveThread {
  alert_id: string; lead_id: string; person: string; display_name: string | null; card_caller: string; card_caller_name: string | null
  email: string | null; owner_name: string | null; address: string | null; municipality: string | null
  their_words: string | null; texts_this_hour: number; at: string
}
export interface LiveThreadSummary { threads: number; pushes: number; emails: number; nothing: number; errors: string[]; off?: string }

const esc = (x: string) => x.replace(/[&<>]/g, (ch) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[ch] as string))

export function liveThreadMessage(t: LiveThread, appUrl: string): { title: string; body: string; url: string; subject: string; text: string; html: string } {
  const who = firstName(t.owner_name, '').replace(/[,;]+$/, '') || 'A seller'      // "HUGHES, JARED T" reads as "Hughes"
  const where = [t.address, t.municipality].filter(Boolean).join(', ')
  const url = `${appUrl.replace(/\/+$/, '')}/lead/${t.lead_id}`
  const whose = t.person !== t.card_caller ? ` (${t.card_caller_name ?? t.card_caller}'s card, off today)` : ''
  const title = `Texting now: ${who}${t.address ? `, ${t.address}` : ''}${whose}`
  const n = Number(t.texts_this_hour ?? 0)
  const body = `"${snippet(t.their_words, 90)}"${n > 1 ? ` · ${n} texts from them this hour` : ''}. Open the card to read it, take it over or call.`
  return {
    title, body, url, subject: title,
    text: `${title}\n${where}\n\nThey wrote: ${t.their_words ?? ''}\n${n > 1 ? `${n} texts from them in the last hour.\n` : ''}\nOpen the card to read the thread, take it over or call: ${url}\nNothing is sent from this email.`,
    html: `<p><strong>${esc(title)}</strong></p><p>${esc(where)}</p><p>They wrote: “${esc(t.their_words ?? '')}”</p>`
      + `${n > 1 ? `<p>${n} texts from them in the last hour.</p>` : ''}<p><a href="${url}">Open the card</a> to read the thread, take it over or call.</p>`
      + `<p style="color:#777;font-size:12px">Nothing is sent from this email.</p>`,
  }
}

export async function runLiveThreadAlerts(opts: { rpc: Rpc; push: PushTo | null
  email: ((m: { to: string; subject: string; text: string; html: string }) => Promise<void>) | null; appUrl: string; now?: () => Date }): Promise<LiveThreadSummary> {
  const s: LiveThreadSummary = { threads: 0, pushes: 0, emails: 0, nothing: 0, errors: [] }
  // nowhere to send anything: claim nothing, so the threads are announced once alerts are set up
  if (!opts.push && !opts.email) { s.off = 'neither push (VAPID) nor email (SMTP) is set up'; return s }
  const r = await opts.rpc('live_threads_claim', { p_now: (opts.now ?? (() => new Date()))().toISOString() })
  if (r.error) { s.errors.push(r.error.message.slice(0, 200)); return s }
  for (const t of (Array.isArray(r.data) ? r.data : []) as LiveThread[]) {
    s.threads += 1
    const m = liveThreadMessage(t, opts.appUrl)
    let reached = 0
    if (opts.push) {
      try { const n = await opts.push(t.person, { title: m.title, body: m.body, url: m.url }); s.pushes += n; reached += n }
      catch (e) { s.errors.push(`${t.person} push ${t.alert_id.slice(-6)}: ${String(e).slice(0, 160)}`) }
    }
    const mailTo = opts.email && t.email && /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(t.email) ? t.email : null
    if (mailTo) {
      try { await opts.email!({ to: mailTo, subject: m.subject, text: m.text, html: m.html }); s.emails += 1; reached += 1 }
      catch (e) { s.errors.push(`${t.person} email ${t.alert_id.slice(-6)}: ${String(e).slice(0, 160)}`) }
    }
    if (reached === 0) s.nothing += 1
    await opts.rpc('live_thread_alerted', { p_id: t.alert_id, p_reached: reached,
      p_note: reached === 0 ? `no phone registered and no alert email on file for ${t.person}` : null })
  }
  return s
}
