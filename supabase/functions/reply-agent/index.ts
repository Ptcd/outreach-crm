// reply-agent : called every minute by pg_cron (supabase/setup/reply_agent_cron.sql).
// Pulls new texts to the reply numbers from Twilio, decides each one (removal / routine line /
// a draft for Colin), and sends routine replies and held approvals that are due. Dry unless
// TWILIO_LIVE_SENDING=1 and every Twilio setting is set; routine replies also need Colin's
// "Auto-answer routine replies" switch, which needs a passing red-team score.
import { createClient } from 'npm:@supabase/supabase-js@2.56.1'
import { runReplyAgent } from '../_shared/replyAgent.ts'
import { claudeDrafter } from '../_shared/drafter.ts'
import { runNotifications } from '../_shared/notify.ts'
import { pmPhoneSender, runHotAlerts } from '../_shared/hotLeads.ts'
import { hotPush, notifyDeps } from '../_shared/notifyDeno.ts'
import { senderEnv, twilioPort, type Rpc } from '../_shared/sending.ts'
import type { RedteamRow } from '../_shared/replyBrain.ts'
import redteam from '../_shared/replyRedteam.generated.json' with { type: 'json' }

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
  const control = await sb.from('campaign_control').select('reply_numbers, redteam_version, agent_last_run_at, test_opener').eq('id', 1).single()
  if (control.error) return Response.json({ error: control.error.message }, { status: 500 })
  const key = Deno.env.get('ANTHROPIC_API_KEY') ?? ''
  try {
    const summary = await runReplyAgent({
      rpc, env, control: control.data,
      twilio: env.twilio ? twilioPort(env.twilio, fetch) : null,
      drafter: key ? claudeDrafter({ apiKey: key, model: Deno.env.get('REPLY_MODEL') ?? undefined,
        effort: Deno.env.get('REPLY_EFFORT') ?? 'low', companyName: Deno.env.get('REPLY_COMPANY_NAME') ?? undefined, fetchFn: fetch }) : null,
      redteamRows: redteam.rows as unknown as RedteamRow[],
    })
    let notified: unknown = null
    try {
      notified = await runNotifications(notifyDeps(sb, rpc))
    } catch (e) {
      notified = { error: String(e).slice(0, 200) }
    }
    const hot = await runHotAlerts({ rpc, send: pmPhoneSender((n) => Deno.env.get(n), fetch), push: hotPush(sb),
      appUrl: Deno.env.get('NOTIFY_APP_URL') || 'https://deals.junkcarsmequon.com' }).catch((e) => ({ error: String(e).slice(0, 200) }))
    await rpc('note_agent_run', { p_summary: { ...summary, notified, hot_alerts: hot, drafter: key ? 'claude' : 'none (ANTHROPIC_API_KEY not set)' } })
    return Response.json({ ...summary, notified, hot_alerts: hot })
  } catch (e) {
    await rpc('note_agent_run', { p_summary: { error: String(e instanceof Error ? e.message : e).slice(0, 300) } })
    return Response.json({ error: String(e) }, { status: 500 })
  }
})
