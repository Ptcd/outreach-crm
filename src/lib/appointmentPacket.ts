import { CALL_SCRIPT } from './callScript'
import { answerOf, answerText, type CallFacts } from './callGate'
import type { GateScore, Lead } from './types'

export interface AppointmentPacketRow {
  id: string
  label: string
  value: string
  known: boolean
  provenance: AppointmentProvenance
}

export interface AppointmentProvenance {
  source: string
  recordedAt: string | null
  recordedBy: string | null
}

export interface AppointmentPacketData {
  appointment: string
  rows: AppointmentPacketRow[]
  unresolved: string[]
  gate: string
  hardStops: string[]
  appointmentProvenance: AppointmentProvenance
  gateProvenance: AppointmentProvenance
}

const CHOICE_LABELS = Object.fromEntries(CALL_SCRIPT.flatMap((q) => (q.choices ?? []).map((c) => [c.id, c.label])))
const clean = (v: unknown): string | null => {
  if (typeof v === 'string') return v.trim() && v !== 'null' && v !== 'false' ? v.trim() : null
  if (Array.isArray(v)) {
    const xs = v.map(clean).filter((x): x is string => !!x)
    return xs.length ? xs.join('; ') : null
  }
  return null
}
type SourcedValue = { value: string; provenance: AppointmentProvenance }
const provenance = (source: string, recordedAt: unknown = null, recordedBy: unknown = null): AppointmentProvenance => ({
  source,
  recordedAt: typeof recordedAt === 'string' && recordedAt ? recordedAt : null,
  recordedBy: typeof recordedBy === 'string' && recordedBy.trim() ? recordedBy.trim() : null,
})
const reply = (facts: Record<string, unknown>, ...keys: string[]): SourcedValue | null => {
  for (const key of keys) {
    const raw = facts[key]
    const structured = raw && typeof raw === 'object' && !Array.isArray(raw)
      ? raw as { value?: unknown; at?: unknown; by?: unknown }
      : null
    const value = clean(structured && 'value' in structured ? structured.value : raw)
    if (value) return { value, provenance: provenance('Seller text reply', structured?.at, structured?.by) }
  }
  return null
}
const call = (facts: CallFacts, ...keys: string[]): SourcedValue | null => {
  for (const key of keys) {
    const value = answerOf(facts, key)
    if (value) return { value: answerText(value, CHOICE_LABELS), provenance: provenance('Call script', facts[key]?.at, facts[key]?.by) }
  }
  return null
}
const when = (iso: string | null | undefined) => iso
  ? new Date(iso).toLocaleString('en-US', { timeZone: 'America/Chicago', weekday: 'long', month: 'long', day: 'numeric', year: 'numeric', hour: 'numeric', minute: '2-digit', timeZoneName: 'short' })
  : 'Unknown — confirm the visit time'

/** A deterministic packet made only from saved lead/call/reply/gate facts. Missing facts stay missing. */
export function buildAppointmentPacket(lead: Lead, callFacts: CallFacts = {}, replyFacts: Record<string, unknown> = {}, latestGate: GateScore | null = null): AppointmentPacketData {
  const address = [lead.property_address, lead.municipality, lead.property_zip].filter(Boolean).join(', ') || null
  const type = [lead.property_type, lead.units ? `${lead.units} units` : null].filter(Boolean).join(', ') || null
  const wpie = (value: string | null): SourcedValue | null => value ? { value, provenance: provenance('WPIE lead record') } : null
  const first = (...xs: Array<SourcedValue | null>) => xs.find((x): x is SourcedValue => !!x) ?? null
  const values: Array<[string, string, SourcedValue | null]> = [
    ['property', 'Property', wpie(address)],
    ['property_type', 'Property type', wpie(type)],
    ['seller', 'Seller / owner', wpie(clean(lead.owner_name))],
    ['identity', 'Who is speaking', call(callFacts, 'identity')],
    ['motivation', 'Reason for selling', first(call(callFacts, 'motivation'), reply(replyFacts, 'motivation'))],
    ['condition', 'Condition / work', first(call(callFacts, 'condition', 'work_list', 'happened'), reply(replyFacts, 'condition'))],
    ['asking_price', 'Seller\'s number', first(call(callFacts, 'price'), reply(replyFacts, 'price_confirmed', 'price_expectation'))],
    ['timing', 'Timing / move plan', first(call(callFacts, 'timeline'), reply(replyFacts, 'timeline'))],
    ['decision_makers', 'Decision-makers / signers', first(call(callFacts, 'decision_makers', 'ready'), reply(replyFacts, 'decision_makers'))],
    ['occupancy', 'Occupancy / access', first(call(callFacts, 'occupancy'), reply(replyFacts, 'occupancy'))],
  ]
  const rows = values.map(([id, label, item]) => ({
    id, label,
    value: item?.value ?? 'Unknown — ask and record',
    known: !!item,
    provenance: item?.provenance ?? provenance('Not recorded'),
  }))
  const appointmentSource = lead.named_date ? 'Lead appointment date' : lead.next_action_at ? 'Lead next action' : 'Not recorded'
  return {
    appointment: when(lead.named_date ?? lead.next_action_at),
    rows,
    unresolved: rows.filter((r) => !r.known).map((r) => r.label),
    gate: latestGate ? `${latestGate.decision.replace(/_/g, ' ')} (${latestGate.total}/12)` : 'Not scored',
    hardStops: latestGate?.hard_stops ?? [],
    appointmentProvenance: provenance(appointmentSource),
    gateProvenance: latestGate
      ? provenance('Booking gate score', latestGate.at, latestGate.decided_by_name)
      : provenance('Not recorded'),
  }
}
