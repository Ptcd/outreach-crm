import { useNavigate } from 'react-router-dom'
import { Button } from '@/components/ui/button'
import { CallButton, PersonalCallButton } from '@/components/CallButton'
import { answerOf, type CallFacts } from '@/lib/callGate'
import { firstNameOf } from '@/lib/inbox'
import { fmtPhone } from '@/lib/format'
import { cn } from '@/lib/utils'
import type { Contact, Lead, Message, TwilioInbound } from '@/lib/types'

/** The name our first text greeted ("Hi Laurie, Colin Merrill here ..."), else the owner's first name. A trust's
 *  texts go to a person (Laurie), not to the name on title ("R Darrell Sutton Revocable Trust"). */
export function greetedName(messages: Message[] | undefined, ownerName: string): string {
  const first = [...(messages ?? [])].filter((m) => m.direction === 'out' && m.channel === 'sms')
    .sort((a, b) => a.sent_at.localeCompare(b.sent_at))[0]
  const m = (first?.body ?? '').match(/^(?:Hi|Hey|Hello)\s+([A-Z][a-z]+)\b|^([A-Z][a-z]+),/)
  return (m && (m[1] || m[2])) || firstNameOf(ownerName)
}

/** The four pillars (Rick: motivation, condition, timeline, price) plus who signs and the booking, in call order.
 *  `call` is the call script's answer id; `reply` is what their texts already told us. */
export const PILLARS: { id: string; label: string; call: string[]; reply: string[] }[] = [
  { id: 'motivation', label: 'Why selling', call: ['motivation'], reply: ['motivation'] },
  { id: 'condition', label: 'Condition', call: ['condition', 'occupancy', 'work_list'], reply: ['condition', 'occupancy'] },
  { id: 'timeline', label: 'Timeline', call: ['timeline'], reply: ['timeline'] },
  { id: 'signers', label: 'Who signs', call: ['decision_makers'], reply: ['decision_makers'] },
  { id: 'price', label: 'Their number', call: ['price'], reply: ['price_expectation', 'price_confirmed'] },
  { id: 'booked', label: 'Booked', call: ['next_step'], reply: ['callback_slot'] },
]

export function pillarsDone(callFacts: CallFacts, replyFacts: Record<string, unknown>): Record<string, boolean> {
  return Object.fromEntries(PILLARS.map((p) => [p.id,
    p.call.some((k) => !!answerOf(callFacts, k)) || p.reply.some((k) => typeof replyFacts[k] === 'string' && !!(replyFacts[k] as string).trim())]))
}

/** The number to call: the one they texted us from, else the first usable phone on the card. */
export function bestPhone(contacts: Contact[], inbound: TwilioInbound[]): Contact | null {
  const phones = contacts.filter((c) => c.kind === 'phone' && c.status !== 'bad' && !c.dnc_app && !c.suppressed)
  const texted = [...(inbound ?? [])].sort((a, b) => b.received_at.localeCompare(a.received_at)).map((t) => t.from10)
  for (const p of texted) {
    const hit = phones.find((c) => (c.value_normalized ?? c.value).replace(/\D/g, '').slice(-10) === p)
    if (hit) return hit
  }
  return phones.find((c) => c.line_type === 'mobile') ?? phones[0] ?? null
}

// The top of a card (Colin 2026-10-24: "Where is the place to call", "figuring out how to do the pillars on a call is
// hard"): one big Call for the number they texted from, the pillars as a checklist that fills in as the call script is
// answered, and one tap to the script.
export function CallPanel({ lead, contacts, inbound, replyFacts, messages }: {
  lead: Lead; contacts: Contact[]; inbound: TwilioInbound[]; replyFacts: Record<string, unknown>; messages?: Message[]
}) {
  const nav = useNavigate()
  if (lead.stage === 'dnc') return null
  const phone = bestPhone(contacts, inbound)
  const done = pillarsDone((lead.call_facts ?? {}) as CallFacts, replyFacts)
  const first = greetedName(messages, lead.owner_name)
  const texted = !!phone && (inbound ?? []).some((t) => (phone.value_normalized ?? phone.value).replace(/\D/g, '').slice(-10) === t.from10)
  const openScript = () => {
    nav({ search: '?call=1', hash: '#call-script' })
    setTimeout(() => document.getElementById('call-script')?.scrollIntoView({ behavior: 'smooth', block: 'start' }), 50)
  }
  return (
    <section className="sticky top-16 z-20 space-y-2.5 rounded-2xl border border-emerald-200 bg-gradient-to-br from-emerald-50 via-card to-card p-4 shadow-[var(--shadow-lift)]">
      {phone ? (
        <div className="flex flex-wrap items-center gap-2">
          <div className="min-w-0 flex-1">
            <p className="text-sm text-muted-foreground">Call {first || 'them'}{texted ? ' on the number they texted from' : ''}</p>
            <p className="text-lg font-semibold">{fmtPhone(phone.value)}</p>
          </div>
          <CallButton to={phone.value} name={phone.person_name || lead.owner_name} address={lead.property_address} leadId={lead.id}
            contactId={phone.id} notBefore={lead.belt === 'not_now_dated' ? lead.named_date : null}
            size="default" className="h-12 px-6 text-base" />
          <PersonalCallButton to={phone.value} leadId={lead.id} activeKey={lead.human_takeover_at ? lead.human_takeover_key : null}
            notBefore={lead.belt === 'not_now_dated' ? lead.named_date : null} />
        </div>
      ) : <p className="text-sm">No usable phone on this card.</p>}
      <div className="flex flex-wrap gap-1.5" aria-label="The pillars">
        {PILLARS.map((p) => (
          <span key={p.id} className={cn('inline-flex items-center gap-1 rounded-full border px-2.5 py-1 text-xs font-medium',
            done[p.id] ? 'border-emerald-300 bg-emerald-100 text-emerald-800' : 'border-border bg-card text-muted-foreground')}>
            {done[p.id] ? '✓' : '○'} {p.label}
          </span>
        ))}
      </div>
      <Button variant="outline" className="h-auto min-h-11 w-full whitespace-normal py-2" onClick={openScript}>Open the call script</Button>
    </section>
  )
}
