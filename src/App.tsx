import { Navigate, Route, Routes } from 'react-router-dom'
import { useAuth } from '@/providers/AuthProvider'
import { AppShell } from '@/components/layout/AppShell'
import { Auth } from '@/routes/Auth'
import Dashboard from '@/routes/Dashboard'
import Prospects from '@/routes/Prospects'
import Campaigns from '@/routes/Campaigns'
import Tasks from '@/routes/Tasks'
import Settings from '@/routes/Settings'
import './App.css'

function ProtectedRoute({ children }: { children: React.ReactNode }) {
  const { user, loading } = useAuth()
  
  if (loading) {
    return <div className="min-h-screen flex items-center justify-center">Loading...</div>
  }
  
  if (!user) {
    return <Navigate to="/auth" replace />
  }
  
  return <AppShell>{children}</AppShell>
}

function App() {
  const { user, loading } = useAuth()

  if (loading) {
    return <div className="min-h-screen flex items-center justify-center">Loading...</div>
  }

  return (
    <Routes>
      <Route path="/auth" element={<Auth />} />
      <Route path="/dashboard" element={
        <ProtectedRoute>
          <Dashboard />
        </ProtectedRoute>
      } />
      <Route path="/prospects" element={
        <ProtectedRoute>
          <Prospects />
        </ProtectedRoute>
      } />
      <Route path="/campaigns" element={
        <ProtectedRoute>
          <Campaigns />
        </ProtectedRoute>
      } />
      <Route path="/tasks" element={
        <ProtectedRoute>
          <Tasks />
        </ProtectedRoute>
      } />
      <Route path="/settings" element={
        <ProtectedRoute>
          <Settings />
        </ProtectedRoute>
      } />
      <Route path="/" element={
        user ? <Navigate to="/dashboard" replace /> : <Navigate to="/auth" replace />
      } />
      <Route path="*" element={<Navigate to="/" replace />} />
    </Routes>
  )
}

export default App
