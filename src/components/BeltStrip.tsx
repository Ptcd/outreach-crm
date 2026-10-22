import { useState } from 'react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge, ErrorNote, Select } from '@/components/ui/form'
import { api, useBeltEvents, useBeltMaxSteps, useWrite } from '@/lib/queries'
import { fmtDateTime, localInputToIso } from '@/lib/format'
import { BELTS, BELT_LABEL, beltLine, type Belt } from '@/lib/belts'
import { PEOPLE } from '@/lib/wpie'
import type { Lead, Person } from '@/lib/types'

const EVENT_WORDS: Record<string, string> = {
  inbound_text: 'They texted', hot_reply: 'Hot reply', human_text: 'A person texted them', call_logged: 'Call logged', next_step: 'Booked',
  verdict_no: "The card said don't book", stop_done: 'Stop logged', auto_text_sent: 'Text went', draft_sent: 'Draft sent', draft_skipped: 'Draft skipped',
  stop_missed: 'Stop missed', stop: 'STOP', dnc: 'Do not contact', wpie_event: 'New public record', cold_text: 'Cold text', flag: 'Flag set',
  move: 'Moved by hand', named_date: 'Date named', stage_changed: 'Stage changed', stops_ran_out: 'Stops ran out', no_answer: 'No answer',
  after_stop_interest: 'Wrote back after STOP', stage_set: 'Deal stage set',
}

/** Under the card's header: the belt, the stop, who and when, what to say; the last three moves; the belt by hand. */
export function BeltStrip({ lead }: { lead: Lead }) {
  const events = useBeltEvents(lead.id, 3)
  const maxSteps = useBeltMaxSteps()
  const [open, setOpen] = useState(false)
  const line = beltLine({ belt: lead.belt ?? null, belt_step: lead.belt_step ?? 0, next_stop_who: lead.next_stop_who ?? null,
    next_stop_at: lead.next_stop_at ?? null, next_stop_say: lead.next_stop_say ?? null }, lead.belt ? maxSteps.data?.[lead.belt] : null)
  const resting = ['dead', 'dnc', 'too_high_or_listed'].includes(lead.belt ?? '') || (lead.belt === 'dormant' && (lead.dormant_round ?? 0) >= 3)
  const late = !!lead.next_stop_at && new Date(lead.next_stop_at).getTime() < Date.now() - 3_600_000
  const noStop = !!lead.belt && !lead.next_stop_at && !resting && lead.belt !== 'cold_texts'
  return (
    <section className={`rounded-lg border p-3 ${noStop ? 'border-red-400 bg-red-50 dark:bg-red-950' : late ? 'border-amber-400 bg-amber-50 dark:bg-amber-950' : 'bg-card'}`}>
      <div className="flex flex-wrap items-start justify-between gap-2">
        <p className="text-sm font-medium">{line}</p>
        <div className="flex flex-wrap gap-1">
          {late && <Badge tone="warn">Stop overdue</Badge>}
          {noStop && <Badge tone="bad">No next stop</Badge>}
          {lead.elderly_or_ill && <Badge tone="warn">Older or ill: phone only</Badge>}
          {lead.grief && <Badge tone="warn">Grieving: phone only</Badge>}
          {(lead.unanswered_count ?? 0) > 0 && <Badge>{lead.unanswered_count} unanswered</Badge>}
        </div>
      </div>
      {lead.named_date && (
        <p className="mt-1 text-xs text-muted-foreground">They named: {fmtDateTime(lead.named_date)}{lead.named_event ? ` (${lead.named_event})` : ''}. Never before that.</p>
      )}
      <ul className="mt-2 space-y-0.5 text-xs text-muted-foreground">
        {events.data?.map((e) => (
          <li key={e.id}>
            {fmtDateTime(e.at)}: {EVENT_WORDS[e.event] ?? e.event}
            {e.payload?.outcome ? ` (${String(e.payload.outcome).replace(/_/g, ' ')})` : ''}
            {e.from_belt !== e.to_belt ? ` ${e.from_belt ? BELT_LABEL[e.from_belt as Belt] ?? e.from_belt : 'no belt'} -> ${e.to_belt ? BELT_LABEL[e.to_belt as Belt] ?? e.to_belt : 'no belt'}` : ''}
            {e.by ? ` - ${e.by}` : ''}
          </li>
        ))}
        {events.data?.length === 0 && <li>No moves yet.</li>}
      </ul>
      <Button variant="ghost" size="sm" className="mt-1" onClick={() => setOpen((o) => !o)}>{open ? 'Close' : 'Move the card, name a date, set a flag'}</Button>
      {open && <MoveForm lead={lead} onDone={() => setOpen(false)} />}
    </section>
  )
}

