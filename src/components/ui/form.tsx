import * as React from 'react'
import { cn } from '@/lib/utils'

const field =
  'w-full rounded-xl border border-input bg-card px-3 py-2 text-base shadow-[inset_0_1px_1px_rgb(16_24_40/0.03)] transition-colors placeholder:text-muted-foreground/70 hover:border-primary/40 sm:text-sm focus-visible:border-primary focus-visible:outline-none focus-visible:ring-4 focus-visible:ring-ring/15 disabled:opacity-50'

export const Select = React.forwardRef<HTMLSelectElement, React.SelectHTMLAttributes<HTMLSelectElement>>(
  ({ className, ...props }, ref) => <select ref={ref} className={cn(field, 'h-11 py-0 sm:h-10', className)} {...props} />,
)
Select.displayName = 'Select'

export const Textarea = React.forwardRef<HTMLTextAreaElement, React.TextareaHTMLAttributes<HTMLTextAreaElement>>(
  ({ className, ...props }, ref) => <textarea ref={ref} className={cn(field, 'min-h-20', className)} {...props} />,
)
Textarea.displayName = 'Textarea'

export function Badge({ className, tone = 'muted', children }: { className?: string; tone?: 'muted' | 'warn' | 'bad' | 'good' | 'info'; children: React.ReactNode }) {
  const tones = {
    muted: 'bg-muted text-muted-foreground ring-border',
    warn: 'bg-amber-50 text-amber-800 ring-amber-200',
    bad: 'bg-rose-50 text-rose-700 ring-rose-200',
    good: 'bg-emerald-50 text-emerald-700 ring-emerald-200',
    info: 'bg-indigo-50 text-indigo-700 ring-indigo-200',
  }
  return <span className={cn('inline-flex items-center gap-1 rounded-full px-2.5 py-0.5 text-xs font-semibold ring-1 ring-inset', tones[tone], className)}>{children}</span>
}

export function Section({ title, children, right }: { title: string; children: React.ReactNode; right?: React.ReactNode }) {
  return (
    <section className="rounded-2xl border border-border/70 bg-card p-4 shadow-[var(--shadow-soft)] sm:p-5">
      <div className="mb-3 flex items-center justify-between gap-2">
        <h2 className="flex items-center gap-2 text-base font-semibold">
          <span className="h-4 w-1 rounded-full bg-gradient-to-b from-[hsl(245_80%_66%)] to-primary" aria-hidden />{title}
        </h2>
        {right}
      </div>
      {children}
    </section>
  )
}

export function Empty({ children }: { children: React.ReactNode }) {
  return <p className="py-2 text-sm text-muted-foreground">{children}</p>
}

export function ErrorNote({ error }: { error: unknown }) {
  if (!error) return null
  const msg = error instanceof Error ? error.message : String(error)
  const offline = typeof navigator !== 'undefined' && navigator.onLine === false
  return (
    <p className="rounded-xl bg-rose-50 p-3 text-sm text-rose-800 ring-1 ring-inset ring-rose-200">
      {offline || /Failed to fetch|NetworkError|Load failed/i.test(msg)
        ? 'No connection right now. This will load when the phone has signal again.'
        : `Something went wrong: ${msg}`}
    </p>
  )
}
