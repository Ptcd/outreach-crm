import { useEffect, useState } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { Button } from '@/components/ui/button'
import { Badge, ErrorNote, Section } from '@/components/ui/form'
import { supabase } from '@/lib/supabaseClient'
import { useAuth } from '@/providers/AuthProvider'
import { cn } from '@/lib/utils'

// Category instructions (0258; Muse, desk 323, 2026-11-20, from Colin): how to run each Research Board job, kept in
// WPIE beside the board, one document per job. Everyone on the team reads them; Colin edits here; an agent writes
// through the door. Every version is kept in the database.

type Row = { id: number; key: string; category: string; job: string; written: boolean; chars: number; version: number; updated_at: string | null; updated_by: string | null }
type Doc = Row & { ok: boolean; body: string; reason?: string }
const when = (iso: string | null) => (iso ? new Date(iso).toLocaleDateString('en-US', { month: 'short', day: 'numeric' }) : '')

export function CategoryInstructions() {
  const { isOwner } = useAuth()
  const [open, setOpen] = useState<string | null>(null)
  const idx = useQuery({ queryKey: ['research_docs_index'], queryFn: async () => {
    const r = await supabase.rpc('research_docs_index')
    if (r.error) throw r.error
    return (Array.isArray(r.data) ? r.data : []) as Row[]
  } })
  const rows = idx.data ?? []
  const written = rows.filter((r) => r.written).length
  return (
    <Section title={`Category instructions (${written} of ${rows.length} written)`}>
      <p className="mb-2 text-sm text-muted-foreground">How to run each job, one document per job. Tap a job to read it.{isOwner ? ' You can edit it here; an agent writes its own through the door.' : ''}</p>
      <ErrorNote error={idx.error} />
      <ul className="divide-y">
        {rows.map((r) => (
          <li key={r.id} className="py-1.5">
            <button type="button" className="flex w-full flex-wrap items-baseline gap-x-2 text-left text-sm" aria-expanded={open === r.key}
              onClick={() => setOpen(open === r.key ? null : r.key)}>
              <span className="w-6 shrink-0 text-xs text-muted-foreground">{r.id}</span>
              <span className="font-medium">{r.category}</span>
              <span className="min-w-0 flex-1 truncate text-muted-foreground">{r.job}</span>
              {r.written
                ? <Badge tone="good">{`v${r.version}${r.updated_by ? `, ${r.updated_by}` : ''}${r.updated_at ? `, ${when(r.updated_at)}` : ''}`}</Badge>
                : <Badge tone="muted">not written</Badge>}
            </button>
            {open === r.key && <DocPanel jobKey={r.key} canEdit={isOwner} />}
          </li>
        ))}
      </ul>
    </Section>
  )
}

function DocPanel({ jobKey, canEdit }: { jobKey: string; canEdit: boolean }) {
  const qc = useQueryClient()
  const q = useQuery({ queryKey: ['research_doc', jobKey], queryFn: async () => {
    const r = await supabase.rpc('research_doc', { p_job: jobKey })
    if (r.error) throw r.error
    return r.data as Doc
  } })
  const d = q.data
  const [edit, setEdit] = useState(false)
  const [text, setText] = useState('')
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  useEffect(() => { if (d && !edit) setText(d.body) }, [d, edit])
  const save = async () => {
    if (!d) return
    setBusy(true); setErr(null)
    const r = await supabase.rpc('research_doc_save', { p_job: jobKey, p_body: text, p_base_version: d.version })
    setBusy(false)
    const out = r.data as { ok?: boolean; reason?: string } | null
    if (r.error || !out?.ok) { setErr(r.error?.message ?? out?.reason ?? 'not saved'); return }
    setEdit(false)
    await Promise.all([qc.invalidateQueries({ queryKey: ['research_doc', jobKey] }), qc.invalidateQueries({ queryKey: ['research_docs_index'] })])
  }
  return (
    <div className="mt-2 rounded-md border bg-muted/30 p-3">
      <ErrorNote error={q.error} />
      {q.isLoading && <p className="text-sm text-muted-foreground">Reading...</p>}
      {d && !edit && (
        <>
          {d.written
            ? <pre className="max-h-[70vh] overflow-auto whitespace-pre-wrap break-words font-sans text-sm leading-relaxed">{d.body}</pre>
            : <p className="text-sm text-muted-foreground">Nothing written for this job yet.</p>}
          {canEdit && <Button size="sm" variant="outline" className="mt-2" onClick={() => { setText(d.body); setEdit(true) }}>{d.written ? 'Edit' : 'Write it'}</Button>}
        </>
      )}
      {d && edit && (
        <div className="space-y-2">
          <textarea aria-label={`Instructions for ${d.category}`} value={text} onChange={(e) => setText(e.target.value)}
            className={cn('h-[60vh] w-full rounded-md border bg-background p-2 font-mono text-sm')} />
          <div className="flex gap-2">
            <Button size="sm" disabled={busy || !text.trim()} onClick={save}>Save</Button>
            <Button size="sm" variant="ghost" disabled={busy} onClick={() => { setEdit(false); setErr(null) }}>Cancel</Button>
          </div>
          {err && <p className="text-sm text-red-700">{err}</p>}
        </div>
      )}
    </div>
  )
}
