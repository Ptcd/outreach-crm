// Warm Leads (Colin 2026-10-25: "We don't really have much for warm lead management do we"): every card past the cold
// texts on one screen, in the order the team works them. Needs a decision first (a call never logged, an overdue
// call, no next step), then hot, booked (by day), talking, callbacks and nurture. Each row: who, where, their last
// words, the pillars so far, and the next step. A tap opens the card. The grouping is the database's (warm_board).
import { Link } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { AlertTriangle, CalendarClock, Flame, HeartHandshake, MessagesSquare, Sprout } from 'lucide-react'
import { supabase } from '@/lib/supabaseClient'
import { Badge, Empty, ErrorNote, Section } from '@/components/ui/form'
import { StatTiles } from '@/components/StatTiles'
import { PILLARS, pillarsDone } from '@/components/CallPanel'
import { BELT_LABEL, type Belt } from '@/lib/belts'
import { fmtDateTime, fullAddress } from '@/lib/format'
import { GROUPS, groupRows, dayKey, nextLine, type Group, type WarmRow } from '@/lib/warm'
import type { CallFacts } from '@/lib/callGate'
import { cn } from '@/lib/utils'

function useWarm() {
  return useQuery({
    queryKey: ['warm_board'],
    queryFn: async () => {
      const r = await supabase.rpc('warm_board')
      if (r.error) throw new Error(r.error.message)
      return (r.data ?? []) as WarmRow[]
    },
    refetchInterval: 60_000,
  })
}

export default function Warm() {
  const q = useWarm()
  const g = groupRows(q.data ?? [])
  return (
    <div className="space-y-4">
      <div>
        <h1 className="text-2xl font-bold tracking-tight">Warm leads</h1>
        <p className="text-sm text-muted-foreground">Everyone past the first texts, in the order to work them.</p>
      </div>
      <StatTiles tiles={[
        { label: 'Decide', value: q.data ? g.decide.length : null, icon: AlertTriangle, tone: 'rose' },
        { label: 'Hot', value: q.data ? g.hot.length : null, icon: Flame, tone: 'amber' },
        { label: 'Booked', value: q.data ? g.booked.length : null, icon: CalendarClock, tone: 'indigo' },
        { label: 'Nurture', value: q.data ? g.talking.length + g.callback.length + g.nurture.length : null, icon: Sprout, tone: 'emerald' },
      ]} />
      <ErrorNote error={q.error} />
      {GROUPS.map((grp) => {
        const rows = g[grp.id]
        if (grp.id === 'decide' && rows.length === 0) return null
        return (
          <Section key={grp.id} title={`${grp.title}${q.data ? ` (${rows.length})` : ''}`}>
            <p className="mb-3 text-sm text-muted-foreground">{grp.hint}</p>
            {q.data && rows.length === 0 && <Empty>Nobody here right now.</Empty>}
            {grp.id === 'booked' ? <ByDay rows={rows} /> : (
              <ul className="space-y-2">{rows.map((r) => <WarmItem key={r.id} r={r} />)}</ul>
            )}
          </Section>
        )
      })}
    </div>
  )
}

function ByDay({ rows }: { rows: WarmRow[] }) {
  const days = new Map<string, WarmRow[]>()
  for (const r of rows) {
    const at = r.named_date ?? r.next_stop_at
    const k = at ? dayKey(at) : 'No date yet'
    days.set(k, [...(days.get(k) ?? []), r])
  }
  return (
    <div className="space-y-3">
      {[...days.entries()].map(([day, rs]) => (
        <div key={day}>
          <p className="mb-1.5 text-xs font-semibold uppercase tracking-wide text-primary">{day}</p>
          <ul className="space-y-2">{rs.map((r) => <WarmItem key={r.id} r={r} />)}</ul>
        </div>
      ))}
    </div>
  )
}

const ICON: Record<Group, typeof Flame> = { decide: AlertTriangle, hot: Flame, booked: CalendarClock, talking: MessagesSquare, callback: CalendarClock, nurture: HeartHandshake }
const RING: Record<Group, string> = {
  decide: 'bg-rose-50 text-rose-600', hot: 'bg-amber-50 text-amber-600', booked: 'bg-indigo-50 text-indigo-600',
  talking: 'bg-sky-50 text-sky-600', callback: 'bg-violet-50 text-violet-600', nurture: 'bg-emerald-50 text-emerald-600',
}

function WarmItem({ r }: { r: WarmRow }) {
  const done = pillarsDone((r.call_facts ?? {}) as CallFacts, r.facts ?? {})
  const n = PILLARS.filter((p) => done[p.id]).length
  const next = nextLine(r)
  const Icon = ICON[r.grp]
  return (
    <li>
      <Link to={`/lead/${r.id}`} className="flex gap-3 rounded-xl border border-border/70 bg-card p-3 transition-all hover:border-primary/30 hover:shadow-[var(--shadow-lift)]">
        <span className={cn('mt-0.5 flex h-9 w-9 shrink-0 items-center justify-center rounded-xl', RING[r.grp])}>
          <Icon className="h-[18px] w-[18px]" aria-hidden />
        </span>
        <span className="min-w-0 flex-1 space-y-1">
          <span className="flex flex-wrap items-center gap-x-2 gap-y-1">
            <span className="font-semibold">{r.owner_name}</span>
            <Badge tone={r.grp === 'decide' ? 'bad' : r.grp === 'hot' ? 'warn' : r.grp === 'booked' ? 'info' : 'muted'}>{BELT_LABEL[r.belt as Belt] ?? r.belt}</Badge>
            {(r.elderly_or_ill || r.grief) && <Badge tone="warn">Go gently</Badge>}
          </span>
          <span className="block truncate text-sm text-muted-foreground">{fullAddress(r)}</span>
          {r.why && <span className="block text-sm font-medium text-rose-700">{r.why}</span>}
          {r.last_in_body && (
            <span className="block truncate text-sm italic text-foreground/80">&ldquo;{r.last_in_body}&rdquo;
              {r.last_in_at && <span className="not-italic text-muted-foreground"> · {fmtDateTime(r.last_in_at)}</span>}</span>
          )}
          <span className="flex flex-wrap items-center gap-x-3 gap-y-1 text-xs">
            <span className={cn('font-medium', next.late ? 'text-rose-700' : 'text-foreground')}>{next.text}</span>
            <span className="flex items-center gap-1 text-muted-foreground" title={PILLARS.map((p) => `${done[p.id] ? '✓' : '○'} ${p.label}`).join('  ')}>
              {PILLARS.map((p) => <span key={p.id} className={cn('h-1.5 w-1.5 rounded-full', done[p.id] ? 'bg-emerald-500' : 'bg-border')} aria-hidden />)}
              <span className="ml-0.5">{n}/{PILLARS.length} pillars</span>
            </span>
            {r.assigned_to && <span className="text-muted-foreground">{r.assigned_to.charAt(0).toUpperCase() + r.assigned_to.slice(1)}</span>}
          </span>
          {r.next_stop_say && r.grp !== 'decide' && <span className="block truncate text-xs text-muted-foreground">Say: {r.next_stop_say}</span>}
        </span>
      </Link>
    </li>
  )
}
