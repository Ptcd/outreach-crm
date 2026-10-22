// reply-inbound: Twilio's "A message comes in" webhook for the WPIE Mail Replies messaging
// service. URL: https://jyfetargyaaxcqmxdgft.supabase.co/functions/v1/reply-inbound (POST).
// Answers Twilio within a database round trip (empty TwiML, so Twilio sends nothing itself and
// nothing is relayed anywhere); the reply agent's decision and any due routine reply run after the answer.
// Requests without a valid X-Twilio-Signature (TWILIO_AUTH_TOKEN of the subaccount) are refused.
import { createClient } from 'npm:@supabase/supabase-js@2.56.1'
import { afterWebhook, recordWebhook } from '../_shared/inbound.ts'
import { claudeDrafter } from '../_shared/drafter.ts'
import { runNotifications } from '../_shared/notify.ts'
import { pmPhoneSender, runHotAlerts } from '../_shared/hotLeads.ts'
import { notifyDeps } from '../_shared/notifyDeno.ts'
import { senderEnv, twilioPort, validTwilioSignature, type Rpc } from '../_shared/sending.ts'
import type { RedteamRow } from '../_shared/replyBrain.ts'
import redteam from '../_shared/replyRedteam.generated.json' with { type: 'json' }

declare const EdgeRuntime: { waitUntil(p: Promise<unknown>): void } | undefined

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('method not allowed', { status: 405 })
  const url = Deno.env.get('SUPABASE_URL') ?? ''
  const params = Object.fromEntries(new URLSearchParams(await req.text())) as Record<string, string>
  const signatureOk = await validTwilioSignature(Deno.env.get('TWILIO_AUTH_TOKEN') ?? '', `${url}/functions/v1/reply-inbound`,
    params, req.headers.get('x-twilio-signature'))
  const sb = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '', { auth: { persistSession: false } })
  const rpc: Rpc = async (fn, args) => {
    const r = await sb.rpc(fn, args)
    return { data: r.data, error: r.error ? { message: r.error.message } : null }
  }
  const res = await recordWebhook({ rpc, params, signatureOk })
  if (res.status === 200 && res.sid) {
    const work = (async () => {
      const env = senderEnv((n) => Deno.env.get(n), `${url}/functions/v1`)
      const control = await sb.from('campaign_control').select('reply_numbers, redteam_version, agent_last_run_at, test_opener').eq('id', 1).single()
      if (control.error) return
      const key = Deno.env.get('ANTHROPIC_API_KEY') ?? ''
      try {
        const runs = await afterWebhook({
          rpc, env, control: control.data,
          twilio: env.twilio ? twilioPort(env.twilio, fetch) : null,
          drafter: key ? claudeDrafter({ apiKey: key, model: Deno.env.get('REPLY_MODEL') ?? undefined,
            effort: Deno.env.get('REPLY_EFFORT') ?? 'low', companyName: Deno.env.get('REPLY_COMPANY_NAME') ?? undefined, fetchFn: fetch }) : null,
          redteamRows: redteam.rows as unknown as RedteamRow[],
        })
        const notified = await runNotifications(notifyDeps(sb, rpc)).catch((e) => ({ error: String(e).slice(0, 200) }))
        // A hot reply texts Colin right away instead of waiting for the next minute's run.
        const hot = await runHotAlerts({ rpc, send: pmPhoneSender((n) => Deno.env.get(n), fetch),
          appUrl: Deno.env.get('NOTIFY_APP_URL') || 'https://deals.junkcarsmequon.com' }).catch((e) => ({ error: String(e).slice(0, 200) }))
        await rpc('note_agent_run', { p_summary: { via: 'webhook', sid: res.sid, runs, notified, hot_alerts: hot } })
      } catch (e) {
        await rpc('note_agent_run', { p_summary: { via: 'webhook', sid: res.sid, error: String(e).slice(0, 300) } })
      }
    })()
    if (typeof EdgeRuntime !== 'undefined') EdgeRuntime.waitUntil(work)
    else await work
  }
  return new Response(res.body, { status: res.status,
    headers: { 'Content-Type': res.status === 200 ? 'text/xml' : 'text/plain' } })
})
