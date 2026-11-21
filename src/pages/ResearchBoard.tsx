import { useQuery } from '@tanstack/react-query'
import { Empty, ErrorNote, Section } from '@/components/ui/form'
import { supabase } from '@/lib/supabaseClient'
import { CategoryInstructions } from '@/components/CategoryInstructions'
import { cn } from '@/lib/utils'

// The Research Board (0213; Colin 2026-11-10 through Muse's desk posts 174 and 175): where every research source stands,
// one always-current page. Twenty source jobs in priority order with a WEEKLY tick (0248, Colin 2026-11-17: a tick means
// the job ran end to end that week: pull, verification, cards in WPIE; in progress is a note, not a tick), and the 21
// buy-box counties x five legs. A job with two whole weeks and no tick is Behind: red here, a text to Colin and a desk
// post every Monday, and a line to Muse on every tool call. Muse's jobs and the desk tick it through the door; Colin
// reads it. Nothing here writes.

type Tick = { done: boolean; note: string | null; by: string | null; at: string }
type Job = { id: number; key: string; priority: string; category: string; job: string; data: string | null; source: string | null; cadence: string
  status: string | null; status_at: string | null; status_by: string | null; ticks: Record<string, Tick>
  last_done?: string | null; weeks_missed?: number; behind?: boolean }
type County = { county: string; legs: Record<string, Tick> }
type Board = { week?: string; weeks?: string[]; jobs: Job[]; legs: string[]; counties: County[]; as_of: string }

const LEG_LABEL: Record<string, string> = { foreclosure_cv: 'Foreclosure CV', probate_pr: 'Probate PR', tax: 'Tax', need_signal: 'Need signal', sale_refresh: 'Sale date' }
// a week is named by its Monday: "Nov 16". Never a bare "Nov 26", which read as a day when it meant November 2026.
const weekLabel = (iso: string) => new Date(iso + 'T12:00:00').toLocaleDateString('en-US', { month: 'short', day: 'numeric' })

// where a job stands, in words a phone shows without scrolling to the ticks
export function standing(j: Pick<Job, 'last_done' | 'weeks_missed' | 'behind'>, week: string): { tone: 'ok' | 'late' | 'behind'; text: string } {
  const last = j.last_done ? `last ran the week of ${weekLabel(j.last_done)}` : 'never ticked'
  const missed = j.weeks_missed ?? 0
  if (j.behind) return { tone: 'behind', text: `Behind: ${missed} weeks with no tick (${last})` }
  if (j.last_done === week) return { tone: 'ok', text: 'Ran this week' }
  if (missed === 0) return { tone: 'ok', text: `Not ticked yet this week (${last})` }
  return { tone: 'late', text: `1 week with no tick (${last})` }
}
const TONE = { ok: 'text-muted-foreground', late: 'text-amber-700 dark:text-amber-300', behind: 'font-semibold text-red-700 dark:text-red-300' }

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
  const weeks = b?.weeks ?? []
  const week = b?.week ?? weeks[0] ?? ''
  const done = b ? b.jobs.filter((j) => j.ticks[week]?.done).length : 0
  const behind = b ? b.jobs.filter((j) => j.behind) : []
  return (
    <div className="space-y-4">
      <h1 className="text-2xl font-bold tracking-tight">Research</h1>
      <p className="text-sm text-muted-foreground">
        Where every research source stands. A tick is a week (Monday to Sunday) in which the job ran end to end: pull, verification, cards in WPIE. In progress is a note, not a tick.
        A job with two whole weeks and no tick is Behind: it is listed here in red, texted to Colin every Monday and put in front of Muse until it is ticked.
        Muse ticks its own jobs; the desk ticks the records and court legs.
      </p>
      <ErrorNote error={q.error} />
      {q.isLoading && <p className="text-sm text-muted-foreground">Reading the board...</p>}
      {b && b.jobs.length === 0 && <Empty>No jobs on the board yet.</Empty>}
      {b && b.jobs.length > 0 && (
        <>
          {behind.length > 0 && (
            <Section title={`Behind more than two weeks (${behind.length})`}>
              <ul className="space-y-1 text-sm">
                {behind.map((j) => (
                  <li key={j.id} className="text-red-700 dark:text-red-300">
                    <span className="font-semibold">{j.category}</span> (job {j.id}): {j.last_done ? `last ran the week of ${weekLabel(j.last_done)}` : 'never ticked'}, {j.weeks_missed} weeks with no tick
                  </li>
                ))}
              </ul>
            </Section>
          )}
          <Section title={`Source jobs (${done} of ${b.jobs.length} ticked this week, the week of ${week ? weekLabel(week) : '?'}; ${behind.length} behind)`}>
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b text-left text-xs uppercase tracking-wide text-muted-foreground">
                    <th className="px-1 py-1">#</th><th className="px-1 py-1">Job</th>
                    {weeks.map((w) => <th key={w} className="px-1 py-1 text-center font-normal whitespace-nowrap" title={`the week of ${weekLabel(w)}`}>{weekLabel(w)}</th>)}
                    <th className="px-1 py-1">Cadence</th><th className="px-1 py-1">Status</th>
                  </tr>
                </thead>
                <tbody>
                  {b.jobs.map((j) => { const st = standing(j, week); return (
                    <tr key={j.id} className="border-b align-top">
                      <td className="px-1 py-1 whitespace-nowrap"><span className={cn('rounded px-1 text-xs font-semibold', j.priority === 'P1' ? 'bg-red-100 text-red-900 dark:bg-red-950/40 dark:text-red-200' : j.priority === 'P2' ? 'bg-amber-100 text-amber-900 dark:bg-amber-950/40 dark:text-amber-200' : 'bg-muted')}>{j.priority}</span> {j.id}</td>
                      <td className="px-1 py-1 min-w-64">
                        <p className="font-medium">{j.category}</p>
                        <p className={cn('text-xs', TONE[st.tone])}>{st.text}</p>
                        <p className="text-muted-foreground">{j.job}</p>
                        {(j.data || j.source) && <p className="mt-0.5 text-xs text-muted-foreground">{j.data ? `Data: ${j.data}. ` : ''}{j.source ? `Source: ${j.source}.` : ''}</p>}
                      </td>
                      {weeks.map((w) => <TickCell key={w} t={j.ticks[w]} title={`${j.key}, the week of ${weekLabel(w)}`} />)}
                      <td className="px-1 py-1 whitespace-nowrap">{j.cadence}</td>
                      <td className="px-1 py-1 min-w-48 text-xs">{j.status ?? <span className="text-muted-foreground">no note</span>}{j.status_by && <span className="text-muted-foreground"> ({j.status_by}{j.status_at ? `, ${new Date(j.status_at).toLocaleDateString('en-US', { month: 'short', day: 'numeric' })}` : ''})</span>}</td>
                    </tr>
                  ) })}
                </tbody>
              </table>
            </div>
          </Section>
          <CategoryInstructions />
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
