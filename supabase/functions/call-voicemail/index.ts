// call-voicemail: leave the recorded voicemail on a caller's live call (0319, Thalia 2026-11-24: one tap at the beep,
// then on to the next card). The signed-in caller sends their own call's id, the card and the number; the database
// (voicemail_drop_check) says whether this number may get one and writes the words from the card; pm-phone's
// /api/voicemail/drop hands the seller's leg the message and ends the caller's leg (pm-phone lib/voicemailDrop).
// pm-phone checks the call is a live app call placed by this same person. Secret: ALERT_SECRET (shared with alerts).
import { createClient } from 'npm:@supabase/supabase-js@2.56.1'

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS })
  // every answer is a 200 with ok true or false: the app shows `error` to the caller as it is
  const json = (body: unknown) => Response.json(body, { headers: CORS })
  const url = Deno.env.get('SUPABASE_URL') ?? ''
  const asUser = createClient(url, Deno.env.get('SUPABASE_ANON_KEY') ?? '', {
    global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } }, auth: { persistSession: false } })
  const body = await req.json().catch(() => ({})) as { callSid?: unknown; leadId?: unknown; phone?: unknown }
  const callSid = String(body.callSid ?? '')
  const leadId = String(body.leadId ?? '')
  const phone = String(body.phone ?? '').replace(/\D/g, '').slice(-10)
  if (!/^CA[0-9a-fA-F]{32}$/.test(callSid)) return json({ ok: false, error: 'No live call.' })
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(leadId)) return json({ ok: false, error: 'No card on this call.' })
  const check = await asUser.rpc('voicemail_drop_check', { p_lead_id: leadId, p_phone: phone })
  if (check.error) return json({ ok: false, error: 'Not your card.' })
  const c = (check.data ?? {}) as { ok?: boolean; reason?: string; person?: string; say?: string; voice?: string }
  if (!c.ok || !c.person || !c.say) return json({ ok: false, error: c.reason ?? 'No recorded message for this number.' })
  const secret = (Deno.env.get('ALERT_SECRET') ?? '').trim()
  if (!secret) return json({ ok: false, error: 'Not set up.' })
  const alertUrl = (Deno.env.get('ALERT_URL') ?? '').trim() || 'https://junkcarsmequon.com/api/alert'
  const dropUrl = alertUrl.replace(/\/api\/alert\/?$/, '/api/voicemail/drop')
  try {
    const r = await fetch(dropUrl, { method: 'POST', headers: { 'content-type': 'application/json', 'x-alert-secret': secret },
      body: JSON.stringify({ callSid, identity: c.person, text: c.say, voice: c.voice }) })
    const d = await r.json().catch(() => ({})) as { ok?: boolean; error?: string; said?: string }
    if (!d.ok) return json({ ok: false, error: d.error ? d.error.charAt(0).toUpperCase() + d.error.slice(1) + '.' : `The phone server answered ${r.status}.` })
    const done = await asUser.rpc('voicemail_drop_done', { p_lead_id: leadId, p_phone: phone, p_call_sid: callSid, p_said: d.said ?? c.say })
    if (done.error) console.error('voicemail_drop_done', done.error.message)
    return json({ ok: true })
  } catch (e) {
    return json({ ok: false, error: e instanceof Error ? e.message : 'The phone server did not answer.' })
  }
})
