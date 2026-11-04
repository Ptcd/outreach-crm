// Next step (0170; Colin 2026-11-03: callers manage their own follow-ups). One control, on the card and on every list
// row that carries a follow-up: set one, move it (presets or a date), close it the right way, delete it. The database
// does the work (followup_set / _move / _done / _delete) and keeps the belt in step; a caller can only touch their own.
import { useState } from 'react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { ErrorNote } from '@/components/ui/form'
import { api, useWrite } from '@/lib/queries'
import { localInputToIso } from '@/lib/format'
import { DONE_OUTCOMES, PRESETS, canDelete, isBeltTask } from '@/lib/nextStep'
import type { Task } from '@/lib/types'
import { cn } from '@/lib/utils'

type Panel = 'move' | 'done' | 'delete' | 'set' | null
const KEYS = (leadId: string | null) => [['tasks'], ['my_piles'], ['warm_board'], ['power_dial'], ['lead', leadId ?? '']]

/** Shown next to a follow-up (`task`), or alone on a card with none (`leadId` only). */
export function NextStep({ leadId, task, compact }: { leadId: string | null; task?: Task | null; compact?: boolean }) {
  const [panel, setPanel] = useState<Panel>(null)
  const [when, setWhen] = useState('')
  const [note, setNote] = useState('')
  const [msg, setMsg] = useState<string | null>(null)
  const keys = KEYS(leadId)
  const move = useWrite(async (atIso: string) => {
    const r = await api.followupMove(task!.id, atIso, note.trim() || null)
    const d = r.data as { ok?: boolean; reason?: string } | null
    return { error: r.error ?? (d && d.ok === false ? { message: d.reason ?? 'not moved' } : null) }
  }, keys)
  const set = useWrite(async (atIso: string) => {
    const r = await api.followupSet(leadId!, atIso, 'call', note.trim() || null)
    const d = r.data as { ok?: boolean; reason?: string } | null
    return { error: r.error ?? (d && d.ok === false ? { message: d.reason ?? 'not set' } : null) }
  }, keys)
  const done = useWrite(async (outcome: string) => {
    const r = await api.followupDone(task!.id, outcome, note.trim() || null)
    const d = r.data as { ok?: boolean; reason?: string } | null
    return { error: r.error ?? (d && d.ok === false ? { message: d.reason ?? 'not closed' } : null) }
  }, keys)
  const del = useWrite(async () => {
    const r = await api.followupDelete(task!.id, note.trim() || null)
    const d = r.data as { ok?: boolean; reason?: string } | null
    return { error: r.error ?? (d && d.ok === false ? { message: d.reason ?? 'not deleted' } : null) }
  }, keys)
  const busy = move.isPending || set.isPending || done.isPending || del.isPending
  const close = (m: string) => { setPanel(null); setWhen(''); setNote(''); setMsg(m) }
  const pick = (atIso: string) => {
    if (task) move.mutate(atIso, { onSuccess: () => close('Moved') })
    else set.mutate(atIso, { onSuccess: () => close('Set') })
  }
  const btn = 'min-h-9 rounded-md border px-2.5 text-xs font-medium hover:bg-accent'
  return (
    <div className={cn('text-sm', compact ? 'space-y-1' : 'space-y-2')}>
      <div className="flex flex-wrap items-center gap-1.5">
        {task ? (
          <>
            <button type="button" className={cn(btn, panel === 'move' && 'bg-accent')} onClick={() => { setPanel(panel === 'move' ? null : 'move'); setMsg(null) }}>Move</button>
            <button type="button" className={cn(btn, panel === 'done' && 'bg-accent')} disabled={busy}
              onClick={() => { setMsg(null); if (isBeltTask(task.source)) setPanel(panel === 'done' ? null : 'done'); else done.mutate('done', { onSuccess: () => close('Done') }) }}>
              Done
            </button>
            {canDelete(task) && (
              <button type="button" className={cn(btn, 'text-red-700', panel === 'delete' && 'bg-accent')} onClick={() => { setPanel(panel === 'delete' ? null : 'delete'); setMsg(null) }}>Delete</button>
            )}
          </>
        ) : (
          leadId && <button type="button" className={cn(btn, panel === 'set' && 'bg-accent')} onClick={() => { setPanel(panel === 'set' ? null : 'set'); setMsg(null) }}>Set a follow-up</button>
        )}
        {msg && <span className="text-xs text-emerald-700">{msg}</span>}
      </div>
      {(panel === 'move' || panel === 'set') && (
        <div className="space-y-2 rounded-md border bg-muted/40 p-2">
          <div className="flex flex-wrap gap-1.5">
            {PRESETS.map((p) => (
              <button key={p.id} type="button" disabled={busy} className={btn} onClick={() => pick(p.at(new Date()).toISOString())}>{p.label}</button>
            ))}
          </div>
          <div className="flex flex-wrap items-center gap-2">
            <Input type="datetime-local" value={when} onChange={(e) => setWhen(e.target.value)} aria-label="Day and time" className="h-9 w-auto" />
            <Input value={note} onChange={(e) => setNote(e.target.value)} placeholder={task ? 'Why (optional)' : 'What for (optional)'} aria-label="Note" className="h-9 min-w-40 flex-1" />
            <Button size="sm" disabled={!when || busy} onClick={() => { const iso = localInputToIso(when); if (iso) pick(iso) }}>{task ? 'Move it' : 'Set it'}</Button>
          </div>
        </div>
      )}
      {panel === 'done' && task && (
        <div className="space-y-2 rounded-md border bg-muted/40 p-2">
          <div className="flex flex-wrap gap-1.5">
            {DONE_OUTCOMES.map((o) => (
              <button key={o.id} type="button" disabled={busy} className={btn} onClick={() => done.mutate(o.id, { onSuccess: () => close('Done') })}>{o.label}</button>
            ))}
          </div>
          <Input value={note} onChange={(e) => setNote(e.target.value)} placeholder="What they said (optional)" aria-label="Note" className="h-9" />
        </div>
      )}
      {panel === 'delete' && task && (
        <div className="flex flex-wrap items-center gap-2 rounded-md border bg-muted/40 p-2">
          <Input value={note} onChange={(e) => setNote(e.target.value)} placeholder="Why (optional)" aria-label="Why" className="h-9 min-w-40 flex-1" />
          <Button size="sm" variant="outline" className="text-red-700" disabled={busy} onClick={() => del.mutate(undefined, { onSuccess: () => close('Deleted') })}>Delete it</Button>
        </div>
      )}
      <ErrorNote error={move.error ?? set.error ?? done.error ?? del.error} />
    </div>
  )
}
