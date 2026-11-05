// The top of the card, in the caller's words (0186; Thalia and Adil's walkthrough 2026-11-04; Colin: "build the full
// shit so the system isnt stupid anymore"). One call (card_brief) gives: what happens next and when, in words; the
// "when you call back, say" line; why this card (reasons, their last words, the last call, what was promised); the last
// three touches and the next two planned; a rest with a wake date; heads-ups between the callers. Everything a caller
// needs before dialing sits here, above the notes, the thread and the script.
import { useState } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge, ErrorNote } from '@/components/ui/form'
import { NextStep } from '@/components/NextStep'
import { WalkControl } from '@/components/WalkControl'
import { supabase } from '@/lib/supabaseClient'
import { fmtDateTime, localInputToIso } from '@/lib/format'
import { CALL_LANES, REST_PRESETS, type CallLane } from '@/lib/nextStep'
import { personLabel } from '@/lib/wpie'
import { useAuth } from '@/providers/AuthProvider'
import type { Lead, Task } from '@/lib/types'
import { cn } from '@/lib/utils'

type Brief = {
  ok: boolean; reason?: string
  lane: string | null; say_next: string | null; next_plain: string | null
  mine_next: { task_id: string; due_at: string | null; kind: string; note: string | null; owner: string | null; source: string | null } | null
  why: { reasons: string[] | null; motivation: string[] | null; last_words: string | null; last_call: string | null; promise: string | null }
  touches: { at: string; channel: string; direction: string; status: string; body: string | null }[]
  touches_total: number
  planned: { at: string; what: string; words: string | null; who: string | null }[]
  rest: { until: string | null; why: string | null; by_colin: boolean } | null
  nudges: { task_id: string; from: string | null; text: string | null; at: string; to: string | null }[]
  locked_to: string | null; belt: string | null; stage: string
}

const KEYS = (leadId: string) => [['card_brief', leadId], ['lead', leadId], ['my_piles'], ['tasks'], ['power_dial'], ['my_day'], ['my_nudges']]
const btn = 'min-h-9 rounded-md border px-2.5 text-xs font-medium hover:bg-accent'

function useBrief(leadId: string) {
  return useQuery({
    queryKey: ['card_brief', leadId],
    queryFn: async () => {
      const r = await supabase.rpc('card_brief', { p_lead_id: leadId })
      if (r.error) throw new Error(r.error.message)
      return r.data as Brief
    },
  })
}

/** The one-line "say" of a touch: who, what, outcome. */
function touchLine(t: Brief['touches'][number]): string {
  if (t.channel === 'call') return (t.body ?? '').replace(/^Call \([^)]*\) from \d+:\s*/, '').replace(/\s+/g, ' ').trim() || `Call: ${t.status.replace(/_/g, ' ')}`
  if (t.channel === 'sms') return `${t.direction === 'in' ? 'They texted' : 'We texted'}: ${(t.body ?? '').replace(/\s+/g, ' ').trim()}`
  return (t.body ?? '').replace(/\s+/g, ' ').trim()
}

