// Row shapes for supabase/migrations/0001_wpie_live.sql and 0003_app_sending.sql.

export type LeadStage =
  | 'postcard_mailed' | 'opener_queued' | 'opener_sent' | 'reply_received' | 'ai_qualifying'
  | 'handoff' | 'colin_call' | 'walk_decision' | 'walkthrough_booked' | 'offer' | 'follow_up'
  | 'under_contract' | 'closed_won' | 'dead' | 'closed_no_contact' | 'dnc' | 'data_fix'
  | 'mail_only' | 'human_owned'

export type Lane = 'hold' | 'flip'
export type Person = 'colin' | 'thalia' | 'adil'
export type Role = 'owner' | 'caller'
export type GateDecision = 'walk' | 'no_walk' | 'one_more_call'
export type DealStatus = 'offer' | 'contract' | 'signed_to_title' | 'closed' | 'dead'
export type OpenerDecision = 'pending' | 'approved' | 'skipped'
export type MilestoneKind = 'connect' | 'contact' | 'lead' | 'handoff' | 'handoff_held' | 'qualifying_call' | 'walk'

export interface TeamMember {
  email: string
  role: Role
  person: Person
  display_name: string
}

export interface Lead {
  id: string
  wpie_owner_id: number | null
  owner_name: string
  owner_type: string | null
  mailing_street: string | null
  mailing_city: string | null
  mailing_state: string | null
  mailing_zip: string | null
  lane: Lane | null
  county: string | null
  municipality: string | null
  property_address: string | null
  property_zip: string | null
  wpie_property_id: number | null
  parcel_id: string | null
  property_type: string | null
  units: number | null
  reasons_to_sell: string[]
  score: number | null
  mailed_on: string | null
  mail_channel: string | null
  stage: LeadStage
  stage_changed_at: string
  next_action_at: string | null
  next_action: string | null
  assigned_to: Person | null
  dead_reason: string | null
  notes: string | null
  last_inbound_at: string | null
  created_at: string
  updated_at: string
  // 0013: answers from the call script, { key: { value, at, by } }
  call_facts?: Record<string, { value: unknown; at: string; by?: string | null }> | null
}

export interface Contact {
  id: string
  lead_id: string
  kind: 'phone' | 'email'
  value: string
  value_normalized: string | null
  person_name: string | null
  line_type: string | null
  dnc_vendor: boolean
  dnc_scrub: 'unknown' | 'clear' | 'dnc'
  suppressed: boolean
  dnc_app: boolean
  source: string | null
  status: 'ok' | 'bad'
  note: string | null
}

export interface Message {
  id: string
  lead_id: string
  direction: 'in' | 'out'
  channel: 'sms' | 'call' | 'note' | 'email'
  body: string | null
  from_number: string | null
  to_number: string | null
  status: string | null
  is_opener: boolean
  is_opt_out: boolean
  sent_at: string
  seen_at: string | null
}

export interface Task {
  id: string
  lead_id: string | null
  due_at: string
  kind: string
  owner: Person
  done_at: string | null
  note: string | null
  created_at: string
  // 0009: opened by the reply agent
  source?: string | null
  title?: string | null
  quote?: string | null
  email_to?: string | null
  phone10?: string | null
}

export interface GateScore {
  id: string
  lead_id: string
  reason_and_clock: number
  decision_makers: number
  number_and_anchor: number
  flexibility: number
  condition: number
  numbers_close: number
  hard_stops: string[]
  total: number
  suggested_decision: GateDecision
  decision: GateDecision
  note: string | null
  decided_by_name: string | null
  at: string
}

export interface Deal {
  id: string
  lead_id: string
  status: DealStatus
  colin_offer: number | null
  contract_date: string | null
  close_date: string | null
  notes: string | null
}

export interface PlannedOpener {
  id: string
  plan_date: string
  wpie_owner_id: number
  attempt: number
  lead_id: string | null
  lane: string | null
  template_lane: string | null
  variant: string | null
  phone: string | null
  body: string
  segments: number | null
  scheduled_at: string | null
  owner_name: string | null
  property_address: string | null
  decision: OpenerDecision
  decided_by_name: string | null
  decided_at: string | null
  decision_note: string | null
  // 0003: where the text stands on the server
  send_status: SendStatus
  send_reason: string | null
  claimed_at: string | null
  sent_at: string | null
  error_code: string | null
}

