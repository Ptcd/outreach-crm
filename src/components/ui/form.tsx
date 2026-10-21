import * as React from 'react'
import { cn } from '@/lib/utils'

const field =
  'w-full rounded-md border border-input bg-background px-3 py-2 text-base sm:text-sm focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring disabled:opacity-50'

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
    muted: 'bg-muted text-muted-foreground',
    warn: 'bg-amber-100 text-amber-900 dark:bg-amber-900/40 dark:text-amber-200',
    bad: 'bg-red-100 text-red-900 dark:bg-red-900/40 dark:text-red-200',
    good: 'bg-emerald-100 text-emerald-900 dark:bg-emerald-900/40 dark:text-emerald-200',
    info: 'bg-blue-100 text-blue-900 dark:bg-blue-900/40 dark:text-blue-200',
  }
  return <span className={cn('inline-flex items-center rounded px-2 py-0.5 text-xs font-medium', tones[tone], className)}>{children}</span>
}

export function Section({ title, children, right }: { title: string; children: React.ReactNode; right?: React.ReactNode }) {
  return (
    <section className="rounded-lg border bg-card p-4 shadow-sm">
      <div className="mb-3 flex items-center justify-between gap-2">
        <h2 className="text-base font-semibold">{title}</h2>
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
    <p className="rounded bg-red-50 p-2 text-sm text-red-800 dark:bg-red-950 dark:text-red-200">
      {offline || /Failed to fetch|NetworkError|Load failed/i.test(msg)
        ? 'No connection right now. This will load when the phone has signal again.'
        : `Something went wrong: ${msg}`}
    </p>
  )
}
