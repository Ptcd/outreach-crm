// Client calls added 2026-10-22 for the Settings page, the call queue and the hand-off (migration 0028).
// Kept apart from queries.ts while the conveyor build edits that file.
import { supabase } from '@/lib/supabaseClient'

export type MyAlerts = { alert_phone: string | null; alert_email: string | null }

/** The signed-in member's alert phone and email (team_members, readable by the team). */
export async function myAlerts(email: string): Promise<MyAlerts> {
  const r = await supabase.from('team_members').select('alert_phone, alert_email').eq('email', email.toLowerCase()).maybeSingle()
  if (r.error) throw new Error(r.error.message)
  return (r.data as MyAlerts | null) ?? { alert_phone: null, alert_email: null }
}

export async function setMyAlerts(phone: string, email: string): Promise<{ ok: boolean; reason?: string; phone?: string | null; email?: string | null }> {
  const r = await supabase.rpc('set_my_alerts', { p_phone: phone, p_email: email })
  if (r.error) throw new Error(r.error.message)
  return r.data as { ok: boolean; reason?: string; phone?: string | null; email?: string | null }
}

/** Hands a card to Colin: assigns him, opens his task with the caller's one line, notes the thread, pings him. */
export async function handoffToColin(leadId: string, note: string): Promise<{ ok: boolean; reason?: string; task_id?: string }> {
  const r = await supabase.rpc('handoff_to_colin', { p_lead_id: leadId, p_note: note })
  if (r.error) throw new Error(r.error.message)
  return r.data as { ok: boolean; reason?: string; task_id?: string }
}
