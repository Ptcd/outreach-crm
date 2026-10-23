import { Section, Badge } from '@/components/ui/form'
import { buildAppointmentPacket } from '@/lib/appointmentPacket'
import type { CallFacts } from '@/lib/callGate'
import type { GateScore, Lead } from '@/lib/types'

/** One reproducible view for a booked visit; unknowns are explicit and never filled by inference. */
export function AppointmentPacket({ lead, callFacts, replyFacts, latestGate }: {
  lead: Lead
  callFacts: CallFacts
  replyFacts: Record<string, unknown>
  latestGate: GateScore | null
}) {
  const packet = buildAppointmentPacket(lead, callFacts, replyFacts, latestGate)
  return (
    <Section title="Appointment packet" right={<Badge tone="good">Booked visit</Badge>}>
      <p className="mb-3 text-sm"><strong>Visit:</strong> {packet.appointment}</p>
      <dl className="divide-y rounded-md border">
        {packet.rows.map((row) => (
          <div key={row.id} className="grid gap-1 px-3 py-2 text-sm sm:grid-cols-3">
            <dt className="font-medium text-muted-foreground">{row.label}</dt>
            <dd className={`sm:col-span-2 ${row.known ? '' : 'font-medium text-amber-700'}`}>{row.value}</dd>
          </div>
        ))}
      </dl>
      <div className="mt-3 rounded-md bg-muted p-3 text-sm">
        <p><strong>Booking gate:</strong> {packet.gate}</p>
        {packet.hardStops.length > 0 && <p className="mt-1 text-red-700"><strong>Hard stops recorded:</strong> {packet.hardStops.join(', ')}</p>}
        <p className="mt-2"><strong>Unresolved ({packet.unresolved.length}):</strong>{' '}
          {packet.unresolved.length ? packet.unresolved.join(', ') : 'None in the required packet fields.'}</p>
      </div>
      <p className="mt-2 text-xs text-muted-foreground">Built from saved WPIE, text, call-script, and gate facts. Unknowns stay unknown until a person records them.</p>
    </Section>
  )
}
