// Data access: thin React Query hooks over supabase-js. RLS on the database decides
// what each person may read and write; these hooks just ask.
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from './supabaseClient'
import type {
  CampaignControl, Contact, Deal, FollowupDebt, GateScore, Lead, LeadStage, Message, Milestone, MilestoneKind,
  OpenerDecision, Person, PlannedOpener, ReplyDraft, ReplyThread, ScoreboardWeek, SignalWeek, Task, TwilioInbound,
} from './types'
import type { InboxLead } from './inbox'

function check<T>(res: { data: T | null; error: { message: string } | null }): T {
  if (res.error) throw new Error(res.error.message)
  return res.data as T
}

// ------------------------------------------------------------------ Today
export function useDueTasks(untilIso: string, owner: Person | 'all') {
  return useQuery({
    queryKey: ['tasks', 'due', untilIso, owner],
    queryFn: async () => {
      let q = supabase
        .from('tasks')
        .select('*, lead:leads(id, owner_name, property_address, stage)')
        .is('done_at', null)
        .lte('due_at', untilIso)
        .order('due_at')
        .limit(200)
      if (owner !== 'all') q = q.eq('owner', owner)
      return check(await q) as (Task & { lead: Pick<Lead, 'id' | 'owner_name' | 'property_address' | 'stage'> | null })[]
    },
  })
}

export function useUnseenReplies() {
  return useQuery({
    queryKey: ['messages', 'unseen'],
    queryFn: async () =>
      check(
        await supabase
          .from('messages')
          .select('*, lead:leads(id, owner_name, property_address, stage)')
          .eq('direction', 'in')
          .is('seen_at', null)
          .order('sent_at', { ascending: false })
          .limit(100),
      ) as (Message & { lead: Pick<Lead, 'id' | 'owner_name' | 'property_address' | 'stage'> | null })[],
  })
}

export function useFollowupDebt() {
  return useQuery({
    queryKey: ['followup_debt'],
    queryFn: async () =>
      check(await supabase.from('followup_debt').select('*').order('days_late', { ascending: false }).limit(200)) as FollowupDebt[],
  })
}

// --------------------------------------------------------------- Pipeline
export function usePipelineCounts() {
  return useQuery({
    queryKey: ['pipeline_counts'],
    queryFn: async () =>
      check(await supabase.from('pipeline_counts').select('*')) as { stage: LeadStage; lane: string | null; county: string | null; n: number }[],
  })
}

export interface LeadFilter {
  stage: LeadStage | 'working' | 'all'
  lane: 'hold' | 'flip' | 'all'
  county: string | 'all'
  search: string
  page: number
}

export const PAGE_SIZE = 50

export function useLeads(f: LeadFilter, workingStages: LeadStage[]) {
  return useQuery({
    queryKey: ['leads', f],
    queryFn: async () => {
      let q = supabase
        .from('leads')
        .select('id, owner_name, property_address, municipality, county, lane, stage, next_action_at, next_action, assigned_to, reasons_to_sell, last_inbound_at', { count: 'exact' })
      if (f.stage === 'working') q = q.in('stage', workingStages)
      else if (f.stage !== 'all') q = q.eq('stage', f.stage)
      if (f.lane !== 'all') q = q.eq('lane', f.lane)
      if (f.county !== 'all') q = q.eq('county', f.county)
      const s = f.search.trim().replace(/[%,()]/g, ' ')
      if (s) q = q.or(`owner_name.ilike.%${s}%,property_address.ilike.%${s}%`)
      q = q.order('next_action_at', { ascending: true, nullsFirst: false }).order('score', { ascending: false, nullsFirst: false })
      const res = await q.range(f.page * PAGE_SIZE, f.page * PAGE_SIZE + PAGE_SIZE - 1)
      if (res.error) throw new Error(res.error.message)
      return { rows: (res.data ?? []) as Partial<Lead>[] as Lead[], count: res.count ?? 0 }
    },
  })
}

