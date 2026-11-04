// A caller's own follow-up reminds them (0170/0171; Colin 2026-11-03: callers manage their own follow-ups). Every
// minute the reply agent asks followups_due_to_alert for Thalia's and Adil's calls, callbacks and visits due in the next
// ten minutes (or up to five minutes late) that have not been reminded, pushes the phones registered under that
// person's login, emails their alert address, and marks the task once anything got through (tasks.notified_at; a move
// clears it, so a moved follow-up reminds again). WhatsApp is not used here: the only approved template is the
// missed-call one. Nothing here touches a seller.
type Rpc = (fn: string, args: Record<string, unknown>) => Promise<{ data: unknown; error: { message: string } | null }>

export interface DueFollowup {
  task_id: string; lead_id: string | null; kind: string; due_at: string; title: string; note: string
  owner_name: string | null; address: string | null; municipality: string | null; person: string; email: string | null; whatsapp?: string | null; display_name: string | null
}
export interface FollowupSummary { pushes: number; emails: number; nothing: number; errors: string[]; off?: string }
export type PushTo = (person: string, message: { title: string; body: string; url: string }) => Promise<number>

const fmtTime = (iso: string) => new Date(iso).toLocaleTimeString('en-US', { timeZone: 'America/Chicago', hour: 'numeric', minute: '2-digit' })
const KIND: Record<string, string> = { call: 'Call', callback: 'Callback you promised', visit: 'Visit' }

export function followupMessage(f: DueFollowup, appUrl: string): { title: string; body: string; url: string; subject: string; text: string; html: string } {
  const who = f.owner_name || 'a seller'
  const where = [f.address, f.municipality].filter(Boolean).join(', ')
  const url = f.lead_id ? `${appUrl.replace(/\/+$/, '')}/lead/${f.lead_id}` : appUrl.replace(/\/+$/, '')
  const what = KIND[f.kind] ?? f.title
  const title = `${what} at ${fmtTime(f.due_at)}: ${who}`
  const body = `${where || 'no address on the card'}${f.note ? `. ${f.note}` : ''}`
  const esc = (x: string) => x.replace(/[&<>]/g, (ch) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[ch] as string))
  return {
    title, body, url, subject: title,
    text: `${title}\n${body}\n\nOpen the card: ${url}`,
    html: `<p><strong>${esc(title)}</strong></p><p>${esc(body)}</p><p><a href="${url}">Open the card</a></p>`,
  }
}

export async function runFollowupReminders(opts: { rpc: Rpc; push: PushTo | null
  email: ((m: { to: string; subject: string; text: string; html: string }) => Promise<void>) | null; appUrl: string; now?: () => Date }): Promise<FollowupSummary> {
  const s: FollowupSummary = { pushes: 0, emails: 0, nothing: 0, errors: [] }
  if (!opts.push && !opts.email) { s.off = 'neither push (VAPID) nor email (SMTP) is set up'; return s }
  const r = await opts.rpc('followups_due_to_alert', { p_now: (opts.now ?? (() => new Date()))().toISOString() })
  if (r.error) { s.errors.push(r.error.message.slice(0, 200)); return s }
  for (const f of (Array.isArray(r.data) ? r.data : []) as DueFollowup[]) {
    const m = followupMessage(f, opts.appUrl)
    let reached = 0
    if (opts.push) {
      try { const n = await opts.push(f.person, { title: m.title, body: m.body, url: m.url }); s.pushes += n; reached += n }
      catch (e) { s.errors.push(`${f.person} push ${f.task_id.slice(-6)}: ${String(e).slice(0, 160)}`) }
    }
    const mailTo = opts.email && f.email && /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(f.email) ? f.email : null
    if (mailTo) {
      try { await opts.email!({ to: mailTo, subject: m.subject, text: m.text, html: m.html }); s.emails += 1; reached += 1 }
      catch (e) { s.errors.push(`${f.person} email ${f.task_id.slice(-6)}: ${String(e).slice(0, 160)}`) }
    }
    if (reached > 0) await opts.rpc('followup_alerted', { p_task_id: f.task_id, p_note: null })
    else if (!opts.push && !mailTo) {
      // nowhere to send it: marked so it does not come up every minute; the task itself is untouched
      s.nothing += 1
      await opts.rpc('followup_alerted', { p_task_id: f.task_id, p_note: `reminder: no phone registered or email on file for ${f.person}` })
    }
  }
  return s
}
