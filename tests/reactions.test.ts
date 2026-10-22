// Phone reactions quote our whole text back, STOP line included (WPIE 2026-10-22: a thumbs-up was
// read as an opt-out). A reaction is never an opt-out: 👍 / Liked means yes, 👎 / Disliked means no
// thanks, anything else is for Colin.
import { describe, expect, it } from 'vitest'
import { isOptOut, reactionKind } from '../supabase/functions/_shared/replyGuard'
import { decide } from '../supabase/functions/_shared/replyBrain'

const OURS = "Hi Gregory, it's Colin Merrill from Mequon. Is the place on S Woodward St still yours? No worries if not, just reply STOP."
const ZW = '\u200b'
const ANDROID_UP = `👍${ZW} to “${ZW}${OURS}${ZW}”`
const IPHONE_LIKED = `Liked “${OURS}”`
const ANDROID_DOWN = `👎 to “${OURS}”`
const IPHONE_DISLIKED = `Disliked “${OURS}”`
const LAUGHED = `Laughed at “${OURS}”`
const QUESTIONED = `Questioned “${OURS}”`
const ctx = (inbound: string) => ({ inbound, priorInbound: [], lastAgentText: OURS, propertyAddress: '2230 S Woodward St', ownerName: 'GREGORY SMITH' })

describe('phone reactions', () => {
  it('are recognised in the Android and iPhone forms, zero-width spaces and all', () => {
    expect(reactionKind(ANDROID_UP)).toBe('positive')
    expect(reactionKind(IPHONE_LIKED)).toBe('positive')
    expect(reactionKind(ANDROID_DOWN)).toBe('negative')
    expect(reactionKind(IPHONE_DISLIKED)).toBe('negative')
    expect(reactionKind(LAUGHED)).toBe('neutral')
    expect(reactionKind(QUESTIONED)).toBe('neutral')
    expect(reactionKind('STOP')).toBe('')
    expect(reactionKind('yes')).toBe('')
  })

  it('are never an opt-out, though the quote carries our STOP line', () => {
    for (const r of [ANDROID_UP, IPHONE_LIKED, ANDROID_DOWN, IPHONE_DISLIKED, LAUGHED, QUESTIONED]) expect(isOptOut(r)).toBe(false)
    expect(isOptOut('STOP')).toBe(true)
    expect(isOptOut(`${ZW}STOP`)).toBe(true)
  })

  it('a thumbs-up or Liked is a yes: the pitch line, never a removal', () => {
    for (const r of [ANDROID_UP, IPHONE_LIKED]) {
      const d = decide(ctx(r))
      expect(d).toMatchObject({ removal: false, kind: 'routine', outcome: 'open' })
      expect(d.reply).toMatch(/^Hi Gregory, thanks for getting back to me\..*Would you ever consider selling that one\?/)
    }
  })

  it('a thumbs-down or Disliked is a no thanks, never a removal; anything else goes to Colin', () => {
    for (const r of [ANDROID_DOWN, IPHONE_DISLIKED]) {
      const d = decide(ctx(r))
      expect(d.removal).toBe(false)
      expect(d.outcome).not.toBe('dnc')
    }
    for (const r of [LAUGHED, QUESTIONED]) {
      expect(decide(ctx(r))).toMatchObject({ kind: 'candidate', removal: false, intent: 'reaction' })
    }
  })
})