// ------------------------------------------------------------ Lead detail
export function useLead(id: string) {
  return useQuery({
    queryKey: ['lead', id],
    queryFn: async () => {
      const [lead, contacts, messages, tasks, gates, milestones, facts] = await Promise.all([
        supabase.from('leads').select('*').eq('id', id).single(),
        supabase.from('contacts').select('*').eq('lead_id', id).order('kind').order('line_type'),
        supabase.from('messages').select('*').eq('lead_id', id).order('sent_at', { ascending: false }),
        supabase.from('tasks').select('*').eq('lead_id', id).order('due_at'),
        supabase.from('gate_scores').select('*').eq('lead_id', id).order('at', { ascending: false }),
        supabase.from('lead_milestones').select('*').eq('lead_id', id),
        supabase.from('reply_drafts').select('facts, inbound_at').eq('lead_id', id).not('facts', 'is', null).order('inbound_at'),
      ])
      return {
        lead: check(lead) as Lead,
        contacts: check(contacts) as Contact[],
        messages: check(messages) as Message[],
        tasks: check(tasks) as Task[],
        gates: check(gates) as GateScore[],
        milestones: check(milestones) as Milestone[],
        // What the seller has told us so far (the drafting model's facts, newest value wins)
        facts: Object.assign({}, ...((facts.data ?? []) as { facts: Record<string, unknown> }[]).map((f) => f.facts ?? {})) as Record<string, unknown>,
      }
    },
  })
}

export function useDeals(leadId: string, enabled: boolean) {
  return useQuery({
    queryKey: ['deals', leadId],
    enabled,
    queryFn: async () => check(await supabase.from('deals').select('*').eq('lead_id', leadId).order('created_at')) as Deal[],
  })
}

/** Every write goes through here so the right screens refresh afterwards. */
export function useWrite<TArgs>(fn: (args: TArgs) => PromiseLike<{ error: { message: string } | null }>, invalidate: string[][]) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (args: TArgs) => {
      const { error } = await fn(args)
      if (error) throw new Error(error.message)
    },
    onSuccess: () => {
      for (const key of invalidate) void qc.invalidateQueries({ queryKey: key })
    },
  })
}

