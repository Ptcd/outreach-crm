// Next step (0170; Colin 2026-11-03: callers manage their own follow-ups). One control, on the card and on every list
// row that carries a follow-up: set one, move it (presets or a date), close it the right way, delete it. The database
// does the work (followup_set / _move / _done / _delete) and keeps the belt in step; a caller can only touch their own.
// 2026-11-04 (the walkthrough): the presets reach past a month, "the day after [an event]" is one tap, a "not now" has
// the same three-way shape here as on the close and on a stop, and a "when you call back, say" line rides along.
import { useState } from 'react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { ErrorNote, Select } from '@/components/ui/form'
import { api, useWrite } from '@/lib/queries'
import { supabase } from '@/lib/supabaseClient'
import { localInputToIso } from '@/lib/format'
import { DONE_OUTCOMES, NOT_NOW_KINDS, PRESETS, canDelete, dayAfter, isBeltTask, type NotNowKind } from '@/lib/nextStep'
import type { Task } from '@/lib/types'
import { cn } from '@/lib/utils'

type Panel = 'move' | 'done' | 'delete' | 'set' | 'not_now' | null
const KEYS = (leadId: string | null) => [['tasks'], ['my_piles'], ['warm_board'], ['power_dial'], ['lead', leadId ?? ''], ['card_brief', leadId ?? '']]
const btn = 'min-h-9 rounded-md border px-2.5 text-xs font-medium hover:bg-accent'

/** The date pickers every follow-up shares: the short presets, the long ones, a day and time, "the day after". */
export function WhenPicker({ onPick, busy, label }: { onPick: (iso: string) => void; busy?: boolean; label: string }) {
  const [when, setWhen] = useState('')
  const [after, setAfter] = useState('')
  return (
    <div className="space-y-2">
      <div className="flex flex-wrap gap-1.5">
        {PRESETS.filter((p) => !p.far).map((p) => (
          <button key={p.id} type="button" disabled={busy} className={btn} onClick={() => onPick(p.at(new Date()).toISOString())}>{p.label}</button>
        ))}
      </div>
      <div className="flex flex-wrap gap-1.5">
        {PRESETS.filter((p) => p.far).map((p) => (
          <button key={p.id} type="button" disabled={busy} className={cn(btn, 'border-dashed')} onClick={() => onPick(p.at(new Date()).toISOString())}>{p.label}</button>
        ))}
      </div>
      <div className="flex flex-wrap items-center gap-2">
        <Input type="datetime-local" value={when} onChange={(e) => setWhen(e.target.value)} aria-label="Day and time" className="h-9 w-auto" />
        <Button size="sm" disabled={!when || busy} onClick={() => { const iso = localInputToIso(when); if (iso) onPick(iso) }}>{label}</Button>
        <span className="text-xs text-muted-foreground">or the day after</span>
        <Input type="date" value={after} onChange={(e) => setAfter(e.target.value)} aria-label="The day after this date" className="h-9 w-auto" />
        <Button size="sm" variant="outline" disabled={!after || busy} onClick={() => { const d = dayAfter(after); if (d) onPick(d.toISOString()) }}>The day after</Button>
      </div>
    </div>
  )
}

/** The one "not now" shape (0178): a date (the caller's call), an event with no date, or nothing to go on (the
 *  machine's). Pure UI: the parent decides what each kind does (log_call, a belt stop, or a follow-up). */
