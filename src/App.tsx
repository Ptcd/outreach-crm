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
import MyCards from '@/pages/MyCards'
import LeadDetail from '@/pages/LeadDetail'
import Approvals from '@/pages/Approvals'
import Inbox from '@/pages/Inbox'
import Texts from '@/pages/Texts'
import Scoreboard from '@/pages/Scoreboard'
import ResearchBoard from '@/pages/ResearchBoard'
import CallTime from '@/pages/CallTime'
import SignContract from '@/pages/SignContract'
import CallQueue from '@/pages/CallQueue'
import Settings from '@/pages/Settings'
import Privacy from '@/pages/Privacy'

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
  // The privacy page Google's consent screen links to: public.
  if (location.pathname === '/privacy') return <Privacy />
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

  // a caller landing on one of Colin's pages goes to My cards (0186; Colin 2026-11-04: the callers' nav is five pages)
  const caller = member.role === 'caller'
  const colinOnly = (page: React.ReactNode) => (caller ? <Navigate to="/mine" replace /> : page)
  return (
    <Layout>
      <Routes>
        <Route path="/today" element={<Today />} />
        <Route path="/calls" element={<CallQueue />} />
        <Route path="/settings" element={<Settings />} />
        <Route path="/pipeline" element={colinOnly(<Pipeline />)} />
        <Route path="/mine" element={<MyCards />} />
        <Route path="/lead/:id" element={<LeadDetail />} />
        <Route path="/inbox" element={caller ? <Navigate to="/texts" replace /> : <Inbox />} />
        <Route path="/texts" element={<Texts />} />
        <Route path="/warm" element={<Warm />} />
        <Route path="/approvals" element={colinOnly(<Approvals />)} />
        <Route path="/scoreboard" element={colinOnly(<Scoreboard />)} />
        <Route path="/research" element={colinOnly(<ResearchBoard />)} />
        <Route path="/call-time" element={<CallTime />} />
        <Route path="*" element={<Navigate to="/today" replace />} />
      </Routes>
    </Layout>
  )
}
