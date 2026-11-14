import { useEffect, useState, type ReactNode } from 'react'
import { NavLink, useLocation } from 'react-router-dom'
import { BarChart3, CalendarCheck, ClipboardList, CheckCheck, Clock, Flame, FolderKanban, Home, Inbox, ListChecks, LogOut, MessageSquareText, Moon, MoreHorizontal, PhoneCall, Settings as SettingsIcon, Sun } from 'lucide-react'
import { useTheme } from '@/lib/theme'
import { useAuth } from '@/providers/AuthProvider'
import { useRepliesWaiting } from '@/lib/queries'
import { OfflineBanner } from '@/components/OfflineBanner'
import { CallAlertsNudge } from '@/components/CallAlertsNudge'
import { CallBar } from '@/components/CallBar'
import { IncomingCallBar } from '@/components/IncomingCallBar'
import { StayAwake } from '@/components/StayAwake'
import { useDialer } from '@/lib/dialer'
import { cn } from '@/lib/utils'
import { OnPhoneSwitch } from '@/components/OnPhonePicker'

// a caller's nav is the five pages she works (Colin 2026-11-04: "build the full shit so the system isnt stupid anymore";
// Thalia: "a caller's nav has Approve, Scoreboard and Pipeline"): Today, My cards, Calls, Texts, Warm. Colin keeps the rest.
// On a phone the bar at the bottom holds at most six. Colin's eleven did not fit (2026-11-14: "Why are there so many
// tabs at the bottom", every label cut to two letters), so his bar is the four marked `phone` and a More button that
// opens the rest.
const PHONE_BAR_MAX = 6
const NAV_ALL: { to: string; label: string; short?: string; icon: typeof CalendarCheck; caller?: boolean; phone?: boolean }[] = [
  { to: '/today', label: 'Today', icon: CalendarCheck, caller: true, phone: true },
  { to: '/mine', label: 'My cards', short: 'Mine', icon: FolderKanban, caller: true },
  { to: '/calls', label: 'Calls', icon: PhoneCall, caller: true, phone: true },
  { to: '/inbox', label: 'Inbox', icon: Inbox, phone: true },
  { to: '/texts', label: 'Texts', icon: MessageSquareText, caller: true },
  { to: '/warm', label: 'Warm', icon: Flame, caller: true },
  { to: '/pipeline', label: 'Pipeline', short: 'Pipe', icon: ListChecks },
  { to: '/approvals', label: 'Approve', short: 'Approve', icon: CheckCheck, phone: true },
  { to: '/scoreboard', label: 'Scoreboard', short: 'Score', icon: BarChart3 },
  // where every research source stands (0213, Colin 2026-11-10); Muse and the desk tick it, Colin reads it
  { to: '/research', label: 'Research', short: 'Research', icon: ClipboardList },
  // call time, Sat-Fri, per caller (Colin 2026-11-06); a caller sees only her own week
  { to: '/call-time', label: 'Call time', short: 'Time', icon: Clock, caller: true },
]

