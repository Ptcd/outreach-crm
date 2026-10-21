// contract: Colin's "Send contract" on the lead card. Called with the signed-in user's token; only the
// owner role may act. preview -> a watermarked WB-11; send -> Colin's signature on the Offer and one
// private link per seller; new_link -> replaces a seller's link; void -> withdraws an unsigned offer;
// pdf -> a short-lived link to the Offer as sent or the sealed PDF; seal -> finishes a fully signed
// contract if sealing was interrupted.
import { createClient } from 'npm:@supabase/supabase-js@2.56.1'
import { newLink, previewOffer, seal, sendOffer } from '../_shared/contracts.ts'
import { bytesToB64 } from '../_shared/contractPdf.ts'
import { CORS, contractPorts, serviceClient, who } from '../_shared/contractDeno.ts'

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS })
  const json = (body: unknown, status = 200) => Response.json(body, { status, headers: CORS })
  const url = Deno.env.get('SUPABASE_URL') ?? ''
  const asUser = createClient(url, Deno.env.get('SUPABASE_ANON_KEY') ?? '', {
    global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } }, auth: { persistSession: false } })
  const owner = await asUser.rpc('is_owner')
  if (owner.error || owner.data !== true) return json({ ok: false, reason: 'Only the owner can send contracts.' }, 403)
  const me = await asUser.from('team_members').select('display_name').limit(1).maybeSingle()
  const actor = (me.data?.display_name as string | undefined) ?? 'Colin'
  const u = await asUser.auth.getUser()
  const body = await req.json().catch(() => ({}))
  const ports = contractPorts()
  const { ip, ua } = who(req)

  try {
    switch (body.action) {
      case 'preview': {
        const r = await previewOffer(ports, body.terms ?? {})
        return json(r.ok ? { ok: true, pdf_b64: bytesToB64(r.pdf) } : r)
      }
      case 'send':
        return json(await sendOffer(ports, { leadId: String(body.lead_id ?? ''), terms: body.terms ?? {}, includeRecr: body.include_recr !== false,
          sellers: body.sellers, buyerSignature: body.signature ?? null, actor, actorId: u.data.user?.id ?? null, ip, ua }))
      case 'new_link':
        return json(await newLink(ports, String(body.signer_id ?? ''), actor))
      case 'void': {
        const r = await ports.rpc('contract_void', { p_id: String(body.id ?? ''), p_reason: String(body.reason ?? ''), p_actor: actor })
        return json(r.error ? { ok: false, reason: r.error.message } : r.data)
      }
      case 'seal':
        return json(await seal(ports, String(body.id ?? '')))
      case 'pdf': {
        const c = await serviceClient().from('contracts').select('offer_path, final_path').eq('id', String(body.id ?? '')).maybeSingle()
        const path = body.which === 'final' ? c.data?.final_path : c.data?.offer_path
        if (!path) return json({ ok: false, reason: 'No PDF yet.' })
        return json({ ok: true, url: await ports.storage.signedUrl(path, 600) })
      }
      default:
        return json({ ok: false, reason: 'bad request' }, 400)
    }
  } catch (e) {
    return json({ ok: false, reason: `Something went wrong: ${String(e instanceof Error ? e.message : e).slice(0, 200)}` }, 500)
  }
})
