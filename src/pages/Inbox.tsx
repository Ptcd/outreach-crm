import { useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge, Empty, ErrorNote } from '@/components/ui/form'
import { api, useInbox, useOtherDrafts, useWaitingDrafts, useWrite } from '@/lib/queries'
import { ReviewDeck } from '@/components/ReviewDeck'
import { ConfirmButton } from '@/components/ui/confirm'
import { DraftBox } from '@/components/DraftBox'
import { CallButton } from '@/components/CallButton'
import { NotifyPanel } from '@/components/NotifyPanel'
import { PhoneLookup } from '@/components/PhoneLookup'
import { fmtDateTime, localInputToIso, todayLocal } from '@/lib/format'
import {
  BUCKETS, type Bucket, type InboxLead, SEND_LABEL, WORDING, bucketOf, intentText, nextBusinessMorning, optedOut,
  reasonText, sendTone, threadOf,
} from '@/lib/inbox'
import { STAGE_LABEL } from '@/lib/wpie'
import { cn } from '@/lib/utils'

function daysAgo(n: number): string {
  return todayLocal(new Date(Date.now() - n * 86400_000))
}

export default function Inbox() {
  const [from] = useState(daysAgo(30))
  const [to] = useState(daysAgo(-7))
  // The replies waiting for Colin load first; the full list follows.
  const waiting = useWaitingDrafts()
  const q = useInbox(from, to, waiting.isFetched)
  const [startId] = useState(() => (window.location.hash.startsWith('#draft-') ? window.location.hash.slice(7) : null))
  const [chip, setChip] = useState<Bucket | 'all'>('all')
  const rows = useMemo(() => (q.data ?? []).map((x) => ({ x, bucket: bucketOf(x) }))
    .sort((a, b) => Number(b.bucket === 'needs_me') - Number(a.bucket === 'needs_me')), [q.data])
  const leadIds = useMemo(() => (q.data ?? []).map((x) => x.opener.lead_id).filter((x): x is string => Boolean(x)), [q.data])
  const other = useOtherDrafts(leadIds)
  // A notification opens /inbox#draft-<id>: show that card once the data is in.
  useEffect(() => {
    const h = window.location.hash
    if (!h.startsWith('#draft-') || !q.data || !other.data) return
    document.getElementById(h.slice(1))?.scrollIntoView({ behavior: 'smooth', block: 'center' })
  }, [q.data, other.data])
  const counts = rows.reduce((c, r) => ({ ...c, [r.bucket]: (c[r.bucket] ?? 0) + 1 }), {} as Record<Bucket, number>)
  const shown = rows.filter((r) => chip === 'all' || r.bucket === chip)

  return (
    <div className="space-y-4">
      <h1 className="text-xl font-semibold">Inbox</h1>
      <PhoneLookup />
      {waiting.isLoading && <Empty>Loading replies that need you...</Empty>}
      <ErrorNote error={waiting.error} />
      {(waiting.data ?? []).length > 0 && <ReviewDeck drafts={waiting.data!} startId={startId} />}
      {waiting.data && waiting.data.length === 0 && (
        <p className="rounded-xl border bg-card p-4 text-base">Nothing needs you right now.</p>
      )}
      <NotifyPanel />
      <p className="text-sm text-muted-foreground">
        Every seller text from the last 30 days and the coming week. Routine ones (removals, wrong numbers, not interested)
        are answered automatically; anything real waits here for your Approve.
      </p>
      <div className="flex flex-wrap gap-2" role="tablist" aria-label="Filter">
        {[{ id: 'all' as const, label: 'All' }, ...BUCKETS].map((b) => (
          <button
            key={b.id}
            role="tab"
            aria-selected={chip === b.id}
            onClick={() => setChip(b.id)}
            className={cn(
              'h-11 shrink-0 rounded-full border px-4 text-sm',
              chip === b.id ? 'border-primary bg-primary text-primary-foreground' : 'bg-background',
            )}
          >
            {b.label} {b.id === 'all' ? rows.length : (counts[b.id] ?? 0)}
          </button>
        ))}
      </div>
      <ErrorNote error={q.error} />
      {(q.isLoading || q.fetchStatus === 'paused') && !q.data && <Empty>Loading all texts...</Empty>}
      {q.data && shown.length === 0 && <Empty>Nothing here.</Empty>}
      <div className="space-y-3">
        {shown.map(({ x, bucket }) => (
          <InboxCard key={x.opener.id} x={x} bucket={bucket} />
        ))}
      </div>
      {(other.data ?? []).length > 0 && (chip === 'all' || chip === 'needs_me') && (
        <section className="space-y-2">
          <h2 className="pt-2 font-semibold">Texts from numbers not on these plans</h2>
          {(other.data ?? []).filter((d) => chip === 'all' || d.status === 'awaiting_approval').map((d) => (
            <div key={d.id} className="rounded-lg border bg-card p-3 shadow-sm"><DraftBox d={d} showFrom /></div>
          ))}
        </section>
      )}
      <ErrorNote error={other.error} />
    </div>
  )
}

