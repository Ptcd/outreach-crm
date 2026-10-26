import { useState } from 'react'
import { Link } from 'react-router-dom'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge, ErrorNote, Select, Textarea } from '@/components/ui/form'
import { ConfirmButton } from '@/components/ui/confirm'
import { api, useWrite, type StopTask } from '@/lib/queries'
import { fmtDateTime, localInputToIso, fullAddress } from '@/lib/format'
import { BELT_LABEL, STOP_OUTCOMES, type Belt } from '@/lib/belts'
import { personLabel } from '@/lib/wpie'
import { cn } from '@/lib/utils'

/** One stop on Today: whose, when, what to say, the numbers, and the outcome buttons that schedule the next stop. */
export function StopCard({ t, now }: { t: StopTask; now: number }) {
  const [outcome, setOutcome] = useState<string>('')
  const [note, setNote] = useState('')
  const [slotKind, setSlotKind] = useState<'callback' | 'walk'>('callback')
  const [when, setWhen] = useState('')
  const [event, setEvent] = useState('')
  const [msg, setMsg] = useState<string | null>(null)
  const done = useWrite(({ o, detail }: { o: string; detail: Record<string, unknown> }) => api.stopDone(t.id, o, note.trim() || null, detail),
    [['tasks'], ['lead'], ['cards_no_stop'], ['belt_counts'], ['leads']])
  const late = new Date(t.due_at).getTime() < now - 60_000
  const chosen = STOP_OUTCOMES.find((o) => o.id === outcome)
  const isDraft = t.kind === 'text'
  const belt = t.lead?.belt ? BELT_LABEL[t.lead.belt as Belt] ?? t.lead.belt : null
  const save = () => {
    const detail: Record<string, unknown> = {}
    if (chosen?.needs === 'slot') { const at = localInputToIso(when); if (!at) { setMsg('Pick the day and time.'); return } detail.kind = slotKind; detail.at = at }
    if (chosen?.needs === 'date') { const at = when ? localInputToIso(when) : null; if (at) detail.named_date = at; if (event.trim()) detail.named_event = event.trim()
      if (!at && !event.trim()) { setMsg('A date, or the thing that has to change.'); return } }
    if (note.trim()) detail.said = note.trim()
    setMsg(null)
    done.mutate({ o: outcome, detail }, { onSuccess: () => setMsg(`Logged: ${chosen?.label}. The belt set the next stop.`) })
  }
  return (
    <li className={cn('rounded-lg border bg-card p-3', late && 'border-amber-400')}>
      <div className="flex flex-wrap items-center gap-1.5">
        <span className="font-medium">{t.title ?? (t.kind === 'visit' ? 'Visit' : t.kind === 'text' ? 'Draft text' : 'Call')}</span>
        {late ? <Badge tone="bad">Overdue</Badge> : <Badge tone="info">{fmtDateTime(t.due_at)}</Badge>}
        <Badge>{personLabel(t.owner)}</Badge>
        {t.source === 'call_list' && <Badge>Call list</Badge>}
        {t.source === 'after_stop' && <Badge tone="bad">After STOP: call only</Badge>}
        {t.lead?.elderly_or_ill && <Badge tone="warn">Older or ill: family on the line</Badge>}
        {t.lead?.grief && <Badge tone="warn">Grieving: their pace</Badge>}
      </div>
      {t.lead && (
        <Link to={`/lead/${t.lead.id}${t.phone10 ? `?call=1&phone=${t.phone10}` : ''}`} className="inline-flex min-h-11 items-center text-sm underline">
          {t.lead.owner_name}{t.lead.property_address ? ` - ${fullAddress(t.lead)}` : ''}
        </Link>
      )}
      {belt && <p className="text-xs text-muted-foreground">{belt}{late ? ` - was due ${fmtDateTime(t.due_at)}` : ''}</p>}
      <p className="mt-1 whitespace-pre-wrap text-sm">{t.note}</p>
      {isDraft ? (
        <p className="mt-2 text-sm"><Link to="/approvals" className="underline">Tap it on Approve</Link>; the belt moves on when it goes or you skip it.</p>
      ) : (
        <div className="mt-2 space-y-2">
          <div className="grid grid-cols-2 gap-2 sm:grid-cols-4">
            {STOP_OUTCOMES.map((o) => (
              <button key={o.id} type="button" aria-pressed={outcome === o.id} onClick={() => { setOutcome(o.id); setMsg(null) }}
                className={cn('min-h-11 rounded-md border px-2 py-2 text-sm font-medium',
                  outcome === o.id ? (o.tone === 'bad' ? 'border-red-700 bg-red-700 text-white' : 'border-primary bg-primary text-primary-foreground') : 'bg-background')}>
                {o.label}
              </button>
            ))}
          </div>
          {chosen && <p className="text-xs text-muted-foreground">{chosen.hint}</p>}
          {chosen?.needs === 'slot' && (
            <div className="grid grid-cols-2 gap-2">
              <Select value={slotKind} onChange={(e) => setSlotKind(e.target.value as 'callback' | 'walk')} aria-label="Booked what">
                <option value="callback">Call back</option>
                <option value="walk">Walk-through</option>
              </Select>
              <Input type="datetime-local" value={when} onChange={(e) => setWhen(e.target.value)} aria-label="Day and time" />
            </div>
          )}
          {chosen?.needs === 'date' && (
            <div className="grid grid-cols-2 gap-2">
              <Input type="datetime-local" value={when} onChange={(e) => setWhen(e.target.value)} aria-label="The date they named" />
              <Input value={event} onChange={(e) => setEvent(e.target.value)} placeholder="What has to change (tenant out, letters, the closing)" aria-label="The event" />
            </div>
          )}
          {outcome && <Textarea rows={2} placeholder="What they said, in their words (the next stop opens with it)" value={note} onChange={(e) => setNote(e.target.value)} />}
          {outcome === 'dnc' ? (
            <ConfirmButton className="h-11" disabled={done.isPending} question="Block every phone of this owner? Nobody calls or texts them again." yes="Yes, do not contact" onConfirm={save}>Log: do not contact</ConfirmButton>
          ) : (
            <Button className="h-11 w-full sm:w-auto" disabled={!outcome || done.isPending} onClick={save}>{done.isPending ? 'Saving...' : 'Log this stop'}</Button>
          )}
          {msg && <p className="text-sm">{msg}</p>}
          <ErrorNote error={done.error} />
        </div>
      )}
    </li>
  )
}
