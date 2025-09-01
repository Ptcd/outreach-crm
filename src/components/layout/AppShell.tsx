import { ReactNode } from 'react'
import { Navbar } from './Navbar'

interface AppShellProps {
  children: ReactNode
}

export function AppShell({ children }: AppShellProps) {
  return (
    <div className="min-h-screen bg-background">
      <Navbar />
      <main className="container">
        {children}
      </main>
    </div>
  )
}
