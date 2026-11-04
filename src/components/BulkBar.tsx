// Bulk actions on My cards (0173; Colin 2026-11-03). Tick rows, then: move every picked follow-up to one time, close
// them, or hand the cards to Colin with one line. Each goes through the single doors (followups_move_many,
// followups_done_many, cards_hand_many), so a follow-up that is not yours is refused and a belt stop is closed the
// belt's way. Cards with no follow-up can still be handed over, and "Set" gives each of them one.
import { useState } from 'react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { ErrorNote } from '@/components/ui/form'
import { api, useWrite } from '@/lib/queries'
import { localInputToIso } from '@/lib/format'
import { PRESETS } from '@/lib/nextStep'
import type { PileCard } from '@/lib/piles'
import { cn } from '@/lib/utils'

const KEYS = [['my_piles'], ['tasks'], ['warm_board'], ['power_dial'], ['leads']]

export function BulkBar({ cards, onDone }: { cards: PileCard[]; onDone: () => void }) {
  const [panel, setPanel] = useState<'move' | 'done' | 'hand' | null>(null)
  const [when, setWhen] = useState('')
  const [note, setNote] = useState('')
  const [msg, setMsg] = useState<string | null>(null)
  const taskIds = cards.map((c) => c.task_id).filter((x): x is string => !!x)
  const noTask = cards.filter((c) => !c.task_id).map((c) => c.lead_id)
  const result = (r: { data: unknown; error: { message: string } | null }, word: string) => {
    const d = r.data as { ok?: boolean; reason?: string; moved?: number; done?: number; handed?: number; refused?: { reason: string }[] } | null
    if (r.error) return { error: r.error }
    if (d && d.ok === false) return { error: { message: d.reason ?? 'not done' } }
    const n = d?.moved ?? d?.done ?? d?.handed ?? 0
    const refused = d?.refused?.length ?? 0
    setMsg(`${n} ${word}${refused ? `, ${refused} refused (${d?.refused?.[0]?.reason})` : ''}`)
    return { error: null }
  }
  const move = useWrite(async (atIso: string) => {
    // a picked card with no follow-up gets one at the same time
    for (const lid of noTask) await api.followupSet(lid, atIso, 'call', note.trim() || null)
    const r = taskIds.length ? await api.followupsMoveMany(taskIds, atIso, note.trim() || null) : { data: { ok: true, moved: 0 }, error: null }
    const out = result(r, 'moved')
    if (!out.error && noTask.length) setMsg((m) => `${m}, ${noTask.length} set`)
    return out
  }, KEYS)
  const done = useWrite(async () => result(await api.followupsDoneMany(taskIds, 'done', note.trim() || null), 'closed'), KEYS)
  const hand = useWrite(async () => result(await api.cardsHandMany(cards.map((c) => c.lead_id), note.trim()), 'handed to Colin'), KEYS)
  const finish = () => { setPanel(null); setWhen(''); setNote(''); onDone() }
  const busy = move.isPending || done.isPending || hand.isPending
  const btn = 'min-h-9 rounded-md border px-2.5 text-xs font-medium hover:bg-accent'
  if (cards.length === 0) return msg ? <p className="text-xs text-emerald-700">{msg}</p> : null
  return (
    <div className="sticky top-16 z-20 space-y-2 rounded-lg border-2 border-primary bg-background p-3 shadow-md">
      <div className="flex flex-wrap items-center gap-2 text-sm">
        <span className="font-semibold">{cards.length} picked</span>
        <button type="button" className={cn(btn, panel === 'move' && 'bg-accent')} onClick={() => setPanel(panel === 'move' ? null : 'move')}>Move to...</button>
        <button type="button" className={cn(btn, panel === 'done' && 'bg-accent')} disabled={taskIds.length === 0} onClick={() => setPanel(panel === 'done' ? null : 'done')}>Done</button>
        <button type="button" className={cn(btn, panel === 'hand' && 'bg-accent')} onClick={() => setPanel(panel === 'hand' ? null : 'hand')}>Hand to Colin</button>
        <button type="button" className={btn} onClick={finish}>Clear</button>
      </div>
      {panel === 'move' && (
        <div className="space-y-2">
          <div className="flex flex-wrap gap-1.5">
            {PRESETS.map((p) => (
              <button key={p.id} type="button" disabled={busy} className={btn} onClick={() => move.mutate(p.at(new Date()).toISOString(), { onSuccess: finish })}>{p.label}</button>
            ))}
          </div>
          <div className="flex flex-wrap items-center gap-2">
            <Input type="datetime-local" value={when} onChange={(e) => setWhen(e.target.value)} aria-label="Day and time" className="h-9 w-auto" />
            <Input value={note} onChange={(e) => setNote(e.target.value)} placeholder="Why (optional)" className="h-9 min-w-40 flex-1" />
            <Button size="sm" disabled={!when || busy} onClick={() => { const iso = localInputToIso(when); if (iso) move.mutate(iso, { onSuccess: finish }) }}>Move them</Button>
          </div>
        </div>
      )}
      {panel === 'done' && (
        <div className="flex flex-wrap items-center gap-2">
          <Input value={note} onChange={(e) => setNote(e.target.value)} placeholder="What happened (optional)" className="h-9 min-w-40 flex-1" />
          <Button size="sm" disabled={busy} onClick={() => done.mutate(undefined, { onSuccess: finish })}>Close {taskIds.length}</Button>
          {noTask.length > 0 && <span className="text-xs text-muted-foreground">{noTask.length} picked have no follow-up to close.</span>}
        </div>
      )}
      {panel === 'hand' && (
        <div className="flex flex-wrap items-center gap-2">
          <Input value={note} onChange={(e) => setNote(e.target.value)} placeholder="One line for Colin: what he needs to do with these" className="h-9 min-w-56 flex-1" />
          <Button size="sm" disabled={!note.trim() || busy} onClick={() => hand.mutate(undefined, { onSuccess: finish })}>Hand {cards.length} over</Button>
        </div>
      )}
      <ErrorNote error={move.error ?? done.error ?? hand.error} />
      {msg && <p className="text-xs text-emerald-700">{msg}</p>}
    </div>
  )
}