export const api = {
  updateLead: (id: string, patch: Partial<Pick<Lead, 'stage' | 'next_action_at' | 'next_action' | 'assigned_to' | 'dead_reason' | 'notes'>>) =>
    supabase.from('leads').update(patch).eq('id', id),
  updateContact: (id: string, patch: Partial<Pick<Contact, 'status' | 'dnc_app' | 'note'>>) =>
    supabase.from('contacts').update(patch).eq('id', id),
  addMessage: (row: { lead_id: string; channel: 'call' | 'note'; direction: 'in' | 'out'; body: string }) =>
    supabase.from('messages').insert(row),
  markSeen: (id: string, userId: string) =>
    supabase.from('messages').update({ seen_at: new Date().toISOString(), seen_by: userId }).eq('id', id),
  addTask: (row: { lead_id: string | null; due_at: string; kind: string; owner: Person; note: string | null }) =>
    supabase.from('tasks').insert(row),
  finishTask: (id: string) => supabase.from('tasks').update({ done_at: new Date().toISOString() }).eq('id', id),
  addGate: (row: Omit<GateScore, 'id' | 'total' | 'suggested_decision' | 'at'>) => supabase.from('gate_scores').insert(row),
  addMilestone: (lead_id: string, kind: MilestoneKind) => supabase.from('lead_milestones').insert({ lead_id, kind }),
  removeMilestone: (id: number) => supabase.from('lead_milestones').delete().eq('id', id),
  saveDeal: (row: Partial<Deal> & { lead_id: string }) =>
    row.id ? supabase.from('deals').update(row).eq('id', row.id) : supabase.from('deals').insert(row),
  decideOpener: (id: string, decision: OpenerDecision, name: string, note: string | null) =>
    supabase
      .from('planned_openers')
      .update({ decision, decided_by_name: name, decided_at: new Date().toISOString(), decision_note: note })
      .eq('id', id),
  // Colin's sending buttons (owner-only functions in migration 0003)
  setSending: (on: boolean) => supabase.rpc('set_sending', { p_on: on }),
  clearPause: () => supabase.rpc('clear_pause'),
  resumeFollowups: () => supabase.rpc('resume_followups'),
  approveDay: (day: string, except: string[]) => supabase.rpc('approve_day', { p_date: day, p_except: except }),
  withdrawDay: (day: string) => supabase.rpc('withdraw_day', { p_date: day }),
  // Inbox one-tap actions
  bookCall: async (leadId: string, atIso: string) => {
    const a = await supabase.from('leads')
      .update({ stage: 'colin_call', next_action: "Colin's call", next_action_at: atIso, assigned_to: 'colin' }).eq('id', leadId)
    if (a.error) return a
    return supabase.from('tasks').insert({ lead_id: leadId, due_at: atIso, kind: 'call', owner: 'colin', note: "Colin's call (booked from Inbox)" })
  },
  // drafted replies: Approve (with Colin's final words) or Skip, through the reply-send Edge Function
  replyAction: async (id: string, action: 'approve' | 'skip', text?: string) => {
    const r = await supabase.functions.invoke('reply-send', { body: { id, action, text } })
    if (r.error) return { error: { message: r.error.message } }
    const d = r.data as { outcome: string; reason?: string }
    return { error: d.outcome === 'refused' ? { message: d.reason ?? 'not sent' } : null, data: d }
  },
  setRoutine: (on: boolean) => supabase.rpc('set_routine_replies', { p_on: on }),
  // A tap-sent email (never AI-sent), from the Gmail sender, logged on the lead
  sendEmail: async (x: { lead_id: string | null; task_id: string | null; to: string; subject: string; body: string }) => {
    const r = await supabase.functions.invoke('reply-send', { body: { action: 'send_email', ...x } })
    if (r.error) return { error: { message: r.error.message } }
    const d = r.data as { outcome: string; reason?: string }
    return { error: d.outcome === 'sent' ? null : { message: d.reason ?? 'The email did not go.' } }
  },
  assignTask: (id: string, owner: Person) => supabase.from('tasks').update({ owner }).eq('id', id),
  markCalled: (leadId: string) => supabase.rpc('mark_called', { p_lead_id: leadId }),
  // Call desk (migration 0013)
  newCaller: (phone: string, name?: string) => supabase.rpc('new_caller', { p_phone: phone, p_name: name ?? null }),
  callAnswer: (leadId: string, key: string, value: unknown) => supabase.rpc('call_answer', { p_lead_id: leadId, p_key: key, p_value: value }),
  logCall: (leadId: string, phone: string | null, outcome: string, note: string | null) =>
    supabase.rpc('log_call', { p_lead_id: leadId, p_phone: phone, p_outcome: outcome, p_note: note }),
  // Send contract (Colin): preview / send / new_link / void / pdf / seal. Errors come back as { ok: false, reason }.
  contract: async (body: Record<string, unknown>): Promise<{ ok: boolean; reason?: string } & Record<string, unknown>> => {
    const r = await supabase.functions.invoke('contract', { body })
    if (r.error) return { ok: false, reason: await fnError(r.error) }
    return r.data as { ok: boolean; reason?: string } & Record<string, unknown>
  },
  // The seller's signing page (no login; the link token is the key).
  contractSign: async (body: Record<string, unknown>): Promise<{ ok: boolean; reason?: string } & Record<string, unknown>> => {
    const r = await supabase.functions.invoke('contract-sign', { body })
    if (r.error) return { ok: false, reason: await fnError(r.error) }
    return r.data as { ok: boolean; reason?: string } & Record<string, unknown>
  },
  setTestPhone: (phone: string) => supabase.rpc('set_test_phone', { p_phone: phone }),
  resetTestPhones: () => supabase.rpc('reset_test_phones'),
  notInterested: (leadId: string) =>
    supabase.from('leads').update({ stage: 'dead', dead_reason: 'not interested', next_action_at: null, next_action: null }).eq('id', leadId),
}

