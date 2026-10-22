// conveyor: called every 15 minutes by pg_cron (migration 0032). Executes the belts' due text stops,
// sweeps missed stops, runs the daily canary and writes the belt_health heartbeat. Dry (no Twilio call)
// unless TWILIO_LIVE_SENDING=1 and every Twilio setting is set; a belt text also needs its own template
// switch on, or it becomes a draft for Colin's tap.
import { createClient } from 'npm:@supabase/supabase-js@2.56.1'
import { runConveyor } from '../_shared/conveyor.ts'
import { senderEnv, twilioPort, type Rpc } from '../_shared/sending.ts'

Deno.serve(async (req) => {
  const url = Deno.env.get('SUPABASE_URL') ?? ''
  const sb = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '', { auth: { persistSession: false } })
  const rpc: Rpc = async (fn, args) => {
    const r = await sb.rpc(fn, args)
    return { data: r.data, error: r.error ? { message: r.error.message } : null }
  }
  const ok = await rpc('cron_secret_ok', { p_secret: req.headers.get('x-wpie-cron-secret') })
  if (ok.error || ok.data !== true) return new Response('forbidden', { status: 403 })
  const env = senderEnv((n) => Deno.env.get(n), `${url}/functions/v1`)
  try {
    const s = await runConveyor({ rpc, live: env.live, twilio: env.twilio ? twilioPort(env.twilio, fetch) : null,
      companyName: Deno.env.get('REPLY_COMPANY_NAME') ?? undefined })
    return Response.json(s)
  } catch (e) {
    await rpc('belt_health_check', { p_extra: { error: String(e instanceof Error ? e.message : e).slice(0, 300) } }).catch(() => null)
    return Response.json({ error: String(e) }, { status: 500 })
  }
})
