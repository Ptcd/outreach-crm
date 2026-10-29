// A missed call emails the caller it is for (migration 0139), once; a caller with no email is marked, not retried every minute.
import { describe, expect, it } from 'vitest'
import { missedCallEmail, runMissedCallAlerts, type MissedCall } from '../supabase/functions/_shared/missedCalls'

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
})