// ------------------------------------------------------------- Sending
export function useCampaignControl() {
  return useQuery({
    queryKey: ['campaign_control'],
    refetchInterval: 60_000,
    queryFn: async () =>
      check(
        await supabase.from('campaign_control')
          .select('sending_enabled, sending_changed_by, sending_changed_at, paused, pause_reason, paused_at, laptop_paused, laptop_pause_reason, daily_cap, window_start, window_end, dnc_policy, last_run_at, last_run_summary, routine_enabled, routine_changed_by, routine_changed_at, agent_rules_version, redteam_version, redteam_passed, redteam_total, redteam_ok, redteam_at, agent_last_run_at, agent_last_summary, test_phones, test_owner_name, test_property_address, followups_paused, followups_pause_reason, followups_paused_at')
          .eq('id', 1).single(),
      ) as CampaignControl,
  })
}

// ---------------------------------------------------------------- Inbox
/** Every planned text in [fromDay, toDay] with its lead, thread, reply-agent view and server-seen replies. */
export function useInbox(fromDay: string, toDay: string, enabled = true) {
  return useQuery({
    queryKey: ['inbox', fromDay, toDay],
    enabled,
    refetchInterval: 60_000,
    queryFn: async (): Promise<InboxLead[]> => {
      const openers = check(
        await supabase.from('planned_openers')
          .select('*, lead:leads(id, owner_name, property_address, stage, next_action_at, next_action, assigned_to, dead_reason)')
          .gte('plan_date', fromDay).lte('plan_date', toDay)
          .order('scheduled_at', { ascending: false, nullsFirst: false })
          .limit(500),
      ) as (PlannedOpener & { lead: InboxLead['lead'] })[]
      const leadIds = [...new Set(openers.map((o) => o.lead_id).filter((x): x is string => Boolean(x)))]
      if (leadIds.length === 0) return openers.map((o) => ({ opener: o, lead: o.lead, messages: [], thread: null, inbound: [], drafts: [] }))
      const [messages, threads, inbound, drafts] = await Promise.all([
        supabase.from('messages').select('*').in('lead_id', leadIds).eq('channel', 'sms').order('sent_at'),
        supabase.from('reply_threads').select('*').in('lead_id', leadIds),
        supabase.from('twilio_inbound').select('*').in('lead_id', leadIds).order('received_at'),
        supabase.from('reply_drafts').select('*').in('lead_id', leadIds).order('inbound_at'),
      ])
      const msgs = check(messages) as Message[]
      const ths = check(threads) as ReplyThread[]
      const inb = check(inbound) as TwilioInbound[]
      const drs = check(drafts) as ReplyDraft[]
      return openers.map((o) => ({
        opener: o,
        lead: o.lead,
        messages: msgs.filter((m) => m.lead_id === o.lead_id),
        thread: ths.find((t) => t.lead_id === o.lead_id) ?? null,
        inbound: inb.filter((m) => m.lead_id === o.lead_id),
        drafts: drs.filter((d) => d.lead_id === o.lead_id),
      }))
    },
  })
}

// ------------------------------------------------------------- Approvals
export function usePlannedOpeners(planDate: string) {
  return useQuery({
    queryKey: ['planned_openers', planDate],
    queryFn: async () =>
      check(
        await supabase.from('planned_openers').select('*').eq('plan_date', planDate).order('scheduled_at', { nullsFirst: false }),
      ) as PlannedOpener[],
  })
}

// ------------------------------------------------------------ Scoreboard
export function useScoreboard(lane: string) {
  return useQuery({
    queryKey: ['scoreboard', lane],
    queryFn: async () =>
      check(
        await supabase.from('scoreboard_weekly').select('*').eq('lane', lane).order('week_start', { ascending: false }).limit(12),
      ) as ScoreboardWeek[],
  })
}

