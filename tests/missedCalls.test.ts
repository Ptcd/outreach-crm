// A missed call alerts the caller it is for (0139/0144/0145): email once, WhatsApp once per caller per card per 15 min
// through Meta's Cloud API template (gated on APPROVED), every attempt logged; a caller with no address is marked, not
// retried every minute; an unknown caller still alerts with the number and "unknown property".
import { describe, expect, it } from 'vitest'
import { missedCallEmail, missedCallVars, runMissedCallAlerts, type MissedCall } from '../supabase/functions/_shared/missedCalls'
import { metaConfig, metaWhatsAppSender, templatePayload, templateStatus } from '../supabase/functions/_shared/metaWhatsApp'

const call = (over: Partial<MissedCall> = {}): MissedCall => ({ call_sid: 'CA1', lead_id: 'L1', from10: '4145550101', at: '2026-10-29T22:42:25Z', voicemail: false, vm_verdict: null,
  owner_name: 'DAVID R LASCELLE', address: '646 W PIERCE ST', municipality: 'Milwaukee', person: 'adil', email: 'adil@example.com', display_name: 'Adil', ...over })

// a database stand-in: the alert log with its 15-minute rule, the template cache, the alerted marks
function fakeDb(rows: MissedCall[]) {
  const log: { id: string; call_sid: string; lead_id: string | null; from10: string; person: string; status: string; message_id?: string | null; error?: string | null }[] = []
  const marked: string[] = []
  let tpl: { status: string; checked_at: string } | null = null
  const rpc = async (fn: string, args: Record<string, unknown>) => {
    if (fn === 'missed_calls_to_alert') return { data: rows, error: null }
    if (fn === 'missed_call_alerted') { marked.push(String(args.p_call_sid)); return { data: null, error: null } }
    if (fn === 'whatsapp_alert_begin') {
      const prev = log.find((l) => l.person === args.p_person && ['sent', 'skipped', 'pending'].includes(l.status)
        && (args.p_lead_id ? l.lead_id === args.p_lead_id : (l.lead_id === null && l.from10 === args.p_from10)))
      if (prev) return { data: { ok: false, reason: prev.status === 'sent' ? 'duplicate' : 'recent_' + prev.status }, error: null }
      const id = 'W' + (log.length + 1)
      log.push({ id, call_sid: String(args.p_call_sid), lead_id: (args.p_lead_id as string | null) ?? null, from10: String(args.p_from10), person: String(args.p_person), status: 'pending' })
      return { data: { ok: true, id }, error: null }
    }
    if (fn === 'whatsapp_alert_finish') { const l = log.find((x) => x.id === args.p_id)!; l.status = String(args.p_status); l.message_id = args.p_message_id as string | null; l.error = args.p_error as string | null; return { data: null, error: null } }
    if (fn === 'meta_wa_template_get') return { data: tpl, error: null }
    if (fn === 'meta_wa_template_set') { tpl = { status: String(args.p_status), checked_at: new Date().toISOString() }; return { data: null, error: null } }
    return { data: null, error: { message: 'no such rpc ' + fn } }
  }
  return { rpc, log, marked, setTemplate: (s: string, at = new Date().toISOString()) => { tpl = { status: s, checked_at: at } } }
}

describe('missed-call emails and template variables', () => {
  it('says who called, when, the voicemail verdict, and links the card', () => {
    const m = missedCallEmail(call({ voicemail: true, vm_verdict: 'seller' }), 'https://deals.example/')
    expect(m.subject).toBe('Missed call: DAVID R LASCELLE (646 W PIERCE ST, Milwaukee)')
    expect(m.text).toContain('called (414) 555-0101 back at 5:42 PM CT')
    expect(m.text).toContain('left a voicemail')
    expect(m.text).toContain('https://deals.example/lead/L1')
    expect(missedCallEmail(call({ vm_verdict: 'stop', voicemail: true }), 'x').text).toContain('do not call back')
    // the Meta template takes who / where / when (Central, no zone suffix); unknown caller = number + unknown property
    expect(missedCallVars(call(), 'https://deals.example')).toMatchObject({ '1': 'DAVID R LASCELLE', '2': '646 W PIERCE ST, Milwaukee', '3': '5:42 PM' })
    const u = call({ lead_id: null, owner_name: null, address: null, municipality: null })
    expect(missedCallVars(u, 'https://deals.example')).toMatchObject({ '1': '(414) 555-0101', '2': 'unknown property', '5': 'https://deals.example' })
    expect(missedCallEmail(u, 'https://deals.example').text).toContain('No card has this number yet')
  })
})

