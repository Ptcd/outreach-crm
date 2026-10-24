// The Inbox's filter chips: which card lands where.
import { describe, expect, it } from 'vitest'
import { bucketOf, nextBusinessMorning, threadOf, type InboxLead } from '@/lib/inbox'
import type { LeadStage, Message, ReplyThread } from '@/lib/types'

function card(stage: LeadStage, o: { msgs?: Partial<Message>[]; thread?: Partial<ReplyThread>; next?: string | null; inbound?: boolean } = {}): InboxLead {
  return {
    opener: { id: 'P', plan_date: '2026-10-21', wpie_owner_id: 1, attempt: 1, lead_id: 'L', lane: 'hold', template_lane: 'hold', variant: 'A',
      phone: '+14145550100', body: 'Hi. reply STOP', segments: 1, scheduled_at: '2026-10-21T15:00:00Z', owner_name: 'A', property_address: 'X',
      decision: 'approved', decided_by_name: null, decided_at: null, decision_note: null, send_status: 'sent', send_reason: null,
      claimed_at: null, sent_at: '2026-10-21T15:00:00Z', error_code: null },
    lead: { id: 'L', owner_name: 'A', property_address: 'X', stage, next_action_at: o.next ?? null, next_action: null, assigned_to: null, dead_reason: null },
    messages: (o.msgs ?? []).map((m, i) => ({ id: `M${i}`, lead_id: 'L', direction: 'in', channel: 'sms', body: 'yes', from_number: null,
      to_number: null, status: null, is_opener: false, is_opt_out: false, sent_at: '2026-10-21T16:00:00Z', seen_at: null, ...m }) as Message),
    thread: o.thread ? ({ phone10: '4145550100', lead_id: 'L', intent: null, agent_stage: 'interest', outcome: null, human_owned: false,
      handoff_flag: null, callback_slot: null, facts: {}, suggested_reply: null, suggestion_note: null, last_inbound_at: null, last_inbound: null, ...o.thread }) : null,
    inbound: o.inbound ? [{ sid: 'SM1', from10: '4145550100', body: 'yes', is_opt_out: false, lead_id: 'L', received_at: '2026-10-21T16:03:00Z' }] : [],
  }
}

describe('bucketOf', () => {
  it('no reply yet', () => expect(bucketOf(card('opener_sent'))).toBe('waiting'))
  it('the reply AI is still talking', () => expect(bucketOf(card('ai_qualifying', { msgs: [{}], thread: {} }))).toBe('ai'))
  it('a human took over, or no AI thread', () => {
    expect(bucketOf(card('reply_received', { msgs: [{}], thread: { human_owned: true } }))).toBe('needs_me')
    expect(bucketOf(card('reply_received', { msgs: [{}] }))).toBe('needs_me')
    expect(bucketOf(card('opener_sent', { inbound: true }))).toBe('needs_me')
  })
  it('a call or walk is booked', () => {
    expect(bucketOf(card('colin_call', { msgs: [{}], next: '2026-10-23T15:00:00Z' }))).toBe('booked')
    expect(bucketOf(card('walkthrough_booked', { msgs: [{}] }))).toBe('booked')
    expect(bucketOf(card('ai_qualifying', { msgs: [{}], thread: { callback_slot: 'Thu after 5' } }))).toBe('booked')
  })
  it('dead, DNC, or a STOP anywhere', () => {
    expect(bucketOf(card('dead', { msgs: [{}] }))).toBe('dead')
    expect(bucketOf(card('ai_qualifying', { msgs: [{ is_opt_out: true, body: 'STOP' }], thread: {} }))).toBe('dead')
    expect(bucketOf(card('reply_received', { msgs: [{}], thread: { outcome: 'close_not_interested' } }))).toBe('dead')
  })
})

describe('threadOf', () => {
  it('shows a reply the server saw once, even after WPIE records it too', () => {
    expect(threadOf(card('reply_received', { msgs: [{ body: 'yes' }], inbound: true })).filter((l) => l.who === 'them')).toHaveLength(1)
    expect(threadOf(card('opener_sent', { inbound: true })).map((l) => l.who)).toEqual(['us', 'them'])
  })
})

