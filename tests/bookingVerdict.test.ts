// The card decides whether a visit is earned (Colin 2026-10-22: "we must must must have those things make
// the decision for us if we go for the appointment"), in the terms of Thalia's guide section 7.
import { describe, expect, it } from 'vitest'
import { bookingVerdict } from '../src/lib/bookingVerdict'
import type { CallFacts, CallValue } from '../src/lib/callGate'

const at = '2026-10-22T20:00:00Z'
const facts = (o: Record<string, CallValue>): CallFacts => Object.fromEntries(Object.entries(o).map(([k, value]) => [k, { value, at }]))

// Every pillar in: a reason with a clock, just them, a number they'd hear under, the place known.
const EARNED = {
  identity: { choices: ['owner'] }, motivation: { choices: ['moving'], text: 'job in Madison' }, timeline: { choices: ['under_30'] },
  decision_makers: { choices: ['only_them'] }, ready: { choices: ['yes'] },
  price: { number: '180000' }, anchor: { choices: ['own_need'] }, flexibility: { choices: ['open'] },
  occupancy: { choices: ['owner'] }, condition: { choices: ['roof'], text: 'roof is 25 years old' },
}

describe('the booking verdict', () => {
  it('says nothing until the questions are answered, and lists what is still to ask', () => {
    const v = bookingVerdict({}, {})
    expect(v.verdict).toBe('open')
    expect(v.still).toEqual(["why they're selling", "where they're headed, and when", 'who else would weigh in', 'their number', 'who lives there', 'the condition, in their words'])
    expect(v.because).toEqual([])
  })

  it('books when every pillar is in, and says why', () => {
    const v = bookingVerdict(facts(EARNED), {})
    expect(v.verdict).toBe('book')
    expect(v.because).toEqual([
      'A reason: Moving', 'A clock: Within 30 days', 'Just them to sign',
      'A number on the table, and open to hearing one under it', "Who lives there and what's wrong, in their words",
    ])
    expect(v.next).toMatch(/When's a good time for us to come by/)
  })

  it('what the seller texted counts as answered', () => {
    const reply = { motivation: 'tired of tenants', timeline: 'this spring', decision_makers: 'just me', price_expectation: '150k', occupancy: 'tenant', condition: 'needs a roof' }
    const v = bookingVerdict(facts({ flexibility: { choices: ['moved'] } }), reply)
    // Named by text but not yet asked whether they can be at the visit: that one question is left.
    expect(v.verdict).toBe('open')
    expect(v.still).toEqual(['whether every signer can be at the visit'])
    expect(bookingVerdict(facts({ flexibility: { choices: ['moved'] }, ready: { choices: ['yes'] } }), reply).verdict).toBe('book')
  })

  it('"only for the right price" is a no, before anything else is asked', () => {
    const v = bookingVerdict(facts({ motivation: { choices: ['just_price'] } }), {})
    expect(v.verdict).toBe('no')
    expect(v.because).toEqual(['No reason to sell beyond "the right price"'])
    expect(v.next).toMatch(/not-ready close/)
  })

  it('a market number held firm is a no; firm on a payoff is still a book', () => {
    const firmMarket = bookingVerdict(facts({ ...EARNED, anchor: { choices: ['online'] }, flexibility: { choices: ['firm'] } }), {})
    expect(firmMarket.verdict).toBe('no')
    expect(firmMarket.because).toEqual(["A market number they won't hear under"])
    const firmNeed = bookingVerdict(facts({ ...EARNED, flexibility: { choices: ['firm'] } }), {})
    expect(firmNeed.verdict).toBe('book')
    expect(firmNeed.because).toContain('Firm, but the number rests on a real need')
  })

  it('a spouse not lined up is one more call, naming them', () => {
    const v = bookingVerdict(facts({ ...EARNED, decision_makers: { choices: ['spouse'], text: 'Dana' }, ready: { choices: ['spouse'] } }), {})
    expect(v.verdict).toBe('call_back')
    expect(v.because).toEqual(['Dana has to be on the next call or at the visit'])
    expect(v.next).toMatch(/call back inside two days/)
  })

  it('a reason with no date, no number after two asks, or wanting to think: one more call', () => {
    expect(bookingVerdict(facts({ ...EARNED, timeline: { choices: ['no_plan'] } }), {}).because).toEqual(['A reason, but no date or event behind it yet'])
    expect(bookingVerdict(facts({ ...EARNED, price: { choices: ['refused'] } }), {}).because).toEqual(['No number after two asks'])
    const think = bookingVerdict(facts({ ...EARNED, ready: { choices: ['think'] } }), {})
    expect(think.verdict).toBe('call_back')
    expect(think.because).toEqual(['Wants to think it over'])
  })

  it('an estate without its signer, or an ill owner without the family, waits for them', () => {
    const estate = bookingVerdict(facts({ ...EARNED, decision_makers: { choices: ['estate'] }, ready: { choices: ['spouse'] } }), {})
    expect(estate.verdict).toBe('call_back')
    expect(estate.because[0]).toMatch(/signs for the estate/)
    const ill = bookingVerdict(facts({ ...EARNED, motivation: { choices: ['health'] }, decision_makers: { choices: ['family'], text: 'her son Mark' }, ready: { choices: ['spouse'] } }), {})
    expect(ill.verdict).toBe('call_back')
    expect(ill.because).toEqual(['Health or age: her son Mark on the line before any visit'])
  })

  it('hard stops win: a sale inside 14 days, listed, a tenant, asked to be removed', () => {
    expect(bookingVerdict(facts({ ...EARNED, behind: { choices: ['sale_14'] } }), {}).because[0]).toMatch(/inside 14 days/)
    expect(bookingVerdict(facts({ ...EARNED, identity: { choices: ['agent'] } }), {}).because).toEqual(['Listed, or signed with another buyer'])
    expect(bookingVerdict(facts({ ...EARNED, identity: { choices: ['tenant'] } }), {}).because).toEqual(["They're the tenant, not the owner"])
    const dnc = bookingVerdict(facts(EARNED), {}, { stage: 'dnc' })
    expect(dnc.verdict).toBe('no')
    expect(dnc.next).toMatch(/Do not contact/)
  })

  it('a refused-once number or "make me an offer" is still open: ask again', () => {
    const v = bookingVerdict(facts({ ...EARNED, price: { choices: ['make_offer'] } }), {})
    expect(v.verdict).toBe('open')
    expect(v.still).toEqual(['their number'])
  })

  it("never holds or prints Colin's number", () => {
    const v = bookingVerdict(facts(EARNED), {})
    expect(JSON.stringify(v)).not.toMatch(/\$\s?\d/)
  })
})
