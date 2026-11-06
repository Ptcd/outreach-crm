import { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { Button } from '@/components/ui/button'
import { Empty, ErrorNote, Section } from '@/components/ui/form'
import { supabase } from '@/lib/supabaseClient'

// Call time, Saturday to Friday, one block per caller (Colin 2026-11-06: "how much time they've been calling for the
// week starting Saturday to Friday, individually not together"). The numbers are the phone company's: every dial from
// the app is a Twilio leg, and the laptop copies them in every ten minutes (0194). Colin sees both callers; a caller
// sees only herself (the server decides, not this page).

type Day = { day: string; dials: number; connected: number; talk_s: number; first_at: string | null; last_at: string | null; span_s: number }
type Person = { person: 'thalia' | 'adil'; days: Day[] }
type Week = { week_start: string; week_end: string; me: string | null; people: Person[] }

const CT = 'America/Chicago'
export function hm(s: number): string {
  const m = Math.round(s / 60)
  return m < 60 ? `${m} min` : `${Math.floor(m / 60)} h ${String(m % 60).padStart(2, '0')} min`
}
export function clock(iso: string | null): string {
  return iso ? new Date(iso).toLocaleTimeString('en-US', { timeZone: CT, hour: 'numeric', minute: '2-digit' }) : '-'
}
function dayLabel(d: string): string {
  return new Date(`${d}T12:00:00Z`).toLocaleDateString('en-US', { timeZone: 'UTC', weekday: 'short', month: 'numeric', day: 'numeric' })
}
function shift(d: string, days: number): string {
  const x = new Date(`${d}T12:00:00Z`); x.setUTCDate(x.getUTCDate() + days); return x.toISOString().slice(0, 10)
}
const name = (p: string) => p.charAt(0).toUpperCase() + p.slice(1)

export default function CallTime() {
  const [pick, setPick] = useState<string | null>(null)
  const q = useQuery({
    queryKey: ['call_time_week', pick],
    refetchInterval: 60_000,
    queryFn: async () => {
      const r = await supabase.rpc('call_time_week', { p_week_start: pick })
      if (r.error) throw new Error(r.error.message)
      return r.data as Week
    },
  })
  const w = q.data
  return (
    <div className="space-y-4">
      <h1 className="text-2xl font-bold tracking-tight">Call time</h1>
      <div className="flex flex-wrap items-center gap-2">
        <Button variant="outline" size="sm" disabled={!w} onClick={() => w && setPick(shift(w.week_start, -7))}>Previous week</Button>
        <span className="text-sm font-medium">{w ? `Sat ${dayLabel(w.week_start).replace(/^\w+, /, '')} to Fri ${dayLabel(w.week_end).replace(/^\w+, /, '')}` : 'Loading...'}</span>
        <Button variant="outline" size="sm" disabled={!w || !pick} onClick={() => w && setPick(shift(w.week_start, 7))}>Next week</Button>
        {pick && <Button variant="ghost" size="sm" onClick={() => setPick(null)}>This week</Button>}
      </div>
      <ErrorNote error={q.error} />
      {w && w.people.length === 0 && <Empty>Nothing to show.</Empty>}
      {w?.people.map((p) => {
        const t = p.days.reduce((a, d) => ({ dials: a.dials + d.dials, connected: a.connected + d.connected, talk_s: a.talk_s + d.talk_s, span_s: a.span_s + d.span_s, days: a.days + (d.dials ? 1 : 0) }),
          { dials: 0, connected: 0, talk_s: 0, span_s: 0, days: 0 })
        return (
          <Section key={p.person} title={name(p.person)}>
            <div className="mb-3 grid grid-cols-2 gap-2 sm:grid-cols-4" aria-label={`${name(p.person)} this week`}>
              {([['Days called', String(t.days)], ['Dials', String(t.dials)], ['On the phone', hm(t.talk_s)], ['On the dialer', hm(t.span_s)]] as const).map(([label, value]) => (
                <div key={label} className="rounded-lg border bg-card p-3 text-center">
                  <p className="text-xs text-muted-foreground">{label}</p>
                  <p className="text-xl font-semibold">{value}</p>
                </div>
              ))}
            </div>
            <table className="w-full text-sm">
              <thead>
                <tr className="text-left text-xs text-muted-foreground">
                  <th className="py-1 pr-2">Day</th>
                  <th className="py-1 pr-2">Dials</th>
                  <th className="py-1 pr-2">Answered</th>
                  <th className="py-1 pr-2">On the phone</th>
                  <th className="hidden py-1 pr-2 sm:table-cell">First dial</th>
                  <th className="hidden py-1 pr-2 sm:table-cell">Last dial</th>
                  <th className="py-1">On the dialer</th>
                </tr>
              </thead>
              <tbody className="divide-y">
                {p.days.map((d) => (
                  <tr key={d.day} className={d.dials ? '' : 'text-muted-foreground'}>
                    <td className="py-1 pr-2">{dayLabel(d.day)}</td>
                    <td className="py-1 pr-2">{d.dials || '-'}</td>
                    <td className="py-1 pr-2">{d.dials ? d.connected : '-'}</td>
                    <td className="py-1 pr-2">{d.dials ? hm(d.talk_s) : '-'}</td>
                    <td className="hidden py-1 pr-2 sm:table-cell">{clock(d.first_at)}</td>
                    <td className="hidden py-1 pr-2 sm:table-cell">{clock(d.last_at)}</td>
                    <td className="py-1">{d.dials ? hm(d.span_s) : '-'}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </Section>
        )
      })}
      <p className="text-xs text-muted-foreground">
        On the phone is talk time the phone company billed, answered calls only. On the dialer is first dial to last dial each day.
        Times are Central. The numbers refresh within about ten minutes of a call.
      </p>
    </div>
  )
}
