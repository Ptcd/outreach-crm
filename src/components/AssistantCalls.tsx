import { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabaseClient'
import { Button } from '@/components/ui/button'
import { fmtDateTime } from '@/lib/format'

// What the phone assistant and the seller said, on the card (Colin 2026-11-25: "How do callers and me see ... how the
// call went with the ai agent?"). The card already carries the assistant's summary as a call line and the call-back
// task; the words themselves sat in voice_calls with no screen. A call nobody spoke on (they hung up on the greeting)
// is not listed: the card's "Missed call" line covers it. The assistant's calls are not recorded, so there is no audio.

type Turn = { role?: string; text?: string }
export type AssistantCall = { call_sid: string; started_at: string | null; ended_at: string | null; created_at: string; seconds: number | null; outcome: string | null; transcript: Turn[] | null }

const OUTCOME: Record<string, string> = {
  callback_booked: 'Call back booked', not_now: 'Not now, call back set', never_callback: 'Not a fit, but asked for a call', never: 'Not a fit',
  stop: 'Asked us to stop', wrong_person: 'Wrong person', hung_up: 'Hung up', talked_no_extraction: 'Talked; the summary failed, read the words', no_card: 'Call back booked',
}

/** The calls worth showing: the seller said something. Newest first. */
export function spokenCalls(rows: AssistantCall[]): AssistantCall[] {
  return rows.filter((r) => (r.transcript ?? []).some((t) => t.role === 'caller' && (t.text ?? '').trim()))
    .sort((a, b) => (b.ended_at ?? b.created_at).localeCompare(a.ended_at ?? a.created_at))
}

export function outcomeWords(outcome: string | null): string {
  return OUTCOME[outcome ?? ''] ?? (outcome ? outcome.replace(/_/g, ' ') : 'Ended')
}

export function AssistantCalls({ leadId }: { leadId: string }) {
  const q = useQuery({
    queryKey: ['assistant_calls', leadId], staleTime: 60_000,
    queryFn: async () => {
      const r = await supabase.from('voice_calls').select('call_sid, started_at, ended_at, created_at, seconds, outcome, transcript')
        .eq('lead_id', leadId).neq('outcome', 'test').order('created_at', { ascending: false }).limit(10)
      if (r.error) throw new Error(r.error.message)
      return spokenCalls((r.data ?? []) as AssistantCall[])
    },
  })
  const calls = q.data ?? []
  if (!calls.length) return null
  return (
    <section className="space-y-2 rounded-2xl border bg-card p-4" aria-label="Calls the assistant took" data-testid="assistant-calls">
      <h2 className="font-semibold">Calls the assistant took</h2>
      <p className="text-xs text-muted-foreground">They called when nobody could pick up, and the automated assistant talked to them. Its summary is in the card's history; these are the words. No recording is kept of these calls.</p>
      {calls.slice(0, 3).map((c, i) => <OneCall key={c.call_sid} c={c} startOpen={i === 0 && calls.length === 1} />)}
    </section>
  )
}

function OneCall({ c, startOpen }: { c: AssistantCall; startOpen: boolean }) {
  const [open, setOpen] = useState(startOpen)
  const turns = (c.transcript ?? []).filter((t) => (t.text ?? '').trim())
  return (
    <div className="rounded-lg border p-2 text-sm">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <p><span className="font-medium">{fmtDateTime(c.ended_at ?? c.created_at)}</span>{c.seconds ? ` · ${c.seconds < 90 ? `${c.seconds} s` : `${Math.round(c.seconds / 60)} min`}` : ''} · {outcomeWords(c.outcome)}</p>
        <Button size="sm" variant="outline" onClick={() => setOpen((o) => !o)}>{open ? 'Hide' : 'What was said'}</Button>
      </div>
      {open && (
        <ol className="mt-2 space-y-1">
          {turns.map((t, i) => (
            <li key={i} className={t.role === 'caller' ? 'font-medium' : 'text-muted-foreground'}>
              <span className="text-xs uppercase tracking-wide">{t.role === 'caller' ? 'Seller' : 'Assistant'}:</span> {t.text}
            </li>
          ))}
        </ol>
      )}
    </div>
  )
}
