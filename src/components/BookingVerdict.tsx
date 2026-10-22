// The card's booking decision, as a box: green "Book the visit", amber "One more call first", red
// "Don't book", grey "Not decided yet" with what is still to ask. Same box on the lead card and at the
// close of the call script; the rule is src/lib/bookingVerdict.ts.
import { Badge } from '@/components/ui/form'
import type { BookingVerdict, Verdict } from '@/lib/bookingVerdict'
import { cn } from '@/lib/utils'

const TONE: Record<Verdict, { box: string; badge: 'good' | 'warn' | 'bad' | 'muted' }> = {
  book: { box: 'border-emerald-500 bg-emerald-50', badge: 'good' },
  call_back: { box: 'border-amber-500 bg-amber-50', badge: 'warn' },
  no: { box: 'border-red-500 bg-red-50', badge: 'bad' },
  open: { box: 'border-input bg-muted/40', badge: 'muted' },
}

export function VerdictBadge({ v }: { v: BookingVerdict }) {
  return <Badge tone={TONE[v.verdict].badge}>{v.headline}</Badge>
}

export function VerdictBox({ v, className }: { v: BookingVerdict; className?: string }) {
  const t = TONE[v.verdict]
  return (
    <div className={cn('rounded-md border-2 p-3', t.box, className)} data-testid="booking-verdict" data-verdict={v.verdict}>
      <p className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">The card says</p>
      <p className="mt-0.5 text-xl font-bold">{v.headline}</p>
      {v.because.length > 0 && (
        <ul className="mt-2 list-disc space-y-0.5 pl-5 text-sm">
          {v.because.map((b) => <li key={b}>{b}</li>)}
        </ul>
      )}
      {v.still.length > 0 && (
        <p className="mt-2 text-sm"><strong>Still to ask:</strong> {v.still.join('; ')}.</p>
      )}
      {v.verdict !== 'open' && <p className="mt-2 text-sm font-medium">{v.next}</p>}
    </div>
  )
}
