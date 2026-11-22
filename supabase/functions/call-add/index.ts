// call-add: put Colin on a caller's live call (Colin 2026-11-22: a caller pulls him in when a seller needs his number).
// The signed-in caller sends their own call's id and the card; the card must be theirs (call_add_check, card_guard),
// then pm-phone's /api/conference/add moves the call into a conference and dials Colin (pm-phone lib/conference).
// pm-phone checks the call is a live app call placed by this same person. Secret: ALERT_SECRET (shared with alerts).
import { createClient } from 'npm:@supabase/supabase-js@2.56.1'

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS })
  const json = (body: unknown, status = 200) => Response.json(body, { status, headers: CORS })
  const url = Deno.env.get('SUPABASE_URL') ?? ''
  const asUser = createClient(url, Deno.env.get('SUPABASE_ANON_KEY') ?? '', {
    global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } }, auth: { persistSession: false } })
  const body = await req.json().catch(() => ({})) as { callSid?: unknown; leadId?: unknown }
  const callSid = String(body.callSid ?? '')
  const leadId = String(body.leadId ?? '')
  if (!/^CA[0-9a-fA-F]{32}$/.test(callSid)) return json({ ok: false, error: 'no live call' }, 400)
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(leadId)) return json({ ok: false, error: 'no card on this call' }, 400)
  const check = await asUser.rpc('call_add_check', { p_lead_id: leadId })
  if (check.error) return json({ ok: false, error: 'not your card' }, 403)
  const who = (check.data ?? {}) as { person?: string }
  const secret = (Deno.env.get('ALERT_SECRET') ?? '').trim()
  if (!secret || !who.person) return json({ ok: false, error: 'not set up' }, 503)
  const alertUrl = (Deno.env.get('ALERT_URL') ?? '').trim() || 'https://junkcarsmequon.com/api/alert'
  const addUrl = alertUrl.replace(/\/api\/alert\/?$/, '/api/conference/add')
  try {
    const r = await fetch(addUrl, { method: 'POST', headers: { 'content-type': 'application/json', 'x-alert-secret': secret },
      body: JSON.stringify({ callSid, identity: who.person }) })
    const d = await r.json().catch(() => ({})) as { ok?: boolean; error?: string }
    return json(d.ok ? { ok: true } : { ok: false, error: d.error ?? `phone server answered ${r.status}` }, d.ok ? 200 : 502)
  } catch (e) {
    return json({ ok: false, error: e instanceof Error ? e.message : 'phone server did not answer' }, 502)
  }
})
