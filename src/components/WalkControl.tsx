// A booked walk or call on My cards (0177; Colin 2026-11-04): the caller moves it, flags a wavering seller for Colin,
// or takes it off and puts the card on their own check-back after a no-show or a cold-feet call. The database
// (walk_outcome) moves the belt and writes the note; a caller can only do this on their own card.
import { useState } from 'react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { ErrorNote } from '@/components/ui/form'
import { api, useWrite } from '@/lib/queries'
import { localInputToIso } from '@/lib/format'
import { cn } from '@/lib/utils'

type Panel = 'rebook' | 'waver' | 'no_show' | 'check_back' | null
const KEYS = (leadId: string) => [['lead', leadId], ['tasks'], ['my_piles'], ['warm_board'], ['power_dial']]

export function WalkControl({ leadId, kind }: { leadId: string; kind: 'walk' | 'call' }) {
  const [panel, setPanel] = useState<Panel>(null)
  const [when, setWhen] = useState('')
  const [note, setNote] = useState('')
  const [msg, setMsg] = useState<string | null>(null)
  const run = useWrite(async (x: { outcome: string; at: string | null }) => {
    const r = await api.walkOutcome(leadId, x.outcome, x.at, note.trim() || null)
    const d = r.data as { ok?: boolean; reason?: string } | null
    return { error: r.error ?? (d && d.ok === false ? { message: d.reason ?? 'not saved' } : null) }
  }, KEYS(leadId))
  const done = (m: string) => { setPanel(null); setWhen(''); setNote(''); setMsg(m) }
  const btn = 'min-h-9 rounded-md border px-2.5 text-xs font-medium hover:bg-accent'
  const thing = kind === 'walk' ? 'walk' : 'call'
  return (
    <div className="space-y-1 text-sm">
      <div className="flex flex-wrap items-center gap-1.5">
        <span className="text-xs font-semibold text-muted-foreground">The {thing}:</span>
        <button type="button" className={cn(btn, panel === 'rebook' && 'bg-accent')} onClick={() => { setPanel(panel === 'rebook' ? null : 'rebook'); setMsg(null) }}>Rebook</button>
        <button type="button" className={cn(btn, panel === 'waver' && 'bg-accent')} onClick={() => { setPanel(panel === 'waver' ? null : 'waver'); setMsg(null) }}>Wavering</button>
        <button type="button" className={cn(btn, panel === 'no_show' && 'bg-accent')} onClick={() => { setPanel(panel === 'no_show' ? null : 'no_show'); setMsg(null) }}>No-show</button>
        <button type="button" className={cn(btn, panel === 'check_back' && 'bg-accent')} onClick={() => { setPanel(panel === 'check_back' ? null : 'check_back'); setMsg(null) }}>Off: check back</button>
        {msg && <span className="text-xs text-emerald-700">{msg}</span>}
      </div>
      {panel === 'rebook' && (
        <div className="flex flex-wrap items-center gap-2 rounded-md border bg-muted/40 p-2">
          <Input type="datetime-local" value={when} onChange={(e) => setWhen(e.target.value)} aria-label="New day and time" className="h-9 w-auto" />
          <Input value={note} onChange={(e) => setNote(e.target.value)} placeholder="Why (optional)" className="h-9 min-w-40 flex-1" />
          <Button size="sm" disabled={!when || run.isPending} onClick={() => { const iso = localInputToIso(when); if (iso) run.mutate({ outcome: 'rebook', at: iso }, { onSuccess: () => done('Rebooked; the confirm call moves with it') }) }}>Move the {thing}</Button>
        </div>
      )}
      {panel === 'waver' && (
        <div className="flex flex-wrap items-center gap-2 rounded-md border bg-muted/40 p-2">
          <Input value={note} onChange={(e) => setNote(e.target.value)} placeholder='Their words: "we want to think it over"' className="h-9 min-w-56 flex-1" />
          <Button size="sm" disabled={!note.trim() || run.isPending} onClick={() => run.mutate({ outcome: 'waver', at: null }, { onSuccess: () => done("Noted; Colin gets a call an hour before to decide. The walk stays.") })}>Tell Colin</Button>
          <p className="w-full text-xs text-muted-foreground">Don&apos;t push. The {thing} stays on unless they cancel.</p>
        </div>
      )}
      {(panel === 'no_show' || panel === 'check_back') && (
        <div className="flex flex-wrap items-center gap-2 rounded-md border bg-muted/40 p-2">
          <Input type="datetime-local" value={when} onChange={(e) => setWhen(e.target.value)} aria-label="Check back on" className="h-9 w-auto" />
          <Input value={note} onChange={(e) => setNote(e.target.value)} placeholder={panel === 'no_show' ? 'What happened (optional)' : 'Their words: what has to change'} className="h-9 min-w-48 flex-1" />
          <Button size="sm" disabled={run.isPending || (panel === 'check_back' && !when)}
            onClick={() => run.mutate({ outcome: panel, at: when ? localInputToIso(when) : null }, { onSuccess: () => done(panel === 'no_show' ? 'Off the list; check-back set' : 'Check-back set') })}>
            {panel === 'no_show' ? `No-show: check back${when ? '' : ' in 3 days'}` : 'Set the check-back'}
          </Button>
          <p className="w-full text-xs text-muted-foreground">The {thing} comes off; the check-back is yours and pings you before.</p>
        </div>
      )}
      <ErrorNote error={run.error} />
    </div>
  )
}
