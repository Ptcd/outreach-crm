// The contract function's actions, apart from who is asking (the Edge Function works that out from the login and
// hands it here; the local end-to-end rig, scripts/e2e-offer.ts, does the same with a pretend login).
//   quick_preview / quick_send   Send offer: the card + the standing terms (0217) + who, how much, when.
//                                Colin sends at any price; a caller only at Colin's number on the card; Muse never.
//                                The offer goes out signed with Colin's kept signature and is emailed to each seller.
//   preview / send               Colin's long form, every term typed by him (0010). Colin only.
//   new_link                     replaces a seller's link (email: true also emails it)
//   void                         withdraws an unsigned offer
//   pdf                          a short-lived link to the Offer as sent or the sealed PDF
//   seal                         finishes a fully signed contract if sealing was interrupted
import {
  newLink, openForSigner, previewOffer, quickPreview, quickSend, seal, sendOffer, signAsSeller,
  type ContractPorts, type OfferContext, type QuickAsk,
} from './contracts.ts'
import { bytesToB64 } from './contractPdf.ts'

export type ApiReply = { status: number; body: Record<string, unknown> }
type Body = Record<string, unknown>
const CALLERS: Record<string, string> = { thalia: 'Thalia', adil: 'Tyler' }

export async function handleContract(ports: ContractPorts, ctx: OfferContext | null, body: Body,
  req: { userId?: string | null; ip?: string | null; ua?: string | null }): Promise<ApiReply> {
  const me = ctx?.me
  if (!ctx || !me) return { status: 403, body: { ok: false, reason: 'You are not on the team.' } }
  if (me.person === 'muse') return { status: 403, body: { ok: false, reason: 'An agent does not send or change contracts.' } }
  // the shared login is Colin's account: a phone set to a caller sends as that caller, under the caller's rule
  const as = typeof body.as_person === 'string' && me.role === 'owner' && body.as_person in CALLERS ? body.as_person : null
  if (as) ctx.me = { person: as, role: 'caller', display_name: CALLERS[as] }
  const boss = me.role === 'owner' && !as
  const actor = (as ? CALLERS[as] : me.display_name) || 'Colin'
  const by = { actor, actorId: req.userId ?? null, ip: req.ip ?? null, ua: req.ua ?? null }
  const ask: QuickAsk = { price: body.price, closingOn: body.closing_on, sellers: body.sellers, includeRecr: body.include_recr !== false,
    property: (body.property ?? undefined) as QuickAsk['property'] }
  const ok = (b: Record<string, unknown>): ApiReply => ({ status: 200, body: b })

  try {
    switch (body.action) {
      case 'quick_preview': {
        const r = await quickPreview(ports, ctx, ask)
        return ok(r.ok ? { ok: true, pdf_b64: bytesToB64(r.pdf) } : r)
      }
      case 'quick_send':
        return ok(await quickSend(ports, ctx, ask, by))
      case 'preview': {
        if (!boss) return { status: 403, body: { ok: false, reason: 'Only Colin writes a custom offer.' } }
        const r = await previewOffer(ports, (body.terms ?? {}) as Body)
        return ok(r.ok ? { ok: true, pdf_b64: bytesToB64(r.pdf) } : r)
      }
      case 'send':
        if (!boss) return { status: 403, body: { ok: false, reason: 'Only Colin writes a custom offer.' } }
        return ok(await sendOffer(ports, { leadId: String(body.lead_id ?? ''), terms: (body.terms ?? {}) as Body, includeRecr: body.include_recr !== false,
          sellers: body.sellers, buyerSignature: (body.signature as string | null) ?? null, emailLinks: body.email_links === true, ...by }))
      case 'new_link':
        return ok(await newLink(ports, String(body.signer_id ?? ''), actor, body.email === true))
      case 'void': {
        const r = await ports.rpc('contract_void', { p_id: String(body.id ?? ''), p_reason: String(body.reason ?? ''), p_actor: actor })
        return ok(r.error ? { ok: false, reason: r.error.message } : (r.data as Record<string, unknown>))
      }
      case 'seal':
        return ok(await seal(ports, String(body.id ?? '')))
      case 'pdf': {
        const b = (await ports.rpc('contract_bundle', { p_id: String(body.id ?? '') })).data as { contract?: { offer_path?: string; final_path?: string | null } } | null
        const path = body.which === 'final' ? b?.contract?.final_path : b?.contract?.offer_path
        if (!path) return ok({ ok: false, reason: 'No PDF yet.' })
        return ok({ ok: true, url: await ports.storage.signedUrl(path, 600) })
      }
      default:
        return { status: 400, body: { ok: false, reason: 'bad request' } }
    }
  } catch (e) {
    return { status: 500, body: { ok: false, reason: `Something went wrong: ${String(e instanceof Error ? e.message : e).slice(0, 200)}` } }
  }
}

/** The seller's signing page: open -> what the page shows; sign -> consent, the report, the signature. */
export async function handleContractSign(ports: ContractPorts, body: Body, req: { ip?: string | null; ua?: string | null }): Promise<ApiReply> {
  const token = String(body.token ?? '')
  try {
    if (body.action === 'open') return { status: 200, body: await openForSigner(ports, token, req.ip, req.ua) }
    if (body.action === 'sign') {
      return { status: 200, body: await signAsSeller(ports, { token, consent: body.consent === true, name: String(body.name ?? ''),
        signature: (body.signature as string | null) ?? null, recr: (body.recr as never) ?? null, ip: req.ip, ua: req.ua }) }
    }
    return { status: 400, body: { ok: false, reason: 'bad request' } }
  } catch (e) {
    return { status: 500, body: { ok: false, reason: `Something went wrong: ${String(e instanceof Error ? e.message : e).slice(0, 200)}` } }
  }
}
