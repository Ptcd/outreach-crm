// The Inbox's sorting rules, kept pure so tests can pin them.
// Nothing here computes or suggests an offer, value or price.
import type { DraftStatus, LeadStage, Message, PlannedOpener, ReplyDraft, ReplyThread, SendStatus, TwilioInbound } from './types'

export interface InboxLead {
  opener: PlannedOpener
  lead: {
    id: string
    owner_name: string
    property_address: string | null
    stage: LeadStage
    next_action_at: string | null
    next_action: string | null
    assigned_to: string | null
    dead_reason: string | null
  } | null
  messages: Message[]
  thread: ReplyThread | null
  inbound: TwilioInbound[]
  drafts: ReplyDraft[]
}

export type Bucket = 'needs_me' | 'ai' | 'booked' | 'dead' | 'waiting'

export const BUCKETS: { id: Bucket; label: string }[] = [
  { id: 'needs_me', label: 'Needs me' },
  { id: 'ai', label: 'AI handling' },
  { id: 'booked', label: 'Booked' },
  { id: 'waiting', label: 'No reply yet' },
  { id: 'dead', label: 'Dead' },
]

const DEAD_STAGES: LeadStage[] = ['dead', 'closed_no_contact', 'dnc', 'mail_only']
const BOOKED_STAGES: LeadStage[] = ['walk_decision', 'walkthrough_booked', 'offer', 'under_contract', 'closed_won']
const NEEDS_ME_STAGES: LeadStage[] = ['reply_received', 'handoff', 'human_owned', 'data_fix', 'follow_up']

export interface ThreadLine {
  key: string
  who: 'us' | 'them'
  body: string
  at: string
  note?: string
}

/** Opener + replies in time order. A reply the server pulled from Twilio is shown until
 *  WPIE records the same text (same body within 10 minutes). */
export function threadOf(x: InboxLead): ThreadLine[] {
  const lines: ThreadLine[] = x.messages.map((m) => ({
    key: m.id, who: m.direction === 'out' ? 'us' : 'them', body: m.body ?? '', at: m.sent_at,
    note: m.is_opt_out ? 'STOP' : undefined,
  }))
  const hasOpener = x.messages.some((m) => m.direction === 'out' && m.is_opener)
  if (!hasOpener && x.opener.sent_at) {
    lines.push({ key: `opener-${x.opener.id}`, who: 'us', body: x.opener.body, at: x.opener.sent_at })
  }
  for (const d of x.drafts ?? []) {
    if (d.status === 'sent' && d.sent_body && d.sent_at && !x.messages.some((m) => m.direction === 'out' && (m.body ?? '') === d.sent_body)) {
      lines.push({ key: `sam-${d.id}`, who: 'us', body: d.sent_body, at: d.sent_at, note: d.kind === 'routine' ? 'auto' : undefined })
    }
  }
  for (const t of x.inbound) {
    const dup = x.messages.some((m) => m.direction === 'in' && (m.body ?? '').trim() === (t.body ?? '').trim()
      && Math.abs(new Date(m.sent_at).getTime() - new Date(t.received_at).getTime()) < 10 * 60_000)
    if (!dup) lines.push({ key: t.sid, who: 'them', body: t.body ?? '', at: t.received_at, note: t.is_opt_out ? 'STOP' : 'new' })
  }
  return lines.sort((a, b) => a.at.localeCompare(b.at))
}

export function optedOut(x: InboxLead): boolean {
  return x.messages.some((m) => m.direction === 'in' && m.is_opt_out) || x.inbound.some((t) => t.is_opt_out)
    || x.lead?.stage === 'dnc' || x.thread?.outcome === 'close_dnc'
}

export function hasReply(x: InboxLead): boolean {
  return x.messages.some((m) => m.direction === 'in') || x.inbound.length > 0
}

export function bucketOf(x: InboxLead): Bucket {
  const stage = x.lead?.stage
  if (optedOut(x) || (stage && DEAD_STAGES.includes(stage)) || x.thread?.outcome === 'close_not_interested'
      || x.thread?.outcome === 'close_wrong_number') {
    return 'dead'
  }
  if ((stage && BOOKED_STAGES.includes(stage)) || (stage === 'colin_call' && x.lead?.next_action_at) || x.thread?.callback_slot) {
    return 'booked'
  }
  if ((x.drafts ?? []).some((d) => d.status === 'awaiting_approval')) return 'needs_me'
  if (!hasReply(x)) return 'waiting'
  const ds = x.drafts ?? []
  const last = ds[ds.length - 1]
  if (last && last.kind === 'routine') return 'ai'
  const t = x.thread
  const aiActive = t && !t.human_owned && !t.outcome && t.agent_stage !== 'closed' && stage !== 'human_owned'
  if (aiActive && (!stage || stage === 'ai_qualifying' || stage === 'opener_sent' || stage === 'reply_received')) return 'ai'
  if (stage && (NEEDS_ME_STAGES.includes(stage) || stage === 'colin_call')) return 'needs_me'
  return 'needs_me'
}

