// My cards search and chips (0186; Colin 2026-11-04: "build the full shit so the system isnt stupid anymore"; Adil: "a card
// you talked to 6 weeks ago whose name you half remember", "search by phone, words they said").
import { describe, expect, it } from 'vitest'
import { PILES, cardMatches, groupPiles, whyParts, type PileCard } from '../src/lib/piles'

const now = new Date(2026, 10, 4, 12, 0)   // Wed Nov 4 2026, noon
const daysAgo = (n: number) => new Date(now.getTime() - n * 86400_000).toISOString()
const card = (p: Partial<PileCard>): PileCard => ({
  lead_id: 'x', owner_name: 'JANE DOE', address: '123 MAIN ST', municipality: 'Racine', county: 'Racine', stage: 'opener_sent', belt: null,
  pile: 'later', next_at: null, next_what: null, last_call_at: null, last_call: null, why: null, locked_to: 'thalia', tier: null,
  task_id: null, task_kind: null, task_source: null, ...p,
})

describe('My cards search', () => {
  const jane = card({ phones: '4145551234 2625550000', last_words: 'call me after the tenant leaves in March', promise: 'send the comps', say_next: 'ask about the roof', reasons: ['behind on taxes'] })
  it('finds a name, an address, a town', () => {
    expect(cardMatches(jane, { search: 'jane' })).toBe(true)
    expect(cardMatches(jane, { search: 'main st' })).toBe(true)
    expect(cardMatches(jane, { search: 'racine' })).toBe(true)
    expect(cardMatches(jane, { search: 'kenosha' })).toBe(false)
  })
  it('finds a phone by any run of digits, formatted or not', () => {
    expect(cardMatches(jane, { search: '(414) 555-1234' })).toBe(true)
    expect(cardMatches(jane, { search: '5550000' })).toBe(true)
    expect(cardMatches(jane, { search: '999' })).toBe(false)
  })
  it('finds the words they said, what you promised, what to say, a reason', () => {
    expect(cardMatches(jane, { search: 'tenant' })).toBe(true)
    expect(cardMatches(jane, { search: 'comps' })).toBe(true)
    expect(cardMatches(jane, { search: 'roof' })).toBe(true)
    expect(cardMatches(jane, { search: 'taxes' })).toBe(true)
  })
  it('a card with no phones or words still matches by name only', () => {
    const bare = card({ phones: null, last_words: null })
    expect(cardMatches(bare, { search: 'doe' })).toBe(true)
    expect(cardMatches(bare, { search: '414' })).toBe(false)
  })
})

describe('the chips', () => {
  it('talked to in the last 2 weeks / 6 weeks / 3 months, by the last call', () => {
    const recent = card({ last_call_at: daysAgo(3) })
    const sixWeeks = card({ last_call_at: daysAgo(40) })
    const old = card({ last_call_at: daysAgo(120) })
    const never = card({ last_call_at: null })
    expect(cardMatches(recent, { talked: '2w' }, now)).toBe(true)
    expect(cardMatches(sixWeeks, { talked: '2w' }, now)).toBe(false)
    expect(cardMatches(sixWeeks, { talked: '6w' }, now)).toBe(true)
    expect(cardMatches(old, { talked: '3m' }, now)).toBe(false)
    expect(cardMatches(never, { talked: '3m' }, now)).toBe(false)
  })
  it('the lane chip', () => {
    expect(cardMatches(card({ lane: 'flip' }), { lane: 'flip' })).toBe(true)
    expect(cardMatches(card({ lane: 'hold' }), { lane: 'flip' })).toBe(false)
    expect(cardMatches(card({ lane: null }), { lane: 'hold' })).toBe(false)
    expect(cardMatches(card({ lane: null }), { lane: null })).toBe(true)
  })
  it('chips and search stack', () => {
    const c = card({ lane: 'flip', last_call_at: daysAgo(5), last_words: 'maybe in spring' })
    expect(cardMatches(c, { search: 'spring', lane: 'flip', talked: '2w' }, now)).toBe(true)
    expect(cardMatches(c, { search: 'spring', lane: 'hold', talked: '2w' }, now)).toBe(false)
  })
})

describe('the piles', () => {
  it('has a Resting pile before Closed, and groups by pile with the filter', () => {
    const ids = PILES.map((p) => p.id)
    expect(ids.indexOf('resting')).toBe(ids.indexOf('closed') - 1)
    const g = groupPiles([card({ lead_id: 'a', pile: 'resting', rest_until: daysAgo(-30) }), card({ lead_id: 'b', pile: 'call_now', owner_name: 'BOB' })], { search: 'bob' })
    expect(g.resting.map((c) => c.lead_id)).toEqual([])
    expect(g.call_now.map((c) => c.lead_id)).toEqual(['b'])
    expect(groupPiles([card({ lead_id: 'a', pile: 'resting' })]).resting).toHaveLength(1)
  })
  it('the old string form of the filter still works', () => {
    expect(groupPiles([card({ owner_name: 'ANN LEE' })], 'lee').later).toHaveLength(1)
  })
})

describe('why this card', () => {
  it('reads the reasons, their words, the promise and the say line in that order', () => {
    const parts = whyParts(card({ reasons: ['behind on taxes', 'estate'], last_words: 'maybe  in spring', promise: 'call back', say_next: 'ask about the roof' }))
    expect(parts.map((p) => p.label)).toEqual(['Why', 'They said', 'You promised', 'Say'])
    expect(parts[1].text).toBe('“maybe in spring”')
  })
  it('is empty when there is nothing to say', () => {
    expect(whyParts(card({}))).toEqual([])
  })
})