export function useSignalScoreboard(weekStart: string | null) {
  return useQuery({
    queryKey: ['scoreboard_signal', weekStart],
    enabled: Boolean(weekStart),
    queryFn: async () =>
      check(
        await supabase.from('scoreboard_weekly_by_signal').select('*').eq('week_start', weekStart!).order('openers_sent', { ascending: false }),
      ) as SignalWeek[],
  })
}

// ------------------------------------------------------------ Drafted replies
/** Replies from numbers that are not on any planned text (no lead, or a lead we never texted). */
export function useOtherDrafts(knownLeadIds: string[]) {
  return useQuery({
    queryKey: ['reply_drafts', 'other', knownLeadIds.length],
    refetchInterval: 60_000,
    queryFn: async () => {
      const rows = check(
        await supabase.from('reply_drafts').select('*').neq('status', 'superseded').order('inbound_at', { ascending: false }).limit(200),
      ) as ReplyDraft[]
      const known = new Set(knownLeadIds)
      return rows.filter((d) => !d.lead_id || !known.has(d.lead_id))
    },
  })
}

/** How many of drafted replies wait for Colin (the Inbox badge). */
export function useRepliesWaiting() {
  return useQuery({
    queryKey: ['reply_waiting'],
    refetchInterval: 60_000,
    queryFn: async () =>
      check(await supabase.from('reply_waiting').select('drafts_waiting, routine_would_send, queued, tasks_open').single()) as
        { drafts_waiting: number; routine_would_send: number; queued: number; tasks_open?: number },
  })
}

// ------------------------------------------------------- drafts waiting for Colin
export interface WaitingDraft extends ReplyDraft {
  owner_name: string | null
  property_address: string | null
  thread: { key: string; who: 'us' | 'them'; body: string; at: string }[]
}

/** The replies waiting for Colin, with their threads: small and loaded first. */
export function useWaitingDrafts() {
  return useQuery({
    queryKey: ['reply_drafts', 'waiting'],
    refetchInterval: 30_000,
    queryFn: async (): Promise<WaitingDraft[]> => {
      const drafts = check(
        await supabase.from('reply_drafts').select('*, lead:leads(owner_name, property_address)')
          .eq('status', 'awaiting_approval').order('inbound_at').limit(50),
      ) as (ReplyDraft & { lead: { owner_name: string | null; property_address: string | null } | null })[]
      if (!drafts.length) return []
      const phones = [...new Set(drafts.map((d) => d.phone10))]
      const leadIds = [...new Set(drafts.map((d) => d.lead_id).filter((x): x is string => Boolean(x)))]
      const [inbound, sent, msgs] = await Promise.all([
        supabase.from('twilio_inbound').select('sid, from10, body, received_at').in('from10', phones).order('received_at'),
        supabase.from('reply_drafts').select('id, phone10, sent_body, sent_at').in('phone10', phones).eq('status', 'sent'),
        leadIds.length
          ? supabase.from('messages').select('id, lead_id, direction, body, sent_at, provider_sid').in('lead_id', leadIds).eq('channel', 'sms')
          : Promise.resolve({ data: [], error: null }),
      ])
      const inb = check(inbound) as { sid: string; from10: string; body: string | null; received_at: string }[]
      const out = check(sent) as { id: string; phone10: string; sent_body: string | null; sent_at: string | null }[]
      const ms = check(msgs) as { id: string; lead_id: string; direction: 'in' | 'out'; body: string | null; sent_at: string; provider_sid: string | null }[]
      return drafts.map((d) => {
        const lines = [
          ...inb.filter((t) => t.from10 === d.phone10 && t.received_at <= d.inbound_at)
            .map((t) => ({ key: t.sid, who: 'them' as const, body: t.body ?? '', at: t.received_at })),
          ...out.filter((s) => s.phone10 === d.phone10 && s.sent_at && s.sent_at <= d.inbound_at)
            .map((s) => ({ key: `s-${s.id}`, who: 'us' as const, body: s.sent_body ?? '', at: s.sent_at! })),
          ...ms.filter((m) => m.lead_id === d.lead_id && m.direction === 'out' && m.sent_at <= d.inbound_at)
            .map((m) => ({ key: m.id, who: 'us' as const, body: m.body ?? '', at: m.sent_at })),
        ].filter((l) => l.body).sort((a, b) => a.at.localeCompare(b.at))
        const { lead, ...rest } = d
        return { ...rest, owner_name: lead?.owner_name ?? null, property_address: lead?.property_address ?? null, thread: lines }
      })
    },
  })
}