describe('nextBusinessMorning', () => {
  it('skips the weekend', () => {
    expect(nextBusinessMorning(new Date('2026-10-23T18:00:00Z'))).toBe('2026-10-26T10:00')   // Friday -> Monday
    expect(nextBusinessMorning(new Date('2026-10-21T18:00:00Z'))).toBe('2026-10-22T10:00')
  })
})

describe('Adil 2026-10-24: replies on top, names not numbers, the whole history', () => {
  const base = (id: string, sent: string, inbound: { at: string; body: string }[] = []) => ({
    opener: { id, lead_id: id, sent_at: sent, scheduled_at: sent, send_status: 'delivered' } as never,
    lead: null, thread: null, drafts: [],
    messages: inbound.map((m, i) => ({ id: `${id}-${i}`, lead_id: id, direction: 'in', channel: 'sms', body: m.body, sent_at: m.at,
      from_number: null, to_number: null, status: null, is_opener: false, is_opt_out: false, seen_at: null })) as never,
    inbound: [],
  })
  it('puts owners who replied first, newest reply on top', async () => {
    const { inboxOrder } = await import('../src/lib/inbox')
    const rows = [
      base('quiet-new', '2026-10-24T15:00:00Z'),
      base('old-reply', '2026-10-21T15:00:00Z', [{ at: '2026-10-22T10:00:00Z', body: 'not now' }]),
      base('new-reply', '2026-10-20T15:00:00Z', [{ at: '2026-10-24T09:00:00Z', body: 'yes' }]),
    ]
    expect([...rows].sort(inboxOrder).map((r) => r.opener.id)).toEqual(['new-reply', 'old-reply', 'quiet-new'])
  })
  it('names the person in the history and merges every kind of contact', async () => {
    const { firstNameOf, timelineOf } = await import('../src/lib/inbox')
    expect(firstNameOf('PATRICIA C GARRITY TRUSTEE')).toBe('Patricia')
    expect(firstNameOf('MANZ, GILBERT J JR')).toBe('Gilbert')
    expect(firstNameOf('ACME HOLDINGS LLC')).toBe('')
    const items = timelineOf({
      ownerName: 'MARK J KRUPSKI & PATRICIA',
      messages: [
        { id: '1', lead_id: 'L', direction: 'out', channel: 'sms', body: 'Hey Mark', sent_at: '2026-10-23T15:00:00Z', from_number: null, to_number: null, status: 'delivered', is_opener: true, is_opt_out: false, seen_at: null },
        { id: '2', lead_id: 'L', direction: 'out', channel: 'call', body: 'left a message', sent_at: '2026-10-24T15:00:00Z', from_number: null, to_number: null, status: null, is_opener: false, is_opt_out: false, seen_at: null },
      ],
      inbound: [{ sid: 'SM1', from10: '4145550000', body: 'Mark passed', is_opt_out: false, lead_id: 'L', received_at: '2026-10-23T23:26:00Z' }],
      stageEvents: [{ id: 9, from_stage: 'reply_received', to_stage: 'dead', at: '2026-10-24T16:00:00Z', source: 'app' }],
    })
    expect(items.map((i) => i.title)).toEqual(['Moved to dead', 'Call with Mark', 'Text from Mark', 'First text to Mark'])
    expect(items.some((i) => /\d{3}/.test(i.title))).toBe(false)
  })
})

describe('the call panel (Colin 2026-10-24: "Where is the place to call")', () => {
  it('calls the number they texted from, and ticks the pillars from the call script and their texts', async () => {
    const { bestPhone, pillarsDone } = await import('../src/components/CallPanel')
    const c = (id: string, v: string, line = 'landline') => ({ id, kind: 'phone', value: v, value_normalized: v, line_type: line, status: 'ok',
      suppressed: false, dnc_app: false, person_name: null }) as never
    const contacts = [c('a', '8472498108', 'mobile'), c('b', '2626390214')]
    expect((bestPhone(contacts, [{ sid: 'S', from10: '2626390214', body: 'We are looking to get it ready to sell', is_opt_out: false, lead_id: 'L', received_at: '2026-10-24T21:19:55Z' }]) as { id: string }).id).toBe('b')
    expect((bestPhone(contacts, []) as { id: string }).id).toBe('a')
    const done = pillarsDone({ motivation: { value: { text: 'tired of it' }, at: 'x' } } as never, { timeline: 'by spring' })
    expect(done).toMatchObject({ motivation: true, timeline: true, condition: false, price: false })
  })
})
