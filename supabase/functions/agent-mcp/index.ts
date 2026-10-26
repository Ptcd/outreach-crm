// agent-mcp: the agent door. An MCP server (streamable HTTP, stateless JSON) for Muse or any MCP client.
// Each agent has its own key, made by Colin in the app (Settings > Agent keys), sent as "Authorization: Bearer <key>"
// or "x-api-key". The key's scopes (prospects, texting, calendar, records, marks) decide which tools it sees; every call
// is logged in agent_calls with its scope. Tools and checks: _shared/agentDoor.ts.
import { createClient } from 'npm:@supabase/supabase-js@2.56.1'
import { handleMessage, keyFrom, SCOPES, type Agent, type DoorDb, type Scope } from '../_shared/agentDoor.ts'
import { approveReply } from '../_shared/replyAgent.ts'
import { senderEnv, twilioPort, type Rpc } from '../_shared/sending.ts'
import { bookSlot, cancelBooking, connect, findSlots, type Cal } from '../_shared/calendar.ts'

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-api-key, content-type, mcp-protocol-version, mcp-session-id',
  'Access-Control-Allow-Methods': 'POST, GET, OPTIONS',
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS })
  if (req.method !== 'POST') return new Response('POST JSON-RPC to this URL (MCP streamable HTTP, no event stream)', { status: 405, headers: CORS })
  const sb = createClient(Deno.env.get('SUPABASE_URL') ?? '', Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '', { auth: { persistSession: false } })
  const key = keyFrom(req.headers)
  const check = key ? await sb.rpc('agent_key_check', { p_key: key }) : null
  const k = check?.data as { ok?: boolean; id?: string; name?: string; role?: string; scopes?: string[] } | null
  if (!k?.ok) return Response.json({ jsonrpc: '2.0', id: null, error: { code: -32001, message: 'missing or turned-off agent key' } }, { status: 401, headers: CORS })
  const role = k.role === 'sender' || k.role === 'records' || k.role === 'agent' ? k.role : 'intake'
  const agent: Agent = { id: k.id!, name: k.name!, role, scopes: (k.scopes ?? []).filter((x): x is Scope => (SCOPES as string[]).includes(x)) }

  const rpc = async (fn: string, args: Record<string, unknown>) => {
    const r = await sb.rpc(fn, args)
    if (r.error) throw new Error(r.error.message)
    return r.data
  }
  const db: DoorDb = {
    addProspect: (p, a) => rpc('agent_add_prospect', { p, p_agent: a }) as Promise<Record<string, unknown>>,
    findProspects: (f) => rpc('agent_find', { p: f }) as Promise<unknown[]>,
    prospectCounts: () => rpc('agent_counts', {}) as Promise<Record<string, unknown>>,
    status: () => rpc('agent_status', {}) as Promise<Record<string, unknown>>,
    readyToText: (f) => rpc('agent_ready_to_text', { p_limit: f.limit, p_followups: f.followups, p_all: f.all_sources }) as Promise<unknown[]>,
    queueText: (t, a) => rpc('agent_queue_text', { p_lead_id: t.lead_id, p_phone: t.phone, p_body: t.body, p_step: t.step,
      p_send_after: t.send_after, p_agent: a, p_variant: t.variant, p_template: t.template, p_slot: t.slot }) as Promise<Record<string, unknown>>,
    records: (fn, args) => rpc(fn, args),
    dueToday: () => rpc('agent_due_today', {}) as Promise<unknown[]>,
    markCard: (m, a) => rpc('agent_mark_card', { p_lead_id: m.lead_id, p_mark: m.mark, p_reason: m.reason, p_date: m.date, p_phone: m.phone, p_agent: a }) as Promise<Record<string, unknown>>,
    linkCards: (l, a) => rpc('agent_link_cards', { p_lead_id: l.lead_id, p_other_id: l.other_id, p_kind: l.kind, p_note: l.note, p_agent: a }) as Promise<Record<string, unknown>>,
    repliesWaiting: (days) => rpc('agent_replies_waiting', { p_days: days }) as Promise<unknown[]>,
    sendReply: async (t, a) => {
      const id = await rpc('agent_start_reply', { p_lead_id: t.lead_id, p_phone: t.phone, p_agent: a }) as string
      const rpcs: Rpc = async (fn, args) => {
        const r = await sb.rpc(fn, args)
        return { data: r.data, error: r.error ? { message: r.error.message } : null }
      }
      const env = senderEnv((n) => Deno.env.get(n), `${Deno.env.get('SUPABASE_URL') ?? ''}/functions/v1`)
      const res = await approveReply({ rpc: rpcs, env, twilio: env.twilio ? twilioPort(env.twilio, fetch) : null, id, text: t.body,
        actor: `Muse (${a})`, companyName: Deno.env.get('REPLY_COMPANY_NAME') ?? undefined })
      if (res.outcome === 'refused') {
        await sb.from('reply_drafts').update({ status: 'superseded', note: 'agent reply not sent: ' + (res.reason ?? '') })
          .eq('id', id).eq('status', 'awaiting_approval')
      }
      return { reply_id: id, ...res }
    },
    testResults: (days, step) => rpc('agent_test_results', { p_days: days, p_step: step }) as Promise<Record<string, unknown>>,
    textTemplates: () => rpc('agent_text_templates', {}) as Promise<Record<string, unknown>>,
    setTextTemplate: (t, a) => rpc('agent_set_text_template', { p_variant: t.variant, p_name: t.name, p_wording: t.wording, p_note: t.note, p_agent: a }) as Promise<Record<string, unknown>>,
    logCall: async (c) => { await sb.rpc('agent_log_call', { p_key_id: agent.id, p_tool: c.tool, p_scope: c.scope, p_ok: c.ok, p_error: c.error, p_ms: c.ms }) },
    queue: (d) => rpc('agent_queue_list', { p_date: d }) as Promise<unknown[]>,
    withdraw: (id, a, reason) => rpc('agent_withdraw_text', { p_id: id, p_agent: a, p_reason: reason }) as Promise<boolean>,
    pause: (reason, a) => rpc('agent_pause', { p_reason: reason, p_agent: a }) as Promise<Record<string, unknown>>,
    resume: (a) => rpc('agent_resume', { p_agent: a }) as Promise<Record<string, unknown>>,
    results: (h) => rpc('agent_results', { p_hours: h }) as Promise<Record<string, unknown>>,
    // Colin's Google Calendar: connected only when a calendar tool is called (a token refresh per request)
    calendar: (() => {
      let cal: Promise<Cal> | null = null
      const live = () => (cal ??= connect(rpc, Deno.env.get('CALENDAR_TOKEN_KEY') ?? ''))
      const appUrl = Deno.env.get('NOTIFY_APP_URL') || 'https://deals.junkcarsmequon.com'
      return {
        slots: async (a) => findSlots(rpc, await live(), a),
        book: async (a, who) => bookSlot(rpc, await live(), a, `Muse (${who})`, appUrl),
        cancel: async (a, who) => cancelBooking(rpc, await live(), a, `Muse (${who})`),
      }
    })(),
  }

  let body: unknown
  try { body = await req.json() } catch {
    return Response.json({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'not JSON' } }, { status: 400, headers: CORS })
  }
  const msgs = Array.isArray(body) ? body : [body]
  const out = []
  for (const m of msgs) {
    if (!m || typeof m !== 'object') { out.push({ jsonrpc: '2.0', id: null, error: { code: -32600, message: 'bad request' } }); continue }
    const r = await handleMessage(m as Record<string, unknown>, agent, db)
    if (r) out.push(r)
  }
  if (!out.length) return new Response(null, { status: 202, headers: CORS })
  return Response.json(Array.isArray(body) ? out : out[0], { headers: { ...CORS, 'content-type': 'application/json' } })
})
