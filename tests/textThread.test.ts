import { describe, expect, it } from 'vitest'
import { textThreadOf } from '@/lib/textThread'
import type { Message, TwilioInbound } from '@/lib/types'

const out = (id: string, at: string, body: string, sid?: string): Message => ({ id, lead_id: 'L', direction: 'out', channel: 'sms', body,
  from_number: '+12624180202', to_number: '+17158965632', status: 'sent', is_opener: false, is_opt_out: false, sent_at: at, seen_at: null, provider_sid: sid })
const inn = (sid: string, at: string, body: string): TwilioInbound => ({ sid, from10: '7158965632', body, is_opt_out: false, lead_id: 'L', received_at: at })

describe('textThreadOf (the card as a phone message log)', () => {
  it('both ways, oldest first, newest last', () => {
    const t = textThreadOf([out('2', '2026-10-24T23:50:00Z', 'Fair question'), out('1', '2026-10-24T23:45:03Z', 'Hi Donald')],
      [inn('SM1', '2026-10-24T23:46:59Z', 'How can I help you')])
    expect(t.map((x) => [x.mine, x.body])).toEqual([[true, 'Hi Donald'], [false, 'How can I help you'], [true, 'Fair question']])
  })
  it('a text in both logs shows once; calls and notes are not texts', () => {
    const m: Message = { ...out('3', '2026-10-24T23:46:59Z', 'How can I help you', 'SM1'), direction: 'in', from_number: '+17158965632', to_number: '+12624180202' }
    const call: Message = { ...out('4', '2026-10-24T23:47:00Z', 'Called'), channel: 'call' }
    const t = textThreadOf([m, call], [inn('SM1', '2026-10-24T23:46:59Z', 'How can I help you')])
    expect(t).toHaveLength(1)
    expect(t[0].mine).toBe(false)
  })
})
