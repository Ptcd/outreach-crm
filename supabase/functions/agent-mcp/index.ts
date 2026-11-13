// agent-mcp: the agent door. An MCP server (streamable HTTP, stateless JSON) for Muse or any MCP client.
// Each agent has its own key, made by Colin in the app (Settings > Agent keys), sent as "Authorization: Bearer <key>"
// or "x-api-key". The key's scopes (prospects, texting, calendar, records, marks) decide which tools it sees; every call
// is logged in agent_calls with its scope. Tools and checks: _shared/agentDoor.ts.
import { createClient } from 'npm:@supabase/supabase-js@2.56.1'
import { handleMessage, keyFrom, keyFromUrl, SCOPES, type Agent, type DoorDb, type Scope } from '../_shared/agentDoor.ts'
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
  const key = keyFrom(req.headers) ?? keyFromUrl(req.url)
  const check = key ? await sb.rpc('agent_key_check', { p_key: key }) : null
  const k = check?.data as { ok?: boolean; id?: string; name?: string; role?: string; scopes?: string[]; tools?: string[] | null } | null
  if (!k?.ok) return Response.json({ jsonrpc: '2.0', id: null, error: { code: -32001, message: 'missing or turned-off agent key' } }, { status: 401, headers: CORS })
  const role = k.role === 'sender' || k.role === 'records' || k.role === 'agent' ? k.role : 'intake'
  const agent: Agent = { id: k.id!, name: k.name!, role, scopes: (k.scopes ?? []).filter((x): x is Scope => (SCOPES as string[]).includes(x)),
    tools: Array.isArray(k.tools) && k.tools.length ? k.tools.map(String) : null }

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
      p_send_after: t.send_after, p_agent: a, p_variant: t.variant, p_template: t.template, p_slot: t.slot, p_interest_id: t.interest_id }) as Promise<Record<string, unknown>>,
    records: (fn, args) => rpc(fn, args),
    // records files (0222): the laptop reaches only the database, so a file crosses on a signed link made here
    recordsFileUpload: async (a, who) => {
      const r = await rpc('records_file_new', { p_request_id: a.request_id, p_name: a.filename, p_portal: a.portal, p_number: a.number, p_note: a.note, p_agent: who }) as Record<string, unknown>
      if (!r?.ok) return r
      const up = await sb.storage.from('records').createSignedUploadUrl(String(r.path), { upsert: true })
      if (up.error) return { ok: false, reason: 'could not make an upload link: ' + up.error.message }
      return { ok: true, file_id: r.file_id, office: r.office, upload_url: up.data.signedUrl,
        how: "PUT the raw file bytes to upload_url within 2 hours (curl -X PUT --data-binary @<file> -H 'Content-Type: application/octet-stream' '<upload_url>'), then call records_file_done with file_id." }
    },
    recordsFileDone: async (id, _who) => {
      const row = (await sb.from('records_files').select('id, storage_path, status, direction, name').eq('id', id).maybeSingle()).data as
        { storage_path: string; status: string; direction: string; name: string } | null
      if (!row || row.direction !== 'to_laptop') return { ok: false, reason: 'no such upload: file_id comes from records_file_upload' }
      if (row.status === 'done') return { ok: true, status: 'done', next: 'the laptop already has it' }
      const link = await sb.storage.from('records').createSignedUrl(row.storage_path, 7 * 24 * 3600)
      if (link.error) return { ok: false, reason: 'the file is not there yet: PUT it to upload_url first (' + link.error.message + ')' }
      await rpc('records_file_mark', { p_id: id, p_status: 'ready', p_url: link.data.signedUrl })
      return { ok: true, status: 'ready', name: row.name,
        next: 'the laptop copies it into the records inbox on its next pass (about 10 minutes) as a reply on that request; the muni intake agent reads it on its next run' }
    },
    recordsFileGet: async (replyId, name, who) => {
      const r = await rpc('records_file_want', { p_reply_id: replyId, p_name: name, p_agent: who }) as Record<string, unknown>
      if (!r?.ok) return r
      if (r.status === 'failed') return { ok: false, reason: 'the laptop could not send that file: ' + String(r.error ?? 'unknown') + '. Ask again to retry.' }
      if (r.status === 'ready' || r.status === 'done') {
        const link = await sb.storage.from('records').createSignedUrl(String(r.path), 600)
        if (link.error) return { ok: false, reason: 'the file is not readable: ' + link.error.message }
        if (r.status === 'ready') await rpc('records_file_mark', { p_id: r.file_id, p_status: 'done' })
        return { ok: true, status: 'ready', url: link.data.signedUrl, expires_in_seconds: 600 }
      }
      if (!r.has_url) {
        const up = await sb.storage.from('records').createSignedUploadUrl(String(r.path), { upsert: true })
        if (up.error) return { ok: false, reason: 'could not make a link for the laptop: ' + up.error.message }
        await rpc('records_file_mark', { p_id: r.file_id, p_status: 'waiting', p_url: up.data.signedUrl })
      }
      return { ok: true, status: 'asked', ready_in: 'about 10 minutes: the laptop sends the file up on its next pass. Call records_file_get again with the same reply_id and name.' }
    },
    dueToday: () => rpc('agent_due_today', {}) as Promise<unknown[]>,
    markCard: (m, a) => rpc('agent_mark_card', { p_lead_id: m.lead_id, p_mark: m.mark, p_reason: m.reason, p_date: m.date, p_phone: m.phone, p_agent: a }) as Promise<Record<string, unknown>>,
    markPerson: (m, a) => rpc('agent_mark_person', { p_lead_id: m.lead_id, p_mark: m.mark, p_interest_id: m.interest_id, p_phone: m.phone, p_reason: m.reason, p_agent: a }) as Promise<Record<string, unknown>>,
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
    rateCheck: (tool) => rpc('agent_rate_check', { p_key_id: agent.id, p_tool: tool }) as Promise<string | null>,
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
