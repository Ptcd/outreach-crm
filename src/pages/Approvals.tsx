import { useState } from 'react'
import { Link } from 'react-router-dom'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge, Empty, ErrorNote, Section } from '@/components/ui/form'
import { ConfirmButton } from '@/components/ui/confirm'
import { api, useCampaignControl, usePlannedOpeners, useWrite } from '@/lib/queries'
import { fmtDateTime, fmtPhone, todayLocal } from '@/lib/format'
import { SEND_LABEL, WORDING, reasonText, sendTone } from '@/lib/inbox'
import { useAuth } from '@/providers/AuthProvider'
import { useColinHere } from '@/components/OnPhonePicker'
import { TouchSwitches } from '@/components/TouchSwitches'
import type { CampaignControl, OpenerDecision, PlannedOpener } from '@/lib/types'

const DECISION_LABEL: Record<OpenerDecision, string> = { pending: 'Waiting', approved: 'Approved', skipped: 'Skipped' }
const UNSENT = new Set(['planned', 'would_send'])

export default function Approvals() {
  const { member } = useAuth()
  const isOwner = useColinHere()   // the switches are Colin's: on the shared login, the phone set to Colin
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
    <div className="space-y-4 pb-36 sm:pb-0">
      <h1 className="text-2xl font-bold tracking-tight">Texts to approve</h1>
      <SendingPanel canDecide={isOwner} />
      <TouchSwitches canDecide={isOwner} />
      <div className="flex flex-wrap items-center gap-3">
        <label className="text-sm font-medium">
          Day <Input type="date" value={day} onChange={(e) => { setDay(e.target.value); setTicked(new Set()) }} className="mt-1 w-48" />
        </label>
        <span className="text-sm">
          {rows.length} planned - {decisions.pending ?? 0} waiting, {decisions.approved ?? 0} approved, {decisions.skipped ?? 0} skipped
          {' | '}{(sends.sent ?? 0) + (sends.delivered ?? 0)} sent, {sends.delivered ?? 0} delivered
          {sends.would_send ? `, ${sends.would_send} passed a test run` : ''}
        </span>
      </div>
      {!isOwner && <p className="rounded bg-muted p-2 text-sm text-muted-foreground">You approve or skip each text and the whole day; the sending switch and the pause are Colin&apos;s.</p>}
      {!!member && rows.length > 0 && (
        <div className="fixed inset-x-0 bottom-[calc(4rem+env(safe-area-inset-bottom))] z-20 !m-0 border-t bg-background p-3 shadow-[0_-4px_12px_rgba(0,0,0,0.06)] sm:sticky sm:top-14 sm:bottom-auto sm:-mx-4 sm:border-b sm:border-t-0 sm:px-4 sm:py-2">
          <div className="mx-auto flex max-w-5xl flex-col gap-2 sm:flex-row sm:flex-wrap">
            <ConfirmButton className="h-12 w-full text-base sm:h-10 sm:w-auto" disabled={busy || waiting.length === 0}
              question={tickedWaiting.length
                ? `Approve ${waiting.length - tickedWaiting.length} texts and skip the ${tickedWaiting.length} you ticked?`
                : `Approve all ${waiting.length} waiting texts for ${day}?`}
              yes="Yes, approve" onConfirm={() => approveAll.mutate(tickedWaiting, { onSuccess: () => setTicked(new Set()) })}>
              {tickedWaiting.length ? `Approve all except ${tickedWaiting.length} ticked` : `Approve all (${waiting.length})`}
            </ConfirmButton>
            <div className="grid grid-cols-2 gap-2 sm:flex">
              <ConfirmButton variant="outline" className="h-12 w-full sm:h-10 sm:w-auto" disabled={busy || unsent.length === 0} tone="danger"
                question={`Withdraw the ${unsent.length} texts for ${day} that have not been sent? They will not go out.`}
                yes="Yes, withdraw" onConfirm={() => withdraw.mutate(undefined)}>
                Withdraw ({unsent.length})
              </ConfirmButton>
              {ticked.size > 0 && <Button variant="ghost" className="h-12 sm:h-10" onClick={() => setTicked(new Set())}>Clear ticks</Button>}
            </div>
          </div>
        </div>
      )}
      <ErrorNote error={q.error ?? decide.error ?? approveAll.error ?? withdraw.error} />
      {q.isLoading && <Empty>Loading...</Empty>}
      {q.data && rows.length === 0 && <Empty>No texts planned for this day. Run the WPIE plan, then the sync push.</Empty>}
      <div className="space-y-3">
        {rows.map((r) => (
          <OpenerCard key={r.id} r={r} canDecide={!!member} busy={busy} ticked={ticked.has(r.id)} onTick={() => toggle(r.id)}
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
  const setRoutine = useWrite((on: boolean) => api.setRoutine(on), keys)
  const setTest = useWrite((p: string) => api.setTestPhone(p), keys)
  const resetTest = useWrite(() => api.resetTestPhones(), keys)
  const [testPhone, setTestPhone] = useState<string | null>(null)
  const clearPause = useWrite(() => api.clearPause(), keys)
  const resumeFollowups = useWrite(() => api.resumeFollowups(), keys)
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
        <div className="mb-3 rounded-md bg-red-50 p-3 text-sm text-red-900 dark:bg-red-950 dark:text-red-100">
          <p className="font-medium">Sending is paused. Nothing goes out until this is cleared.</p>
          {c.paused && <p>{c.pause_reason} {c.paused_at ? `(${fmtDateTime(c.paused_at)})` : ''}</p>}
          {c.laptop_paused && <p>WPIE's delivery watchdog on the laptop: {c.laptop_pause_reason}. Clear it there with "watchdog --clear".</p>}
          {c.paused && canDecide && (
            <div className="mt-2">
              <ConfirmButton variant="outline" className="h-12 w-full sm:w-auto" disabled={clearPause.isPending}
                question="Clear the pause? Only do this once you know why Twilio or the carriers refused texts." yes="Yes, clear it"
                onConfirm={() => clearPause.mutate(undefined)}>
                Clear pause
              </ConfirmButton>
            </div>
          )}
        </div>
      )}
      {c.followups_paused && (
        <div className="mb-3 rounded-md bg-amber-50 p-3 text-sm text-amber-950">
          <p className="font-medium">Follow-up texts (2 and 3) are paused. New openers keep going.</p>
          <p>{c.followups_pause_reason} {c.followups_paused_at ? `(${fmtDateTime(c.followups_paused_at)})` : ''}</p>
          {canDecide && (
            <ConfirmButton variant="outline" className="mt-2 h-12 w-full sm:w-auto" disabled={resumeFollowups.isPending}
              question="Restart follow-up texts? Only once you know why people opted out of them." yes="Yes, restart"
              onConfirm={() => resumeFollowups.mutate(undefined)}>
              Restart follow-ups
            </ConfirmButton>
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
            <Button variant="outline" className="h-12 w-full sm:w-auto" disabled={setSending.isPending} onClick={() => setSending.mutate(false)}>Turn sending off</Button>
          ) : (
            <ConfirmButton className="h-12 w-full sm:w-auto" disabled={setSending.isPending}
              question="Turn sending on? Approved texts start going out to sellers at their planned times." yes="Yes, turn on"
              onConfirm={() => setSending.mutate(true)}>
              Turn sending on
            </ConfirmButton>
          )}
        </div>
      )}
      <div className="mt-4 border-t pt-3">
        <div className="flex items-center justify-between gap-2">
          <p className="font-medium">Auto-answer routine replies</p>
          <Badge tone={c.routine_enabled ? 'good' : 'muted'}>{c.routine_enabled ? 'On' : 'Off'}</Badge>
        </div>
        <p className="mt-1 text-sm">
          Removals always take effect at once. When this is on, the system also answers wrong numbers, sold, not interested,
          &quot;who is this&quot; and &quot;is this a bot&quot; with WPIE&apos;s fixed lines (8am-9pm). Real replies always wait for your Approve.
        </p>
        <p className="mt-1 text-xs text-muted-foreground">
          Red-team test: {c.redteam_total ? `${c.redteam_passed}/${c.redteam_total} ${c.redteam_ok ? 'passed' : 'FAILED'}` : 'not run yet'}
          {c.redteam_version && c.redteam_version !== c.agent_rules_version ? ' (for older rules)' : ''}
          {c.agent_last_run_at ? ` - last checked ${fmtDateTime(c.agent_last_run_at)}` : ' - not checked yet'}
        </p>
        {canDecide && (
          c.routine_enabled ? (
            <Button className="mt-2 h-12 w-full sm:w-auto" variant="outline" disabled={setRoutine.isPending} onClick={() => setRoutine.mutate(false)}>Turn routine replies off</Button>
          ) : (
            <div className="mt-2">
              <ConfirmButton className="h-12 w-full sm:w-auto" disabled={setRoutine.isPending || !c.redteam_ok}
                question="Answer wrong numbers, sold, not interested, who-is-this and is-this-a-bot texts automatically?" yes="Yes, turn on"
                onConfirm={() => setRoutine.mutate(true)}>
                Turn routine replies on
              </ConfirmButton>
            </div>
          )
        )}
      </div>
      {canDecide && (
        <div className="mt-4 border-t pt-3">
          <p className="font-medium">Test phone</p>
          {c.test_phones.length > 0 ? (
            <p className="mt-1 rounded-md bg-amber-50 p-2 text-sm font-medium text-amber-950">
              Test phone: {c.test_phones.map(fmtPhone).join(', ')} plays {c.test_owner_name || 'a sample owner'}
              {c.test_property_address ? `, ${c.test_property_address}` : ''}.
            </p>
          ) : <p className="mt-1 text-sm">No test phone set.</p>}
          <p className="mt-1 text-sm">
            Text the campaign number from that phone and you get exactly what that owner would get: a draft for you to approve,
            marked TEST in the Inbox. Nothing touches the real owner.
          </p>
          <div className="mt-2 flex flex-wrap items-center gap-2">
            <Input className="w-44" inputMode="tel" placeholder="Your cell" value={testPhone ?? (c.test_phones[0] ?? '')}
              onChange={(e) => setTestPhone(e.target.value)} aria-label="Test phone" />
            <Button variant="outline" disabled={setTest.isPending} onClick={() => setTest.mutate((testPhone ?? '').trim())}>Save</Button>
            <ConfirmButton variant="ghost" disabled={resetTest.isPending || !c.test_phones.length}
              question="Unblock your test phone after a STOP test?" yes="Yes, unblock" onConfirm={() => resetTest.mutate(undefined)}>
              Reset after a STOP test
            </ConfirmButton>
          </div>
        </div>
      )}
      <ErrorNote error={setSending.error ?? clearPause.error ?? resumeFollowups.error ?? setRoutine.error ?? setTest.error ?? resetTest.error} />
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
        {(r.step ?? 1) > 1 ? <Badge tone="info">Text {r.step} (follow-up)</Badge> : <Badge>Text 1</Badge>}
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
        <Link to={`/lead/${r.lead_id}`} className="mt-1 inline-flex min-h-11 items-center text-sm underline">
          Open lead
        </Link>
      )}
      {canDecide && open && (
        <div className="mt-3 space-y-2">
          {r.decision === 'pending' && (
            <label className="flex min-h-11 cursor-pointer items-center gap-3 text-sm">
              <input type="checkbox" className="h-6 w-6" checked={ticked} onChange={onTick} />
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