describe('runMissedCallAlerts', () => {
  it('emails each caller once and marks the call; no address on file is marked too; a failed send is left for next minute', async () => {
    const sent: { to: string; subject: string }[] = []
    const rows = [call(), call({ call_sid: 'CA2', person: 'thalia', email: null }), call({ call_sid: 'CA3', email: 'boom@example.com' })]
    const f = fakeDb(rows)
    const email = async (m: { to: string; subject: string }) => { if (m.to.startsWith('boom')) throw new Error('smtp down'); sent.push({ to: m.to, subject: m.subject }) }
    const s = await runMissedCallAlerts({ rpc: f.rpc, email, appUrl: 'https://deals.example' })
    expect(sent).toEqual([{ to: 'adil@example.com', subject: 'Missed call: DAVID R LASCELLE (646 W PIERCE ST, Milwaukee)' }])
    expect(f.marked).toEqual(['CA1', 'CA2'])
    expect(s).toMatchObject({ emails: 1, no_email: 1 })
    expect(s.errors[0]).toContain('smtp down')
    expect(await runMissedCallAlerts({ rpc: f.rpc, email: null, appUrl: 'x' })).toMatchObject({ off: expect.stringContaining('email') })
  })

  it('WhatsApp: sent once per caller per card, logged with the message id; a second call on the same card inside 15 minutes is suppressed', async () => {
    const rows = [call({ whatsapp: '+923246343665', voicemail: true, vm_verdict: 'seller' }), call({ call_sid: 'CA2', email: null, whatsapp: '+923246343665' })]
    const f = fakeDb(rows)
    const wa: { to: string; vars: Record<string, string> }[] = []
    const whatsapp = async (to: string, _text: string, vars: Record<string, string>) => { wa.push({ to, vars }); return { ok: true, id: 'wamid.1' } }
    const s = await runMissedCallAlerts({ rpc: f.rpc, email: async () => {}, whatsapp, appUrl: 'https://deals.example' })
    expect(s).toMatchObject({ emails: 1, whatsapps: 1, suppressed: 1, errors: [] })
    expect(wa).toHaveLength(1)
    expect(wa[0].vars).toMatchObject({ '1': 'DAVID R LASCELLE', '2': '646 W PIERCE ST, Milwaukee', '3': '5:42 PM' })
    expect(f.log).toEqual([expect.objectContaining({ call_sid: 'CA1', status: 'sent', message_id: 'wamid.1' })])
    expect(f.marked).toEqual(['CA1', 'CA2'])   // the duplicate counts as reached: Adil already has this card's alert
  })

  it('WhatsApp: a template still in review is skipped (logged, not an error) and a Meta failure is logged and retried', async () => {
    const f = fakeDb([call({ call_sid: 'CA5', email: null, whatsapp: '+639753125183', person: 'thalia' })])
    const skip = async () => ({ ok: false, skipped: true, error: 'template missed_call_alert is PENDING' })
    const s1 = await runMissedCallAlerts({ rpc: f.rpc, email: null, whatsapp: skip, appUrl: 'x' })
    expect(s1).toMatchObject({ whatsapps: 0, whatsapp_skipped: 1, errors: [] })
    expect(f.log[0]).toMatchObject({ status: 'skipped', error: expect.stringContaining('PENDING') })
    expect(f.marked).toEqual([])   // not reached: tried again later
    // next minute, still pending: the skipped row holds the slot, no new log row
    const s2 = await runMissedCallAlerts({ rpc: f.rpc, email: null, whatsapp: skip, appUrl: 'x' })
    expect(s2).toMatchObject({ suppressed: 1, whatsapp_skipped: 0 })
    expect(f.log).toHaveLength(1)
    const g = fakeDb([call({ call_sid: 'CA6', email: null, whatsapp: '+639753125183', person: 'thalia' })])
    const down = async () => ({ ok: false, error: 'meta 401: Invalid OAuth access token' })
    const s3 = await runMissedCallAlerts({ rpc: g.rpc, email: null, whatsapp: down, appUrl: 'x' })
    expect(s3.errors[0]).toContain('401')
    expect(g.log[0]).toMatchObject({ status: 'failed', error: expect.stringContaining('401') })
    expect(g.marked).toEqual([])
  })
})

