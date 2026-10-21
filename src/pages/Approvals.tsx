import { useState } from 'react'
import { Link } from 'react-router-dom'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge, Empty, ErrorNote, Section } from '@/components/ui/form'
import { api, useCampaignControl, usePlannedOpeners, useWrite } from '@/lib/queries'
import { fmtDateTime, fmtPhone, todayLocal } from '@/lib/format'
import { SEND_LABEL, WORDING, reasonText, sendTone } from '@/lib/inbox'
import { useAuth } from '@/providers/AuthProvider'
import type { CampaignControl, OpenerDecision, PlannedOpener } from '@/lib/types'

const DECISION_LABEL: Record<OpenerDecision, string> = { pending: 'Waiting', approved: 'Approved', skipped: 'Skipped' }
const UNSENT = new Set(['planned', 'would_send'])

export default function Approvals() {
  const { isOwner, member } = useAuth()
  const [day, setDay] = useState(todayLocal())
  const [ticked, setTicked] = useState<Set<string>>(new Set())
  const q = usePlannedOpeners(day)
  const keys = [['planned_openers', day], ['campaign_control'], ['inbox']]
  const decide = useWrite(
    ({ id, decision, note }: { id: string; decision: OpenerDecision; note: string | null }) =>
      api.decideOpener(id, decision, member?.display_name ?? 'Colin', note),
    keys,
  )
  const approveAll = useWrite((except: string[]) => api.approveDay(day, except), keys)
  const withdraw = useWrite(() => api.withdrawDay(day), keys)
  const rows = q.data ?? []
  const waiting = rows.filter((r) => r.decision === 'pending' && UNSENT.has(r.send_status))
  const unsent = rows.filter((r) => UNSENT.has(r.send_status))
  const by = (k: (r: PlannedOpener) => string) => rows.reduce((c, r) => ({ ...c, [k(r)]: (c[k(r)] ?? 0) + 1 }), {} as Record<string, number>)
  const decisions = by((r) => r.decision)
  const sends = by((r) => r.send_status)
  const tickedWaiting = waiting.filter((r) => ticked.has(r.id)).map((r) => r.id)
  const busy = decide.isPending || approveAll.isPending || withdraw.isPending

  const toggle = (id: string) => setTicked((s) => {
    const n = new Set(s)
    if (n.has(id)) n.delete(id)
    else n.add(id)
    return n
  })

  return (
    <div className="space-y-4">
      <h1 className="text-xl font-semibold">Texts to approve</h1>
      <SendingPanel canDecide={isOwner} />
      <div className="flex flex-wrap items-center gap-3">
        <label className="text-sm font-medium">
          Day <Input type="date" value={day} onChange={(e) => { setDay(e.target.value); setTicked(new Set()) }} className="mt-1 w-44" />
        </label>
        <span className="text-sm">
          {rows.length} planned - {decisions.pending ?? 0} waiting, {decisions.approved ?? 0} approved, {decisions.skipped ?? 0} skipped
          {' | '}{(sends.sent ?? 0) + (sends.delivered ?? 0)} sent, {sends.delivered ?? 0} delivered
          {sends.would_send ? `, ${sends.would_send} passed a test run` : ''}
        </span>
      </div>
      {!isOwner && <p className="rounded bg-amber-50 p-2 text-sm text-amber-900">Only Colin can approve, skip or withdraw.</p>}
      {isOwner && rows.length > 0 && (
        <div className="sticky top-14 z-[5] -mx-4 flex flex-wrap gap-2 border-b bg-background/95 px-4 py-2 backdrop-blur">
          <Button
            disabled={busy || waiting.length === 0}
            onClick={() => {
              const n = waiting.length - tickedWaiting.length
              const msg = tickedWaiting.length
                ? `Approve ${n} texts and skip the ${tickedWaiting.length} you ticked?`
                : `Approve all ${n} waiting texts for ${day}?`
              if (window.confirm(msg)) approveAll.mutate(tickedWaiting, { onSuccess: () => setTicked(new Set()) })
            }}
          >
            {tickedWaiting.length ? `Approve all except ${tickedWaiting.length} ticked` : `Approve all (${waiting.length})`}
          </Button>
          <Button
            variant="outline"
            disabled={busy || unsent.length === 0}
            onClick={() => { if (window.confirm(`Withdraw the ${unsent.length} texts for ${day} that have not been sent? They will not go out.`)) withdraw.mutate(undefined) }}
          >
            Withdraw unsent ({unsent.length})
          </Button>
          {ticked.size > 0 && <Button variant="ghost" onClick={() => setTicked(new Set())}>Clear ticks</Button>}
        </div>
      )}
      <ErrorNote error={q.error ?? decide.error ?? approveAll.error ?? withdraw.error} />
      {q.isLoading && <Empty>Loading...</Empty>}
      {q.data && rows.length === 0 && <Empty>No texts planned for this day. Run the WPIE plan, then the sync push.</Empty>}
      <div className="space-y-3">
        {rows.map((r) => (
          <OpenerCard key={r.id} r={r} canDecide={isOwner} busy={busy} ticked={ticked.has(r.id)} onTick={() => toggle(r.id)}
            onDecide={(decision, note) => decide.mutate({ id: r.id, decision, note })} />
        ))}
      </div>
    </div>
  )
}

