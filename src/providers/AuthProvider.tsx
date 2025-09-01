import { createContext, useContext, useEffect, useState, ReactNode } from 'react'
import type { User, Session } from '@supabase/supabase-js'
import { supabase } from '@/lib/supabaseClient'

interface AuthContextType {
  user: User | null
  session: Session | null
  loading: boolean
  orgId: string | null
  signInWithPassword: (email: string, password: string) => Promise<{ error: any }>
  signUp: (email: string, password: string) => Promise<{ error: any }>
  signOut: () => Promise<void>
}

const AuthContext = createContext<AuthContextType | undefined>(undefined)

interface AuthProviderProps {
  children: ReactNode
}

export function AuthProvider({ children }: AuthProviderProps) {
  const [user, setUser] = useState<User | null>(null)
  const [session, setSession] = useState<Session | null>(null)
  const [loading, setLoading] = useState(true)
  const [orgId, setOrgId] = useState<string | null>(null)

  useEffect(() => {
    // Get initial session
    supabase.auth.getSession().then(({ data: { session } }) => {
      setSession(session)
      setUser(session?.user ?? null)
      setLoading(false)
      if (session?.user) void fetchOrgId(session.user.id)
    })

    // Listen for auth changes
    const { data: { subscription } } = supabase.auth.onAuthStateChange(
      async (event, session) => {
        setSession(session)
        setUser(session?.user ?? null)
        setLoading(false)
        if (session?.user) void fetchOrgId(session.user.id)

        // Create profile and org on first login
        if (event === 'SIGNED_IN' && session?.user) {
          await ensureUserProfile(session.user)
        }
      }
    )

    return () => subscription.unsubscribe()
  }, [])

  const ensureUserProfile = async (user: User) => {
    try {
      // Check if profile exists
      const { data: profile } = await supabase
        .from('profiles')
        .select('*')
        .eq('id', user.id)
        .single()

      if (!profile) {
        // Create org first
        const { data: org, error: orgError } = await supabase
          .from('orgs')
          .insert({
            name: `${user.email}'s Organization`,
            owner: user.id,
          })
          .select()
          .single()

        if (orgError) throw orgError

        // Create profile
        const { error: profileError } = await supabase
          .from('profiles')
          .insert({
            id: user.id,
            org_id: org.id,
            email: user.email,
          })

        if (profileError) throw profileError
      }
      // cache org id
      try {
        const { data } = await supabase
          .from('profiles')
          .select('org_id')
          .eq('id', user.id)
          .single()
        if (data?.org_id) setOrgId(data.org_id)
      } catch (err) {
        console.error('Error fetching org id:', err)
      }
    } catch (error) {
      console.error('Error creating user profile:', error)
    }
  }

  const fetchOrgId = async (userId: string) => {
    try {
      const { data } = await supabase
        .from('profiles')
        .select('org_id')
        .eq('id', userId)
        .single()
      if (data?.org_id) setOrgId(data.org_id)
    } catch (err) {
      console.error('Error retrieving org id:', err)
    }
  }

  const signInWithPassword = async (email: string, password: string) => {
    return await supabase.auth.signInWithPassword({ email, password })
  }

  const signUp = async (email: string, password: string) => {
    return await supabase.auth.signUp({ email, password })
  }

  const signOut = async () => {
    await supabase.auth.signOut()
  }

  const value = {
    user,
    session,
    loading,
    orgId,
    signInWithPassword,
    signUp,
    signOut,
  }

  return (
    <AuthContext.Provider value={value}>
      {children}
    </AuthContext.Provider>
  )
}

export function useAuth() {
  const context = useContext(AuthContext)
  if (context === undefined) {
    throw new Error('useAuth must be used within an AuthProvider')
  }
  return context
}
