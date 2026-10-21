import { createContext, useContext, useEffect, useState, type ReactNode } from 'react'
import type { Session, User } from '@supabase/supabase-js'
import { appLoginEmail, supabase, supabaseConfigured } from '@/lib/supabaseClient'
import type { TeamMember } from '@/lib/types'

interface AuthContextType {
  user: User | null
  session: Session | null
  member: TeamMember | null // null = signed in but not on the team (or still loading)
  loading: boolean
  isOwner: boolean
  recovering: boolean // opened from a "set the app password" email: show the new-password form
  signInWithPassword: (password: string) => Promise<{ error: string | null }>
  sendPasswordLink: () => Promise<{ error: string | null }>
  setPassword: (password: string) => Promise<{ error: string | null }>
  signOut: () => Promise<void>
}

const AuthContext = createContext<AuthContextType | undefined>(undefined)

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null)
  const [member, setMember] = useState<TeamMember | null>(null)
  const [loading, setLoading] = useState(supabaseConfigured)
  const [recovering, setRecovering] = useState(false)

  useEffect(() => {
    if (!supabaseConfigured) return
    let alive = true
    const load = async (s: Session | null) => {
      setSession(s)
      if (!s?.user?.email) {
        setMember(null)
        setLoading(false)
        return
      }
      const { data } = await supabase
        .from('team_members')
        .select('email, role, person, display_name')
        .eq('email', s.user.email.toLowerCase())
        .maybeSingle()
      if (!alive) return
      setMember((data as TeamMember | null) ?? null)
      setLoading(false)
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
  }, [])

  // One shared app account: the login screen asks only for the app password.
  const notSetUp = 'The app account is not set up yet (VITE_WPIE_APP_EMAIL on Vercel, see DEPLOY.md).'
  const signInWithPassword = async (password: string) => {
    if (!appLoginEmail) return { error: notSetUp }
    const { error } = await supabase.auth.signInWithPassword({ email: appLoginEmail, password })
    return { error: error ? (error.message === 'Invalid login credentials' ? 'Wrong password.' : error.message) : null }
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
    await supabase.auth.signOut()
  }

  return (
    <AuthContext.Provider
      value={{
        user: session?.user ?? null,
        session,
        member,
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
