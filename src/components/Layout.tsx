import type { ReactNode } from 'react'
import { NavLink } from 'react-router-dom'
import { BarChart3, CalendarCheck, Home, Inbox, ListChecks, LogOut, MessageSquareText, PhoneCall, Settings as SettingsIcon } from 'lucide-react'
import { useAuth } from '@/providers/AuthProvider'
import { useRepliesWaiting } from '@/lib/queries'
import { OfflineBanner } from '@/components/OfflineBanner'
import { CallBar } from '@/components/CallBar'
import { IncomingCallBar } from '@/components/IncomingCallBar'
import { useDialer } from '@/lib/dialer'
import { cn } from '@/lib/utils'
import { OnPhoneSwitch } from '@/components/OnPhonePicker'

const NAV = [
  { to: '/today', label: 'Today', icon: CalendarCheck },
  { to: '/calls', label: 'Calls', icon: PhoneCall },
  { to: '/inbox', label: 'Inbox', icon: Inbox },
  { to: '/pipeline', label: 'Pipeline', icon: ListChecks },
  { to: '/approvals', label: 'Approve', icon: MessageSquareText },
  { to: '/scoreboard', label: 'Scoreboard', icon: BarChart3 },
]

export function Layout({ children }: { children: ReactNode }) {
  const { member, signOut } = useAuth()
  const { ready } = useDialer()   // registered with Twilio: a seller's call rings in this open app
  const w = useRepliesWaiting().data
  const waiting = (w?.drafts_waiting ?? 0) + (w?.tasks_open ?? 0)
  const badge = (to: string) => (to === '/inbox' && waiting > 0
    ? <span aria-label={`${waiting} replies waiting`} className="ml-1.5 rounded-full bg-rose-500 px-1.5 py-px text-[11px] font-bold text-white shadow-sm">{waiting}</span>
    : null)
  return (
    <div className="min-h-dvh pb-[calc(5rem+env(safe-area-inset-bottom))] md:pb-0">
      <header className="pt-safe sticky top-0 z-30 border-b border-border/60 bg-background/75 backdrop-blur-xl">
        <div className="mx-auto flex h-16 max-w-6xl items-center justify-between gap-3 px-4">
          <NavLink to="/today" className="flex items-center gap-2.5" aria-label="WPIE home">
            <span className="flex h-9 w-9 items-center justify-center rounded-xl bg-gradient-to-br from-[hsl(250_85%_66%)] to-[hsl(232_70%_48%)] text-white shadow-[var(--shadow-lift)]">
              <Home className="h-5 w-5" aria-hidden />
            </span>
            <span className="text-lg font-bold tracking-tight">WPIE</span>
          </NavLink>
          <nav className="hidden items-center gap-0.5 rounded-2xl border border-border/70 bg-card/80 p-1 shadow-[var(--shadow-soft)] md:flex">
            {NAV.map((n) => (
              <NavLink
                key={n.to}
                to={n.to}
                className={({ isActive }) =>
                  cn('flex items-center rounded-xl px-3.5 py-2 text-sm font-medium transition-colors',
                    isActive ? 'bg-primary text-primary-foreground shadow-[var(--shadow-soft)]' : 'text-muted-foreground hover:bg-accent hover:text-accent-foreground')
                }
              >
                {n.label}
                {badge(n.to)}
              </NavLink>
            ))}
          </nav>
          <div className="flex items-center gap-1 text-sm">
            {ready && (
              <span className="flex items-center gap-1.5 rounded-full bg-emerald-50 px-2.5 py-1 text-xs font-medium text-emerald-700 ring-1 ring-inset ring-emerald-200"
                title="Ready for calls: a seller calling the seller line rings here while the app is open">
                <span className="relative flex h-2 w-2" aria-hidden>
                  <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-emerald-400 opacity-60" />
                  <span className="relative inline-flex h-2 w-2 rounded-full bg-emerald-500" />
                </span>
                <span className="sr-only lg:not-sr-only">Ready for calls</span>
              </span>
            )}
            {member?.role === 'caller' && <span className="hidden text-muted-foreground sm:inline">{member?.display_name}</span>}
            <OnPhoneSwitch />
            <NavLink to="/settings" aria-label="Settings" title="Settings: your alert email and phone, notifications"
              className={({ isActive }) => cn('flex h-10 w-10 items-center justify-center rounded-xl transition-colors', isActive ? 'bg-accent text-primary' : 'text-muted-foreground hover:bg-accent hover:text-accent-foreground')}>
              <SettingsIcon className="h-5 w-5" aria-hidden />
            </NavLink>
            <button className="flex h-10 items-center gap-1.5 rounded-xl px-2.5 text-muted-foreground transition-colors hover:bg-accent hover:text-accent-foreground" onClick={() => void signOut()}
              title="Sign out">
              <LogOut className="h-4 w-4" aria-hidden /><span className="hidden lg:inline">Sign out</span><span className="sr-only lg:hidden">Sign out</span>
            </button>
          </div>
        </div>
        <OfflineBanner />
      </header>
      <main className="mx-auto max-w-6xl px-4 py-5 sm:py-6">{children}</main>
      <IncomingCallBar />
      <CallBar />
      <nav className="pb-safe fixed inset-x-0 bottom-0 z-30 grid grid-cols-6 border-t border-border/60 bg-background/85 px-1 backdrop-blur-xl md:hidden" aria-label="Main">
        {NAV.map((n) => (
          <NavLink
            key={n.to}
            to={n.to}
            className={({ isActive }) =>
              cn('group flex min-h-16 flex-col items-center justify-center gap-1 text-[11px] font-medium', isActive ? 'text-primary' : 'text-muted-foreground')
            }
          >
            {({ isActive }) => (<>
            <span className={cn('relative flex h-8 w-14 items-center justify-center rounded-full transition-colors', isActive ? 'bg-accent' : 'group-hover:bg-muted')}>
              <n.icon className="h-[22px] w-[22px]" strokeWidth={isActive ? 2.4 : 2} aria-hidden />
              {n.to === '/inbox' && waiting > 0 && (
                <span className="absolute -top-1 right-1 rounded-full bg-rose-500 px-1 text-[10px] font-bold text-white shadow-sm">{waiting}</span>
              )}
            </span>
            {n.label}
            </>)}
          </NavLink>
        ))}
      </nav>
    </div>
  )
}
