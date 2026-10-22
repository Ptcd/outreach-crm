// reply-send: the Inbox's Approve / Skip. Called by the app with the signed-in user's token;
// only the owner role may act. Approve re-checks the wording (no price, offer or business
// name), then the database refuses anything stale, already sent or to an opted-out phone,
// and holds it until morning in quiet hours. Dry ("would send") unless TWILIO_LIVE_SENDING=1.
import { createClient } from 'npm:@supabase/supabase-js@2.56.1'
import { approveReply } from '../_shared/replyAgent.ts'
import { senderEnv, twilioPort, type Rpc } from '../_shared/sending.ts'
import { testNotification } from '../_shared/notify.ts'
import { notifyDeps } from '../_shared/notifyDeno.ts'
import { bodyHtml, checkEmail } from '../_shared/emailSend.ts'
import { sendMail } from '../_shared/smtp.ts'

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
  // Any team member approves or skips a draft (Colin 2026-10-22: "they approve the texts and drafts").
  const me = await asUser.from('team_members').select('person').limit(1).maybeSingle()
  if (me.error || !me.data) return json({ outcome: 'refused', reason: 'not on the team' }, 403)
  const me = await asUser.from('team_members').select('display_name').limit(1).maybeSingle()
  const actor = (me.data?.display_name as string | undefined) ?? 'Colin'

  const body = await req.json().catch(() => ({}))
  const { id, action, text } = body
  if (action === 'send_email') {
    // Colin's or Adil's tap: an email from the Gmail sender, logged on the lead. Never AI-sent.
    const to = String(body.to ?? '').trim()
    const subject = String(body.subject ?? '').trim()
    const content = String(body.body ?? '')
    const problem = checkEmail({ to, subject, body: content })
    if (problem) return json({ outcome: 'refused', reason: problem })
    const user = Deno.env.get('SMTP_USER') ?? ''
    const pass = Deno.env.get('SMTP_PASSWORD') ?? ''
    if (!user || !pass) return json({ outcome: 'refused', reason: 'Email is not set up yet: Colin runs tools\\set_supabase_email.ps1 once.' })
    try {
      const conn = await Deno.connectTls({ hostname: Deno.env.get('SMTP_HOST') || 'smtp.gmail.com', port: 465 })
      await sendMail(conn, { user, pass }, { from: Deno.env.get('SMTP_FROM') || user, to, subject, text: content, html: bodyHtml(content) })
    } catch (e) {
      return json({ outcome: 'refused', reason: `The email did not go: ${String(e instanceof Error ? e.message : e).slice(0, 160)}` })
    }
    const sbs = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '', { auth: { persistSession: false } })
    await sbs.rpc('log_email', { p_lead_id: body.lead_id ?? null, p_task_id: body.task_id ?? null, p_to: to, p_subject: subject,
      p_body: content, p_actor: body.actor ?? actor })
    return json({ outcome: 'sent' })
  }
  if (action === 'test_notification') {
    const sbs = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '', { auth: { persistSession: false } })
    const rpcs: Rpc = async (fn, args) => {
      const r = await sbs.rpc(fn, args)
      return { data: r.data, error: r.error ? { message: r.error.message } : null }
    }
    const deps = notifyDeps(sbs, rpcs)
    const s = await testNotification(deps)
    return json({ outcome: 'tested', push_configured: deps.push != null, email_configured: deps.email != null && deps.emailTo != null, ...s })
  }
  if (!id || (action !== 'approve' && action !== 'skip')) return json({ outcome: 'refused', reason: 'bad request' }, 400)
  if (action === 'skip') {
    const r = await asUser.rpc('skip_reply', { p_id: id })
    return json(r.error ? { outcome: 'refused', reason: r.error.message } : { outcome: 'skipped' })
  }
  const sb = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '', { auth: { persistSession: false } })
  const rpc: Rpc = async (fn, args) => {
    const r = await sb.rpc(fn, args)
    return { data: r.data, error: r.error ? { message: r.error.message } : null }
  }
  const env = senderEnv((n) => Deno.env.get(n), `${url}/functions/v1`)
  const result = await approveReply({ rpc, env, twilio: env.twilio ? twilioPort(env.twilio, fetch) : null, id,
    text: String(text ?? ''), actor, companyName: Deno.env.get('REPLY_COMPANY_NAME') ?? undefined })
  return json(result)
})
