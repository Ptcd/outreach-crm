import { useState } from 'react'
import { Link } from 'react-router-dom'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge, Empty, ErrorNote, Section } from '@/components/ui/form'
import { api, usePlannedOpeners, useWrite } from '@/lib/queries'
import { fmtDateTime, fmtPhone, todayLocal } from '@/lib/format'
import { useAuth } from '@/providers/AuthProvider'
import type { OpenerDecision, PlannedOpener } from '@/lib/types'

const DECISION_LABEL: Record<OpenerDecision, string> = { pending: 'Waiting', approved: 'Approved', skipped: 'Skipped' }

export default function Approvals() {
  const { isOwner, member } = useAuth()
  const [day, setDay] = useState(todayLocal())
  const q = usePlannedOpeners(day)
  const decide = useWrite(
    ({ id, decision, note }: { id: string; decision: OpenerDecision; note: string | null }) =>
      api.decideOpener(id, decision, member?.display_name ?? 'Colin', note),
    [['planned_openers', day]],
  )
  const rows = q.data ?? []
  const counts = rows.reduce(
    (c, r) => ({ ...c, [r.decision]: (c[r.decision] ?? 0) + 1 }),
    {} as Record<OpenerDecision, number>,
  )

  return (
    <div className="space-y-4">
      <h1 className="text-xl font-semibold">Pilot approvals</h1>
      <p className="text-sm text-muted-foreground">
        The opener texts WPIE planned for this day. Approve or skip each one. Sending still happens in WPIE; nothing is sent
        from this page.
      </p>
      <div className="flex flex-wrap items-center gap-3">
        <label className="text-sm font-medium">
          Day <Input type="date" value={day} onChange={(e) => setDay(e.target.value)} className="mt-1 w-44" />
        </label>
        <span className="text-sm">
          {rows.length} planned - {counts.pending ?? 0} waiting, {counts.approved ?? 0} approved, {counts.skipped ?? 0} skipped
        </span>
      </div>
      {!isOwner && <p className="rounded bg-amber-50 p-2 text-sm text-amber-900">Only Colin can approve or skip.</p>}
      <ErrorNote error={q.error ?? decide.error} />
      {q.isLoading && <Empty>Loading...</Empty>}
      {q.data && rows.length === 0 && <Empty>No openers planned for this day. Run the WPIE plan, then the sync push.</Empty>}
      <div className="space-y-3">
        {rows.map((r) => (
          <OpenerCard key={r.id} r={r} canDecide={isOwner} busy={decide.isPending} onDecide={(decision, note) => decide.mutate({ id: r.id, decision, note })} />
        ))}
      </div>
    </div>
  )
}

function OpenerCard({
  r, canDecide, busy, onDecide,
}: {
  r: PlannedOpener
  canDecide: boolean
  busy: boolean
  onDecide: (d: OpenerDecision, note: string | null) => void
}) {
  const [note, setNote] = useState(r.decision_note ?? '')
  return (
    <Section
      title={r.owner_name ?? `Owner ${r.wpie_owner_id}`}
      right={<Badge tone={r.decision === 'approved' ? 'good' : r.decision === 'skipped' ? 'bad' : 'warn'}>{DECISION_LABEL[r.decision]}</Badge>}
    >
      <div className="mb-2 text-sm text-muted-foreground">
        {r.property_address} - to {fmtPhone(r.phone)} {r.scheduled_at ? `- planned ${fmtDateTime(r.scheduled_at)}` : ''}
      </div>
      <div className="mb-2 flex flex-wrap gap-2">
        {r.lane && <Badge tone="info">{r.lane}</Badge>}
        {r.template_lane && <Badge>template: {r.template_lane}</Badge>}
        {r.variant && <Badge>version {r.variant}</Badge>}
        {r.segments && <Badge>{r.segments} segments</Badge>}
        {r.attempt > 1 && <Badge tone="warn">second number (wrong number before)</Badge>}
      </div>
      <p className="whitespace-pre-wrap rounded-md bg-muted p-3 text-sm">{r.body}</p>
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
      {canDecide && (
        <div className="mt-3 space-y-2">
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
