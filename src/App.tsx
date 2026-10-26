import { Navigate, Route, Routes, useLocation } from 'react-router-dom'
import { useAuth } from '@/providers/AuthProvider'
import { supabaseConfigured } from '@/lib/supabaseClient'
import { Layout } from '@/components/Layout'
import { Button } from '@/components/ui/button'
import Login from '@/pages/Login'
import SetPassword from '@/pages/SetPassword'
import Today from '@/pages/Today'
import Warm from '@/pages/Warm'
import Pipeline from '@/pages/Pipeline'
import LeadDetail from '@/pages/LeadDetail'
import Approvals from '@/pages/Approvals'
import Inbox from '@/pages/Inbox'
import Scoreboard from '@/pages/Scoreboard'
import SignContract from '@/pages/SignContract'
import CallQueue from '@/pages/CallQueue'
import Settings from '@/pages/Settings'

function Centered({ children }: { children: React.ReactNode }) {
  return <div className="flex min-h-dvh items-center justify-center p-6 text-center text-base">{children}</div>
}

export default function App() {
  const { user, member, memberStatus, memberError, retryMember, loading, recovering, signOut } = useAuth()
  const location = useLocation()

  if (!supabaseConfigured) {
    return (
      <Centered>
        <div className="max-w-md space-y-2">
          <h1 className="text-lg font-semibold">WPIE is not connected yet</h1>
          <p>
            Set VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY on the Vercel project (see DEPLOY.md), then redeploy.
          </p>
        </div>
      </Centered>
    )
  }
  // A seller's signing link: no login, no team check.
  if (location.pathname.startsWith('/sign/')) {
    return <Routes><Route path="/sign/:token" element={<SignContract />} /></Routes>
  }
  if (loading) return <Centered>Loading...</Centered>
  if (!user) return <Login />
  if (recovering) return <SetPassword />
  if (memberStatus === 'checking' || memberStatus === 'idle') return <Centered>Signing you in...</Centered>
  if (memberStatus === 'error') {
    const offline = typeof navigator !== 'undefined' && navigator.onLine === false
    return (
      <Centered>
        <div className="max-w-md space-y-3">
          <h1 className="text-lg font-semibold">Signed in, but WPIE could not load your access</h1>
          <p>{offline ? 'This phone is offline. Check the signal or Wi-Fi, then try again.' : 'The connection dropped or the server did not answer.'}</p>
          {memberError && <p className="text-sm text-muted-foreground">Details: {memberError}</p>}
          <div className="flex justify-center gap-2">
            <Button className="h-12 px-6" onClick={retryMember}>Try again</Button>
            <Button className="h-12 px-6" variant="outline" onClick={() => void signOut()}>Sign out</Button>
          </div>
        </div>
      </Centered>
    )
  }
  if (memberStatus === 'none' || !member) {
    return (
      <Centered>
        <div className="max-w-md space-y-3">
          <h1 className="text-lg font-semibold">This login is not on the WPIE team list</h1>
          <p>Signed in as {user.email}, but that address is not in the team list. Colin can add it in Supabase (team_members).</p>
          <Button className="h-12 px-6" variant="outline" onClick={() => void signOut()}>Sign out</Button>
        </div>
      </Centered>
    )
  }

  return (
    <Layout>
      <Routes>
        <Route path="/today" element={<Today />} />
        <Route path="/calls" element={<CallQueue />} />
        <Route path="/settings" element={<Settings />} />
        <Route path="/pipeline" element={<Pipeline />} />
        <Route path="/lead/:id" element={<LeadDetail />} />
        <Route path="/inbox" element={<Inbox />} />
        <Route path="/warm" element={<Warm />} />
        <Route path="/approvals" element={<Approvals />} />
        <Route path="/scoreboard" element={<Scoreboard />} />
        <Route path="*" element={<Navigate to="/today" replace />} />
      </Routes>
    </Layout>
  )
}