describe('Meta Cloud API sender', () => {
  const env = (o: Record<string, string>) => (n: string) => o[n]
  const CFG = { META_WHATSAPP_TOKEN: 'tok', META_WA_PHONE_NUMBER_ID: '1360870210447247', META_WABA_ID: '2330456737707324' }

  it('is off without the token or sender id; defaults the template and version', () => {
    expect(metaConfig(env({}))).toBeNull()
    expect(metaConfig(env({ META_WHATSAPP_TOKEN: 'tok' }))).toBeNull()
    expect(metaConfig(env(CFG))).toMatchObject({ template: 'missed_call_alert', version: 'v21.0', wabaId: '2330456737707324' })
  })

  it('builds the template payload Meta expects: digits only, three body parameters, no newlines', () => {
    const p = templatePayload(metaConfig(env(CFG))!, '+92 324 6343665', { '1': 'DAVID R LASCELLE', '2': '646 W PIERCE ST,\nMilwaukee', '3': '5:42 PM' })
    expect(p).toEqual({ messaging_product: 'whatsapp', to: '923246343665', type: 'template',
      template: { name: 'missed_call_alert', language: { code: 'en_US' }, components: [{ type: 'body', parameters: [
        { type: 'text', text: 'DAVID R LASCELLE' }, { type: 'text', text: '646 W PIERCE ST, Milwaukee' }, { type: 'text', text: '5:42 PM' }] }] } })
    expect(templatePayload(metaConfig(env(CFG))!, '639753125183', {}).template.components[0].parameters.map((x) => x.text)).toEqual(['unknown caller', 'unknown property', 'just now'])
  })

  it('polls the template status at most every 10 minutes and caches it; sends only when APPROVED', async () => {
    const f = fakeDb([])
    const calls: { url: string; init?: RequestInit }[] = []
    let status = 'PENDING'
    const fetchFn = (async (url: string, init?: RequestInit) => {
      calls.push({ url, init })
      if (url.includes('/message_templates')) return new Response(JSON.stringify({ data: [{ name: 'missed_call_alert', status, language: 'en_US' }] }), { status: 200 })
      return new Response(JSON.stringify({ messages: [{ id: 'wamid.HBg' }] }), { status: 200 })
    }) as unknown as typeof fetch
    const cfg = metaConfig(env(CFG))!
    expect(await templateStatus(cfg, f.rpc, fetchFn)).toEqual({ status: 'PENDING', source: 'meta' })
    expect(await templateStatus(cfg, f.rpc, fetchFn)).toEqual({ status: 'PENDING', source: 'cache' })   // within 10 minutes: no second poll
    expect(calls.filter((c) => c.url.includes('message_templates'))).toHaveLength(1)
    expect(calls[0].url).toContain('/v21.0/2330456737707324/message_templates?name=missed_call_alert')
    expect((calls[0].init?.headers as Record<string, string>).authorization).toBe('Bearer tok')
    const send = metaWhatsAppSender(env(CFG), fetchFn, f.rpc)!
    expect(await send('+639753125183', 'text', { '1': 'a', '2': 'b', '3': 'c' })).toMatchObject({ ok: false, skipped: true, error: expect.stringContaining('PENDING') })
    // the cache ages out, Meta now says APPROVED: the send goes through to the sender's messages endpoint
    f.setTemplate('PENDING', new Date(Date.now() - 11 * 60_000).toISOString()); status = 'APPROVED'
    const r = await send('+639753125183', 'text', { '1': 'DAVID R LASCELLE', '2': '646 W PIERCE ST', '3': '5:42 PM' })
    expect(r).toEqual({ ok: true, id: 'wamid.HBg' })
    const post = calls.find((c) => c.init?.method === 'POST')!
    expect(post.url).toBe('https://graph.facebook.com/v21.0/1360870210447247/messages')
    expect(JSON.parse(post.init!.body as string)).toMatchObject({ to: '639753125183', template: { name: 'missed_call_alert' } })
    // a Meta error comes back as a plain failure
    const bad = (async () => new Response(JSON.stringify({ error: { message: 'Invalid OAuth access token', code: 190 } }), { status: 401 })) as unknown as typeof fetch
    f.setTemplate('APPROVED')
    expect(await metaWhatsAppSender(env(CFG), bad, f.rpc)!('639753125183', 't', {})).toMatchObject({ ok: false, error: expect.stringContaining('401 #190') })
  })

  it('a WABA id missing or a Meta outage keeps the last known status instead of guessing APPROVED', async () => {
    const f = fakeDb([])
    const cfg = metaConfig(env({ META_WHATSAPP_TOKEN: 'tok', META_WA_PHONE_NUMBER_ID: '1' }))!
    expect(await templateStatus(cfg, f.rpc, fetch)).toMatchObject({ status: 'UNKNOWN', source: 'error' })
    f.setTemplate('APPROVED', new Date(Date.now() - 11 * 60_000).toISOString())
    const down = (async () => { throw new Error('ENOTFOUND') }) as unknown as typeof fetch
    expect(await templateStatus(metaConfig(env(CFG))!, f.rpc, down)).toMatchObject({ status: 'APPROVED', source: 'error' })
  })
})
