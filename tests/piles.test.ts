import { describe, expect, it } from 'vitest'
import { PILES, groupPiles, type PileCard } from '../src/lib/piles'

const card = (over: Partial<PileCard>): PileCard => ({
  lead_id: 'x', owner_name: 'JANE DOE', address: '12 OAK ST', municipality: 'Racine', county: 'Racine', stage: 'follow_up',
  belt: null, pile: 'call_now', next_at: null, next_what: null, last_call_at: null, last_call: null, why: null, locked_to: null, tier: null, task_id: null, task_kind: null, task_source: null, ...over,
})

describe('my cards piles', () => {
  it('keeps the database order inside each pile and covers every pile', () => {
    const g = groupPiles([card({ lead_id: 'a' }), card({ lead_id: 'b', pile: 'later' }), card({ lead_id: 'c' })])
    expect(Object.keys(g).sort()).toEqual(PILES.map((p) => p.id).sort())
    expect(g.call_now.map((c) => c.lead_id)).toEqual(['a', 'c'])
    expect(g.later.map((c) => c.lead_id)).toEqual(['b'])
  })
  it('searches name, address and town', () => {
    const cards = [card({ lead_id: 'a' }), card({ lead_id: 'b', owner_name: 'BOB ROE', address: '9 ELM ST', municipality: 'Kenosha' })]
    expect(groupPiles(cards, 'elm').call_now.map((c) => c.lead_id)).toEqual(['b'])
    expect(groupPiles(cards, 'racine').call_now.map((c) => c.lead_id)).toEqual(['a'])
  })
  it('puts an unknown pile in talked-nothing-scheduled rather than dropping it', () => {
    expect(groupPiles([card({ pile: 'mystery' as PileCard['pile'] })]).no_step).toHaveLength(1)
  })
})
