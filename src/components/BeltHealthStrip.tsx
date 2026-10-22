import { useBeltHealth } from '@/lib/queries'
import { fmtDateTime } from '@/lib/format'

/** Top of Today: green with the counts when every belt is moving, red with the failed check in plain words. */
export function BeltHealthStrip() {
  const q = useBeltHealth()
  if (q.isLoading) return null
  const run = q.data?.run ?? null
  const canary = q.data?.canary ?? null
  const ageMin = run ? Math.round((Date.now() - new Date(run.at).getTime()) / 60_000) : null
  const stale = ageMin === null || ageMin > 60
  const ok = !!run && run.ok && !stale
  const counts = (run?.checks?.counts ?? {}) as Record<string, number>
  const onBelts = Object.entries(counts).filter(([b]) => !['dead', 'dnc'].includes(b)).reduce((a, [, n]) => a + Number(n), 0)
  const fails = ((run?.checks?.fails ?? []) as string[])
  return (
    <section className={ok ? 'rounded-lg border border-emerald-300 bg-emerald-50 p-3 dark:border-emerald-800 dark:bg-emerald-950'
      : 'rounded-lg border-2 border-red-400 bg-red-50 p-3 dark:border-red-800 dark:bg-red-950'}>
      <p className="font-semibold">{ok ? 'Belts moving' : 'A belt is broken'}</p>
      {q.error && <p className="text-sm">Could not read the belt health.</p>}
      {!run && !q.error && <p className="text-sm">The conveyor has not run yet (it runs every 15 minutes once migration 0032 is applied).</p>}
      {run && stale && <p className="text-sm">The conveyor last ran {fmtDateTime(run.at)}: over an hour ago. Stops are not moving.</p>}
      {run && !stale && ok && (
        <p className="text-sm">{onBelts} cards on belts, {Object.values(counts).length ? '' : ''}{run.summary?.replace(/^All belts moving: /, '')}. Checked {fmtDateTime(run.at)}.
          {canary ? ` Test card ${canary.ok ? 'passed' : 'FAILED'} ${fmtDateTime(canary.at)}.` : ''}</p>
      )}
      {run && !stale && !ok && (
        <ul className="mt-1 list-disc pl-5 text-sm">
          {(fails.length ? fails : [run.summary ?? 'a check failed']).map((f) => <li key={f}>{f}</li>)}
        </ul>
      )}
      {run && !ok && canary && !canary.ok && <p className="mt-1 text-xs">Test card: {canary.summary}</p>}
    </section>
  )
}
