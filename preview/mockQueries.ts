// DEV ONLY (npm run preview:mock): the real pages with sample data instead of Supabase, for
// checking the phone layout. Never part of the production build.
import { useMutation } from '@tanstack/react-query'
import type { WaitingDraft } from '../src/lib/queries'

export const PAGE_SIZE = 50
export interface LeadFilter { stage: string; lane: string; county: string; search: string; page: number }
const ok = <T,>(data: T) => ({ data, error: null, isLoading: false, isFetched: true, isPending: false, fetchStatus: 'idle' as const })
const now = Date.now()
const ago = (min: number) => new Date(now - min * 60_000).toISOString()

const OPENER = (name: string, street: string) =>
  `Hi ${name}, Colin Merrill here. I'm looking to buy another place and yours on ${street} caught my eye. Any interest in selling? No worries if not, just reply STOP.`

const base = { inbound_sid: '', our_number: '+12629996513', kind: 'candidate' as const, outcome: 'open', note: null, draft_source: 'claude',
  status: 'awaiting_approval' as const, send_after: null, sent_body: null, sent_at: null, decided_by: null, decided_at: null, is_test: false }

export const WAITING: WaitingDraft[] = [
  { ...base, id: 'd1', phone10: '4145550177', lead_id: 'L1', inbound_at: ago(6), intent: 'price_first',
    inbound_body: "Maybe. Depends what you'd pay, the roof needs work and the tenant leaves in March.",
    body: "Thanks for getting back to me, Dale. I don't have a number yet - what were you hoping to get for it, and how'd you come up with that?",
    owner_name: 'DALE NOVAK', property_address: '2847 N Burleigh St',
    thread: [{ key: 't1', who: 'us', body: OPENER('Dale', 'N Burleigh St'), at: ago(180) }] },
  { ...base, id: 'd2', phone10: '2625550142', lead_id: 'L2', inbound_at: ago(25), intent: 'buyer_check',
    inbound_body: 'Who is actually buying it? I might sell if the price is right.',
    body: "Good question - I buy them myself. Is the place on Pewaukee Rd still yours, and is anyone living there right now?",
    owner_name: 'RITA SCHMIDT', property_address: 'W220 N1765 Pewaukee Rd',
    thread: [{ key: 't2', who: 'us', body: OPENER('Rita', 'Pewaukee Rd'), at: ago(240) }] },
  { ...base, id: 'd3', phone10: '2625550111', lead_id: null, inbound_at: ago(40), intent: 'wants_call', our_number: '+12624180202',
    inbound_body: 'Got your letter about the duplex on Oak. Call me after 5.',
    body: "Thanks - this is Colin Merrill. I'll call you after 5. Which address on Oak is it?",
    owner_name: null, property_address: null, thread: [] },
]

const lead = (id: string, name: string, address: string, stage: string) => ({ id, wpie_owner_id: 1, owner_name: name, owner_type: 'individual',
  mailing_street: '1 A ST', mailing_city: 'MILWAUKEE', mailing_state: 'WI', mailing_zip: '53202', lane: 'hold', county: 'Milwaukee',
  municipality: 'Milwaukee', property_address: address, property_zip: '53202', wpie_property_id: 11, parcel_id: 'P-11', property_type: 'duplex',
  units: 2, reasons_to_sell: ['tired landlord', 'deep tax delinquency'], score: 412.5, mailed_on: '2026-10-20', mail_channel: 'postcard',
  stage, stage_changed_at: ago(60), next_action_at: null, next_action: null, assigned_to: 'colin', dead_reason: null, notes: null,
  last_inbound_at: ago(6), created_at: ago(9000), updated_at: ago(60) })
const LEADS = [lead('L1', 'DALE NOVAK', '2847 N Burleigh St', 'reply_received'), lead('L2', 'RITA SCHMIDT', 'W220 N1765 Pewaukee Rd', 'reply_received'),
  lead('L3', 'ACME HOLDINGS LLC', '200 S Oak Ave', 'opener_sent'), lead('L4', 'BOB SMITH', '300 W Elm St', 'dnc')]

