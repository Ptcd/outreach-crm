// agent-mcp: the agent door. An MCP server (streamable HTTP, stateless JSON) for Muse or any MCP client.
// Each agent has its own key, made by Colin in the app (Settings > Agent keys), sent as "Authorization: Bearer <key>"
// or "x-api-key". The key's role (intake or sender) decides which tools it sees. Tools and checks: _shared/agentDoor.ts.
import { createClient } from 'npm:@supabase/supabase-js@2.56.1'
import { handleMessage, keyFrom, type Agent, type DoorDb } from '../_shared/agentDoor.ts'

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
  const k = check?.data as { ok?: boolean; id?: string; name?: string; role?: string } | null
  if (!k?.ok) return Response.json({ jsonrpc: '2.0', id: null, error: { code: -32001, message: 'missing or turned-off agent key' } }, { status: 401, headers: CORS })
  const agent: Agent = { id: k.id!, name: k.name!, role: k.role === 'sender' ? 'sender' : 'intake' }

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
      p_send_after: t.send_after, p_agent: a }) as Promise<Record<string, unknown>>,
    queue: (d) => rpc('agent_queue_list', { p_date: d }) as Promise<unknown[]>,
    withdraw: (id, a, reason) => rpc('agent_withdraw_text', { p_id: id, p_agent: a, p_reason: reason }) as Promise<boolean>,
    pause: (reason, a) => rpc('agent_pause', { p_reason: reason, p_agent: a }) as Promise<Record<string, unknown>>,
    resume: (a) => rpc('agent_resume', { p_agent: a }) as Promise<Record<string, unknown>>,
    results: (h) => rpc('agent_results', { p_hours: h }) as Promise<Record<string, unknown>>,
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