function InboxCard({ x, bucket }: { x: InboxLead; bucket: Bucket }) {
  const o = x.opener
  const lines = threadOf(x)
  const stopped = optedOut(x)
  const [when, setWhen] = useState(nextBusinessMorning())
  const [booking, setBooking] = useState(false)
  const book = useWrite(({ id, at }: { id: string; at: string }) => api.bookCall(id, at), [['inbox'], ['tasks']])
  const drop = useWrite((id: string) => api.notInterested(id), [['inbox']])
  const leadId = x.lead?.id ?? o.lead_id
  const t = x.thread

  return (
    <section className="rounded-lg border bg-card p-3 shadow-sm sm:p-4">
      <div className="flex items-start justify-between gap-2">
        <div className="min-w-0">
          <h2 className="truncate font-semibold">
            {leadId ? (
              <Link to={`/lead/${leadId}`} className="underline decoration-muted-foreground/40 underline-offset-4">
                {x.lead?.owner_name ?? o.owner_name ?? `Owner ${o.wpie_owner_id}`}
              </Link>
            ) : (x.lead?.owner_name ?? o.owner_name ?? `Owner ${o.wpie_owner_id}`)}
          </h2>
          <p className="truncate text-sm text-muted-foreground">{x.lead?.property_address ?? o.property_address}</p>
        </div>
        <div className="flex shrink-0 items-center gap-2">
          <CallButton to={o.phone} name={x.lead?.owner_name ?? o.owner_name} address={x.lead?.property_address ?? o.property_address}
            leadId={leadId ?? null} blocked={stopped} />
          <Badge tone={sendTone(o.send_status)}>{SEND_LABEL[o.send_status]}</Badge>
        </div>
      </div>

      <div className="mt-2 flex flex-wrap gap-1.5">
        {x.lead && <Badge tone={bucket === 'dead' ? 'bad' : bucket === 'booked' ? 'good' : 'info'}>{STAGE_LABEL[x.lead.stage]}</Badge>}
        {o.template_lane && <Badge>{WORDING[o.template_lane] ?? o.template_lane} wording{o.variant ? ` ${o.variant}` : ''}</Badge>}
        {o.scheduled_at && !o.sent_at && <Badge>planned {fmtDateTime(o.scheduled_at)}</Badge>}
        {o.sent_at && <Badge>sent {fmtDateTime(o.sent_at)}</Badge>}
        {o.decision === 'pending' && o.send_status === 'planned' && <Badge tone="warn">waiting for approval</Badge>}
        {stopped && <Badge tone="bad">STOP honored - never texted again</Badge>}
      </div>
      {o.send_reason && (o.send_status === 'skipped' || o.send_status === 'withdrawn' || o.send_status === 'failed' || o.send_status === 'uncertain') && (
        <p className="mt-1 text-xs text-muted-foreground">Why: {reasonText(o.send_reason)}</p>
      )}

      <div className="mt-3 space-y-1.5">
        {lines.length === 0 && <p className="whitespace-pre-wrap rounded-md bg-muted p-2 text-sm">{o.body}</p>}
        {lines.map((l) => (
          <div key={l.key} className={cn('flex', l.who === 'us' ? 'justify-end' : 'justify-start')}>
            <div className={cn('max-w-[85%] rounded-lg px-3 py-2 text-sm',
              l.who === 'us' ? 'bg-primary text-primary-foreground' : 'bg-muted')}>
              <p className="whitespace-pre-wrap">{l.body}</p>
              <p className={cn('mt-0.5 text-[11px]', l.who === 'us' ? 'text-primary-foreground/80' : 'text-muted-foreground')}>
                {fmtDateTime(l.at)}{l.note ? ` - ${l.note}` : ''}
              </p>
            </div>
          </div>
        ))}
      </div>

      {x.drafts.filter((d) => d.status !== 'superseded').slice(-1).map((d) => <DraftBox key={d.id} d={d} />)}

      {x.drafts.length === 0 && t && (t.intent || t.suggested_reply || t.handoff_flag) && (
        <div className="mt-3 rounded-md border border-blue-200 bg-blue-50 p-2 text-sm text-blue-950">
          <p className="font-medium">
            Reply AI: {intentText(t.intent) || 'no read yet'}
            {t.human_owned ? ' - you are handling this one' : t.outcome === 'handoff' ? ' - handed to you' : ''}
          </p>
          {t.handoff_flag && <p className="text-xs">Flag: {t.handoff_flag}</p>}
          {t.callback_slot && <p className="text-xs">Callback asked for: {t.callback_slot}</p>}
          {t.suggested_reply && (
            <p className="mt-1 whitespace-pre-wrap">
              <span className="text-xs font-medium uppercase tracking-wide">Suggests: </span>
              {t.suggested_reply}
            </p>
          )}
        </div>
      )}

      {leadId && (
        <div className="mt-3 flex flex-wrap items-center gap-2">
          {!stopped && bucket !== 'dead' && (
            booking ? (
              <>
                <Input type="datetime-local" value={when} onChange={(e) => setWhen(e.target.value)} className="h-10 w-auto" aria-label="Call time" />
                <Button
                  disabled={book.isPending || !when}
                  onClick={() => { const at = localInputToIso(when); if (at) book.mutate({ id: leadId, at }, { onSuccess: () => setBooking(false) }) }}
                >
                  Save call
                </Button>
                <Button variant="ghost" onClick={() => setBooking(false)}>Cancel</Button>
              </>
            ) : (
              <Button onClick={() => setBooking(true)}>Book Colin's call</Button>
            )
          )}
          {!stopped && bucket !== 'dead' && (
            <ConfirmButton variant="outline" disabled={drop.isPending} yes="Yes, not interested"
              question="Mark this owner not interested? The lead moves to Dead." onConfirm={() => drop.mutate(leadId)}>
              Not interested
            </ConfirmButton>
          )}
          <Link to={`/lead/${leadId}`} className="ml-auto inline-flex min-h-11 items-center px-2 text-sm underline">Open card</Link>
        </div>
      )}
      <ErrorNote error={book.error ?? drop.error} />
    </section>
  )
}
