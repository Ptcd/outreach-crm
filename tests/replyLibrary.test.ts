// The reply library: ~1,000 everyday seller replies and what should happen to each (replyLibraryScore.ts).
// Severity 1, never allowed: a removal request not honoured, or a hot alert for a reply that is not hot.
// Everything else the rules still get wrong is listed in the fixture (known_miss), like the red team's
// known failures: a fix that makes a known miss pass fails this test until the fixture is refreshed
// (WPIE: python -m tests.test_reply_library --refresh, then tools/export_reply_prompt.py --app-dir).
import { describe, expect, it } from 'vitest'
import library from '../supabase/functions/_shared/replyLibrary.generated.json'
import { scoreRow, type LibraryRow } from './replyLibraryScore'

const rows = (library as { rows: LibraryRow[] }).rows
const scored = rows.map(scoreRow)

describe('the reply library', () => {
  it('has the everyday replies in it', () => {
    expect(rows.length).toBeGreaterThan(900)
  })

  it('honours every removal request', () => {
    expect(scored.filter((s) => s.misses.includes('stop')).map((s) => s.row.text)).toEqual([])
  })

  it('never sends a hot alert for a reply that is not hot (a yes that only confirms, a later, a no)', () => {
    expect(scored.filter((s) => s.misses.includes('hot')).map((s) => `${s.row.id} [${s.intent}] ${s.row.text}`)).toEqual([])
  })

  it('every other miss is a known one, and a fixed one is taken off the list', () => {
    const now = scored.filter((s) => s.misses.length).map((s) => `${s.row.id} ${[...s.misses].sort().join(',')}`)
    const known = rows.filter((r) => r.known_miss?.length).map((r) => `${r.id} ${[...(r.known_miss ?? [])].sort().join(',')}`)
    expect(now.sort()).toEqual(known.sort())
  })
})
