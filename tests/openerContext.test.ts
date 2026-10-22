// The first reply depends on what our first text asked (WPIE wpie/reply/brain.py _OPENER_ASKED_SELLING_RE,
// prompt.py dynamic block): a question-only opener gets the pitch on a yes; an old-style opener that
// already asked about selling makes a yes interest, so the pitch question is never asked twice.
import { describe, expect, it } from 'vitest'
import { decide, openerAskedSelling } from '../supabase/functions/_shared/replyBrain'
import { conversationContext } from '../supabase/functions/_shared/drafter'

const Q_ONLY = "Hi Laurie, it's Colin Merrill from Mequon. Is the place on N Main St still yours? No worries if not, just reply STOP."
const OLD = "Hi Laurie, Colin Merrill here. I'd like to buy your house at 3424 N Main St as-is. Any interest in selling? Reply STOP to opt out."
const ctx = (opener: string) => ({ inbound: 'yes', priorInbound: [], lastAgentText: opener, propertyAddress: '3424 N Main St', ownerName: 'LAURIE ROE', ourTurns: 0 })

describe('what the opener asked', () => {
  it('spots an opener that already asked about selling', () => {
    expect(openerAskedSelling(Q_ONLY)).toBe(false)
    expect(openerAskedSelling(OLD)).toBe(true)
    expect(openerAskedSelling('We buy houses for cash')).toBe(true)
    expect(openerAskedSelling(null)).toBe(false)
  })

  it('pitches a yes to a question-only opener, but not a yes to an opener that already asked', () => {
    expect(decide(ctx(Q_ONLY))).toMatchObject({ kind: 'routine', reply: expect.stringMatching(/Would you ever consider selling/) })
    expect(decide(ctx(OLD))).toMatchObject({ kind: 'candidate', reply: null })
  })

  it('quotes the opener in the drafter context and says whether the pitch was already made', () => {
    const base = { inbound: 'yes', ownerName: 'LAURIE ROE', propertyAddress: '3424 N Main St' }
    const q = conversationContext({ ...base, history: [{ who: 'us', body: Q_ONLY }] })
    expect(q).toContain(`Colin's first text was: "${Q_ONLY}"`)
    expect(q).toMatch(/only asked whether the place is still theirs/)
    const o = conversationContext({ ...base, history: [{ who: 'us', body: OLD }] })
    expect(o).toMatch(/already asked about selling, so a yes is interest: do NOT ask whether they would consider selling again/)
    expect(conversationContext({ ...base, history: [] })).not.toMatch(/How this thread started/)
  })
})
