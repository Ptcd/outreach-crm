// contract: "Send offer" on the lead card. Called with the signed-in user's token. This file only works out who
// is asking (the login -> their team row, the card, the standards, Colin's number); the actions themselves are in
// _shared/contractApi.ts.
import { createClient } from 'npm:@supabase/supabase-js@2.56.1'
import { handleContract } from '../_shared/contractApi.ts'
import type { OfferContext } from '../_shared/contracts.ts'
import { CORS, contractPorts, who } from '../_shared/contractDeno.ts'

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS })
  const json = (body: unknown, status = 200) => Response.json(body, { status, headers: CORS })
  const asUser = createClient(Deno.env.get('SUPABASE_URL') ?? '', Deno.env.get('SUPABASE_ANON_KEY') ?? '', {
    global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } }, auth: { persistSession: false } })
  const u = await asUser.auth.getUser()
  const myEmail = (u.data.user?.email ?? '').toLowerCase()
  if (!myEmail) return json({ ok: false, reason: 'Sign in again.' }, 401)
  const body = await req.json().catch(() => ({}))
  const ports = contractPorts()
  const leadId = typeof body.lead_id === 'string' && /^[0-9a-f-]{36}$/i.test(body.lead_id) ? body.lead_id : null
  const ctx = await ports.rpc('offer_context', { p_lead_id: leadId, p_email: myEmail })
  if (ctx.error) return json({ ok: false, reason: 'Something went wrong. Try again in a minute.' }, 500)
  const r = await handleContract(ports, ctx.data as OfferContext | null, body, { userId: u.data.user?.id ?? null, ...who(req) })
  return json(r.body, r.status)
})