/** Open tasks the reply agent opened (things no text can do), oldest first. */
export function useReplyTasks() {
  return useQuery({
    queryKey: ['tasks', 'reply'],
    refetchInterval: 60_000,
    queryFn: async () =>
      check(await supabase.from('tasks').select('*, lead:leads(id, owner_name, property_address)')
        .eq('source', 'reply').is('done_at', null).order('created_at').limit(100)) as
        (Task & { lead: { id: string; owner_name: string; property_address: string | null } | null })[],
  })
}

/** A function error's own message when it sent one ({ reason }), else the transport error. */
async function fnError(e: unknown): Promise<string> {
  const ctx = (e as { context?: Response }).context
  try {
    const j = ctx && typeof ctx.json === 'function' ? await ctx.json() : null
    if (j && typeof j.reason === 'string') return j.reason
  } catch { /* not json */ }
  return e instanceof Error ? e.message : String(e)
}

export type ContractRow = {
  id: string; lead_id: string; form: string; status: 'sent' | 'signed' | 'void'; created_at: string; signed_at: string | null
  voided_at: string | null; void_reason: string | null; final_path: string | null; include_recr: boolean
  terms: { price: number; closing: string; street: string }
  contract_signers: { id: string; position: number; name: string; email: string | null; phone: string | null; opened_at: string | null
    signed_at: string | null; expires_at: string }[]
}

/** Contracts on a lead, newest first, with each seller's progress. */
export function useContracts(leadId: string) {
  return useQuery({
    queryKey: ['contracts', leadId],
    refetchInterval: 30_000,
    queryFn: async () =>
      check(await supabase.from('contracts')
        .select('id, lead_id, form, status, created_at, signed_at, voided_at, void_reason, final_path, include_recr, terms, contract_signers(id, position, name, email, phone, opened_at, signed_at, expires_at)')
        .eq('lead_id', leadId).order('created_at', { ascending: false })) as ContractRow[],
  })
}

export type PhoneMatch = { lead_id: string; owner_name: string; property_address: string | null; municipality: string | null
  lane: string | null; stage: LeadStage; phone: string; person_name: string | null; blocked: boolean; exact: boolean }

/** Owners whose phone ends in these digits (last 4 is the usual case), or is exactly this number. */
export function usePhoneLookup(digits: string) {
  const d = digits.replace(/\D/g, '')
  return useQuery({
    queryKey: ['phone_lookup', d],
    enabled: d.length >= 3,
    staleTime: 60_000,
    queryFn: async () => check(await supabase.rpc('phone_lookup', { p_digits: d })) as PhoneMatch[],
  })
}

export type HotAlertRow = { id: string; created_at: string; body: string; alert1_at: string | null; alert2_at: string | null
  called_at: string | null; is_test: boolean; phone10: string }

/** Hot replies on a lead (newest first): when Colin was texted and how fast he called. */
export function useHotAlerts(leadId: string) {
  return useQuery({
    queryKey: ['hot_alerts', leadId],
    refetchInterval: 30_000,
    queryFn: async () => check(await supabase.from('hot_alerts')
      .select('id, created_at, body, alert1_at, alert2_at, called_at, is_test, phone10')
      .eq('lead_id', leadId).order('created_at', { ascending: false }).limit(5)) as HotAlertRow[],
  })
}
