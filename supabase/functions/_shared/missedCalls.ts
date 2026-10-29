// A missed call emails the caller it is for (Colin 2026-10-29: "have it email them when a missed call comes to
// them"). Every minute the reply agent asks missed_calls_to_alert (migration 0139) for seller calls nobody picked
// up whose call-back task belongs to Thalia or Adil, emails that person (alert email, else sign-in email), and marks
// the call alerted. Colin already gets the forwarding app's text on his cell. The card is first in Power hour anyway;
// the email makes sure the caller knows while they are looking elsewhere.
type Rpc = (fn: string, args: Record<string, unknown>) => Promise<{ data: unknown; error: { message: string } | null }>

export interface MissedCall {
  call_sid: string; lead_id: string; from10: string; at: string; voicemail: boolean | null; vm_verdict: string | null
  owner_name: string | null; address: string | null; municipality: string | null; person: string; email: string | null; whatsapp?: string | null; display_name: string | null
}
export interface MissedSummary { emails: number; whatsapps: number; no_email: number; errors: string[]; off?: string }

/** A WhatsApp send through the forwarding app (channel whatsapp): text plus the template variables for outside the 24-hour window. */
export type WhatsAppSend = (to: string, text: string, vars: Record<string, string>) => Promise<{ ok: boolean; error?: string }>

const fmtPhone = (d: string) => (/^\d{10}$/.test(d) ? `(${d.slice(0, 3)}) ${d.slice(3, 6)}-${d.slice(6)}` : d)
const fmtTime = (iso: string) =>
  new Date(iso).toLocaleTimeString('en-US', { timeZone: 'America/Chicago', hour: 'numeric', minute: '2-digit' })

/** The approved WhatsApp template's variables, in order: who, where, when, voicemail line, card link. */
export function missedCallVars(c: MissedCall, appUrl: string): Record<string, string> {
  const who = c.owner_name || fmtPhone(c.from10)
  const where = [c.address, c.municipality].filter(Boolean).join(', ') || 'no address on the card'
  const vm = c.vm_verdict === 'stop' ? 'Their voicemail asked us to stop: do not call back.'
    : c.vm_verdict === 'wrong_person' ? 'Their voicemail says we have the wrong person.'
    : c.vm_verdict === 'upset' ? 'Their voicemail was upset: tell Colin before calling.'
    : c.vm_verdict === 'not_seller' ? 'Their voicemail says they are not a seller.'
    : c.voicemail ? 'They left a voicemail; it is on the card.' : 'No voicemail.'
  return { '1': who, '2': where, '3': `${fmtTime(c.at)} CT`, '4': vm, '5': `${appUrl.replace(/\/+$/, '')}/lead/${c.lead_id}` }
}

export function missedCallEmail(c: MissedCall, appUrl: string): { subject: string; text: string; html: string } {
  const who = c.owner_name || fmtPhone(c.from10)
  const where = [c.address, c.municipality].filter(Boolean).join(', ')
  const vm = c.vm_verdict === 'stop' ? 'Their voicemail asked us to stop: do not call back.'
    : c.vm_verdict === 'wrong_person' ? 'Their voicemail says we have the wrong person.'
    : c.vm_verdict === 'upset' ? 'Their voicemail was upset: tell Colin before calling.'
    : c.vm_verdict === 'not_seller' ? 'Their voicemail says they are not a seller.'
    : c.voicemail ? 'They left a voicemail; it is on the card.' : 'No voicemail.'
  const url = `${appUrl.replace(/\/+$/, '')}/lead/${c.lead_id}`
  const line = `Missed call: ${who}${where ? ` (${where})` : ''} called ${fmtPhone(c.from10)} back at ${fmtTime(c.at)} CT and nobody picked up. ${vm}`
  const esc = (x: string) => x.replace(/[&<>]/g, (ch) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[ch] as string))
  return {
    subject: `Missed call: ${who}${where ? ` (${where})` : ''}`,
    text: `${line}\n\nThey are first in your Power hour. Open the card: ${url}`,
    html: `<p>${esc(line)}</p><p>They are first in your Power hour. <a href="${url}">Open the card</a></p>`,
  }
}

/** Email each caller their missed calls, once per call. A failed email is retried next minute; a caller with no
 * email at all is marked so the call does not come up every minute. */
export async function runMissedCallAlerts(opts: { rpc: Rpc; email: ((m: { to: string; subject: string; text: string; html: string }) => Promise<void>) | null
  whatsapp?: WhatsAppSend | null; appUrl: string; now?: () => Date }): Promise<MissedSummary> {
  const s: MissedSummary = { emails: 0, whatsapps: 0, no_email: 0, errors: [] }
  if (!opts.email && !opts.whatsapp) { s.off = 'neither email (SMTP) nor WhatsApp is set up'; return s }
  const r = await opts.rpc('missed_calls_to_alert', { p_now: (opts.now ?? (() => new Date()))().toISOString() })
  if (r.error) { s.errors.push(r.error.message.slice(0, 200)); return s }
  for (const c of (Array.isArray(r.data) ? r.data : []) as MissedCall[]) {
    const mailTo = opts.email && c.email && /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(c.email) ? c.email : null
    const waTo = opts.whatsapp && c.whatsapp && /^\+\d{8,15}$/.test(c.whatsapp) ? c.whatsapp : null
    if (!mailTo && !waTo) {
      s.no_email += 1
      await opts.rpc('missed_call_alerted', { p_call_sid: c.call_sid, p_note: `no email or WhatsApp on file for ${c.person}` })
      continue
    }
    let reached = 0
    if (mailTo) {
      try { await opts.email!({ to: mailTo, ...missedCallEmail(c, opts.appUrl) }); s.emails += 1; reached += 1 }
      catch (e) { s.errors.push(`${c.person} email ${c.call_sid.slice(-6)}: ${String(e).slice(0, 160)}`) }
    }
    if (waTo) {
      const m = missedCallEmail(c, opts.appUrl)
      const r2 = await opts.whatsapp!(waTo, m.text, missedCallVars(c, opts.appUrl)).catch((e) => ({ ok: false, error: String(e) }))
      if (r2.ok) { s.whatsapps += 1; reached += 1 }
      else s.errors.push(`${c.person} whatsapp ${c.call_sid.slice(-6)}: ${String(r2.error ?? 'not sent').slice(0, 160)}`)
    }
    // marked once anything got through; a call nothing reached is tried again next minute
    if (reached > 0) await opts.rpc('missed_call_alerted', { p_call_sid: c.call_sid, p_note: null })
  }
  return s
}
