// voice-token: a short-lived Twilio Voice access token for the app's in-browser dialer (Colin 2026-10-22:
// "app/browser based dialer"). Any signed-in team member gets one, under their own identity (colin /
// thalia / adil), good for one hour, outgoing calls only. The call itself is placed by the browser with
// Twilio's Voice SDK; the TwiML App "WPIE app dialer" (TWILIO_TWIML_APP_SID) points at pm-phone's
// /api/twilio/voice/client, which dials the owner showing a seller number as caller ID.
// Secrets: TWILIO_ACCOUNT_SID (the WPIE Mail Replies subaccount), TWILIO_API_KEY_SID, TWILIO_API_KEY_SECRET,
// TWILIO_TWIML_APP_SID. Nothing here sends a text or places a call.
import { createClient } from 'npm:@supabase/supabase-js@2.56.1'
import { voiceToken } from '../_shared/voiceToken.ts'

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS })
  const json = (body: unknown, status = 200) => Response.json(body, { status, headers: CORS })
  const url = Deno.env.get('SUPABASE_URL') ?? ''
  const auth = req.headers.get('Authorization') ?? ''
  const asUser = createClient(url, Deno.env.get('SUPABASE_ANON_KEY') ?? '', {
    global: { headers: { Authorization: auth } }, auth: { persistSession: false } })
  const me = await asUser.from('team_members').select('person, display_name').limit(1).maybeSingle()
  if (me.error || !me.data) return json({ error: 'not on the team' }, 403)
  const missing = ['TWILIO_ACCOUNT_SID', 'TWILIO_API_KEY_SID', 'TWILIO_API_KEY_SECRET', 'TWILIO_TWIML_APP_SID']
    .filter((k) => !(Deno.env.get(k) ?? '').trim())
  if (missing.length) return json({ error: `The dialer is not set up yet (missing ${missing.join(', ')}).` }, 503)
  const identity = String(me.data.person ?? 'colin')
  const token = await voiceToken({
    accountSid: Deno.env.get('TWILIO_ACCOUNT_SID')!, apiKeySid: Deno.env.get('TWILIO_API_KEY_SID')!,
    apiKeySecret: Deno.env.get('TWILIO_API_KEY_SECRET')!, appSid: Deno.env.get('TWILIO_TWIML_APP_SID')!, identity,
  })
  return json({ token, identity, ttl: 3600 })
})
