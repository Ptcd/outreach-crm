// A missed call alerts the caller it belongs to (Colin 2026-10-29: "have it email them when a missed call comes to
// them"; 2026-10-30: WhatsApp through Meta's Cloud API, build spec). Every minute the reply agent asks
// missed_calls_to_alert (0139/0144/0145) for seller calls nobody picked up whose call-back belongs to Thalia or Adil
// (the task owner, else whoever dialed that number out, else the shift), emails that person's alert address, sends the
// WhatsApp template, and marks the call alerted once anything got through. Colin already gets the forwarding app's text
// on his cell. The card is first in Power hour anyway; the alert makes sure the caller knows while they are looking
// elsewhere. A call from a number no card knows still alerts, with the number and "unknown property" (0145).
type Rpc = (fn: string, args: Record<string, unknown>) => Promise<{ data: unknown; error: { message: string } | null }>

export interface MissedCall {
  call_sid: string; lead_id: string | null; from10: string; at: string; voicemail: boolean | null; vm_verdict: string | null
  owner_name: string | null; address: string | null; municipality: string | null; person: string; email: string | null; whatsapp?: string | null; display_name: string | null
}
export interface MissedSummary { emails: number; whatsapps: number; whatsapp_skipped: number; suppressed: number; no_email: number; errors: string[]; off?: string }

/** A WhatsApp send (Meta Cloud API template, or the forwarding app's sandbox route): the plain text plus the template
 * variables. `skipped` means the template is not approved yet: not an error, try again later. */
export type WhatsAppSend = (to: string, text: string, vars: Record<string, string>) => Promise<{ ok: boolean; id?: string | null; error?: string; skipped?: boolean }>

const fmtPhone = (d: string) => (/^\d{10}$/.test(d) ? `(${d.slice(0, 3)}) ${d.slice(3, 6)}-${d.slice(6)}` : d)
const fmtTime = (iso: string) =>
  new Date(iso).toLocaleTimeString('en-US', { timeZone: 'America/Chicago', hour: 'numeric', minute: '2-digit' })

const vmLine = (c: MissedCall) => c.vm_verdict === 'stop' ? 'Their voicemail asked us to stop: do not call back.'
  : c.vm_verdict === 'wrong_person' ? 'Their voicemail says we have the wrong person.'
  : c.vm_verdict === 'upset' ? 'Their voicemail was upset: tell Colin before calling.'
  : c.vm_verdict === 'not_seller' ? 'Their voicemail says they are not a seller.'
  : c.voicemail ? 'They left a voicemail; it is on the card.' : 'No voicemail.'
const cardUrl = (c: MissedCall, appUrl: string) => c.lead_id ? `${appUrl.replace(/\/+$/, '')}/lead/${c.lead_id}` : appUrl.replace(/\/+$/, '')

/** The missed_call_alert template's variables, in order: who (name or number), where, when (Central, "4:42 PM");
 * 4 and 5 (voicemail line, card link) ride along for the sandbox route's longer template. */
export function missedCallVars(c: MissedCall, appUrl: string): Record<string, string> {
  const who = c.owner_name || fmtPhone(c.from10)
  const where = [c.address, c.municipality].filter(Boolean).join(', ') || 'unknown property'
  return { '1': who, '2': where, '3': fmtTime(c.at), '4': vmLine(c), '5': cardUrl(c, appUrl) }
}

export function missedCallEmail(c: MissedCall, appUrl: string): { subject: string; text: string; html: string } {
  const who = c.owner_name || fmtPhone(c.from10)
  const where = [c.address, c.municipality].filter(Boolean).join(', ')
  const url = cardUrl(c, appUrl)
  const line = `Missed call: ${who}${where ? ` (${where})` : ''} called ${fmtPhone(c.from10)} back at ${fmtTime(c.at)} CT and nobody picked up. ${vmLine(c)}`
  const esc = (x: string) => x.replace(/[&<>]/g, (ch) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[ch] as string))
  const tail = c.lead_id ? 'They are first in your Power hour.' : 'No card has this number yet: check Today for the unknown caller.'
  const link = c.lead_id ? 'Open the card' : 'Open the app'
  return {
    subject: `Missed call: ${who}${where ? ` (${where})` : ''}`,
    text: `${line}\n\n${tail} ${link}: ${url}`,
    html: `<p>${esc(line)}</p><p>${esc(tail)} <a href="${url}">${link}</a></p>`,
  }
}