export function NotNowPicker({ kind, onKind, date, onDate, event, onEvent, say, onSay, busy }: {
  kind: NotNowKind; onKind: (k: NotNowKind) => void
  date: string; onDate: (ymd: string) => void
  event: string; onEvent: (s: string) => void
  say: string; onSay: (s: string) => void
  busy?: boolean
}) {
  const chosen = NOT_NOW_KINDS.find((k) => k.id === kind)
  const [after, setAfter] = useState('')
  const today = new Date(); const min = `${today.getFullYear()}-${String(today.getMonth() + 1).padStart(2, '0')}-${String(today.getDate()).padStart(2, '0')}`
  const pick = (d: Date) => onDate(`${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`)
  return (
    <div className="space-y-2 rounded-md bg-muted p-2">
      <label className="block text-sm font-medium">What did they give you?
        <Select className="mt-1" value={kind} onChange={(e) => onKind(e.target.value as NotNowKind)} disabled={busy}>
          {NOT_NOW_KINDS.map((k) => <option key={k.id} value={k.id}>{k.label}</option>)}
        </Select>
      </label>
      {chosen && <p className="text-xs text-muted-foreground">{chosen.hint}</p>}
      {kind === 'date' && (
        <div className="space-y-1.5">
          <div className="flex flex-wrap gap-1.5">
            {PRESETS.filter((p) => p.id !== 'later_today').map((p) => (
              <button key={p.id} type="button" disabled={busy} className={cn(btn, p.far && 'border-dashed')} onClick={() => pick(p.at(new Date()))}>{p.label}</button>
            ))}
          </div>
          <div className="flex flex-wrap items-center gap-2">
            <label className="text-sm font-medium">Check back on
              <Input type="date" className="mt-1 h-9 w-auto" value={date} min={min} onChange={(e) => onDate(e.target.value)} />
            </label>
            <label className="text-sm font-medium">or the day after
              <span className="mt-1 flex items-center gap-1">
                <Input type="date" className="h-9 w-auto" value={after} min={min} onChange={(e) => setAfter(e.target.value)} aria-label="The day after this date" />
                <Button size="sm" variant="outline" disabled={!after || busy} onClick={() => { const d = dayAfter(after); if (d) pick(d) }}>Use it</Button>
              </span>
            </label>
          </div>
        </div>
      )}
      {kind === 'condition' && (
        <Input className="h-9" value={event} onChange={(e) => onEvent(e.target.value)} placeholder="What has to change (the tenant moves, the letters come, the closing)" aria-label="The event" />
      )}
      <Input className="h-9" value={say} onChange={(e) => onSay(e.target.value)} placeholder='When you call back, say: "you said the tenant leaves in March; did that happen?"' aria-label="When you call back, say" />
    </div>
  )
}

/** Saves the "say" line on the card (0186 card_say_next); quiet when empty. */
export async function saveSayNext(leadId: string, say: string): Promise<void> {
  if (!say.trim()) return
  await supabase.rpc('card_say_next', { p_lead_id: leadId, p_text: say.trim() })
}

