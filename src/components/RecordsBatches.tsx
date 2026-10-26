// Records-request batches waiting for Colin (Colin 2026-10-26: "Muse drafts and tracks, but I approve each batch before
// it sends"). Each batch is the letters the records agent wrote; Colin reads them, unticks any he does not want, and
// approves or rejects. Only approved letters leave, from the laptop, on its next pass (about 10 minutes).
import { useState } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { Button } from '@/components/ui/button'
import { Badge, Empty, ErrorNote, Section } from '@/components/ui/form'
import { supabase } from '@/lib/supabaseClient'
import { fmtDateTime } from '@/lib/format'

type Letter = { draft_id: string; to: string; kind: string; to_email: string; cc: string | null; purpose: string; subject: string; body: string }
type Batch = { batch_id: string; proposed_by: string; note: string | null; created_at: string; letters: Letter[] }

export function RecordsBatches() {
  const qc = useQueryClient()
  const q = useQuery({ queryKey: ['records_batches'], refetchInterval: 60_000, queryFn: async () => {
    const r = await supabase.rpc('records_batches_waiting')
    if (r.error) throw new Error(r.error.message)
    return (r.data ?? []) as Batch[]
  } })
  return (
    <Section title={`Records requests to approve${q.data ? ` (${q.data.length})` : ''}`}>
      <p className="mb-3 text-sm text-muted-foreground">
        Letters the records agent wrote to clerks and Registers of Deeds. Nothing goes until you approve the batch. Untick a letter to leave it out.
      </p>
      <ErrorNote error={q.error} />
      {q.data?.length === 0 && <Empty>No batches waiting.</Empty>}
      <div className="space-y-4">
        {q.data?.map((b) => <BatchCard key={b.batch_id} b={b} onDone={() => void qc.invalidateQueries({ queryKey: ['records_batches'] })} />)}
      </div>
    </Section>
  )
}

function BatchCard({ b, onDone }: { b: Batch; onDone: () => void }) {
  const [drop, setDrop] = useState<Set<string>>(new Set())
  const [open, setOpen] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [msg, setMsg] = useState<string | null>(null)
  const decide = async (approve: boolean) => {
    setBusy(true); setMsg(null)
    const r = await supabase.rpc('records_decide_batch', { p_batch_id: b.batch_id, p_approve: approve, p_drop: [...drop] })
    setBusy(false)
    if (r.error) { setMsg(r.error.message); return }
    const d = r.data as { ok: boolean; reason?: string; approved_letters?: number }
    setMsg(!d.ok ? (d.reason ?? 'not saved') : approve ? `Approved: ${d.approved_letters} letters go out on the laptop's next pass.` : 'Rejected. Nothing will send.')
    onDone()
  }
  const keep = b.letters.length - drop.size
  return (
    <div className="rounded-xl border border-border/70 p-3">
      <div className="flex flex-wrap items-center gap-2">
        <Badge tone="info">{b.letters.length} letters</Badge>
        <span className="text-sm font-medium">{b.note || 'Records requests'}</span>
        <span className="text-xs text-muted-foreground">{b.proposed_by}, {fmtDateTime(b.created_at)}</span>
      </div>
      <ul className="mt-2 divide-y">
        {b.letters.map((l) => (
          <li key={l.draft_id} className="py-2">
            <label className="flex items-start gap-2 text-sm">
              <input type="checkbox" className="mt-1 h-4 w-4" checked={!drop.has(l.draft_id)}
                onChange={(e) => { const n = new Set(drop); if (e.target.checked) n.delete(l.draft_id); else n.add(l.draft_id); setDrop(n) }} />
              <span className="min-w-0 flex-1">
                <span className="font-medium">{l.to}</span>
                <span className="text-muted-foreground"> · {l.purpose.replace('_', ' ')} · {l.to_email}{l.cc ? `, cc ${l.cc}` : ''}</span>
                <span className="block truncate text-muted-foreground">{l.subject}</span>
              </span>
              <Button size="sm" variant="ghost" type="button" onClick={() => setOpen(open === l.draft_id ? null : l.draft_id)}>{open === l.draft_id ? 'Hide' : 'Read'}</Button>
            </label>
            {open === l.draft_id && <pre className="mt-2 whitespace-pre-wrap rounded-lg bg-muted p-3 font-sans text-sm">{l.body}</pre>}
          </li>
        ))}
      </ul>
      <div className="mt-3 flex flex-wrap items-center gap-2">
        <Button disabled={busy || keep === 0} onClick={() => void decide(true)}>Approve {keep} {keep === 1 ? 'letter' : 'letters'}</Button>
        <Button variant="outline" disabled={busy} onClick={() => void decide(false)}>Reject the batch</Button>
        {msg && <span className="text-sm">{msg}</span>}
      </div>
    </div>
  )
}
