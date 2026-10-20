// Data access: thin React Query hooks over supabase-js. RLS on the database decides
// what each person may read and write; these hooks just ask.
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from './supabaseClient'
import type {
  Contact, Deal, FollowupDebt, GateScore, Lead, LeadStage, Message, Milestone, MilestoneKind,
  OpenerDecision, Person, PlannedOpener, ScoreboardWeek, SignalWeek, Task,
} from './types'

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
      const [lead, contacts, messages, tasks, gates, milestones] = await Promise.all([
        supabase.from('leads').select('*').eq('id', id).single(),
        supabase.from('contacts').select('*').eq('lead_id', id).order('kind').order('line_type'),
        supabase.from('messages').select('*').eq('lead_id', id).order('sent_at', { ascending: false }),
        supabase.from('tasks').select('*').eq('lead_id', id).order('due_at'),
        supabase.from('gate_scores').select('*').eq('lead_id', id).order('at', { ascending: false }),
        supabase.from('lead_milestones').select('*').eq('lead_id', id),
      ])
      return {
        lead: check(lead) as Lead,
        contacts: check(contacts) as Contact[],
        messages: check(messages) as Message[],
        tasks: check(tasks) as Task[],
        gates: check(gates) as GateScore[],
        milestones: check(milestones) as Milestone[],
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
