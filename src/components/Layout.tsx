import type { ReactNode } from 'react'
import { NavLink } from 'react-router-dom'
import { BarChart3, CalendarCheck, Inbox, ListChecks, MessageSquareText } from 'lucide-react'
import { useAuth } from '@/providers/AuthProvider'
import { cn } from '@/lib/utils'

const NAV = [
  { to: '/today', label: 'Today', icon: CalendarCheck },
  { to: '/inbox', label: 'Inbox', icon: Inbox },
  { to: '/pipeline', label: 'Pipeline', icon: ListChecks },
  { to: '/approvals', label: 'Approve', icon: MessageSquareText },
  { to: '/scoreboard', label: 'Scoreboard', icon: BarChart3 },
]

export function Layout({ children }: { children: ReactNode }) {
  const { member, signOut } = useAuth()
  return (
    <div className="min-h-screen bg-muted/40 pb-20 sm:pb-0">
      <header className="sticky top-0 z-10 border-b bg-background/95 backdrop-blur">
        <div className="mx-auto flex h-14 max-w-5xl items-center justify-between px-4">
          <span className="font-semibold">WPIE</span>
          <nav className="hidden gap-1 sm:flex">
            {NAV.map((n) => (
              <NavLink
                key={n.to}
                to={n.to}
                className={({ isActive }) =>
                  cn('rounded-md px-3 py-2 text-sm', isActive ? 'bg-primary text-primary-foreground' : 'hover:bg-accent')
                }
              >
                {n.label}
              </NavLink>
            ))}
          </nav>
          <div className="flex items-center gap-3 text-sm">
            <span className="text-muted-foreground">{member?.display_name}</span>
            <button className="underline" onClick={() => void signOut()}>
              Sign out
            </button>
          </div>
        </div>
      </header>
      <main className="mx-auto max-w-5xl px-4 py-4">{children}</main>
      <nav className="fixed inset-x-0 bottom-0 z-10 grid grid-cols-5 border-t bg-background sm:hidden">
        {NAV.map((n) => (
          <NavLink
            key={n.to}
            to={n.to}
            className={({ isActive }) =>
              cn('flex flex-col items-center gap-0.5 py-2 text-xs', isActive ? 'text-primary' : 'text-muted-foreground')
            }
          >
            <n.icon className="h-5 w-5" aria-hidden />
            {n.label}
          </NavLink>
        ))}
      </nav>
    </div>
  )
}
