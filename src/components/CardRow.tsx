// The pieces of a card row that say why (0186; Colin 2026-11-04: "build the full shit so the system isnt stupid
// anymore"; Thalia: "the row never says why"). Shared by My cards and Today so the two read the same.
import { Link } from 'react-router-dom'
import { Badge } from '@/components/ui/form'
import { whyParts, type PileCard } from '@/lib/piles'
import { fmtDateTime } from '@/lib/format'
import { cn } from '@/lib/utils'

/** The buy-box lane on the card: a flip (wholesale, statewide) or a hold (cash flow, the buy counties). */
export function LaneBadge({ lane }: { lane: string | null | undefined }) {
  if (!lane) return null
  return <Badge tone={lane === 'hold' ? 'info' : undefined}>{lane === 'hold' ? 'Hold' : lane === 'flip' ? 'Flip' : lane}</Badge>
}

/** Why this card: the reasons, their last words, what you promised, what to say. */
export function WhyLine({ c, className }: { c: PileCard; className?: string }) {
  const parts = whyParts(c)
  if (parts.length === 0) return null
  return (
    <p className={cn('text-xs text-muted-foreground', className)}>
      {parts.map((p, i) => (
        <span key={p.label} className={cn(i > 0 && 'ml-2')}>
          <span className="font-medium text-foreground/80">{p.label}:</span> {p.text}
        </span>
      ))}
    </p>
  )
}

/** Touches so far, and a heads-up marker when another person left one on the card. */
export function TouchLine({ c }: { c: PileCard }) {
  const n = c.touches ?? 0
  return (
    <p className="text-xs text-muted-foreground">
      {n ? `${n} touch${n === 1 ? '' : 'es'} so far` : 'Never touched'}
      {c.last_call_at ? ` · last call ${fmtDateTime(c.last_call_at)}` : ''}
      {c.nudge && <span className="ml-2 rounded bg-amber-100 px-1.5 py-px font-medium text-amber-900 dark:bg-amber-950/40 dark:text-amber-200">Heads-up: {c.nudge.replace(/\s+/g, ' ').slice(0, 80)}</span>}
    </p>
  )
}

/** A compact row for Today's caller list: name, lane, address, next in words, why. */
export function CardLine({ c }: { c: PileCard }) {
  const late = c.next_at != null && new Date(c.next_at).getTime() < Date.now()
  return (
    <Link to={`/lead/${c.lead_id}`} className="block min-w-0">
      <div className="flex flex-wrap items-center gap-2">
        <span className="font-medium">{c.owner_name}</span>
        <LaneBadge lane={c.lane} />
        {c.hot_at && <Badge tone="warn">Hot</Badge>}
      </div>
      <div className="text-sm text-muted-foreground">{c.address}{c.municipality ? `, ${c.municipality}` : ''}</div>
      {c.next_at ? (
        <div className={cn('text-xs', late && 'font-medium text-rose-600')}>
          {late ? 'Was due' : 'Next'} {fmtDateTime(c.next_at)}{c.next_what ? `: ${c.next_what}` : ''}
        </div>
      ) : c.next_plain ? <div className="text-xs">{c.next_plain}</div> : null}
      <WhyLine c={c} />
    </Link>
  )
}
