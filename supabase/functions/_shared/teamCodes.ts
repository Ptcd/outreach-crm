// Who signs in, and with what (Colin 2026-10-28: a code per person). Shared by the team-codes function and the app's
// sign-in screen, so both agree on each person's account.

export const TEAM_PEOPLE = [
  { person: 'thalia', name: 'Thalia' },
  { person: 'adil', name: 'Adil' },
] as const

export const TEAM_DOMAIN = 'team.junkcarsmequon.com'

/** Thalia's and Adil's own app accounts. Colin's stays the app's main account (VITE_WPIE_APP_EMAIL). */
export function teamEmail(person: string): string {
  return `${person.toLowerCase()}@${TEAM_DOMAIN}`
}

/** Why a code won't do, or null. At least 6 characters (the sign-in service's own minimum), no spaces at the ends. */
export function teamCodeProblem(code: string): string | null {
  if (code !== code.trim()) return 'no spaces at the start or end'
  if (code.length < 6) return 'at least 6 characters'
  if (code.length > 72) return 'at most 72 characters'
  return null
}
