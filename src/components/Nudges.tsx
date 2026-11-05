// Heads-ups for me (0186; Thalia and Adil 2026-11-04: "two people, one seller, no message between us"). The other
// caller, or Colin, leaves a line on a card (card_nudge); it lands here, on Today, until I tap Done (nudge_done).
import { Link } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { Button } from '@/components/ui/button'
import { Empty, ErrorNote, Section } from '@/components/ui/form'
import { supabase } from '@/lib/supabaseClient'
import { useWrite } from '@/lib/queries'
import { fmtDateTime } from '@/lib/format'

export type Nudge = { task_id: string; lead_id: string; from: string | null; text: string | null; at: string; owner_name: string | null; address: string | null }

function useMyNudges(enabled = true) {
  return useQuery({
    queryKey: ['my_nudges'],
    enabled,
    refetchInterval: 60_000,
    queryFn: async () => {
      const r = await supabase.rpc('my_nudges')
      if (r.error) throw new Error(r.error.message)
      return (r.data ?? []) as Nudge[]
    },
  })
}

export function Nudges() {
  const q = useMyNudges()
  const done = useWrite((id: string) => supabase.rpc('nudge_done', { p_task_id: id }), [['my_nudges'], ['my_day'], ['my_piles'], ['tasks']])
  if (q.data && q.data.length === 0) return null
  return (
    <Section title={`Heads-ups for you${q.data ? ` (${q.data.length})` : ''}`}>
      <p className="mb-2 text-sm text-muted-foreground">A line someone left you on a card. Read it, then Done.</p>
      <ErrorNote error={q.error ?? done.error} />
      {q.isLoading && <Empty>Loading...</Empty>}
      <ul className="divide-y">
        {q.data?.map((n) => (
          <li key={n.task_id} className="flex items-start justify-between gap-3 py-3">
            <div className="min-w-0">
              <Link to={`/lead/${n.lead_id}`} className="inline-flex min-h-11 items-center font-medium underline">{n.owner_name ?? 'Card'}</Link>
              <span className="text-sm text-muted-foreground"> {n.address ? `- ${n.address}` : ''}</span>
              <p className="mt-1 whitespace-pre-wrap text-sm">{n.text}</p>
              <p className="text-xs text-muted-foreground">{n.from ?? 'Heads-up'} · {fmtDateTime(n.at)}</p>
            </div>
            <Button size="sm" variant="outline" className="h-10 shrink-0" disabled={done.isPending} onClick={() => done.mutate(n.task_id)}>Done</Button>
          </li>
        ))}
      </ul>
    </Section>
  )
}
