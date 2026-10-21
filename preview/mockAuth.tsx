// DEV ONLY: signed in as the owner, for the phone-layout preview.
/* eslint-disable react-refresh/only-export-components */
import type { ReactNode } from 'react'

const value = {
  user: { id: 'u1', email: 'owner@example.com' }, session: null,
  member: { email: 'owner@example.com', role: 'owner', person: 'colin', display_name: 'Colin' },
  memberStatus: 'ok', memberError: null, retryMember: () => {}, loading: false, isOwner: true, recovering: false,
  signInWithPassword: async () => ({ error: null }), sendPasswordLink: async () => ({ error: null }),
  setPassword: async () => ({ error: null }), signOut: async () => {},
}
export function AuthProvider({ children }: { children: ReactNode }) { return <>{children}</> }
export function useAuth() { return value }
