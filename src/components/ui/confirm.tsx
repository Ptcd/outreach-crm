import { useState, type ReactNode } from 'react'
import { Button, type ButtonProps } from '@/components/ui/button'
import { cn } from '@/lib/utils'

// A button whose confirm step is part of the page (no browser pop-up): the first tap opens a
// short question with two thumb-sized answers right where the thumb already is.
export function ConfirmButton({
  children, question, yes, onConfirm, variant, className, disabled, tone = 'warn',
}: {
  children: ReactNode
  question: ReactNode
  yes: string
  onConfirm: () => void
  variant?: ButtonProps['variant']
  className?: string
  disabled?: boolean
  tone?: 'warn' | 'danger'
}) {
  const [asking, setAsking] = useState(false)
  if (!asking) {
    return <Button variant={variant} className={className} disabled={disabled} onClick={() => setAsking(true)}>{children}</Button>
  }
  return (
    <div role="group" aria-label="Confirm" className={cn('w-full rounded-lg border p-3',
      tone === 'danger' ? 'border-red-300 bg-red-50 dark:border-red-800 dark:bg-red-950' : 'border-amber-300 bg-amber-50 dark:border-amber-800 dark:bg-amber-950')}>
      <p className="text-sm">{question}</p>
      <div className="mt-2 grid grid-cols-2 gap-2">
        <Button className="h-12" variant={tone === 'danger' ? 'destructive' : 'default'} onClick={() => { setAsking(false); onConfirm() }}>{yes}</Button>
        <Button className="h-12" variant="outline" onClick={() => setAsking(false)}>Cancel</Button>
      </div>
    </div>
  )
}