export type SendStatus =
  | 'planned' | 'would_send' | 'sending' | 'sent' | 'delivered' | 'undelivered'
  | 'failed' | 'uncertain' | 'skipped' | 'withdrawn'

export interface RunSummary {
  mode: 'live' | 'dry'
  why_dry: string
  inbound_new: number
  inbound_error: string | null
  sent: number
  would_send: number
  skipped: { id: string; reason: string }[]
  failed: number
  uncertain: number
  stopped: string
}

export interface CampaignControl {
  sending_enabled: boolean
  sending_changed_by: string | null
  sending_changed_at: string | null
  paused: boolean
  pause_reason: string | null
  paused_at: string | null
  laptop_paused: boolean
  laptop_pause_reason: string | null
  daily_cap: number
  window_start: string
  window_end: string
  dnc_policy: 'require_scrub' | 'allow_unknown'
  last_run_at: string | null
  last_run_summary: RunSummary | null
  // 0004: The reply agent
  routine_enabled: boolean
  routine_changed_by: string | null
  routine_changed_at: string | null
  agent_rules_version: string | null
  redteam_version: string | null
  redteam_passed: number | null
  redteam_total: number | null
  redteam_ok: boolean
  redteam_at: string | null
  agent_last_run_at: string | null
  agent_last_summary: Record<string, unknown> | null
  test_phones: string[]
  test_owner_name?: string | null
  test_property_address?: string | null
}

export type DraftStatus =
  | 'no_reply' | 'would_send' | 'awaiting_approval' | 'queued' | 'sending' | 'sent' | 'dry_sent'
  | 'failed' | 'uncertain' | 'skipped' | 'superseded'

/** One inbound text and the drafted answer to it (migration 0004). */
export interface ReplyDraft {
  id: string
  inbound_sid: string
  phone10: string
  our_number: string | null
  lead_id: string | null
  inbound_body: string | null
  inbound_at: string
  intent: string | null
  kind: 'removal' | 'routine' | 'candidate'
  outcome: string | null
  note: string | null
  body: string | null
  draft_source: string | null
  status: DraftStatus
  send_after: string | null
  sent_body: string | null
  sent_at: string | null
  decided_by: string | null
  decided_at: string | null
  is_test: boolean
}

/** The reply agent's view of one conversation, pushed by the WPIE sync. */
export interface ReplyThread {
  phone10: string
  lead_id: string | null
  intent: string | null
  agent_stage: string | null
  outcome: string | null
  human_owned: boolean
  handoff_flag: string | null
  callback_slot: string | null
  facts: Record<string, string>
  suggested_reply: string | null
  suggestion_note: string | null
  last_inbound_at: string | null
  last_inbound: string | null
}

/** An inbound text the server pulled from Twilio (may not be in WPIE yet). */
export interface TwilioInbound {
  sid: string
  from10: string
  body: string | null
  is_opt_out: boolean
  lead_id: string | null
  received_at: string
}

export interface Milestone {
  id: number
  lead_id: string
  kind: MilestoneKind
  at: string
}

export interface ScoreboardWeek {
  week_start: string
  lane: string
  openers_sent: number
  delivered: number
  replies: number
  opt_outs: number
  connects: number
  contacts: number
  leads: number
  handoffs: number
  handoffs_held: number
  qualifying_calls: number
  walks: number
  contracts: number
  closes: number
  delivery_rate: number | null
  reply_rate: number | null
  opt_out_rate: number | null
  contact_rate: number | null
  leads_per_delivered: number | null
  handoffs_held_rate: number | null
  walk_rate: number | null
  walks_per_contract: number | null
}

export interface SignalWeek {
  week_start: string
  signal: string
  openers_sent: number
  delivered: number
  replies: number
  opt_outs: number
  leads: number
  walks: number
  contracts: number
}

export interface FollowupDebt {
  lead_id: string
  owner_name: string
  property_address: string | null
  stage: LeadStage
  next_action_at: string
  next_action: string | null
  assigned_to: Person | null
  days_late: number
}