export function Layout({ children }: { children: ReactNode }) {
  const { member, signOut } = useAuth()
  const NAV = member?.role === 'caller' ? NAV_ALL.filter((n) => n.caller) : NAV_ALL
  const { ready } = useDialer()   // registered with Twilio: a seller's call rings in this open app
  // the phone's bottom bar: everything when it fits, else the four marked `phone` and More
  const crowded = NAV.length > PHONE_BAR_MAX
  const BAR = crowded ? NAV.filter((n) => n.phone) : NAV
  const REST = crowded ? NAV.filter((n) => !n.phone) : []
  const [more, setMore] = useState(false)
  const { pathname } = useLocation()
  useEffect(() => { setMore(false) }, [pathname])
  const inRest = REST.some((n) => pathname === n.to || pathname.startsWith(n.to + '/'))
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
            <StayAwake />
            <OnPhoneSwitch />
            <ThemeButton />
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
        <CallAlertsNudge />
      </header>
      <main className="mx-auto max-w-6xl px-4 py-5 sm:py-6">{children}</main>
      <IncomingCallBar />
      <CallBar />
      {more && REST.length > 0 && (<>
        <button type="button" aria-label="Close the menu" className="fixed inset-0 z-30 bg-black/40 md:hidden" onClick={() => setMore(false)} />
        <div role="menu" aria-label="More pages"
          className="fixed inset-x-2 bottom-[calc(4.75rem+env(safe-area-inset-bottom))] z-40 grid grid-cols-2 gap-1 rounded-2xl border border-border bg-background p-2 shadow-2xl md:hidden">
          {REST.map((n) => (
            <NavLink key={n.to} to={n.to} role="menuitem" onClick={() => setMore(false)}
              className={({ isActive }) => cn('flex min-h-14 items-center gap-3 rounded-xl px-3 text-base font-medium', isActive ? 'bg-accent text-primary' : 'text-foreground hover:bg-muted')}>
              <n.icon className="h-5 w-5 shrink-0" aria-hidden />{n.label}
            </NavLink>
          ))}
        </div>
      </>)}
      <nav className="pb-safe fixed inset-x-0 bottom-0 z-30 grid border-t border-border/60 bg-background/85 px-1 backdrop-blur-xl md:hidden" style={{ gridTemplateColumns: `repeat(${BAR.length + (crowded ? 1 : 0)}, minmax(0, 1fr))` }} aria-label="Main">
        {BAR.map((n) => (
          <NavLink
            key={n.to}
            to={n.to}
            className={({ isActive }) =>
              cn('group flex min-h-16 flex-col items-center justify-center gap-1 text-[11px] font-medium', isActive ? 'text-primary' : 'text-muted-foreground')
            }
          >
            {({ isActive }) => (<>
            <span className={cn('relative flex h-8 w-12 items-center justify-center rounded-full transition-colors', isActive ? 'bg-accent' : 'group-hover:bg-muted')}>
              <n.icon className="h-[22px] w-[22px]" strokeWidth={isActive ? 2.4 : 2} aria-hidden />
              {n.to === '/inbox' && waiting > 0 && (
                <span className="absolute -top-1 right-1 rounded-full bg-rose-500 px-1 text-[10px] font-bold text-white shadow-sm">{waiting}</span>
              )}
            </span>
            <span className="max-w-full truncate px-0.5">{crowded ? n.label : (n.short ?? n.label)}</span>
            </>)}
          </NavLink>
        ))}
        {crowded && (
          <button type="button" aria-expanded={more} aria-haspopup="menu" onClick={() => setMore((m) => !m)}
            className={cn('group flex min-h-16 flex-col items-center justify-center gap-1 text-[11px] font-medium', more || inRest ? 'text-primary' : 'text-muted-foreground')}>
            <span className={cn('relative flex h-8 w-12 items-center justify-center rounded-full transition-colors', more || inRest ? 'bg-accent' : 'group-hover:bg-muted')}>
              <MoreHorizontal className="h-[22px] w-[22px]" strokeWidth={more || inRest ? 2.4 : 2} aria-hidden />
            </span>
            <span className="max-w-full truncate px-0.5">More</span>
          </button>
        )}
      </nav>
    </div>
  )
}

/** Light / dark, per browser (Colin 2026-10-28). */
function ThemeButton() {
  const [theme, setTheme] = useTheme()
  const dark = theme === 'dark'
  return (
    <button type="button" onClick={() => setTheme(dark ? 'light' : 'dark')} aria-pressed={dark}
      aria-label={dark ? 'Switch to light mode' : 'Switch to dark mode'} title={dark ? 'Light mode' : 'Dark mode'}
      className="flex h-10 w-10 items-center justify-center rounded-xl text-muted-foreground transition-colors hover:bg-accent hover:text-accent-foreground">
      {dark ? <Sun className="h-5 w-5" aria-hidden /> : <Moon className="h-5 w-5" aria-hidden />}
    </button>
  )
}
