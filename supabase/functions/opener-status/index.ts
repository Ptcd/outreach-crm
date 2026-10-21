// opener-status: Twilio's status callback for texts send-openers sent. Records delivered /
// undelivered and lets the database pause sending on an account error or carrier
// filtering (record_delivery, migration 0003). Requests are accepted only with a valid
// X-Twilio-Signature, which needs the TWILIO_AUTH_TOKEN function secret; without it,
// send-openers does not ask Twilio for callbacks at all (WPIE's watchdog --poll still
// reads delivery from Twilio on the laptop).
import { createClient } from 'npm:@supabase/supabase-js@2.56.1'
import { validTwilioSignature } from '../_shared/sending.ts'

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('method not allowed', { status: 405 })
  const url = Deno.env.get('SUPABASE_URL') ?? ''
  const params = Object.fromEntries(new URLSearchParams(await req.text())) as Record<string, string>
  const callbackUrl = `${url}/functions/v1/opener-status`
  const token = Deno.env.get('TWILIO_AUTH_TOKEN') ?? ''
  if (!(await validTwilioSignature(token, callbackUrl, params, req.headers.get('x-twilio-signature')))) {
    return new Response('forbidden', { status: 403 })
  }
  const sb = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '', { auth: { persistSession: false } })
  const r = await sb.rpc('record_delivery', {
    p_sid: params.MessageSid ?? params.SmsSid ?? '', p_status: params.MessageStatus ?? params.SmsStatus ?? '',
    p_error_code: params.ErrorCode ?? null,
  })
  if (r.error) return new Response(r.error.message, { status: 500 })
  return new Response('ok')
})
