// Someone else's stop on the owner's phone blocks that phone only; the owner's card stays open (Colin 2026-10-27:
// "System should automatically add these ones to do not contact for that phone number, keep card open").
import { describe, expect, it } from 'vitest'
import { decide, saysWrongPerson } from '../supabase/functions/_shared/replyBrain'

const ctx = (inbound: string) => ({ inbound, priorInbound: [], lastAgentText: "Hello Nora, my name is Colin Merrill. Are you still the owner of 1219 W Greenfield Av?", propertyAddress: '1219 W Greenfield Av', ownerName: 'NORA V VAZQUEZ' })

describe('a stop from someone who is not the owner', () => {
  it.each([
    'Wrong number, STOP',
    "I've told y'all this isn't Nora number. Yall are making me sick. Leave me alone",
    "hello colin, the number you found on the internet for the property owner doesn't belong to her.  please remove from your database  ty",
  ])('blocks this phone only: %s', (text) => {
    const d = decide(ctx(text))
    expect(d.removal).toBe(true)
    expect(d.kind).toBe('removal')
    expect(d.outcome).toBe('wrong_number')
    expect(d.intent).toBe('wrong_number')
  })

  it.each([
    'STOP',
    'Get fucked. Scammer',
    'This a personal home ,not a rental stop',
    "Keeping it. I don't know how you got my number or know anything about my house. DO NOT TEXT ME AGAIN!",
    'Stop texting me, this is my number and I am not selling',
  ])('the owner asking to stop still closes the card: %s', (text) => {
    const d = decide(ctx(text))
    expect(d.removal).toBe(true)
    expect(d.outcome).toBe('dnc')
  })

  it('reads voicemail words the same way', () => {
    expect(saysWrongPerson('Please erase my number out of your system 414-322-8092. There is no nor at this number. Please stop calling me')).toBe(true)
    expect(saysWrongPerson('Please stop calling me about my house')).toBe(false)
  })
})