export const WORDING: Record<string, string> = {
  hold: 'Landlord / building',
  flip: 'House',
  estate: 'Estate',
  llc: 'Company owner',
}

export const SEND_LABEL: Record<SendStatus, string> = {
  planned: 'Planned',
  would_send: 'Would send (test run)',
  sending: 'Sending',
  sent: 'Sent',
  delivered: 'Delivered',
  undelivered: 'Not delivered',
  failed: 'Failed',
  uncertain: 'Unclear - check Twilio',
  skipped: 'Skipped',
  withdrawn: 'Withdrawn',
}

export function sendTone(s: SendStatus): 'muted' | 'warn' | 'bad' | 'good' | 'info' {
  if (s === 'delivered' || s === 'sent') return 'good'
  if (s === 'failed' || s === 'undelivered' || s === 'uncertain') return 'bad'
  if (s === 'skipped' || s === 'withdrawn') return 'muted'
  if (s === 'sending' || s === 'would_send') return 'info'
  return 'warn'
}

/** Why a text was skipped, in plain words (reasons come from claim_next_opener). */
export function reasonText(r: string | null | undefined): string {
  if (!r) return ''
  const map: Record<string, string> = {
    phone_suppressed: 'this phone said STOP',
    owner_opted_out_on_another_phone: 'the owner said STOP on another phone',
    owner_replied: 'the owner already replied',
    phone_dnc_positive: 'phone is on a do-not-call list',
    phone_marked_bad: 'phone marked bad',
    phone_shared: 'phone belongs to more than one owner',
    owner_already_texted: 'this owner was already texted once',
    no_recipient_window: 'no safe sending time for this person',
    body_changed_since_plan: 'wording changed after it was checked',
    phone_invalid: 'not a valid phone number',
    no_lead: 'no lead record',
    dnc_unscreened_under_require_scrub: 'phone not DNC-screened',
    dnc_scrub_older_than_31_days: 'DNC scrub older than 31 days',
  }
  if (map[r]) return map[r]
  if (r.startsWith('lead_stage_')) return `lead is already "${r.slice(11).replace(/_/g, ' ')}"`
  if (r.startsWith('template:')) return `wording problem (${r.slice(9).replace(/_/g, ' ')})`
  return r.replace(/_/g, ' ')
}

/** Plain words for the reply agent's coarse intent (wpie/reply/rules.py classify). */
export function intentText(i: string | null | undefined): string {
  if (!i) return ''
  const map: Record<string, string> = {
    opt_out: 'Wants no more texts', wrong_number: 'Wrong number', who_is_this: 'Asking who this is', tenant: 'A tenant answered',
    hostile: 'Hostile', annoyed: 'Annoyed', manager: 'Property manager', elderly: 'Older owner / needs care', bot_question: 'Asking if this is a bot',
    sold: 'Says it is sold', middleman: 'Asking if we are a middleman', listed: 'Says it is listed', estate: 'Estate / owner passed',
    foreclosure: 'Mentions foreclosure', relative: 'A relative answered', burned: 'Burned by investors before', other_buyer: 'Talking to another buyer',
    worth: 'Asking what it is worth', terms: 'Talking terms', firm: 'Firm on their number', joke_number: 'Joke number',
    number_only: 'Sent a number', price_first: 'Wants a price first', not_now: 'Not right now', my_home: 'It is their home',
    not_interested: 'Not interested', busy: 'Busy right now', prefer_text: 'Prefers text', wants_call: 'Wants a call',
    interested: 'Interested', statement: 'Said something else', empty: 'Empty text',
  }
  return map[i] ?? i.replace(/_/g, ' ')
}

/** Next weekday 10:00 Milwaukee time after `now`, as a datetime-local value. */
export function nextBusinessMorning(now: Date = new Date()): string {
  const fmt = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Chicago', year: 'numeric', month: '2-digit', day: '2-digit', weekday: 'short' })
  for (let add = 1; add < 8; add++) {
    const d = new Date(now.getTime() + add * 86400_000)
    const parts = fmt.formatToParts(d)
    const get = (t: string) => parts.find((p) => p.type === t)?.value ?? ''
    if (get('weekday') !== 'Sat' && get('weekday') !== 'Sun') return `${get('year')}-${get('month')}-${get('day')}T10:00`
  }
  return ''
}

export const DRAFT_LABEL: Record<DraftStatus, string> = {
  no_reply: 'Nothing to send',
  would_send: 'Would auto-send this (routine replies are off)',
  awaiting_approval: 'Waiting for you',
  queued: 'Queued - goes out when allowed',
  sending: 'Sending',
  sent: 'Sent',
  dry_sent: 'Approved - would send (live sending is off)',
  failed: 'Failed',
  uncertain: 'Unclear - check Twilio',
  skipped: 'Skipped',
  superseded: 'Replaced by a newer text',
}

/** Statuses where Colin can still approve (with edits) or skip. */
export const DRAFT_OPEN: DraftStatus[] = ['awaiting_approval', 'would_send', 'no_reply', 'dry_sent']
