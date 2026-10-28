import { createContext, useCallback, useContext, useEffect, useRef, useState, type ReactNode } from 'react'
import type { Session, User } from '@supabase/supabase-js'
import { appLoginEmail, supabase, supabaseConfigured } from '@/lib/supabaseClient'
import { teamEmail, type SignInPerson } from '@/lib/teamCodes'
import type { TeamMember } from '@/lib/types'
import { clearCachedData } from '@/lib/queryClient'

/** Where the team check stands. 'checking' must never be shown as "not on the team" (2026-10-21:
 *  Adil saw that screen while the lookup was still in flight on a phone connection). */
export type MemberStatus = 'idle' | 'checking' | 'ok' | 'none' | 'error'

interface AuthContextType {
  user: User | null
  session: Session | null
  member: TeamMember | null
  memberStatus: MemberStatus
  memberError: string | null
  retryMember: () => void
  loading: boolean
  isOwner: boolean
  recovering: boolean // opened from a "set the app password" email: show the new-password form
  signInWithPassword: (password: string, person?: SignInPerson) => Promise<{ error: string | null }>
  sendPasswordLink: () => Promise<{ error: string | null }>
  setPassword: (password: string) => Promise<{ error: string | null }>
  signOut: () => Promise<void>
}

const AuthContext = createContext<AuthContextType | undefined>(undefined)

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null)
  const [member, setMember] = useState<TeamMember | null>(null)
  const [memberStatus, setMemberStatus] = useState<MemberStatus>('idle')
  const [memberError, setMemberError] = useState<string | null>(null)
  const [loading, setLoading] = useState(supabaseConfigured)
  const [recovering, setRecovering] = useState(false)
  const checkedFor = useRef<string | null>(null)       // the email the current member answer belongs to

  const checkMember = useCallback(async (email: string) => {
    setMemberStatus('checking')
    setMemberError(null)
    let last = ''
    for (let attempt = 0; attempt < 3; attempt++) {        // a weak phone signal gets three tries
      if (attempt) await sleep(800 * attempt)
      const { data, error } = await supabase
        .from('team_members')
        .select('email, role, person, display_name')
        .eq('email', email)
        .maybeSingle()
      if (!error) {
        checkedFor.current = email
        setMember((data as TeamMember | null) ?? null)
        setMemberStatus(data ? 'ok' : 'none')
        return
      }
      last = error.message
    }
    checkedFor.current = null
    setMember(null)
    setMemberError(last || 'no answer from the database')
    setMemberStatus('error')
  }, [])

  useEffect(() => {
    if (!supabaseConfigured) return
    let alive = true
    const load = async (s: Session | null) => {
      if (!alive) return
      setSession(s)
      const email = s?.user?.email?.toLowerCase()
      if (!email) {
        checkedFor.current = null
        setMember(null)
        setMemberStatus('idle')
        setLoading(false)
        return
      }
      setLoading(false)
      // A token refresh (hourly) or the same login again keeps the answer we already have.
      if (checkedFor.current === email) return
      await checkMember(email)
    }
    supabase.auth.getSession().then(({ data }) => load(data.session))
    const { data: sub } = supabase.auth.onAuthStateChange((event, s) => {
      if (event === 'PASSWORD_RECOVERY') setRecovering(true)
      // defer: calling Supabase inside this callback can deadlock the auth client
      setTimeout(() => void load(s), 0)
    })
    return () => {
      alive = false
      sub.subscription.unsubscribe()
    }
  }, [checkMember])

  // A code per person (Colin 2026-10-28): Colin signs in to the app's main account; Thalia and Adil to their own
  // (<person>@team.junkcarsmequon.com, codes set by Colin in Settings), so every call and package is theirs.
  const notSetUp = 'The app account is not set up yet (VITE_WPIE_APP_EMAIL on Vercel, see DEPLOY.md).'
  const signInWithPassword = async (password: string, person: SignInPerson = 'colin') => {
    const email = person === 'colin' ? appLoginEmail : teamEmail(person)
    if (!email) return { error: notSetUp }
    const { error } = await supabase.auth.signInWithPassword({ email, password })
    return { error: error ? (error.message === 'Invalid login credentials' ? 'Wrong code.' : error.message) : null }
  }

  // Emails the app account's owner (Colin) a link that opens this app to set a new password.
  const sendPasswordLink = async () => {
    if (!appLoginEmail) return { error: notSetUp }
    const { error } = await supabase.auth.resetPasswordForEmail(appLoginEmail, { redirectTo: window.location.origin })
    return { error: error ? error.message : null }
  }

  const setPassword = async (password: string) => {
    const { error } = await supabase.auth.updateUser({ password })
    if (!error) setRecovering(false)
    return { error: error ? error.message : null }
  }

  const signOut = async () => {
    checkedFor.current = null
    clearCachedData()
    // Only this phone: Colin's account is open on several phones, so a global sign-out would sign them all out.
    await supabase.auth.signOut({ scope: 'local' })
  }

  const email = session?.user?.email?.toLowerCase()
  return (
    <AuthContext.Provider
      value={{
        user: session?.user ?? null,
        session,
        member,
        memberStatus,
        memberError,
        retryMember: () => { if (email) void checkMember(email) },
        loading,
        isOwner: member?.role === 'owner',
        recovering,
        signInWithPassword,
        sendPasswordLink,
        setPassword,
        signOut,
      }}
    >
      {children}
    </AuthContext.Provider>
  )
}

// eslint-disable-next-line react-refresh/only-export-components
export function useAuth() {
  const ctx = useContext(AuthContext)
  if (!ctx) throw new Error('useAuth must be used within an AuthProvider')
  return ctx
}
