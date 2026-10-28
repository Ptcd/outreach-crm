// A code per person (2026-10-28): the sign-in screen and the team-codes function agree on each account and on what a
// code must be.
import { describe, expect, it } from 'vitest'
import { teamCodeProblem as appProblem, teamEmail as appEmail } from '../src/lib/teamCodes'
import { teamCodeProblem as fnProblem, teamEmail as fnEmail } from '../supabase/functions/_shared/teamCodes'

describe('team codes', () => {
  it('the app and the function name the same account', () => {
    for (const p of ['thalia', 'adil']) expect(appEmail(p)).toBe(fnEmail(p))
    expect(appEmail('Thalia')).toBe('thalia@team.junkcarsmequon.com')
  })
  it('a code needs 6+ characters and no spaces at the ends, in both', () => {
    for (const [code, ok] of [['abc12', false], ['abcdef', true], [' abcdef', false], ['x'.repeat(73), false]] as const) {
      expect(appProblem(code) === null).toBe(ok)
      expect(fnProblem(code) === null).toBe(ok)
    }
  })
})