/** Alert each caller to their missed calls, once per call. A failed send is retried next minute; a caller with no
 * address at all is marked so the call does not come up every minute. WhatsApp goes through whatsapp_alert_begin /
 * whatsapp_alert_finish (0145): one alert per caller per card per 15 minutes, every attempt logged. */
export async function runMissedCallAlerts(opts: { rpc: Rpc; email: ((m: { to: string; subject: string; text: string; html: string }) => Promise<void>) | null
  whatsapp?: WhatsAppSend | null; appUrl: string; now?: () => Date }): Promise<MissedSummary> {
  const s: MissedSummary = { emails: 0, whatsapps: 0, whatsapp_skipped: 0, suppressed: 0, no_email: 0, errors: [] }
  if (!opts.email && !opts.whatsapp) { s.off = 'neither email (SMTP) nor WhatsApp is set up'; return s }
  const r = await opts.rpc('missed_calls_to_alert', { p_now: (opts.now ?? (() => new Date()))().toISOString() })
  if (r.error) { s.errors.push(r.error.message.slice(0, 200)); return s }
  for (const c of (Array.isArray(r.data) ? r.data : []) as MissedCall[]) {
    const mailTo = opts.email && c.email && /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(c.email) ? c.email : null
    const waTo = opts.whatsapp && c.whatsapp && /^\+?\d{8,15}$/.test(c.whatsapp) ? c.whatsapp : null
    if (!mailTo && !waTo) {
      s.no_email += 1
      await opts.rpc('missed_call_alerted', { p_call_sid: c.call_sid, p_note: `no email or WhatsApp on file for ${c.person}` })
      continue
    }
    let reached = 0
    const m = missedCallEmail(c, opts.appUrl)
    if (mailTo) {
      try { await opts.email!({ to: mailTo, ...m }); s.emails += 1; reached += 1 }
      catch (e) { s.errors.push(`${c.person} email ${c.call_sid.slice(-6)}: ${String(e).slice(0, 160)}`) }
    }
    if (waTo) {
      const vars = missedCallVars(c, opts.appUrl)
      const b = await opts.rpc('whatsapp_alert_begin', { p_call_sid: c.call_sid, p_lead_id: c.lead_id, p_from10: c.from10, p_person: c.person, p_to: waTo, p_params: { '1': vars['1'], '2': vars['2'], '3': vars['3'] } })
      const bd = (b.data ?? {}) as { ok?: boolean; id?: string; reason?: string }
      if (b.error) s.errors.push(`${c.person} whatsapp ${c.call_sid.slice(-6)}: ${b.error.message.slice(0, 160)}`)
      else if (!bd.ok) {
        // the caller already has an alert for this card from the last 15 minutes: that counts as reached
        s.suppressed += 1
        if (bd.reason === 'duplicate') reached += 1
      } else {
        const r2: Awaited<ReturnType<WhatsAppSend>> = await opts.whatsapp!(waTo, m.text, vars).catch((e) => ({ ok: false, error: String(e) }))
        if (r2.ok) { s.whatsapps += 1; reached += 1; await opts.rpc('whatsapp_alert_finish', { p_id: bd.id, p_status: 'sent', p_message_id: r2.id ?? null, p_error: null }) }
        else if (r2.skipped) { s.whatsapp_skipped += 1; await opts.rpc('whatsapp_alert_finish', { p_id: bd.id, p_status: 'skipped', p_message_id: null, p_error: r2.error ?? 'skipped' }) }
        else {
          s.errors.push(`${c.person} whatsapp ${c.call_sid.slice(-6)}: ${String(r2.error ?? 'not sent').slice(0, 160)}`)
          await opts.rpc('whatsapp_alert_finish', { p_id: bd.id, p_status: 'failed', p_message_id: null, p_error: r2.error ?? 'not sent' })
        }
      }
    }
    // marked once anything got through; a call nothing reached is tried again next minute
    if (reached > 0) await opts.rpc('missed_call_alerted', { p_call_sid: c.call_sid, p_note: null })
  }
  return s
}
