// A row of colorful number tiles at the top of a page (2026-10-25 refresh: "make it more modern").
import type { LucideIcon } from 'lucide-react'
import { Link } from 'react-router-dom'
import { cn } from '@/lib/utils'

export type Tile = { label: string; value: number | string | null | undefined; icon: LucideIcon; tone: 'indigo' | 'rose' | 'amber' | 'emerald' | 'sky'; to?: string }

const TONE: Record<Tile['tone'], string> = {
  indigo: 'from-indigo-500 to-violet-500',
  rose: 'from-rose-500 to-pink-500',
  amber: 'from-amber-400 to-orange-500',
  emerald: 'from-emerald-500 to-teal-500',
  sky: 'from-sky-500 to-cyan-500',
}

export function StatTiles({ tiles }: { tiles: Tile[] }) {
  return (
    <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
      {tiles.map((t) => {
        const body = (
          <>
            <span className={cn('flex h-10 w-10 shrink-0 items-center justify-center rounded-xl bg-gradient-to-br text-white shadow-[var(--shadow-lift)]', TONE[t.tone])}>
              <t.icon className="h-5 w-5" aria-hidden />
            </span>
            <span className="min-w-0">
              <span className="block text-2xl font-bold leading-none tracking-tight tabular">{t.value ?? '–'}</span>
              <span className="mt-1 block truncate text-xs font-medium text-muted-foreground">{t.label}</span>
            </span>
          </>
        )
        const cls = 'flex items-center gap-3 rounded-2xl border border-border/70 bg-card p-3.5 shadow-[var(--shadow-soft)] transition-shadow'
        return t.to
          ? <Link key={t.label} to={t.to} className={cn(cls, 'hover:shadow-[var(--shadow-lift)]')}>{body}</Link>
          : <div key={t.label} className={cls}>{body}</div>
      })}
    </div>
  )
}
