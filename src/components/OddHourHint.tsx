// A callback or walk set in the middle of the night (Thalia 2026-10-28: Shirikin's callback saved as 4:00 AM; Chrome's
// time box starts on AM, so "4:00" meant for the afternoon stays AM). Any time between midnight and 7 AM Central gets a
// warning and a one-tap fix to the same time in the afternoon or evening.
import { Button } from '@/components/ui/button'

const TZ = 'America/Chicago'

/** The same time twelve hours later when the given time is between midnight and 7 AM Central; null otherwise. */
export function oddHourFix(iso: string | null | undefined): string | null {
  if (!iso) return null
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return null
  const hour = Number(new Intl.DateTimeFormat('en-US', { timeZone: TZ, hour: 'numeric', hourCycle: 'h23' }).format(d))
  return hour < 7 ? new Date(d.getTime() + 12 * 3600_000).toISOString() : null
}

const clock = (iso: string) => new Date(iso).toLocaleString('en-US', { timeZone: TZ, weekday: 'short', hour: 'numeric', minute: '2-digit' })

export function OddHourHint({ iso, onFix }: { iso: string | null | undefined; onFix: (fixed: string) => void }) {
  const fixed = oddHourFix(iso)
  if (!iso || !fixed) return null
  return (
    <div role="alert" className="mt-1 flex flex-wrap items-center gap-2 rounded-md border-2 border-amber-400 bg-amber-50 p-2 text-sm dark:bg-amber-950/30">
      <span className="flex-1">That&apos;s <b>{clock(iso)}</b>, in the middle of the night. Did you mean <b>{clock(fixed)}</b>? (Check AM / PM.)</span>
      <Button type="button" size="sm" onClick={() => onFix(fixed)}>Make it {clock(fixed)}</Button>
    </div>
  )
}
