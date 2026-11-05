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
const esc = (x: string) => x.replace(/[&<>]/g, (ch) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[ch] as string))

export function followupMessage(f: DueFollowup, appUrl: string): { title: string; body: string; url: string; subject: string; text: string; html: string } {
  const who = f.owner_name || 'a seller'
  const where = [f.address, f.municipality].filter(Boolean).join(', ')
  const url = f.lead_id ? `${appUrl.replace(/\/+$/, '')}/lead/${f.lead_id}` : appUrl.replace(/\/+$/, '')
  // a heads-up from the other caller (0186/0187): the title is "Heads-up from X", the body is what they wrote
  if (f.kind === 'nudge') {
    const title = `${f.title || 'Heads-up'}: ${who}`
    const body = `${f.note || ''}${where ? ` (${where})` : ''}`
    return { title, body, url, subject: title, text: `${title}\n${body}\n\nOpen the card: ${url}`,
      html: `<p><strong>${esc(title)}</strong></p><p>${esc(body)}</p><p><a href="${url}">Open the card</a></p>` }
  }
  const what = KIND[f.kind] ?? f.title
  const title = `${what} at ${fmtTime(f.due_at)}: ${who}`
  const body = `${where || 'no address on the card'}${f.note ? `. ${f.note}` : ''}`
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

// ---------------------------------------------------------------------------------------------------------------
// The weekly digest (0187; Thalia and Adil 2026-11-04: "a weekly morning digest of This week with the reasons, pushed,
// not found"). Monday 8:00 AM Central, once per caller per week: a push to their phones and an email to their alert
// address. The database keeps the ledger (digest_mark is true once per person per week), so a retry never sends twice.

export interface WeeklyDigest {
  person: string; week_start: string; email: string | null; display_name: string | null
  calls: number; first_three: { name: string | null; address: string | null; when: string; reasons: string[] | null; say: string | null }[]
  resting_waking: number; nudges: number; no_step: number
}
export interface DigestSummary { sent: string[]; skipped: string[]; errors: string[]; off?: string }

/** The Monday (Central) that starts the week `now` is in, as YYYY-MM-DD, when `now` sits in the 8:00-8:10 AM Monday
 *  window; otherwise null. Pure, so it is testable. */
export function digestDue(now: Date): string | null {
  const parts = new Intl.DateTimeFormat('en-US', { timeZone: 'America/Chicago', weekday: 'short', hour: 'numeric', minute: 'numeric', hour12: false,
    year: 'numeric', month: '2-digit', day: '2-digit' }).formatToParts(now)
  const get = (k: string) => parts.find((x) => x.type === k)?.value ?? ''
  if (get('weekday') !== 'Mon') return null
  const hour = Number(get('hour')) % 24, minute = Number(get('minute'))
  if (hour !== 8 || minute >= 10) return null
  return `${get('year')}-${get('month')}-${get('day')}`
}

const fmtDay = (iso: string) => new Date(iso).toLocaleString('en-US', { timeZone: 'America/Chicago', weekday: 'short', hour: 'numeric', minute: '2-digit' })

export function digestMessage(d: WeeklyDigest, appUrl: string): { title: string; body: string; url: string; subject: string; text: string; html: string } {
  const url = `${appUrl.replace(/\/+$/, '')}/mine`
  const names = d.first_three.map((x) => `${x.name || 'a seller'} (${fmtDay(x.when)}${x.reasons?.length ? `: ${x.reasons.slice(0, 2).join(', ')}` : ''})`)
  const lines = [
    `${d.calls} call${d.calls === 1 ? '' : 's'} this week${names.length ? `: ${names.join('; ')}` : ''}`,
    `${d.resting_waking} resting card${d.resting_waking === 1 ? '' : 's'} waking this week`,
    `${d.nudges} heads-up${d.nudges === 1 ? '' : 's'} waiting`,
    `${d.no_step} card${d.no_step === 1 ? '' : 's'} talked to with nothing scheduled`,
  ]
  const title = `This week, ${d.display_name || d.person}: ${d.calls} call${d.calls === 1 ? '' : 's'}, ${d.no_step} with nothing scheduled`
  const body = lines.join('. ') + '.'
  return { title, body, url, subject: title, text: `${title}\n${lines.join('\n')}\n\nMy cards: ${url}`,
    html: `<p><strong>${esc(title)}</strong></p><ul>${lines.map((l) => `<li>${esc(l)}</li>`).join('')}</ul><p><a href="${url}">My cards</a></p>` }
}

export async function runWeeklyDigest(opts: { rpc: Rpc; push: PushTo | null
  email: ((m: { to: string; subject: string; text: string; html: string }) => Promise<void>) | null; appUrl: string; now?: () => Date
  people?: string[] }): Promise<DigestSummary> {
  const s: DigestSummary = { sent: [], skipped: [], errors: [] }
  const now = (opts.now ?? (() => new Date()))()
  const week = digestDue(now)
  if (!week) { s.off = 'not Monday 8:00-8:10 AM Central'; return s }
  if (!opts.push && !opts.email) { s.off = 'neither push (VAPID) nor email (SMTP) is set up'; return s }
  for (const person of opts.people ?? ['thalia', 'adil']) {
    const d = await opts.rpc('weekly_digest', { p_person: person, p_now: now.toISOString() })
    if (d.error || !d.data) { s.errors.push(`${person}: ${d.error?.message?.slice(0, 160) ?? 'no digest'}`); continue }
    const digest = d.data as WeeklyDigest
    const mark = await opts.rpc('digest_mark', { p_person: person, p_week_start: week, p_summary: digest })
    if (mark.error) { s.errors.push(`${person} mark: ${mark.error.message.slice(0, 160)}`); continue }
    if (mark.data !== true) { s.skipped.push(person); continue }
    const m = digestMessage(digest, opts.appUrl)
    let reached = 0
    if (opts.push) {
      try { reached += await opts.push(person, { title: m.title, body: m.body, url: m.url }) }
      catch (e) { s.errors.push(`${person} push: ${String(e).slice(0, 160)}`) }
    }
    const mailTo = opts.email && digest.email && /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(digest.email) ? digest.email : null
    if (mailTo) {
      try { await opts.email!({ to: mailTo, subject: m.subject, text: m.text, html: m.html }); reached += 1 }
      catch (e) { s.errors.push(`${person} email: ${String(e).slice(0, 160)}`) }
    }
    if (reached > 0) s.sent.push(person); else s.errors.push(`${person}: nowhere to send it`)
  }
  return s
}
