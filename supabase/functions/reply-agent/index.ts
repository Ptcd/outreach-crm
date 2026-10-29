// reply-agent : called every minute by pg_cron (supabase/setup/reply_agent_cron.sql).
// Pulls new texts to the reply numbers from Twilio, decides each one (removal / routine line /
// a draft for Colin), and sends routine replies and held approvals that are due. Dry unless
// TWILIO_LIVE_SENDING=1 and every Twilio setting is set; routine replies also need Colin's
// "Auto-answer routine replies" switch, which needs a passing red-team score.
import { createClient } from 'npm:@supabase/supabase-js@2.56.1'
import { runReplyAgent } from '../_shared/replyAgent.ts'
import { claudeDrafter } from '../_shared/drafter.ts'
import { pushAll, runNotifications, type NotifySummary } from '../_shared/notify.ts'
import { runPackageMail } from '../_shared/packages.ts'
import { runVoicemailRead } from '../_shared/voicemailRead.ts'
import { pmPhoneSender, pmPhoneWhatsApp, runHotAlerts } from '../_shared/hotLeads.ts'
import { runMissedCallAlerts } from '../_shared/missedCalls.ts'
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
    // Hot alerts also go by email to every member with an alert email on file (Settings page, migration 0028).
    const deps = notifyDeps(sb, rpc)
    const hotEmail = deps.email ? { send: deps.email, recipients: async () => {
      const r = await rpc('alert_email_recipients', {})
      return Array.isArray(r.data) ? (r.data as { person: string; email: string }[]) : []
    } } : null
    const hot = await runHotAlerts({ rpc, send: pmPhoneSender((n) => Deno.env.get(n), fetch), push: hotPush(sb), email: hotEmail,
      appUrl: Deno.env.get('NOTIFY_APP_URL') || 'https://deals.junkcarsmequon.com' }).catch((e) => ({ error: String(e).slice(0, 200) }))
    // packages (migration 0085): the email to Colin with everything, and the "number ready" push for the callback
    const packages = await runPackageMail(deps, rpc, async (m) => {
      const s: NotifySummary = { drafts: 0, reminders: 0, tasks: 0, pushes_ok: 0, pushes_failed: 0, emails: 0, email_errors: [] }
      await pushAll(deps, m, s)
    }).catch((e) => ({ error: String(e).slice(0, 200) }))
    // voicemails (migration 0118): who gets a call back, and who doesn't (upset, not a seller, a stop, the wrong person)
    const voicemails = await runVoicemailRead(rpc, { apiKey: key, fetchFn: fetch, model: Deno.env.get('VOICEMAIL_MODEL') || undefined })
      .catch((e) => ({ error: String(e).slice(0, 200) }))
    // missed calls (migration 0139): the caller the call-back belongs to gets an email, once per call
    const missed = await runMissedCallAlerts({ rpc, email: deps.email, whatsapp: pmPhoneWhatsApp((n) => Deno.env.get(n), fetch), appUrl: Deno.env.get('NOTIFY_APP_URL') || 'https://deals.junkcarsmequon.com' })
      .catch((e) => ({ error: String(e).slice(0, 200) }))
    await rpc('note_agent_run', { p_summary: { ...summary, notified, hot_alerts: hot, packages, voicemails, missed_calls: missed, drafter: key ? 'claude' : 'none (ANTHROPIC_API_KEY not set)' } })
    return Response.json({ ...summary, notified, hot_alerts: hot, packages, voicemails, missed_calls: missed })
  } catch (e) {
    await rpc('note_agent_run', { p_summary: { error: String(e instanceof Error ? e.message : e).slice(0, 300) } })
    return Response.json({ error: String(e) }, { status: 500 })
  }
})
