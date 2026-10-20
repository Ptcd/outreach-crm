import { createContext, useContext, useEffect, useState, type ReactNode } from 'react'
import type { Session, User } from '@supabase/supabase-js'
import { supabase, supabaseConfigured } from '@/lib/supabaseClient'
import type { TeamMember } from '@/lib/types'

interface AuthContextType {
  user: User | null
  session: Session | null
  member: TeamMember | null // null = signed in but not on the team (or still loading)
  loading: boolean
  isOwner: boolean
  sendMagicLink: (email: string) => Promise<{ error: string | null }>
  signOut: () => Promise<void>
}

const AuthContext = createContext<AuthContextType | undefined>(undefined)

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null)
  const [member, setMember] = useState<TeamMember | null>(null)
  const [loading, setLoading] = useState(supabaseConfigured)

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
    const { data: sub } = supabase.auth.onAuthStateChange((_event, s) => {
      // defer: calling Supabase inside this callback can deadlock the auth client
      setTimeout(() => void load(s), 0)
    })
    return () => {
      alive = false
      sub.subscription.unsubscribe()
    }
  }, [])

  const sendMagicLink = async (email: string) => {
    const { error } = await supabase.auth.signInWithOtp({
      email: email.trim().toLowerCase(),
      // only people Colin has added in Supabase can sign in; no self sign-up
      options: { shouldCreateUser: false, emailRedirectTo: window.location.origin },
    })
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
        sendMagicLink,
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
