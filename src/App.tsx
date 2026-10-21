import { Navigate, Route, Routes } from 'react-router-dom'
import { useAuth } from '@/providers/AuthProvider'
import { supabaseConfigured } from '@/lib/supabaseClient'
import { Layout } from '@/components/Layout'
import Login from '@/pages/Login'
import Today from '@/pages/Today'
import Pipeline from '@/pages/Pipeline'
import LeadDetail from '@/pages/LeadDetail'
import Approvals from '@/pages/Approvals'
import Inbox from '@/pages/Inbox'
import Scoreboard from '@/pages/Scoreboard'

function Centered({ children }: { children: React.ReactNode }) {
  return <div className="flex min-h-screen items-center justify-center p-6 text-center text-sm">{children}</div>
}

export default function App() {
  const { user, member, loading, signOut } = useAuth()

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
  if (loading) return <Centered>Loading...</Centered>
  if (!user) return <Login />
  if (!member) {
    return (
      <Centered>
        <div className="max-w-md space-y-3">
          <p>
            You are signed in as {user.email}, but this email is not on the WPIE team. Ask Colin to add it.
          </p>
          <button className="underline" onClick={() => void signOut()}>
            Sign out
          </button>
        </div>
      </Centered>
    )
  }

  return (
    <Layout>
      <Routes>
        <Route path="/today" element={<Today />} />
        <Route path="/pipeline" element={<Pipeline />} />
        <Route path="/lead/:id" element={<LeadDetail />} />
        <Route path="/inbox" element={<Inbox />} />
        <Route path="/approvals" element={<Approvals />} />
        <Route path="/scoreboard" element={<Scoreboard />} />
        <Route path="*" element={<Navigate to="/today" replace />} />
      </Routes>
    </Layout>
  )
}
