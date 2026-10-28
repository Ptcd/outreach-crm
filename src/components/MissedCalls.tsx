// Missed calls and voicemails on Today (Colin 2026-10-27: "she needs to see that", "those voicemails should be visible
// easily with that text showing"). Every call nobody picked up, or that left a voicemail, in the last two days, with the
// voicemail's words in full. Only the ones that still need a call back show (stopped numbers, closed cards and calls
// already returned drop off).
import { useQuery } from '@tanstack/react-query'
import { Link } from 'react-router-dom'
import { Badge, ErrorNote, Section } from '@/components/ui/form'
import { supabase } from '@/lib/supabaseClient'
import { fmtDateTime, fmtPhone } from '@/lib/format'

type Missed = { call_sid: string; at: string; phone: string; status: string; voicemail: boolean; words: string | null; lead_id: string | null
  owner_name: string | null; property_address: string | null; municipality: string | null; stage: string | null; closed: boolean; card_closed?: boolean; phone_blocked?: boolean; called_back: boolean }

export function MissedCalls() {
  const q = useQuery({ queryKey: ['missed_calls'], refetchInterval: 60_000, queryFn: async () => {
    const r = await supabase.rpc('missed_calls_recent', { p_hours: 48 })
    if (r.error) throw new Error(r.error.message)
    return (r.data ?? []) as Missed[]
  } })
  // only the calls that need someone: not called back yet, and not a stopped number or closed card (Colin 2026-10-28:
  // "this shouldnt show if it doesnt need our attention"); nothing to do = no box at all
  const rows = (q.data ?? []).filter((x) => !x.closed && !x.called_back)
  if (q.error) return <ErrorNote error={q.error} />
  if (!rows.length) return null
  return (
    <Section title={`Missed calls to call back (${rows.length})`}>
      <ul className="space-y-2">
        {rows.map((x) => (
          <li key={x.call_sid} className="rounded-md border border-amber-300 bg-amber-50/60 p-2 text-sm dark:bg-amber-950/20">
            <div className="flex flex-wrap items-center gap-2">
              {x.lead_id
                ? <Link className="font-medium underline" to={`/lead/${x.lead_id}#history`}>{x.owner_name ?? 'Unknown'}{x.property_address ? `, ${x.property_address}` : ''}</Link>
                : <span className="font-medium">No card for this number</span>}
              <span className="text-muted-foreground">{fmtPhone(x.phone)} · {fmtDateTime(x.at)}</span>
              <Badge tone="warn">Call them back</Badge>
              {x.voicemail && <Badge tone="info">Voicemail</Badge>}
            </div>
            {x.words
              ? <blockquote className="mt-1 rounded border-l-4 border-sky-400 bg-sky-50 p-2 text-[0.95rem] dark:bg-sky-950/30">&ldquo;{x.words}&rdquo;</blockquote>
              : x.voicemail ? <p className="mt-1 text-muted-foreground">Voicemail left; the words are still being written out.</p> : null}
          </li>
        ))}
      </ul>
    </Section>
  )
}