function SendingPanel({ canDecide }: { canDecide: boolean }) {
  const q = useCampaignControl()
  const keys = [['campaign_control']]
  const setSending = useWrite((on: boolean) => api.setSending(on), keys)
  const clearPause = useWrite(() => api.clearPause(), keys)
  const c: CampaignControl | undefined = q.data
  if (q.error) return <ErrorNote error={q.error} />
  if (!c) return null
  const run = c.last_run_summary
  return (
    <Section
      title="Sending"
      right={<Badge tone={c.paused || c.laptop_paused ? 'bad' : c.sending_enabled ? 'good' : 'muted'}>
        {c.paused || c.laptop_paused ? 'Paused' : c.sending_enabled ? 'On' : 'Off'}
      </Badge>}
    >
      {(c.paused || c.laptop_paused) && (
        <div className="mb-3 rounded-md bg-red-50 p-3 text-sm text-red-900">
          <p className="font-medium">Sending is paused. Nothing goes out until this is cleared.</p>
          {c.paused && <p>{c.pause_reason} {c.paused_at ? `(${fmtDateTime(c.paused_at)})` : ''}</p>}
          {c.laptop_paused && <p>WPIE's delivery watchdog on the laptop: {c.laptop_pause_reason}. Clear it there with "watchdog --clear".</p>}
          {c.paused && canDecide && (
            <Button className="mt-2" variant="outline" disabled={clearPause.isPending}
              onClick={() => { if (window.confirm('Clear the pause? Only do this once you know why Twilio or the carriers refused texts.')) clearPause.mutate(undefined) }}>
              Clear pause
            </Button>
          )}
        </div>
      )}
      <p className="text-sm">
        {c.sending_enabled
          ? 'On: approved texts go out from the server at their planned time, between '
          : 'Off: nothing is sent. When on, approved texts go out from the server at their planned time, between '}
        {c.window_start.slice(0, 5)} and {c.window_end.slice(0, 5)} Central, at most {c.daily_cap} a day, never on Sunday.
        Every text is checked again right before it goes (STOP list, replies, DNC, one text per owner).
      </p>
      {c.sending_changed_at && (
        <p className="mt-1 text-xs text-muted-foreground">Turned {c.sending_enabled ? 'on' : 'off'} by {c.sending_changed_by} {fmtDateTime(c.sending_changed_at)}</p>
      )}
      {run && (
        <p className="mt-1 text-xs text-muted-foreground">
          Last server check {fmtDateTime(c.last_run_at)}: {run.mode === 'dry' ? `test run only (${run.why_dry})` : 'live'}
          {' - '}{run.sent} sent{run.would_send ? `, ${run.would_send} would send` : ''}{run.skipped.length ? `, ${run.skipped.length} skipped` : ''}
          {run.inbound_new ? `, ${run.inbound_new} replies read` : ''}{run.inbound_error ? `, could not read replies: ${run.inbound_error}` : ''}
        </p>
      )}
      {canDecide && (
        <div className="mt-3">
          {c.sending_enabled ? (
            <Button variant="outline" disabled={setSending.isPending} onClick={() => setSending.mutate(false)}>Turn sending off</Button>
          ) : (
            <Button disabled={setSending.isPending}
              onClick={() => { if (window.confirm('Turn sending on? Approved texts will start going out to sellers at their planned times.')) setSending.mutate(true) }}>
              Turn sending on
            </Button>
          )}
        </div>
      )}
      <ErrorNote error={setSending.error ?? clearPause.error} />
    </Section>
  )
}

function OpenerCard({
  r, canDecide, busy, ticked, onTick, onDecide,
}: {
  r: PlannedOpener
  canDecide: boolean
  busy: boolean
  ticked: boolean
  onTick: () => void
  onDecide: (d: OpenerDecision, note: string | null) => void
}) {
  const [note, setNote] = useState(r.decision_note ?? '')
  const open = UNSENT.has(r.send_status)
  return (
    <Section
      title={r.owner_name ?? `Owner ${r.wpie_owner_id}`}
      right={
        <div className="flex flex-wrap justify-end gap-1">
          <Badge tone={r.decision === 'approved' ? 'good' : r.decision === 'skipped' ? 'bad' : 'warn'}>{DECISION_LABEL[r.decision]}</Badge>
          {r.send_status !== 'planned' && <Badge tone={sendTone(r.send_status)}>{SEND_LABEL[r.send_status]}</Badge>}
        </div>
      }
    >
      <div className="mb-2 text-sm text-muted-foreground">
        {r.property_address} - to {fmtPhone(r.phone)} {r.scheduled_at ? `- planned ${fmtDateTime(r.scheduled_at)}` : ''}
        {r.sent_at ? ` - sent ${fmtDateTime(r.sent_at)}` : ''}
      </div>
      <div className="mb-2 flex flex-wrap gap-2">
        {r.lane && <Badge tone="info">{r.lane}</Badge>}
        {r.template_lane && <Badge>{WORDING[r.template_lane] ?? r.template_lane} wording</Badge>}
        {r.variant && <Badge>version {r.variant}</Badge>}
        {r.segments && <Badge>{r.segments} segments</Badge>}
        {r.attempt > 1 && <Badge tone="warn">second number (wrong number before)</Badge>}
      </div>
      <p className="whitespace-pre-wrap rounded-md bg-muted p-3 text-sm">{r.body}</p>
      {r.send_reason && !open && <p className="mt-2 text-xs text-muted-foreground">Why: {reasonText(r.send_reason)}</p>}
      {r.decided_at && (
        <p className="mt-2 text-xs text-muted-foreground">
          {DECISION_LABEL[r.decision]} by {r.decided_by_name} {fmtDateTime(r.decided_at)}
          {r.decision_note ? ` - ${r.decision_note}` : ''}
        </p>
      )}
      {r.lead_id && (
        <Link to={`/lead/${r.lead_id}`} className="mt-2 inline-block text-sm underline">
          Open lead
        </Link>
      )}
      {canDecide && open && (
        <div className="mt-3 space-y-2">
          {r.decision === 'pending' && (
            <label className="flex items-center gap-2 text-sm">
              <input type="checkbox" className="h-5 w-5" checked={ticked} onChange={onTick} />
              Leave this one out of "Approve all"
            </label>
          )}
          <Input placeholder="Note (optional)" value={note} onChange={(e) => setNote(e.target.value)} />
          <div className="flex gap-2">
            <Button disabled={busy || r.decision === 'approved'} onClick={() => onDecide('approved', note.trim() || null)}>
              Approve
            </Button>
            <Button variant="outline" disabled={busy || r.decision === 'skipped'} onClick={() => onDecide('skipped', note.trim() || null)}>
              Skip
            </Button>
          </div>
        </div>
      )}
    </Section>
  )
}
