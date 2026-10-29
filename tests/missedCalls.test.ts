// A missed call emails the caller it is for (migration 0139), once; a caller with no email is marked, not retried every minute.
import { describe, expect, it } from 'vitest'
import { missedCallEmail, missedCallVars, runMissedCallAlerts, type MissedCall } from '../supabase/functions/_shared/missedCalls'

const call = (over: Partial<MissedCall> = {}): MissedCall => ({ call_sid: 'CA1', lead_id: 'L1', from10: '4145550101', at: '2026-10-29T22:42:25Z', voicemail: false, vm_verdict: null,
  owner_name: 'DAVID R LASCELLE', address: '646 W PIERCE ST', municipality: 'Milwaukee', person: 'adil', email: 'adil@example.com', display_name: 'Adil', ...over })

describe('missed-call emails', () => {
  it('says who called, when, the voicemail verdict, and links the card', () => {
    const m = missedCallEmail(call({ voicemail: true, vm_verdict: 'seller' }), 'https://deals.example/')
    expect(m.subject).toBe('Missed call: DAVID R LASCELLE (646 W PIERCE ST, Milwaukee)')
    expect(m.text).toContain('called (414) 555-0101 back at 5:42 PM CT')
    expect(m.text).toContain('left a voicemail')
    expect(m.text).toContain('https://deals.example/lead/L1')
    expect(missedCallEmail(call({ vm_verdict: 'stop', voicemail: true }), 'x').text).toContain('do not call back')
  })
  it('emails each caller once and marks the call; no email on file is marked too; a failed send is left for next minute', async () => {
    const sent: { to: string; subject: string }[] = []
    const marked: string[] = []
    const rows = [call(), call({ call_sid: 'CA2', person: 'thalia', email: null }), call({ call_sid: 'CA3', email: 'boom@example.com' })]
    const rpc = async (fn: string, args: Record<string, unknown>) => {
      if (fn === 'missed_calls_to_alert') return { data: rows, error: null }
      if (fn === 'missed_call_alerted') { marked.push(String(args.p_call_sid)); return { data: null, error: null } }
      return { data: null, error: { message: 'no such rpc ' + fn } }
    }
    const email = async (m: { to: string; subject: string }) => { if (m.to.startsWith('boom')) throw new Error('smtp down'); sent.push({ to: m.to, subject: m.subject }) }
    const s = await runMissedCallAlerts({ rpc, email, appUrl: 'https://deals.example' })
    expect(sent).toEqual([{ to: 'adil@example.com', subject: 'Missed call: DAVID R LASCELLE (646 W PIERCE ST, Milwaukee)' }])
    expect(marked).toEqual(['CA1', 'CA2'])
    expect(s).toMatchObject({ emails: 1, no_email: 1 })
    expect(s.errors[0]).toContain('smtp down')
    expect(await runMissedCallAlerts({ rpc, email: null, appUrl: 'x' })).toMatchObject({ off: expect.stringContaining('email') })
  })
  it('a caller with a WhatsApp number gets it there too, with the template variables; WhatsApp alone is enough to mark the call', async () => {
    const wa: { to: string; vars: Record<string, string> }[] = []
    const marked: string[] = []
    const rows = [call({ whatsapp: '+923246343665', voicemail: true, vm_verdict: 'seller' }), call({ call_sid: 'CA2', email: null, whatsapp: '+14145550199' })]
    const rpc = async (fn: string, args: Record<string, unknown>) => {
      if (fn === 'missed_calls_to_alert') return { data: rows, error: null }
      if (fn === 'missed_call_alerted') { marked.push(String(args.p_call_sid)); return { data: null, error: null } }
      return { data: null, error: { message: 'no such rpc ' + fn } }
    }
    const sent: string[] = []
    const email = async (m: { to: string }) => { sent.push(m.to) }
    const whatsapp = async (to: string, _text: string, vars: Record<string, string>) => { wa.push({ to, vars }); return { ok: true } }
    const s = await runMissedCallAlerts({ rpc, email, whatsapp, appUrl: 'https://deals.example' })
    expect(s).toMatchObject({ emails: 1, whatsapps: 2, no_email: 0, errors: [] })
    expect(sent).toEqual(['adil@example.com'])
    expect(wa.map((w) => w.to)).toEqual(['+923246343665', '+14145550199'])
    expect(wa[0].vars).toEqual({ '1': 'DAVID R LASCELLE', '2': '646 W PIERCE ST, Milwaukee', '3': '5:42 PM CT', '4': 'They left a voicemail; it is on the card.', '5': 'https://deals.example/lead/L1' })
    expect(marked).toEqual(['CA1', 'CA2'])
    expect(missedCallVars(call({ address: null, municipality: null }), 'x')['2']).toBe('no address on the card')
    // WhatsApp down and no email: left for next minute, not marked
    const down = async () => ({ ok: false, error: 'pm-phone 503: whatsapp not set up' })
    const s2 = await runMissedCallAlerts({ rpc: async (fn: string) => fn === 'missed_calls_to_alert' ? { data: [rows[1]], error: null } : { data: null, error: null }, email: null, whatsapp: down, appUrl: 'x' })
    expect(s2).toMatchObject({ whatsapps: 0 })
    expect(s2.errors[0]).toContain('not set up')
  })
})
