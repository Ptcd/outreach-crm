// Missed calls and voicemails on Today (Colin 2026-10-27: "she needs to see that", "those voicemails should be visible
// easily with that text showing"). Every call nobody picked up, or that left a voicemail, in the last two days, with the
// voicemail's words in full. A closed card (do not contact) still shows, marked, so nobody wonders and nobody dials it.
import { useQuery } from '@tanstack/react-query'
import { Link } from 'react-router-dom'
import { Badge, ErrorNote, Section } from '@/components/ui/form'
import { supabase } from '@/lib/supabaseClient'
import { fmtDateTime, fmtPhone } from '@/lib/format'

type Missed = { call_sid: string; at: string; phone: string; status: string; voicemail: boolean; words: string | null; lead_id: string | null
  owner_name: string | null; property_address: string | null; municipality: string | null; stage: string | null; closed: boolean; called_back: boolean }

export function MissedCalls() {
  const q = useQuery({ queryKey: ['missed_calls'], refetchInterval: 60_000, queryFn: async () => {
    const r = await supabase.rpc('missed_calls_recent', { p_hours: 48 })
    if (r.error) throw new Error(r.error.message)
    return (r.data ?? []) as Missed[]
  } })
  const rows = q.data ?? []
  const waiting = rows.filter((x) => !x.closed && !x.called_back).length
  return (
    <Section title={`Missed calls and voicemails${q.data ? ` (${waiting} to call back)` : ''}`}>
      <ErrorNote error={q.error} />
      {q.data && rows.length === 0 && <p className="text-sm text-muted-foreground">No missed calls in the last two days.</p>}
      <ul className="space-y-2">
        {rows.map((x) => (
          <li key={x.call_sid} className={`rounded-md border p-2 text-sm ${x.closed ? 'border-red-300 bg-red-50/60 dark:bg-red-950/20' : x.called_back ? '' : 'border-amber-300 bg-amber-50/60 dark:bg-amber-950/20'}`}>
            <div className="flex flex-wrap items-center gap-2">
              {x.lead_id
                ? <Link className="font-medium underline" to={`/lead/${x.lead_id}#history`}>{x.owner_name ?? 'Unknown'}{x.property_address ? `, ${x.property_address}` : ''}</Link>
                : <span className="font-medium">No card for this number</span>}
              <span className="text-muted-foreground">{fmtPhone(x.phone)} · {fmtDateTime(x.at)}</span>
              {x.closed ? <Badge tone="bad">Card closed: do not call</Badge> : x.called_back ? <Badge tone="good">Called back</Badge> : <Badge tone="warn">Call them back</Badge>}
              {x.voicemail && <Badge tone="info">Voicemail</Badge>}
            </div>
            {x.words
              ? <blockquote className="mt-1 rounded border-l-4 border-sky-400 bg-sky-50 p-2 text-[0.95rem] dark:bg-sky-950/30">&ldquo;{x.words}&rdquo;</blockquote>
              : x.voicemail ? <p className="mt-1 text-muted-foreground">Voicemail left; the words are still being written out.</p> : null}
            {x.closed && <p className="mt-1 text-xs text-muted-foreground">They asked us to stop. Colin decides whether anyone calls back.</p>}
          </li>
        ))}
      </ul>
    </Section>
  )
}