function MoveForm({ lead, onDone }: { lead: Lead; onDone: () => void }) {
  const [belt, setBelt] = useState<string>('')
  const [reason, setReason] = useState('')
  const [when, setWhen] = useState('')
  const [event, setEvent] = useState(lead.named_event ?? '')
  const [who, setWho] = useState<Person | ''>(lead.assigned_to ?? '')
  const [elderly, setElderly] = useState(!!lead.elderly_or_ill)
  const [grief, setGrief] = useState(!!lead.grief)
  const save = useWrite(() => api.leadMove(lead.id, {
    belt: belt || null, reason: reason.trim() || null, named_date: when ? localInputToIso(when) : null, named_event: event.trim() || null,
    elderly: elderly !== !!lead.elderly_or_ill ? elderly : null, grief: grief !== !!lead.grief ? grief : null,
    assigned_to: who !== (lead.assigned_to ?? '') ? who || null : null,
  }), [['lead', lead.id], ['belt_events', lead.id], ['leads'], ['tasks'], ['cards_no_stop'], ['belt_counts']])
  return (
    <div className="mt-2 grid gap-2 rounded-md border p-2 sm:grid-cols-2">
      <label className="text-sm font-medium">Belt
        <Select value={belt} onChange={(e) => setBelt(e.target.value)} className="mt-1">
          <option value="">Leave as is</option>
          {BELTS.map((b) => <option key={b} value={b}>{BELT_LABEL[b]}</option>)}
        </Select>
      </label>
      <label className="text-sm font-medium">Who has it
        <Select value={who} onChange={(e) => setWho(e.target.value as Person | '')} className="mt-1">
          <option value="">Nobody yet</option>
          {PEOPLE.map((p) => <option key={p.id} value={p.id}>{p.label}</option>)}
        </Select>
      </label>
      <label className="text-sm font-medium">Date or slot they named
        <Input type="datetime-local" value={when} onChange={(e) => setWhen(e.target.value)} className="mt-1" />
      </label>
      <label className="text-sm font-medium">What it is (the event, the condition, the person)
        <Input value={event} onChange={(e) => setEvent(e.target.value)} placeholder="the tenant moving out / her son / the letters" className="mt-1" />
      </label>
      <label className="flex min-h-11 items-center gap-2 text-sm"><input type="checkbox" checked={elderly} onChange={(e) => setElderly(e.target.checked)} /> Older or ill: phone only, family on the line</label>
      <label className="flex min-h-11 items-center gap-2 text-sm"><input type="checkbox" checked={grief} onChange={(e) => setGrief(e.target.checked)} /> Grieving: phone only, their pace</label>
      <Input value={reason} onChange={(e) => setReason(e.target.value)} placeholder="Why (goes in the log)" className="sm:col-span-2" />
      <div className="flex items-center gap-2 sm:col-span-2">
        <Button className="h-11" disabled={save.isPending} onClick={() => save.mutate(undefined, { onSuccess: onDone })}>{save.isPending ? 'Saving...' : 'Save'}</Button>
        <Button className="h-11" variant="outline" onClick={onDone}>Cancel</Button>
      </div>
      <div className="sm:col-span-2"><ErrorNote error={save.error} /></div>
    </div>
  )
}