export function CardBrief({ lead, tasks }: { lead: Lead; tasks: Task[] }) {
  const { member, isOwner } = useAuth()
  const me = member?.person ?? null
  const isCaller = member?.role === 'caller'
  const q = useBrief(lead.id)
  const qc = useQueryClient()
  const keys = KEYS(lead.id)
  const refresh = () => { for (const k of keys) void qc.invalidateQueries({ queryKey: k }) }
  const [err, setErr] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const rpc = async (fn: string, args: Record<string, unknown>, after?: () => void) => {
    setBusy(true); setErr(null)
    const r = await supabase.rpc(fn, args)
    const d = r.data as { ok?: boolean; reason?: string } | null
    setBusy(false)
    if (r.error || d?.ok === false) { setErr(r.error?.message ?? d?.reason ?? 'Not saved'); return false }
    refresh(); after?.(); return true
  }

  // say line
  const [editSay, setEditSay] = useState(false)
  const [say, setSay] = useState('')
  // rest
  const [restOpen, setRestOpen] = useState(false)
  const [restWhen, setRestWhen] = useState('')
  const [restWhy, setRestWhy] = useState('')
  // heads-up
  const [nudgeOpen, setNudgeOpen] = useState(false)
  const [nudgeTo, setNudgeTo] = useState<string>('')
  const [nudgeText, setNudgeText] = useState('')

  const b = q.data
  const callLane = ((lead.call_facts?.lane?.value as { choices?: string[] } | undefined)?.choices?.[0] ?? null) as CallLane | null
  const laneWords = callLane ? CALL_LANES.find((l) => l.id === callLane)?.label ?? null : null
  const booked = lead.belt === 'visit_booked' || lead.belt === 'visit_missed' || lead.stage === 'walkthrough_booked' ? 'walk'
    : lead.belt === 'call_booked' || lead.belt === 'call_missed' ? 'call' : null
  // the follow-up the Next step control works on: mine first, else (for Colin) the earliest open one on the card
  const open = tasks.filter((t) => !t.done_at && t.kind !== 'nudge' && t.kind !== 'confirm_walk')
  const mineTask = open.find((t) => t.owner === me) ?? (isOwner ? open[0] : undefined) ?? null
  const others = (['thalia', 'adil', 'colin'] as const).filter((p) => p !== me)
  const canTouch = isOwner || (!!me && lead.locked_to === me)

  return (
    <section className="space-y-3 rounded-lg border-2 border-primary/40 bg-card p-3" data-testid="card-brief">
      {/* what happens next */}
      <div>
        <div className="flex flex-wrap items-center gap-1.5">
          <p className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">What happens next</p>
          {laneWords && <Badge tone="info">{laneWords}</Badge>}
          {b?.rest && <Badge tone="warn">Resting</Badge>}
        </div>
        {q.isLoading && <p className="text-sm text-muted-foreground">Reading the card...</p>}
        {b && (
          <p className="mt-0.5 text-base font-medium">
            {b.mine_next
              ? `${b.mine_next.owner === me ? 'Your' : `${personLabel(b.mine_next.owner ?? 'colin')}'s`} ${b.mine_next.kind === 'callback' ? 'callback' : b.mine_next.kind} ${fmtDateTime(b.mine_next.due_at)}${b.mine_next.note ? `: ${b.mine_next.note}` : ''}. `
              : ''}
            <span className={cn(b.mine_next && 'font-normal text-muted-foreground')}>{b.next_plain}</span>
          </p>
        )}
        {booked && <div className="mt-1"><WalkControl leadId={lead.id} kind={booked} /></div>}
        <div className="mt-1"><NextStep leadId={lead.id} task={mineTask} compact /></div>
      </div>

      {/* when you call back, say */}
      <div>
        <p className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">When you call back, say</p>
        {editSay ? (
          <div className="mt-1 flex flex-wrap items-center gap-2">
            <Input value={say} onChange={(e) => setSay(e.target.value)} placeholder='"You said the tenant leaves in March; did that happen?"' className="h-9 min-w-56 flex-1" aria-label="When you call back, say" />
            <Button size="sm" disabled={busy} onClick={() => void rpc('card_say_next', { p_lead_id: lead.id, p_text: say }, () => setEditSay(false))}>Save</Button>
            <Button size="sm" variant="ghost" onClick={() => setEditSay(false)}>Cancel</Button>
          </div>
        ) : (
          <button type="button" className="mt-0.5 block w-full text-left" disabled={!canTouch} onClick={() => { setSay(b?.say_next ?? ''); setEditSay(true) }}>
            {b?.say_next
              ? <span className="text-base">&ldquo;{b.say_next}&rdquo; <span className="text-xs text-muted-foreground">(tap to change)</span></span>
              : <span className="text-sm text-muted-foreground">{canTouch ? 'Nothing written yet. Tap to write the one line your next call opens with.' : 'Nothing written yet.'}</span>}
          </button>
        )}
      </div>

      {/* why this card */}
      {b && (
        <div>
          <p className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">Why this card</p>
          <div className="mt-0.5 flex flex-wrap gap-1">
            {(b.why.reasons ?? []).map((r) => <Badge key={r} tone="warn">{r}</Badge>)}
            {!(b.why.reasons ?? []).length && <span className="text-sm text-muted-foreground">No reason on record yet.</span>}
          </div>
          {!!b.why.motivation?.length && <p className="mt-1 text-sm">{b.why.motivation.join(' · ')}</p>}
          {b.why.last_words && <p className="mt-1 text-sm"><span className="font-medium">Their last text:</span> &ldquo;{b.why.last_words}&rdquo;</p>}
          {b.why.last_call && <p className="mt-1 text-sm"><span className="font-medium">Last call:</span> {b.why.last_call.replace(/\s+/g, ' ')}</p>}
          {b.why.promise && <p className="mt-1 text-sm"><span className="font-medium">Promised:</span> {b.why.promise}</p>}
          <p className="mt-1 text-xs text-muted-foreground">Never say the reason on the phone; it is why we are calling, not what we say.</p>
        </div>
      )}

      {/* touches */}
      {b && (
        <div>
          <p className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">Touches ({b.touches_total} calls and texts)</p>
          <ul className="mt-0.5 space-y-0.5 text-sm">
            {b.touches.map((t) => <li key={`${t.at}-${t.channel}`}><span className="text-muted-foreground">{fmtDateTime(t.at)}</span> · {touchLine(t)}</li>)}
            {b.touches.length === 0 && <li className="text-muted-foreground">Nobody has touched this card yet.</li>}
          </ul>
          {b.planned.length > 0 && (
            <ul className="mt-1 space-y-0.5 text-sm">
              {b.planned.map((p) => (
                <li key={`${p.at}-${p.what}`}><span className="font-medium">Next:</span> {fmtDateTime(p.at)} · {p.what === 'belt' ? 'the machine' : p.what}{p.who ? ` (${personLabel(p.who.replace(/_call|_visit/, ''))})` : ''}{p.words ? `: ${p.words}` : ''}</li>
              ))}
            </ul>
          )}
        </div>
      )}

      {/* rest */}
      {b && (
        <div>
          {b.rest ? (
            <div className="flex flex-wrap items-center gap-2 text-sm">
              <span>
                {b.rest.by_colin ? 'Colin parked this card' : `Resting until ${fmtDateTime(b.rest.until)}`}
                {b.rest.why ? <span className="text-muted-foreground"> · {b.rest.why.split(' | ').slice(-1)[0]}</span> : null}
                {!b.rest.by_colin && <span className="text-muted-foreground">. Wakes sooner on a text, a call or a new record.</span>}
              </span>
              {(isOwner || (!b.rest.by_colin && canTouch)) && (
                <button type="button" className={btn} disabled={busy} onClick={() => void rpc('card_unrest', { p_lead_id: lead.id })}>Wake it</button>
              )}
            </div>
          ) : canTouch && (
            <div className="space-y-1">
              <button type="button" className={cn(btn, restOpen && 'bg-accent')} onClick={() => setRestOpen(!restOpen)}>Rest this card</button>
              {restOpen && (
                <div className="space-y-2 rounded-md border bg-muted/40 p-2">
                  <p className="text-xs text-muted-foreground">Quiet until the day you pick; it wakes sooner if they text, call, or a new record lands on the house.</p>
                  <div className="flex flex-wrap gap-1.5">
                    {REST_PRESETS.map((p) => (
                      <button key={p.id} type="button" className={btn} disabled={busy}
                        onClick={() => void rpc('card_rest', { p_lead_id: lead.id, p_until: p.at(new Date()).toISOString(), p_why: restWhy.trim() || null }, () => setRestOpen(false))}>{p.label}</button>
                    ))}
                  </div>
                  <div className="flex flex-wrap items-center gap-2">
                    <Input type="date" value={restWhen} onChange={(e) => setRestWhen(e.target.value)} aria-label="Rest until" className="h-9 w-auto" />
                    <Input value={restWhy} onChange={(e) => setRestWhy(e.target.value)} placeholder="Why (optional)" className="h-9 min-w-40 flex-1" />
                    <Button size="sm" disabled={!restWhen || busy} onClick={() => { const iso = localInputToIso(`${restWhen}T10:00`); if (iso) void rpc('card_rest', { p_lead_id: lead.id, p_until: iso, p_why: restWhy.trim() || null }, () => setRestOpen(false)) }}>Rest until then</Button>
                  </div>
                </div>
              )}
            </div>
          )}
        </div>
      )}

      {/* heads-ups between the callers */}
      {b && (
        <div>
          <div className="flex flex-wrap items-center gap-2">
            <p className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">Heads-ups</p>
            <button type="button" className={cn(btn, nudgeOpen && 'bg-accent')} onClick={() => setNudgeOpen(!nudgeOpen)}>
              Heads-up to {others.map(personLabel).join(' / ')}
            </button>
          </div>
          {b.nudges.length > 0 && (
            <ul className="mt-1 space-y-1 text-sm">
              {b.nudges.map((n) => (
                <li key={n.task_id} className="flex flex-wrap items-center gap-2 rounded-md bg-amber-50 p-2 dark:bg-amber-950/30">
                  <span><span className="font-medium">{n.from ?? 'Heads-up'}</span> to {personLabel(n.to ?? '')}, {fmtDateTime(n.at)}: {n.text}</span>
                  {(n.to === me || isOwner) && <button type="button" className={btn} disabled={busy} onClick={() => void rpc('nudge_done', { p_task_id: n.task_id })}>Got it</button>}
                </li>
              ))}
            </ul>
          )}
          {nudgeOpen && (
            <div className="mt-1 flex flex-wrap items-center gap-2 rounded-md border bg-muted/40 p-2">
              <div className="flex gap-1">
                {others.map((p) => (
                  <button key={p} type="button" aria-pressed={nudgeTo === p} className={cn(btn, nudgeTo === p && 'bg-primary text-primary-foreground')} onClick={() => setNudgeTo(p)}>{personLabel(p)}</button>
                ))}
              </div>
              <Input value={nudgeText} onChange={(e) => setNudgeText(e.target.value)} placeholder="What they should know (they get a push and see it on Today)" className="h-9 min-w-56 flex-1" />
              <Button size="sm" disabled={!nudgeTo || !nudgeText.trim() || busy}
                onClick={() => void rpc('card_nudge', { p_lead_id: lead.id, p_to: nudgeTo, p_text: nudgeText.trim() }, () => { setNudgeOpen(false); setNudgeText('') })}>Send</Button>
            </div>
          )}
        </div>
      )}

      {isCaller && lead.locked_to && lead.locked_to !== me && (
        <p className="text-xs text-muted-foreground">{personLabel(lead.locked_to)}&apos;s card: you can read it and send a heads-up; the follow-ups are theirs.</p>
      )}
      <ErrorNote error={q.error ?? (err ? new Error(err) : null)} />
    </section>
  )
}
