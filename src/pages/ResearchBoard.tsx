import { useQuery } from '@tanstack/react-query'
import { Empty, ErrorNote, Section } from '@/components/ui/form'
import { supabase } from '@/lib/supabaseClient'
import { cn } from '@/lib/utils'

// The Research Board (0213; Colin 2026-11-10 through Muse's desk posts 174 and 175): where every research source stands,
// one always-current page. Twenty source jobs in priority order with a monthly tick Nov 2026 - Oct 2027 (a tick means
// the job ran end to end that month: pull, verification, cards in WPIE; in progress is a note, not a tick), and the 21
// buy-box counties x five legs. Muse's jobs and the desk tick it through the door; Colin reads it. Nothing here writes.

type Tick = { done: boolean; note: string | null; by: string | null; at: string }
type Job = { id: number; key: string; priority: string; category: string; job: string; data: string | null; source: string | null; cadence: string
  status: string | null; status_at: string | null; status_by: string | null; ticks: Record<string, Tick> }
type County = { county: string; legs: Record<string, Tick> }
type Board = { months: string[]; jobs: Job[]; legs: string[]; counties: County[]; as_of: string }

const LEG_LABEL: Record<string, string> = { foreclosure_cv: 'Foreclosure CV', probate_pr: 'Probate PR', tax: 'Tax', need_signal: 'Need signal', sale_refresh: 'Sale date' }
const monthLabel = (iso: string) => new Date(iso + 'T12:00:00').toLocaleDateString('en-US', { month: 'short', year: '2-digit' })

function TickCell({ t, title }: { t: Tick | undefined; title: string }) {
  const label = t ? `${title}: ${t.done ? 'done' : 'not done'}${t.note ? ` - ${t.note}` : ''}${t.by ? ` (${t.by})` : ''}` : `${title}: nothing recorded`
  return (
    <td className="px-1 py-1 text-center" title={label} aria-label={label}>
      <span className={cn('inline-block h-5 w-5 rounded-full text-xs leading-5',
        t?.done ? 'bg-emerald-600 text-white' : t?.note ? 'bg-amber-200 text-amber-900 dark:bg-amber-900/50 dark:text-amber-100' : 'bg-muted text-muted-foreground')}>
        {t?.done ? '✓' : t?.note ? '…' : ''}
      </span>
    </td>
  )
}

export default function ResearchBoard() {
  const q = useQuery({ queryKey: ['research_board'], queryFn: async () => { const r = await supabase.rpc('research_board'); if (r.error) throw r.error; return r.data as Board } })
  const b = q.data
  const done = b ? b.jobs.filter((j) => j.ticks[b.months[0]]?.done).length : 0
  return (
    <div className="space-y-4">
      <h1 className="text-2xl font-bold tracking-tight">Research</h1>
      <p className="text-sm text-muted-foreground">
        Where every research source stands. A tick is a month in which the job ran end to end: pull, verification, cards in WPIE. In progress is a note, not a tick.
        Muse ticks its own jobs; the desk ticks the records legs. Hover a cell for who and when.
      </p>
      <ErrorNote error={q.error} />
      {q.isLoading && <p className="text-sm text-muted-foreground">Reading the board...</p>}
      {b && b.jobs.length === 0 && <Empty>No jobs on the board yet.</Empty>}
      {b && b.jobs.length > 0 && (
        <>
          <Section title={`Source jobs (${done} of ${b.jobs.length} done for ${monthLabel(b.months[0])})`}>
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b text-left text-xs uppercase tracking-wide text-muted-foreground">
                    <th className="px-1 py-1">#</th><th className="px-1 py-1">Job</th><th className="px-1 py-1">Cadence</th><th className="px-1 py-1">Status</th>
                    {b.months.map((m) => <th key={m} className="px-1 py-1 text-center font-normal">{monthLabel(m)}</th>)}
                  </tr>
                </thead>
                <tbody>
                  {b.jobs.map((j) => (
                    <tr key={j.id} className="border-b align-top">
                      <td className="px-1 py-1 whitespace-nowrap"><span className={cn('rounded px-1 text-xs font-semibold', j.priority === 'P1' ? 'bg-red-100 text-red-900 dark:bg-red-950/40 dark:text-red-200' : j.priority === 'P2' ? 'bg-amber-100 text-amber-900 dark:bg-amber-950/40 dark:text-amber-200' : 'bg-muted')}>{j.priority}</span> {j.id}</td>
                      <td className="px-1 py-1 min-w-64">
                        <p className="font-medium">{j.category}</p>
                        <p className="text-muted-foreground">{j.job}</p>
                        {(j.data || j.source) && <p className="mt-0.5 text-xs text-muted-foreground">{j.data ? `Data: ${j.data}. ` : ''}{j.source ? `Source: ${j.source}.` : ''}</p>}
                      </td>
                      <td className="px-1 py-1 whitespace-nowrap">{j.cadence}</td>
                      <td className="px-1 py-1 min-w-48 text-xs">{j.status ?? <span className="text-muted-foreground">no note</span>}{j.status_by && <span className="text-muted-foreground"> ({j.status_by}{j.status_at ? `, ${new Date(j.status_at).toLocaleDateString('en-US', { month: 'short', day: 'numeric' })}` : ''})</span>}</td>
                      {b.months.map((m) => <TickCell key={m} t={j.ticks[m]} title={`${j.key} ${monthLabel(m)}`} />)}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </Section>
          <Section title="Counties">
            <div className="overflow-x-auto">
              <table className="text-sm">
                <thead>
                  <tr className="border-b text-left text-xs uppercase tracking-wide text-muted-foreground">
                    <th className="px-2 py-1">County</th>
                    {b.legs.map((l) => <th key={l} className="px-2 py-1 text-center font-normal">{LEG_LABEL[l] ?? l}</th>)}
                  </tr>
                </thead>
                <tbody>
                  {b.counties.map((c) => (
                    <tr key={c.county} className="border-b">
                      <td className="px-2 py-1 whitespace-nowrap">{c.county}</td>
                      {b.legs.map((l) => <TickCell key={l} t={c.legs[l]} title={`${c.county} ${LEG_LABEL[l] ?? l}`} />)}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </Section>
          <p className="text-xs text-muted-foreground">Board read {new Date(b.as_of).toLocaleString('en-US')}.</p>
        </>
      )}
    </div>
  )
}