/** Shown next to a follow-up (`task`), or alone on a card with none (`leadId` only). */
export function NextStep({ leadId, task, compact }: { leadId: string | null; task?: Task | null; compact?: boolean }) {
  const [panel, setPanel] = useState<Panel>(null)
  const [note, setNote] = useState('')
  const [say, setSay] = useState('')
  const [msg, setMsg] = useState<string | null>(null)
  // the not-now shape
  const [nnKind, setNnKind] = useState<NotNowKind>('date')
  const [nnDate, setNnDate] = useState('')
  const [nnEvent, setNnEvent] = useState('')
  const keys = KEYS(leadId)
  const unwrap = (r: { data: unknown; error: { message: string } | null }) => {
    const d = r.data as { ok?: boolean; reason?: string } | null
    return { error: r.error ?? (d && d.ok === false ? { message: d.reason ?? 'not saved' } : null) }
  }
  const move = useWrite(async (atIso: string) => unwrap(await api.followupMove(task!.id, atIso, note.trim() || null)), keys)
  const set = useWrite(async (atIso: string) => {
    const r = unwrap(await api.followupSet(leadId!, atIso, 'call', note.trim() || null))
    if (!r.error && leadId) await saveSayNext(leadId, say)
    return r
  }, keys)
  const notNow = useWrite(async () => {
    if (!leadId) return { error: { message: 'no card' } }
    let r: { error: { message: string } | null }
    if (nnKind === 'date') {
      const iso = localInputToIso(`${nnDate}T10:00`)
      if (!iso) return { error: { message: 'pick the date they gave' } }
      // the date they gave is the caller's call (0178 not_now_dated): a named date on the belt and a follow-up of mine
      r = unwrap(await api.leadMove(leadId, { belt: 'not_now_dated', named_date: iso, named_event: nnEvent.trim() || null, reason: 'not now, a date they gave' }))
      if (!r.error) r = unwrap(await api.followupSet(leadId, iso, 'call', note.trim() || null))
    } else if (nnKind === 'condition') {
      if (!nnEvent.trim()) return { error: { message: 'write what has to change' } }
      r = unwrap(await api.leadMove(leadId, { belt: 'not_now_condition', named_event: nnEvent.trim(), reason: 'not now, an event with no date' }))
    } else {
      r = unwrap(await api.leadMove(leadId, { belt: 'dormant', reason: 'not now, nothing to go on' }))
    }
    if (!r.error) await saveSayNext(leadId, say)
    return r
  }, keys)
  const done = useWrite(async (outcome: string) => unwrap(await api.followupDone(task!.id, outcome, note.trim() || null)), keys)
  const del = useWrite(async () => unwrap(await api.followupDelete(task!.id, note.trim() || null)), keys)
  const busy = move.isPending || set.isPending || done.isPending || del.isPending || notNow.isPending
  const close = (m: string) => { setPanel(null); setNote(''); setSay(''); setNnDate(''); setNnEvent(''); setMsg(m) }
  const pick = (atIso: string) => {
    if (task) move.mutate(atIso, { onSuccess: () => close('Moved') })
    else set.mutate(atIso, { onSuccess: () => close('Set') })
  }
  const toggle = (p: Panel) => { setPanel(panel === p ? null : p); setMsg(null) }
  return (
    <div className={cn('text-sm', compact ? 'space-y-1' : 'space-y-2')}>
      <div className="flex flex-wrap items-center gap-1.5">
        {task ? (
          <>
            <button type="button" className={cn(btn, panel === 'move' && 'bg-accent')} onClick={() => toggle('move')}>Move</button>
            <button type="button" className={cn(btn, panel === 'done' && 'bg-accent')} disabled={busy}
              onClick={() => { setMsg(null); if (isBeltTask(task.source)) setPanel(panel === 'done' ? null : 'done'); else done.mutate('done', { onSuccess: () => close('Done') }) }}>
              Done
            </button>
            {canDelete(task) && (
              <button type="button" className={cn(btn, 'text-red-700', panel === 'delete' && 'bg-accent')} onClick={() => toggle('delete')}>Delete</button>
            )}
          </>
        ) : (
          leadId && <button type="button" className={cn(btn, panel === 'set' && 'bg-accent')} onClick={() => toggle('set')}>Set a follow-up</button>
        )}
        {leadId && <button type="button" className={cn(btn, panel === 'not_now' && 'bg-accent')} onClick={() => toggle('not_now')}>Not now</button>}
        {msg && <span className="text-xs text-emerald-700">{msg}</span>}
      </div>
      {(panel === 'move' || panel === 'set') && (
        <div className="space-y-2 rounded-md border bg-muted/40 p-2">
          <WhenPicker onPick={pick} busy={busy} label={task ? 'Move it' : 'Set it'} />
          <Input value={note} onChange={(e) => setNote(e.target.value)} placeholder={task ? 'Why (optional)' : 'What for (optional)'} aria-label="Note" className="h-9" />
          {!task && <Input value={say} onChange={(e) => setSay(e.target.value)} placeholder="When you call back, say (optional)" aria-label="When you call back, say" className="h-9" />}
        </div>
      )}
      {panel === 'not_now' && leadId && (
        <div className="space-y-2 rounded-md border bg-muted/40 p-2">
          <NotNowPicker kind={nnKind} onKind={setNnKind} date={nnDate} onDate={setNnDate} event={nnEvent} onEvent={setNnEvent} say={say} onSay={setSay} busy={busy} />
          <div className="flex flex-wrap items-center gap-2">
            <Input value={note} onChange={(e) => setNote(e.target.value)} placeholder="Their words (optional)" aria-label="Their words" className="h-9 min-w-40 flex-1" />
            <Button size="sm" disabled={busy || (nnKind === 'date' && !nnDate) || (nnKind === 'condition' && !nnEvent.trim())}
              onClick={() => notNow.mutate(undefined, { onSuccess: () => close(nnKind === 'date' ? 'Not now: your call on that date' : 'Not now: the machine keeps the door open') })}>Save</Button>
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
      <ErrorNote error={move.error ?? set.error ?? done.error ?? del.error ?? notNow.error} />
    </div>
  )
}
