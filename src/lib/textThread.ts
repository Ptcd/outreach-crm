import type { Message, TwilioInbound } from './types'

export interface ThreadText { key: string; mine: boolean; body: string; at: string; phone10: string; ourNumber: string | null }

const last10 = (n: string | null | undefined) => (n ?? '').replace(/[^0-9]/g, '').slice(-10)

/** Every text on the card, both ways, oldest first, like a phone's message log (Colin 2026-10-24: "show all the
 *  messages back and forth from top to bottom with newest visible at the bottom"). Their texts come from Twilio's
 *  inbound log as well as WPIE's messages; the same text in both shows once. */
export function textThreadOf(messages: Message[], inbound: TwilioInbound[]): ThreadText[] {
  const out: ThreadText[] = []
  const seen = new Set<string>()
  for (const m of messages ?? []) {
    if (m.channel !== 'sms') continue
    const mine = m.direction === 'out'
    if (m.provider_sid) seen.add(m.provider_sid)
    out.push({ key: `m:${m.id}`, mine, body: m.body ?? '', at: m.sent_at, phone10: last10(mine ? m.to_number : m.from_number),
      ourNumber: (mine ? m.from_number : m.to_number) ?? null })
  }
  for (const t of inbound ?? []) {
    if (seen.has(t.sid)) continue
    const dup = out.some((x) => !x.mine && x.phone10 === t.from10 && x.body.trim() === (t.body ?? '').trim()
      && Math.abs(new Date(x.at).getTime() - new Date(t.received_at).getTime()) < 120_000)
    if (dup) continue
    out.push({ key: `i:${t.sid}`, mine: false, body: t.body ?? '', at: t.received_at, phone10: t.from10, ourNumber: null })
  }
  return out.sort((a, b) => a.at.localeCompare(b.at))
}
