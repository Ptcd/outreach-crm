// send-openers: called every 5 minutes by pg_cron (supabase/setup/send_openers_cron.sql).
// Pulls new inbound texts from Twilio, then claims and sends approved, due openers one at a
// time. Every "may this text go?" decision is made in Postgres (claim_next_opener).
//
// Dry unless the function secret TWILIO_LIVE_SENDING=1 is set AND every Twilio setting is
// present: a dry run checks everything and records "would send", and never calls Twilio's
// send endpoint. Even live, nothing goes unless Colin turned sending on in the app and
// approved the text.
import { createClient } from 'npm:@supabase/supabase-js@2.56.1'
import { runSendOpeners, senderEnv, twilioPort, type Rpc } from '../_shared/sending.ts'

Deno.serve(async (req) => {
  const url = Deno.env.get('SUPABASE_URL') ?? ''
  const sb = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '', { auth: { persistSession: false } })
  const rpc: Rpc = async (fn, args) => {
    const r = await sb.rpc(fn, args)
    return { data: r.data, error: r.error ? { message: r.error.message } : null }
  }

  const secret = req.headers.get('x-wpie-cron-secret')
  const ok = await rpc('cron_secret_ok', { p_secret: secret })
  if (ok.error || ok.data !== true) return new Response('forbidden', { status: 403 })

  const env = senderEnv((n) => Deno.env.get(n), `${url}/functions/v1`)
  const control = await sb.from('campaign_control').select('max_per_run, last_inbound_poll_at').eq('id', 1).single()
  if (control.error) return Response.json({ error: control.error.message }, { status: 500 })

  const summary = await runSendOpeners({
    rpc, env,
    twilio: env.twilio ? twilioPort(env.twilio, fetch) : null,
    maxSends: control.data.max_per_run,
    lastInboundPollAt: control.data.last_inbound_poll_at,
  })
  await rpc('note_run', { p_summary: summary, p_inbound_polled: env.twilio != null && !summary.inbound_error })
  return Response.json(summary)
})
