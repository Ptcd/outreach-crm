import { CALL_SCRIPT } from './callScript'
import { answerOf, answerText, type CallFacts } from './callGate'
import type { GateScore, Lead } from './types'

export interface AppointmentPacketRow {
  id: string
  label: string
  value: string
  known: boolean
}

export interface AppointmentPacketData {
  appointment: string
  rows: AppointmentPacketRow[]
  unresolved: string[]
  gate: string
  hardStops: string[]
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
const reply = (facts: Record<string, unknown>, ...keys: string[]) => {
  for (const key of keys) { const value = clean(facts[key]); if (value) return value }
  return null
}
const call = (facts: CallFacts, ...keys: string[]) => {
  for (const key of keys) {
    const value = answerOf(facts, key)
    if (value) return answerText(value, CHOICE_LABELS)
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
  const values: Array<[string, string, string | null]> = [
    ['property', 'Property', address],
    ['property_type', 'Property type', type],
    ['seller', 'Seller / owner', clean(lead.owner_name)],
    ['identity', 'Who is speaking', call(callFacts, 'identity')],
    ['motivation', 'Reason for selling', call(callFacts, 'motivation') ?? reply(replyFacts, 'motivation')],
    ['condition', 'Condition / work', call(callFacts, 'condition', 'work_list', 'happened') ?? reply(replyFacts, 'condition')],
    ['asking_price', 'Seller’s number', call(callFacts, 'price') ?? reply(replyFacts, 'price_confirmed', 'price_expectation')],
    ['timing', 'Timing / move plan', call(callFacts, 'timeline') ?? reply(replyFacts, 'timeline')],
    ['decision_makers', 'Decision-makers / signers', call(callFacts, 'decision_makers', 'ready') ?? reply(replyFacts, 'decision_makers')],
    ['occupancy', 'Occupancy / access', call(callFacts, 'occupancy') ?? reply(replyFacts, 'occupancy')],
  ]
  const rows = values.map(([id, label, value]) => ({ id, label, value: value ?? 'Unknown — ask and record', known: !!value }))
  return {
    appointment: when(lead.named_date ?? lead.next_action_at),
    rows,
    unresolved: rows.filter((r) => !r.known).map((r) => r.label),
    gate: latestGate ? `${latestGate.decision.replace(/_/g, ' ')} (${latestGate.total}/12)` : 'Not scored',
    hardStops: latestGate?.hard_stops ?? [],
  }
}
