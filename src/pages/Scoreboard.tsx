import { useState } from 'react'
import { Empty, ErrorNote, Section, Select } from '@/components/ui/form'
import { useScoreboard, useSignalScoreboard } from '@/lib/queries'
import { fmtDate, pct } from '@/lib/format'
import type { ScoreboardWeek } from '@/lib/types'

// docs/ACQUISITION_SYSTEM_PLAYBOOK.md section 4. Targets are starting guesses until our own data.
const ROWS: { n: number; label: string; def: string; target: string; value: (w: ScoreboardWeek) => string }[] = [
  { n: 1, label: 'Openers sent', def: 'Openers Twilio accepted this week', target: '600', value: (w) => String(w.openers_sent) },
  { n: 2, label: 'Delivery rate', def: 'Delivered / sent', target: '90%+', value: (w) => pct(w.delivery_rate) },
  { n: 3, label: 'Reply rate', def: 'Owners with a non-STOP reply / delivered', target: '5-15%', value: (w) => `${pct(w.reply_rate)} (${w.replies})` },
  { n: 4, label: 'Opt-out rate', def: 'STOPs and removals / delivered', target: 'under 3%', value: (w) => `${pct(w.opt_out_rate)} (${w.opt_outs})` },
  { n: 5, label: 'Contact rate', def: 'Confirmed owners / people reached', target: '70%+', value: (w) => `${pct(w.contact_rate)} (${w.contacts}/${w.connects})` },
  { n: 6, label: 'Leads', def: 'Would sell and gave a reason; and / delivered', target: '1-3%', value: (w) => `${w.leads} (${pct(w.leads_per_delivered)})` },
  { n: 7, label: 'Booked calls held', def: 'Connected at the booked time / calls booked', target: '50%+', value: (w) => `${pct(w.handoffs_held_rate)} (${w.handoffs_held}/${w.handoffs})` },
  { n: 8, label: 'Walk rate', def: 'Walks / qualifying calls done', target: '20-40%', value: (w) => `${pct(w.walk_rate)} (${w.walks}/${w.qualifying_calls})` },
  { n: 9, label: 'Walks per contract', def: 'Walks / contracts signed (your key number)', target: '3-6', value: (w) => (w.walks_per_contract === null ? '-' : String(w.walks_per_contract)) },
  { n: 11, label: 'Contracts / closes', def: 'Signed this week; closed this week', target: '-', value: (w) => `${w.contracts} / ${w.closes}` },
]

