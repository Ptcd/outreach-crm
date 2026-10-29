// The call queue: the calls due to the signed-in person, one card at a time (Colin 2026-10-22: "do they go to
// the call outs to do and do one then choose dispo then it brings the next and tells them context"). Each
// card says who, where, why they are on the list, what they texted, the numbers to dial, then the script with
// the booking verdict and Log this call. Logging the call finishes the task and brings the next one; Skip
// moves it to the end of this sitting; Hand to Colin gives him the card with one line and pings him.
import { useEffect, useMemo, useState } from 'react'
import { Link, useSearchParams } from 'react-router-dom'
import { Button } from '@/components/ui/button'
import { Badge, Empty, ErrorNote, Textarea } from '@/components/ui/form'
import { CallButton, PersonalCallButton } from '@/components/CallButton'
import { CallScript } from '@/components/CallScript'
import { useDueTasks, useLead, useWrite } from '@/lib/queries'
import { handoffToColin } from '@/lib/apiExtra'
import { endOfTodayIso, fmtDateTime, fmtPhone, fullAddress } from '@/lib/format'
import { STAGE_LABEL } from '@/lib/wpie'
import { useAuth } from '@/providers/AuthProvider'
import { ownerFilterFor, useOnPhone, workerFor } from '@/lib/onPhone'
import { OnPhonePrompt, useColinHere } from '@/components/OnPhonePicker'
import type { Task } from '@/lib/types'
import { orderPhones } from '@/lib/phoneOrder'
import { PowerDial } from '@/components/PowerDial'
import { useDialer } from '@/lib/dialer'

type QueueTask = Task & { lead: { id: string; owner_name: string; property_address: string | null; municipality?: string | null; property_zip?: string | null; stage: string } | null }

export default function CallQueue() {
  const { member } = useAuth()
  const [picked] = useOnPhone()
  const worker = workerFor(member, picked)
  const until = endOfTodayIso()
  // Thalia and Adil work the callers' list (the call list and caller stops are in Thalia's name); Colin his own
  const tasks = useDueTasks(until, ownerFilterFor(worker, member?.person))
  // the Walk-through override is Colin's alone, so on the shared login it follows the person on the phone
  const canOverride = useColinHere()
  const [skipped, setSkipped] = useState<string[]>([])
  const [done, setDone] = useState<string[]>([])
  const queue = useMemo(() => {
    const all = ((tasks.data ?? []) as QueueTask[]).filter((t) => t.kind === 'call' && t.lead_id && !done.includes(t.id))
    const head = all.filter((t) => !skipped.includes(t.id))
    const tail = skipped.map((id) => all.find((t) => t.id === id)).filter((t): t is QueueTask => !!t)
    return [...head, ...tail]
  }, [tasks.data, skipped, done])
  // the card a call is open on stays up until it is logged or skipped, even when the minute's refresh no longer lists
  // it (Thalia 2026-10-28: the next lead came up while she was still on the call)
  const { active } = useDialer()
  const [held, setHeld] = useState<QueueTask | null>(null)
  const top = queue[0] ?? null
  useEffect(() => {
    if (active?.leadId && top?.lead_id === active.leadId && held?.id !== top.id) setHeld(top)
  }, [active?.leadId, top, held?.id])
  const current = held && !done.includes(held.id) && !skipped.includes(held.id) ? held : top
  // A logged call closes the stop on the server (log_call's call row; the belt's trigger) and a hand-off closes the
  // caller's open stops itself, so the queue only steps forward and refreshes; it never marks a stop Done by hand,
  // which the belt would read as a plain Done and route again.
  const refresh = useWrite(async () => ({ data: null, error: null }), [['tasks'], ['lead'], ['leads'], ['pipeline_counts']])
  const total = queue.length + done.length
  // Power hour: the fast cold-call mode (Colin 2026-10-28); remembered per device. Today's Power hour button opens
  // it directly with ?mode=power (Colin 2026-10-29).
  const [params, setParams] = useSearchParams()
  const [mode, setModeState] = useState<'list' | 'power'>(() => {
    if (params.get('mode') === 'power') { try { localStorage.setItem('calls:mode', 'power') } catch { /* fine */ } return 'power' }
    try { return localStorage.getItem('calls:mode') === 'power' ? 'power' : 'list' } catch { return 'list' }
  })
  const setMode = (m: 'list' | 'power') => {
    setModeState(m); try { localStorage.setItem('calls:mode', m) } catch { /* fine */ }
    if (params.has('mode')) setParams({}, { replace: true })
  }
  const tabs = (
    <div className="flex gap-2" role="tablist">
      <Button role="tab" aria-selected={mode === 'list'} variant={mode === 'list' ? 'default' : 'outline'} className="h-10" onClick={() => setMode('list')}>Today&apos;s list</Button>
      <Button role="tab" aria-selected={mode === 'power'} variant={mode === 'power' ? 'default' : 'outline'} className="h-10" onClick={() => setMode('power')}>Power hour</Button>
    </div>
  )
  if (mode === 'power') {
    return (
      <div className="space-y-4">
        <h1 className="text-2xl font-bold tracking-tight">Calls</h1>
        {tabs}
        <OnPhonePrompt />
        <PowerDial caller={worker ?? member?.person ?? 'thalia'} />
      </div>
    )
  }

  return (
    <div className="space-y-4">
      {tabs}
      <div className="flex items-baseline justify-between">
        <h1 className="text-2xl font-bold tracking-tight">Calls</h1>
        <p className="text-sm text-muted-foreground" data-testid="queue-count">
          {total === 0 ? 'nothing to call' : `${Math.min(done.length + 1, total)} of ${total}${skipped.length ? `, ${skipped.length} skipped for now` : ''}`}
        </p>
      </div>
      <OnPhonePrompt />
      <ErrorNote error={tasks.error} />
      {tasks.isLoading && <Empty>Loading...</Empty>}
      {!tasks.isLoading && !current && (
        <Empty>
          {done.length ? `All ${done.length} done. ` : ''}Nothing to call right now. A hot reply pings you the moment it lands; the day&apos;s list is on here each morning.
        </Empty>
      )}
      {current && (
        <QueueCard key={current.id} task={current} canOverride={canOverride}
          onDone={() => { setDone((d) => [...d, current.id]); refresh.mutate(undefined) }}
          onSkip={() => setSkipped((s) => [...s, current.id])} />
      )}
    </div>
  )
}

