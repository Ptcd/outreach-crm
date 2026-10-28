// Who signs in (Colin 2026-10-28: a code per person). The twin of supabase/functions/_shared/teamCodes.ts: the
// sign-in screen and the team-codes function must agree on each person's account.

export type SignInPerson = 'colin' | 'thalia' | 'adil'
export const SIGN_IN_PEOPLE: { person: SignInPerson; name: string }[] = [
  { person: 'colin', name: 'Colin' },
  { person: 'thalia', name: 'Thalia' },
  { person: 'adil', name: 'Adil' },
]
export const TEAM_DOMAIN = 'team.junkcarsmequon.com'

/** Thalia's and Adil's own app accounts; Colin's is the app's main account. */
export function teamEmail(person: string): string {
  return `${person.toLowerCase()}@${TEAM_DOMAIN}`
}

/** Why a code won't do, or null (the sign-in service needs at least 6 characters). */
export function teamCodeProblem(code: string): string | null {
  if (code !== code.trim()) return 'No spaces at the start or end.'
  if (code.length < 6) return 'At least 6 characters.'
  if (code.length > 72) return 'At most 72 characters.'
  return null
}

const KEY = 'wpie.signin_as'
export function lastSignIn(): SignInPerson {
  try {
    const v = globalThis.localStorage?.getItem(KEY)
    return v === 'thalia' || v === 'adil' || v === 'colin' ? v : 'colin'
  } catch { return 'colin' }
}
export function rememberSignIn(p: SignInPerson) {
  try { globalThis.localStorage?.setItem(KEY, p) } catch { /* private window */ }
}
