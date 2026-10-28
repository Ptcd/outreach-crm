// What the reply agent turns into a Task for a person (Adil), and what it must not.
import { describe, expect, it } from 'vitest'
import data from '../supabase/functions/_shared/replyRedteam.generated.json'
import { workNeeded } from '../supabase/functions/_shared/needsWork'

describe('workNeeded', () => {
  it.each([
    ['Can you email me the details? bob@example.com', 'email'],
    ['Send it to my business email', 'email'],
    ['send me an offer in writing', 'send_docs'],
    ['Can you send pictures of what you buy?', 'send_docs'],
    ['can I send you photos?', 'send_docs'],
    ['Do you have proof of funds?', 'records'],
    ['Can you send me the comps you used', 'records'],
    ['proof of funds?', 'records'],
    ['Talk to my attorney', 'contact_other'],
    ["I'm 80, call my daughter instead", 'contact_other'],
    ["You'll have to talk to my power of attorney", 'contact_other'],
    ['Interested. When can you come see it?', 'appointment'],
  ])('%s -> %s', (text, kind) => {
    expect(workNeeded(text)?.kind).toBe(kind)
  })
  it('keeps the address they gave', () => {
    expect(workNeeded('email me at Bob.Smith@Example.com please')).toMatchObject({ kind: 'email', email: 'Bob.Smith@Example.com' })
  })
  it.each([
    "I'll report back after I talk to my wife",
    "don't text my husband, he doesn't know yet",
    'Maybe, what would you pay?',
    'who is this?',
    'not interested',
    'The roof is old and the tenant leaves in March',
    // mentioning a record is not asking for one (Colin 2026-10-28)
    "I'd have to look and see where everything is, but the last tax bill said FMV was $441K, and with all the work we're doing, I'm thinking closer to $500-525K.",
    'The appraisal came in at 300 last year',
  ])('no task for: %s', (text) => {
    expect(workNeeded(text)).toBeNull()
  })
  it('flags only a handful of the 440 red-team texts', () => {
    const hits = (data.rows as { text: string }[]).filter((r) => workNeeded(r.text))
    expect(hits.length).toBeLessThanOrEqual(12)
  })
})
