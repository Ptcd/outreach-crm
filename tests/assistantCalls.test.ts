// The card's "Calls the assistant took": only calls where the seller said something, newest first, in plain words.
import { describe, expect, it } from 'vitest'
import { outcomeWords, spokenCalls, type AssistantCall } from '../src/components/AssistantCalls'

const call = (sid: string, at: string, transcript: AssistantCall['transcript'], outcome = 'callback_booked'): AssistantCall =>
  ({ call_sid: sid, started_at: at, ended_at: at, created_at: at, seconds: 60, outcome, transcript })

describe('the assistant calls shown on a card', () => {
  it('leaves out a call the seller never spoke on, and puts the newest first', () => {
    const rows = [
      call('a', '2026-11-24T15:00:00Z', [{ role: 'agent', text: 'Hi' }, { role: 'caller', text: 'This is Pat' }]),
      call('b', '2026-11-25T15:00:00Z', [{ role: 'agent', text: 'Hi' }, { role: 'agent', text: 'Are you still there?' }], 'hung_up'),
      call('c', '2026-11-25T16:00:00Z', [{ role: 'agent', text: 'Hi' }, { role: 'caller', text: 'Call me back' }]),
      call('d', '2026-11-25T17:00:00Z', null, 'hung_up'),
    ]
    expect(spokenCalls(rows).map((r) => r.call_sid)).toEqual(['c', 'a'])
  })
  it('says the outcome in plain words', () => {
    expect(outcomeWords('callback_booked')).toBe('Call back booked')
    expect(outcomeWords('talked_no_extraction')).toContain('read the words')
    expect(outcomeWords('something_new')).toBe('something new')
    expect(outcomeWords(null)).toBe('Ended')
  })
})
