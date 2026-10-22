// Colin's correction text for owner 91999 (approved 2026-10-22) must pass the approve-time wording checks.
import { describe, expect, it } from 'vitest'
import { guardDraft } from '../supabase/functions/_shared/replyGuard'

const TEXT = "Gregory, Colin here. Sorry, my system misread your 👍 as a stop. If you'd ever consider selling 2230 S Woodward St, I'd be glad to talk. If not, no worries, and I won't text again."

describe('correction text', () => {
  it('passes the price/offer/business-name checks unchanged', () => {
    const g = guardDraft(TEXT, { companyName: 'Merrill Holdings', maxChars: 480 })
    expect(g.violations.filter((v) => v === 'price_or_offer' || v === 'names_company' || v === 'mentions_postcard')).toEqual([])
  })
})