const opener = (id: string, l: ReturnType<typeof lead>, status: string, extra: Record<string, unknown> = {}) => ({
  id, plan_date: '2026-10-21', wpie_owner_id: 1, attempt: 1, lead_id: l.id, lane: 'hold', template_lane: 'hold', variant: 'A',
  phone: '+14145550177', body: OPENER(l.owner_name.split(' ')[0][0] + l.owner_name.split(' ')[0].slice(1).toLowerCase(), l.property_address),
  segments: 2, scheduled_at: ago(200), owner_name: l.owner_name, property_address: l.property_address, decision: 'approved',
  decided_by_name: 'Colin', decided_at: ago(300), decision_note: null, send_status: status, send_reason: null, claimed_at: ago(200),
  sent_at: status === 'planned' ? null : ago(200), error_code: null, ...extra })

const INBOX = [
  { opener: opener('P1', LEADS[0], 'delivered'), lead: LEADS[0], thread: null, inbound: [],
    messages: [{ id: 'm1', lead_id: 'L1', direction: 'out', channel: 'sms', body: OPENER('Dale', 'N Burleigh St'), sent_at: ago(180), seen_at: null, is_opt_out: false, is_opener: true, status: 'delivered', from_number: null, to_number: null }],
    drafts: [WAITING[0]] },
  { opener: opener('P2', LEADS[1], 'delivered'), lead: LEADS[1], thread: null, inbound: [], messages: [], drafts: [WAITING[1]] },
  { opener: opener('P3', LEADS[2], 'planned', { decision: 'pending', sent_at: null }), lead: LEADS[2], thread: null, inbound: [], messages: [], drafts: [] },
  { opener: opener('P4', LEADS[3], 'skipped', { send_reason: 'phone_suppressed' }), lead: LEADS[3], thread: null, messages: [], drafts: [],
    inbound: [{ sid: 'SMx', from10: '4145550400', body: 'STOP', is_opt_out: true, lead_id: 'L4', received_at: ago(500) }] },
]

const CONTROL = { sending_enabled: false, sending_changed_by: null, sending_changed_at: null, paused: false, pause_reason: null, paused_at: null,
  laptop_paused: false, laptop_pause_reason: null, daily_cap: 100, window_start: '10:00:00', window_end: '18:15:00', dnc_policy: 'allow_unknown',
  last_run_at: ago(2), last_run_summary: { mode: 'dry', why_dry: 'TWILIO_LIVE_SENDING is not 1', inbound_new: 0, inbound_error: null, sent: 0,
    would_send: 0, skipped: [], failed: 0, uncertain: 0, stopped: 'nothing_due' },
  routine_enabled: false, routine_changed_by: null, routine_changed_at: null, agent_rules_version: 'r1', redteam_version: 'r1',
  redteam_passed: 440, redteam_total: 440, redteam_ok: true, redteam_at: ago(30), agent_last_run_at: ago(1), agent_last_summary: null,
  test_phones: ['4145550909'] }

const PLANNED = ['ACME HOLDINGS LLC', 'JANE ROE', 'TOM WEBER', 'MARIA LOPEZ'].map((n, i) => ({
  ...opener(`Q${i}`, lead(`LQ${i}`, n, `${100 + i * 37} N ${['Main', 'Center', 'Lake', 'Oak'][i]} St`, 'opener_queued'), 'planned'),
  decision: i === 0 ? 'approved' : 'pending', sent_at: null, scheduled_at: new Date(now + (i + 1) * 3600_000).toISOString() }))

export const useWaitingDrafts = () => ok(WAITING)
export const useInbox = () => ok(INBOX)
export const useOtherDrafts = () => ok([{ ...base, id: 'd9', phone10: '2625550190', lead_id: null, inbound_at: ago(90), intent: 'wrong_number',
  kind: 'routine', status: 'would_send', inbound_body: 'wrong number', body: "Sorry about that - looks like I had the wrong number. I'll make sure you don't hear from me again. Take care.",
  draft_source: 'fixed_line' }])