export default function Scoreboard() {
  const [lane, setLane] = useState('all')
  const q = useScoreboard(lane)
  const weeks = q.data ?? []
  const [pick, setPick] = useState<string | null>(null)
  const week = weeks.find((w) => w.week_start === pick) ?? weeks[0]
  const signals = useSignalScoreboard(week?.week_start ?? null)

  return (
    <div className="space-y-4">
      <h1 className="text-xl font-semibold">Scoreboard</h1>
      <div className="grid grid-cols-2 gap-2 sm:w-96">
        <Select value={lane} onChange={(e) => setLane(e.target.value)} aria-label="Lane">
          <option value="all">Both lanes</option>
          <option value="hold">Hold lane</option>
          <option value="flip">Flip lane</option>
        </Select>
        <Select value={week?.week_start ?? ''} onChange={(e) => setPick(e.target.value)} aria-label="Week">
          {weeks.map((w) => (
            <option key={w.week_start} value={w.week_start}>
              Week of {fmtDate(w.week_start)}
            </option>
          ))}
        </Select>
      </div>
      <ErrorNote error={q.error} />
      {q.data && weeks.length === 0 && <Empty>No activity yet. Numbers appear once openers go out.</Empty>}
      {week && (
        <Section title={`Week of ${fmtDate(week.week_start)}`}>
          {/* phones: one card per number */}
          <ul className="space-y-2 sm:hidden">
            {ROWS.map((r) => (
              <li key={r.n} className="rounded-lg border p-3">
                <div className="flex items-baseline justify-between gap-3">
                  <span className="font-medium">{r.n}. {r.label}</span>
                  <span className="shrink-0 text-lg font-semibold">{r.value(week)}</span>
                </div>
                <p className="mt-1 text-xs text-muted-foreground">{r.def}</p>
                <p className="text-xs text-muted-foreground">Starting guess: {r.target}</p>
              </li>
            ))}
          </ul>
          <table className="hidden w-full text-sm sm:table">
            <thead>
              <tr className="text-left text-xs text-muted-foreground">
                <th className="py-1 pr-2">#</th>
                <th className="py-1 pr-2">Number</th>
                <th className="py-1 pr-2">This week</th>
                <th className="hidden py-1 sm:table-cell">Starting guess</th>
              </tr>
            </thead>
            <tbody className="divide-y">
              {ROWS.map((r) => (
                <tr key={r.n}>
                  <td className="py-2 pr-2 align-top text-muted-foreground">{r.n}</td>
                  <td className="py-2 pr-2 align-top">
                    <div className="font-medium">{r.label}</div>
                    <div className="text-xs text-muted-foreground">{r.def}</div>
                  </td>
                  <td className="py-2 pr-2 align-top font-medium">{r.value(week)}</td>
                  <td className="hidden py-2 align-top text-muted-foreground sm:table-cell">{r.target}</td>
                </tr>
              ))}
            </tbody>
          </table>
          <p className="mt-3 text-xs text-muted-foreground">
            Number 10 (follow-up debt) is on the Today page. Number 12 (profit per 1,000 owners) is not tracked in this app.
            Targets are starting guesses until we have four weeks of our own numbers.
          </p>
        </Section>
      )}
      {week && (
        <Section title="By WPIE signal (same week)">
          <ErrorNote error={signals.error} />
          {signals.data?.length === 0 && <Empty>Nothing this week.</Empty>}
          {signals.data && signals.data.length > 0 && (
            <>
            <ul className="space-y-2 sm:hidden">
              {signals.data.map((s) => (
                <li key={s.signal} className="rounded-lg border p-3">
                  <p className="font-medium">{s.signal}</p>
                  <dl className="mt-1 grid grid-cols-3 gap-x-3 gap-y-1 text-sm">
                    {([['Sent', s.openers_sent], ['Replies', s.replies], ['STOPs', s.opt_outs], ['Leads', s.leads], ['Walks', s.walks], ['Contracts', s.contracts]] as const).map(([k, v]) => (
                      <div key={k}><dt className="text-xs text-muted-foreground">{k}</dt><dd className="font-semibold">{v}</dd></div>
                    ))}
                  </dl>
                </li>
              ))}
            </ul>
            <div className="hidden sm:block">
              <table className="w-full text-sm">
                <thead>
                  <tr className="text-left text-xs text-muted-foreground">
                    <th className="py-1 pr-2">Signal</th>
                    <th className="py-1 pr-2">Sent</th>
                    <th className="py-1 pr-2">Replies</th>
                    <th className="py-1 pr-2">STOPs</th>
                    <th className="py-1 pr-2">Leads</th>
                    <th className="py-1 pr-2">Walks</th>
                    <th className="py-1">Contracts</th>
                  </tr>
                </thead>
                <tbody className="divide-y">
                  {signals.data.map((s) => (
                    <tr key={s.signal}>
                      <td className="py-1 pr-2">{s.signal}</td>
                      <td className="py-1 pr-2">{s.openers_sent}</td>
                      <td className="py-1 pr-2">{s.replies}</td>
                      <td className="py-1 pr-2">{s.opt_outs}</td>
                      <td className="py-1 pr-2">{s.leads}</td>
                      <td className="py-1 pr-2">{s.walks}</td>
                      <td className="py-1">{s.contracts}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            </>
          )}
          <p className="mt-2 text-xs text-muted-foreground">A lead with several reasons counts under each one. Judge a signal after about 2,000 owners.</p>
        </Section>
      )}
    </div>
  )
}
