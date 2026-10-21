import { useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge, Empty, ErrorNote } from '@/components/ui/form'
import { api, useInbox, useWrite } from '@/lib/queries'
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
  const q = useInbox(from, to)
  const [chip, setChip] = useState<Bucket | 'all'>('all')
  const rows = useMemo(() => (q.data ?? []).map((x) => ({ x, bucket: bucketOf(x) })), [q.data])
  const counts = rows.reduce((c, r) => ({ ...c, [r.bucket]: (c[r.bucket] ?? 0) + 1 }), {} as Record<Bucket, number>)
  const shown = rows.filter((r) => chip === 'all' || r.bucket === chip)

  return (
    <div className="space-y-4">
      <h1 className="text-xl font-semibold">Inbox</h1>
      <p className="text-sm text-muted-foreground">
        Every seller text from the last 30 days and the coming week: what was sent, what came back, and what the reply AI
        thinks. Tap a card's buttons to move the lead along.
      </p>
      <div className="-mx-4 flex gap-2 overflow-x-auto px-4 pb-1" role="tablist" aria-label="Filter">
        {[{ id: 'all' as const, label: 'All' }, ...BUCKETS].map((b) => (
          <button
            key={b.id}
            role="tab"
            aria-selected={chip === b.id}
            onClick={() => setChip(b.id)}
            className={cn(
              'shrink-0 rounded-full border px-3 py-1.5 text-sm',
              chip === b.id ? 'border-primary bg-primary text-primary-foreground' : 'bg-background',
            )}
          >
            {b.label} {b.id === 'all' ? rows.length : (counts[b.id] ?? 0)}
          </button>
        ))}
      </div>
      <ErrorNote error={q.error} />
      {q.isLoading && <Empty>Loading...</Empty>}
      {q.data && shown.length === 0 && <Empty>Nothing here.</Empty>}
      <div className="space-y-3">
        {shown.map(({ x, bucket }) => (
          <InboxCard key={x.opener.id} x={x} bucket={bucket} />
        ))}
      </div>
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
          <h2 className="truncate font-semibold">{x.lead?.owner_name ?? o.owner_name ?? `Owner ${o.wpie_owner_id}`}</h2>
          <p className="truncate text-sm text-muted-foreground">{x.lead?.property_address ?? o.property_address}</p>
        </div>
        <Badge tone={sendTone(o.send_status)}>{SEND_LABEL[o.send_status]}</Badge>
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

      {t && (t.intent || t.suggested_reply || t.handoff_flag) && (
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
            <Button variant="outline" disabled={drop.isPending}
              onClick={() => { if (window.confirm('Mark this owner not interested? The lead moves to Dead.')) drop.mutate(leadId) }}>
              Not interested
            </Button>
          )}
          <Link to={`/lead/${leadId}`} className="ml-auto text-sm underline">Open lead</Link>
        </div>
      )}
      <ErrorNote error={book.error ?? drop.error} />
    </section>
  )
}
