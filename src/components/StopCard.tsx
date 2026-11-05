import { useState } from 'react'
import { Link } from 'react-router-dom'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge, ErrorNote, Select, Textarea } from '@/components/ui/form'
import { ConfirmButton } from '@/components/ui/confirm'
import { api, useWrite, type StopTask } from '@/lib/queries'
import { fmtDateTime, localInputToIso, fullAddress } from '@/lib/format'
import { BELT_LABEL, STOP_OUTCOMES, type Belt } from '@/lib/belts'
import { NotNowPicker, saveSayNext } from '@/components/NextStep'
import type { NotNowKind } from '@/lib/nextStep'
import { personLabel } from '@/lib/wpie'
import { cn } from '@/lib/utils'

/** One stop on Today: whose, when, what to say, the numbers, and the outcome buttons that schedule the next stop.
 *  "Not now" has the one shape the close and the Next step control use (2026-11-04): a date (the caller's call), an
 *  event with no date, or nothing to go on (the machine's); the belt reads named_date / named_event / neither. */
export function StopCard({ t, now }: { t: StopTask; now: number }) {
  const [outcome, setOutcome] = useState<string>('')
  const [note, setNote] = useState('')
  const [slotKind, setSlotKind] = useState<'callback' | 'walk'>('callback')
  const [when, setWhen] = useState('')
  const [nnKind, setNnKind] = useState<NotNowKind>('date')
  const [nnDate, setNnDate] = useState('')
  const [event, setEvent] = useState('')
  const [say, setSay] = useState('')
  const [msg, setMsg] = useState<string | null>(null)
  const done = useWrite(async ({ o, detail }: { o: string; detail: Record<string, unknown> }) => {
    const r = await api.stopDone(t.id, o, note.trim() || null, detail)
    if (!r.error && t.lead?.id) await saveSayNext(t.lead.id, say)
    return r
  }, [['tasks'], ['lead'], ['cards_no_stop'], ['belt_counts'], ['leads'], ['my_piles'], ['card_brief']])
  const late = new Date(t.due_at).getTime() < now - 60_000
  const chosen = STOP_OUTCOMES.find((o) => o.id === outcome)
  const isDraft = t.kind === 'text'
  const belt = t.lead?.belt ? BELT_LABEL[t.lead.belt as Belt] ?? t.lead.belt : null
  const save = () => {
    const detail: Record<string, unknown> = {}
    if (chosen?.needs === 'slot') { const at = localInputToIso(when); if (!at) { setMsg('Pick the day and time.'); return } detail.kind = slotKind; detail.at = at }
    if (chosen?.needs === 'date') {
      if (nnKind === 'date') { const at = nnDate ? localInputToIso(`${nnDate}T10:00`) : null; if (!at) { setMsg('The date they gave.'); return } detail.named_date = at; if (event.trim()) detail.named_event = event.trim() }
      else if (nnKind === 'condition') { if (!event.trim()) { setMsg('What has to change.'); return } detail.named_event = event.trim() }
      // nothing to go on: no date, no event; the belt rests the card (dormant) and the texts keep the door open
    }
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
          {chosen && chosen.needs !== 'date' && <p className="text-xs text-muted-foreground">{chosen.hint}</p>}
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
            <NotNowPicker kind={nnKind} onKind={setNnKind} date={nnDate} onDate={setNnDate} event={event} onEvent={setEvent} say={say} onSay={setSay} busy={done.isPending} />
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
