// Warm Leads board helpers (src/pages/Warm.tsx; the grouping itself is the database's warm_board).
import { WHO_LABEL, type StopWho } from './belts'
import { fmtDateTime } from './format'

export type WarmRow = {
  id: string; owner_name: string; property_address: string | null; municipality: string | null; belt: string; stage: string
  next_stop_at: string | null; next_stop_who: string | null; next_stop_say: string | null; named_date: string | null; named_event: string | null
  assigned_to: string | null; hot_at: string | null; human_takeover_at: string | null; call_facts: Record<string, unknown> | null
  facts: Record<string, unknown>; last_in_body: string | null; last_in_at: string | null; last_out_at: string | null; replies: number
  elderly_or_ill: boolean; grief: boolean; grp: Group; why: string | null
}
export type Group = 'decide' | 'hot' | 'booked' | 'talking' | 'callback' | 'nurture'

export const GROUPS: { id: Group; title: string; hint: string }[] = [
  { id: 'decide', title: 'Needs a decision', hint: 'A call that was never logged, a call more than a day late, or a card with no next step. Open it and log what happened.' },
  { id: 'hot', title: 'Hot: call today', hint: 'Said yes, or a call or visit was missed. Run the pillars and book Colin.' },
  { id: 'booked', title: 'Booked', hint: "Colin's calls and visits, by day, and offers waiting on an answer." },
  { id: 'talking', title: 'Talking', hint: 'They replied and went quiet. The card nudges them on its own; call when it says so.' },
  { id: 'callback', title: 'Callback set', hint: 'They said not now and gave a date. Soonest first.' },
  { id: 'nurture', title: 'Nurture', hint: 'The long ones: waiting on family, papers, a change, or a price that has to come down.' },
]

export function groupRows(rows: WarmRow[]): Record<Group, WarmRow[]> {
  const out = { decide: [], hot: [], booked: [], talking: [], callback: [], nurture: [] } as Record<Group, WarmRow[]>
  for (const r of rows) (out[r.grp] ?? out.nurture).push(r)
  return out
}

export function dayKey(iso: string): string {
  return new Date(iso).toLocaleDateString('en-US', { timeZone: 'America/Chicago', weekday: 'long', month: 'short', day: 'numeric' })
}

export function nextLine(r: WarmRow, now = Date.now()): { text: string; late: boolean } {
  if (r.grp === 'booked' && r.named_date) return { text: `${r.named_event === 'visit' ? 'Visit' : 'Call'} ${fmtDateTime(r.named_date)}`, late: false }
  if (!r.next_stop_at) return { text: r.belt === 'too_high_or_listed' || r.belt === 'dormant' ? 'Resting, no next step' : 'No next step', late: r.grp === 'decide' }
  const who = WHO_LABEL[r.next_stop_who as StopWho] ?? r.next_stop_who ?? 'Next'
  const late = new Date(r.next_stop_at).getTime() < now
  return { text: `${who.charAt(0).toUpperCase()}${who.slice(1)} · ${late ? 'due since ' : ''}${fmtDateTime(r.next_stop_at)}`, late }
}

