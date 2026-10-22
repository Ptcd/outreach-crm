import type { ReactNode } from 'react'
import { NavLink } from 'react-router-dom'
import { BarChart3, CalendarCheck, Inbox, ListChecks, MessageSquareText } from 'lucide-react'
import { useAuth } from '@/providers/AuthProvider'
import { useRepliesWaiting } from '@/lib/queries'
import { OfflineBanner } from '@/components/OfflineBanner'
import { CallBar } from '@/components/CallBar'
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
  const w = useRepliesWaiting().data
  const waiting = (w?.drafts_waiting ?? 0) + (w?.tasks_open ?? 0)
  const badge = (to: string) => (to === '/inbox' && waiting > 0
    ? <span aria-label={`${waiting} replies waiting`} className="ml-1 rounded-full bg-red-600 px-1.5 text-[11px] font-semibold text-white">{waiting}</span>
    : null)
  return (
    <div className="min-h-dvh bg-muted/40 pb-[calc(4.5rem+env(safe-area-inset-bottom))] sm:pb-0">
      <header className="pt-safe sticky top-0 z-30 border-b bg-background/95 backdrop-blur">
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
                {badge(n.to)}
              </NavLink>
            ))}
          </nav>
          <div className="flex items-center gap-1 text-sm">
            <span className="hidden text-muted-foreground sm:inline">{member?.display_name}</span>
            <button className="h-11 rounded-md px-3 text-muted-foreground underline" onClick={() => void signOut()}>
              Sign out
            </button>
          </div>
        </div>
        <OfflineBanner />
      </header>
      <main className="mx-auto max-w-5xl px-4 py-4">{children}</main>
      <CallBar />
      <nav className="pb-safe fixed inset-x-0 bottom-0 z-30 grid grid-cols-5 border-t bg-background sm:hidden" aria-label="Main">
        {NAV.map((n) => (
          <NavLink
            key={n.to}
            to={n.to}
            className={({ isActive }) =>
              cn('flex min-h-16 flex-col items-center justify-center gap-0.5 text-xs', isActive ? 'font-semibold text-primary' : 'text-muted-foreground')
            }
          >
            <span className="relative">
              <n.icon className="h-6 w-6" aria-hidden />
              {n.to === '/inbox' && waiting > 0 && (
                <span className="absolute -right-2 -top-1 rounded-full bg-red-600 px-1 text-[10px] font-semibold text-white">{waiting}</span>
              )}
            </span>
            {n.label}
          </NavLink>
        ))}
      </nav>
    </div>
  )
}