function QueueCard({ task, canOverride, onDone, onSkip }: { task: QueueTask; canOverride: boolean; onDone: () => void; onSkip: () => void }) {
  const q = useLead(task.lead_id!)
  const [handing, setHanding] = useState(false)
  const [note, setNote] = useState('')
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  if (q.isLoading) return <Empty>Loading the card...</Empty>
  if (q.error) return <ErrorNote error={q.error} />
  if (!q.data) return <Empty>That card is gone.</Empty>
  const { lead, contacts, messages, gates } = q.data
  const facts = q.data.facts ?? {}
  const phones = orderPhones(contacts, lead.owner_name)
  const phoneRow = (c: (typeof phones)[number]) => {
            const blocked = c.suppressed || c.dnc_app || c.dnc_vendor || c.dnc_scrub === 'dnc' || c.status === 'bad'
            const ten = (c.value_normalized ?? c.value).replace(/\D/g, '').slice(-10)
            return (
              <li key={c.id} className="flex flex-wrap items-center gap-2 text-sm">
                <span>{fmtPhone(c.value_normalized ?? c.value)}</span>
                {c.line_type && <Badge>{c.line_type}</Badge>}
                {c.person_name && (c.owners
                  ? <span className="text-muted-foreground">{c.person_name}</span>
                  : <Badge tone="warn">Not the owner: {c.person_name}</Badge>)}
                <CallButton to={c.value_normalized ?? c.value} name={lead.owner_name} address={lead.property_address} leadId={lead.id}
                  contactId={c.id} blocked={blocked} size="sm" notBefore={lead.belt === 'not_now_dated' ? lead.named_date : null} />
                {/* the same door as on the card: a call from your own phone pauses the texts too, and a call that
                    never connected is undone here without leaving the list (2026-10-22) */}
                {(!lead.human_takeover_at || lead.human_takeover_phone === ten) && (
                  <PersonalCallButton to={c.value_normalized ?? c.value} leadId={lead.id} blocked={blocked}
                    activeKey={lead.human_takeover_at ? lead.human_takeover_key : null}
                    notBefore={lead.belt === 'not_now_dated' ? lead.named_date : null} />
                )}
              </li>
            )
  }
  const ownPhones = phones.filter((c) => c.owners)
  const otherPhones = phones.filter((c) => !c.owners)
  const texted = messages.filter((m) => m.channel === 'sms' && m.direction === 'in').slice(-3)
  const hand = async () => {
    setBusy(true)
    setErr(null)
    try {
      const r = await handoffToColin(lead.id, note.trim())
      if (!r.ok) { setErr(r.reason ?? 'Not handed off'); return }
      onDone()
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e))
    } finally {
      setBusy(false)
    }
  }
  return (
    <section className="space-y-3 rounded-lg border-2 border-primary/40 bg-card p-3" data-testid="queue-card">
      <div>
        <h2 className="text-lg font-semibold">{lead.owner_name}</h2>
        <p className="text-sm">{fullAddress(lead)}</p>
        <div className="mt-1 flex flex-wrap gap-2">
          <Badge>{STAGE_LABEL[lead.stage]}</Badge>
          {lead.lane && <Badge tone="info">{lead.lane === 'hold' ? 'Hold lane' : 'Flip lane'}</Badge>}
          <Link to={`/lead/${lead.id}`} className="inline-flex min-h-6 items-center text-sm underline">Open the full card</Link>
        </div>
      </div>

      <div className="rounded-md bg-muted p-3 text-sm">
        <p className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">Why this call</p>
        <p className="mt-1 font-medium">{task.title ?? 'On your list'}{task.note ? `: ${task.note}` : ''}</p>
        {lead.reasons_to_sell.length > 0 && (
          <p className="mt-1 text-muted-foreground">Why they are on the list (never say this to them): {lead.reasons_to_sell.join(', ')}</p>
        )}
        {task.quote && <p className="mt-1">They said: &ldquo;{task.quote}&rdquo;</p>}
        <p className="mt-1 text-xs text-muted-foreground">Due {fmtDateTime(task.due_at)}</p>
      </div>

      {texted.length > 0 && (
        <div className="text-sm">
          <p className="font-medium">What they texted</p>
          {texted.map((m) => <p key={m.id} className="mt-1 rounded bg-blue-50 p-2">{m.body} <span className="text-xs text-muted-foreground">{fmtDateTime(m.sent_at)}</span></p>)}
        </div>
      )}

      <div>
        <p className="text-sm font-medium">Numbers to dial <span className="font-normal text-muted-foreground">(the owner&apos;s first; someone else&apos;s number: ask for the owner)</span></p>
        {lead.belt === 'not_now_dated' && lead.named_date && new Date(lead.named_date).getTime() > Date.now() && (
          <p className="mt-1 rounded-md border border-amber-400 bg-amber-50 p-2 text-sm">
            They asked us to wait until {fmtDateTime(lead.named_date)}. Outbound call controls return then.
          </p>
        )}
        {phones.length === 0 && <p className="text-sm text-muted-foreground">No phone on the card.</p>}
        {/* other people's numbers fold away once the owner has a number of their own (a card showed 1 owner number
            and 10 of a relative's, pushing the script off the screen) */}
        <ul className="mt-1 space-y-2">{ownPhones.map(phoneRow)}</ul>
        {otherPhones.length > 0 && (ownPhones.length > 0
          ? <details className="mt-2 text-sm"><summary className="cursor-pointer text-muted-foreground">Other people&apos;s numbers ({otherPhones.length}): only if the owner&apos;s don&apos;t answer; ask for the owner</summary>
              <ul className="mt-2 space-y-2">{otherPhones.map(phoneRow)}</ul></details>
          : <ul className="mt-1 space-y-2">{otherPhones.map(phoneRow)}</ul>)}
        {lead.human_takeover_at && (
          <p className="mt-2 rounded-md border-2 border-amber-400 bg-amber-50 p-2 text-sm">
            A call is open on this card (started by {lead.human_takeover_by ?? 'the team'}): texts to them are paused. Log the
            outcome below, or tap <span className="font-medium">Call did not happen — resume</span> if it never connected.
          </p>
        )}
      </div>

      <CallScript lead={lead} contacts={contacts} messages={messages} replyFacts={facts} latestGate={gates[0] ?? null}
        phone={phones[0]?.value_normalized ?? null} startOpen canOverride={canOverride} onLogged={onDone} />

      <div className="space-y-2 rounded-md border p-3">
        <div className="flex flex-wrap gap-2">
          <Button variant="outline" className="h-11" onClick={onSkip}>Skip for now</Button>
          <Button variant="outline" className="h-11" onClick={() => setHanding((h) => !h)}>Hand to Colin</Button>
        </div>
        {handing && (
          <div className="space-y-2">
            <Textarea rows={2} placeholder="One line for Colin: why this one is worth his time (their reason, their number, who signs)"
              value={note} onChange={(e) => setNote(e.target.value)} />
            <Button className="h-11" disabled={busy || !note.trim()} onClick={() => void hand()}>{busy ? 'Handing off...' : 'Send to Colin'}</Button>
            <p className="text-xs text-muted-foreground">Colin gets the card, a task with your line, and a ping on his phone. This call leaves your list.</p>
          </div>
        )}
        {err && <p className="text-sm text-red-700">{err}</p>}
      </div>
    </section>
  )
}