export const useRepliesWaiting = () => ok({ drafts_waiting: WAITING.length, routine_would_send: 1, queued: 0, tasks_open: 1 })
export const useCampaignControl = () => ok(CONTROL)
export const usePlannedOpeners = () => ok(PLANNED)
export const useDueTasks = () => ok([{ id: 'T1', lead_id: 'L1', due_at: ago(30), kind: 'call', owner: 'colin', done_at: null, note: 'after 5', created_at: '', lead: LEADS[0] }])
export const useUnseenReplies = () => ok([{ id: 'M1', lead_id: 'L1', direction: 'in', channel: 'sms', body: "Maybe. Depends what you'd pay.", sent_at: ago(6), seen_at: null, is_opt_out: false, is_opener: false, status: 'replied', lead: LEADS[0] }])
export const useFollowupDebt = () => ok([{ lead_id: 'L2', owner_name: 'RITA SCHMIDT', property_address: 'W220 N1765 Pewaukee Rd', stage: 'follow_up', next_action_at: ago(4000), next_action: 'call back about the roof', assigned_to: 'colin', days_late: 3 }])
export const usePipelineCounts = () => ok([{ stage: 'reply_received', lane: 'hold', county: 'Milwaukee', n: 2 }, { stage: 'postcard_mailed', lane: 'flip', county: 'Racine', n: 4996 }, { stage: 'dnc', lane: 'hold', county: 'Milwaukee', n: 1 }])
export const useLeads = () => ok({ rows: LEADS, count: LEADS.length })
const REPLY_TASKS = [{ id: 'T9', lead_id: 'L1', due_at: ago(5), kind: 'email', owner: 'adil' as const, done_at: null, note: null, created_at: ago(5), source: 'reply',
  title: 'Email them the info they asked for', quote: "Can you email me what you'd need? dale.novak@example.com", email_to: 'dale.novak@example.com', phone10: '4145550177' }]
export const useLead = () => ok({
  lead: LEADS[0],
  contacts: [{ id: 'C1', lead_id: 'L1', kind: 'phone', value: '4145550177', value_normalized: '4145550177', person_name: 'DALE NOVAK', line_type: 'mobile', dnc_vendor: false, dnc_scrub: 'unknown', suppressed: false, dnc_app: false, source: 'fiverr', status: 'ok', note: null }],
  messages: INBOX[0].messages, tasks: REPLY_TASKS, gates: [], milestones: [{ id: 1, lead_id: 'L1', kind: 'connect', at: ago(6) }],
  facts: { motivation: 'tired of the tenants', timeline: 'before winter if I can', decision_makers: 'me and my sister', price_expectation: '"around 180"', flexibility: 'some, for a quick close', condition: 'roof is 20 years old', quotes: ["I'm done being a landlord"] },
})
export const useReplyTasks = () => ok(REPLY_TASKS.map((t) => ({ ...t, lead: LEADS[0] })))
export const useDeals = () => ok([])
export const useScoreboard = () => ok([{ week_start: '2026-10-19', lane: 'all', openers_sent: 100, delivered: 92, replies: 7, opt_outs: 2, connects: 6, contacts: 5, leads: 2, handoffs: 1, handoffs_held: 1, qualifying_calls: 1, walks: 1, contracts: 0, closes: 0, delivery_rate: 0.92, reply_rate: 0.0761, opt_out_rate: 0.0217, contact_rate: 0.8333, leads_per_delivered: 0.0217, handoffs_held_rate: 1, walk_rate: 1, walks_per_contract: null }])
export const useSignalScoreboard = () => ok([{ week_start: '2026-10-19', signal: 'tired landlord', openers_sent: 40, delivered: 37, replies: 3, opt_outs: 1, leads: 1, walks: 0, contracts: 0 },
  { week_start: '2026-10-19', signal: 'deep tax delinquency', openers_sent: 33, delivered: 31, replies: 2, opt_outs: 0, leads: 1, walks: 1, contracts: 0 }])

export function useWrite<TArgs>(fn: (args: TArgs) => PromiseLike<{ error: { message: string } | null }>) {
  return useMutation({ mutationFn: async (args: TArgs) => { const r = await fn(args); if (r.error) throw new Error(r.error.message) } })
}
const done = async () => ({ error: null, data: { outcome: 'dry_sent' } })
export const api = new Proxy({}, { get: () => done }) as Record<string, (...a: unknown[]) => Promise<{ error: null; data: { outcome: string } }>>
