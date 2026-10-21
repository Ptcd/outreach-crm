// Send contract, end to end: Colin's terms -> the official WB-11 signed by him -> a private link per
// seller -> consent + condition report + signature -> one sealed PDF with a signature certificate.
// The database functions (migration 0010) own every state change; this file builds the PDFs and
// moves bytes. Ports keep it testable: rpc, storage, pdf-lib, a notifier, the clock.
import type { Rpc } from './sending.ts'
import {
  fillWb11, mergePdfs, pngFromDataUrl, renderCertificate, renderRecr, sha256Hex,
  type AuditRow, type PdfLib, type SignatureMark, type Wb11Terms,
} from './contractPdf.ts'
import { recrProblems, type RecrAnswers } from './recr.ts'

export const FORM_VERSION = 'WB-11 10-1-2026'
export const LINK_DAYS = 14

export interface Storage {
  put: (path: string, bytes: Uint8Array, contentType: string) => Promise<void>
  get: (path: string) => Promise<Uint8Array>
  signedUrl: (path: string, seconds: number) => Promise<string>
}
export interface ContractPorts {
  rpc: Rpc
  storage: Storage
  lib: PdfLib
  template: Uint8Array
  notify?: (m: { title: string; body: string; url: string; tag: string }) => Promise<void>
  appUrl: string
  now?: () => Date
}
export type Seller = { name: string; email?: string | null; phone?: string | null }
export type Result<T> = ({ ok: true } & T) | { ok: false; reason: string }

const TZ = 'America/Chicago'
export const centralDate = (d: Date) => d.toLocaleDateString('en-US', { timeZone: TZ, month: 'numeric', day: 'numeric', year: 'numeric' })
export const centralStamp = (d: Date) =>
  `${d.toLocaleString('en-US', { timeZone: TZ, month: 'numeric', day: 'numeric', year: 'numeric', hour: 'numeric', minute: '2-digit' })} CT`
export const longDate = (d: Date) => d.toLocaleDateString('en-US', { timeZone: TZ, month: 'long', day: 'numeric', year: 'numeric' })

export async function hashToken(token: string): Promise<string> {
  return sha256Hex(new TextEncoder().encode(token))
}
export function newToken(): string {
  const b = crypto.getRandomValues(new Uint8Array(32))
  return btoa(String.fromCharCode(...b)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

const str = (v: unknown, max = 2000) => String(v ?? '').replace(/\s+$/g, '').slice(0, max)
const num = (v: unknown) => {
  const n = typeof v === 'number' ? v : Number(String(v ?? '').replace(/[$,\s]/g, ''))
  return Number.isFinite(n) ? n : NaN
}
const optInt = (v: unknown) => (v === '' || v == null ? undefined : Math.round(num(v)))

/** Colin's form -> terms the PDF can take, or the problems in plain words. */
export function checkTerms(raw: Record<string, unknown>): { terms: Wb11Terms; problems: string[] } {
  const muni = str(raw.muniType, 10)
  const terms: Wb11Terms = {
    draftDate: str(raw.draftDate, 40),
    buyerName: str(raw.buyerName, 120).trim(),
    street: str(raw.street, 120).trim(),
    street2: str(raw.street2, 160).trim() || undefined,
    muniType: (['City', 'Village', 'Town'].includes(muni) ? muni : 'City') as Wb11Terms['muniType'],
    muniName: str(raw.muniName, 60).trim(),
    county: str(raw.county, 40).trim().replace(/\s+County$/i, ''),
    price: num(raw.price),
    included: str(raw.included, 600).trim() || undefined,
    excluded: str(raw.excluded, 500).trim() || undefined,
    bindingDeadline: str(raw.bindingDeadline, 80).trim(),
    closing: str(raw.closing, 80).trim(),
    earnestMoney: num(raw.earnestMoney),
    earnestDays: optInt(raw.earnestDays),
    earnestHolder: str(raw.earnestHolder, 140).trim(),
    inspection: raw.inspection === true,
    inspectionComponents: str(raw.inspectionComponents, 200).trim() || undefined,
    inspectionDays: optInt(raw.inspectionDays),
    proofOfFundsDays: optInt(raw.proofOfFundsDays),
    leaseTerms: str(raw.leaseTerms, 500).trim() || undefined,
    additional: str(raw.additional, 8000).trim() || undefined,
    sellerAddress: str(raw.sellerAddress, 120).trim() || undefined,
    buyerAddress: str(raw.buyerAddress, 120).trim() || undefined,
    sellerEmail: str(raw.sellerEmail, 120).trim() || undefined,
    buyerEmail: str(raw.buyerEmail, 120).trim() || undefined,
  }
  const p: string[] = []
  if (!terms.draftDate) p.push('Add the date.')
  if (!terms.buyerName) p.push('Add the buyer name.')
  if (!terms.street) p.push('Add the property address.')
  if (!terms.muniName) p.push('Add the city, village or town.')
  if (!terms.county) p.push('Add the county.')
  if (!(terms.price > 0 && terms.price < 100_000_000)) p.push('Add the price.')
  if (!terms.bindingDeadline) p.push('Add the acceptance deadline.')
  if (!terms.closing) p.push('Add the closing date.')
  if (!(terms.earnestMoney >= 0 && terms.earnestMoney < terms.price)) p.push('Earnest money must be a number below the price.')
  if (!terms.earnestHolder) p.push('Say who holds the earnest money (the title company).')
  for (const [k, v] of [['earnest days', terms.earnestDays], ['inspection days', terms.inspectionDays], ['proof of funds days', terms.proofOfFundsDays]] as const) {
    if (v !== undefined && !(v >= 0 && v <= 365)) p.push(`The ${k} must be a number of days.`)
  }
  return { terms, problems: p }
}

export function checkSellers(raw: unknown): { sellers: Seller[]; problems: string[] } {
  const list = (Array.isArray(raw) ? raw : []).map((s) => ({
    name: str((s as Seller)?.name, 120).trim(), email: str((s as Seller)?.email, 120).trim() || null, phone: str((s as Seller)?.phone, 30).trim() || null,
  })).filter((s) => s.name)
  const problems: string[] = []
  if (list.length < 1 || list.length > 2) problems.push('Add one or two sellers (everyone on title who must sign).')
  return { sellers: list, problems }
}

export async function previewOffer(ports: ContractPorts, rawTerms: Record<string, unknown>): Promise<Result<{ pdf: Uint8Array }>> {
  const { terms, problems } = checkTerms(rawTerms)
  if (problems.length) return { ok: false, reason: problems.join(' ') }
  const { bytes } = await fillWb11(ports.lib, ports.template, terms, { watermark: 'PREVIEW - NOT FOR SIGNATURE' })
  return { ok: true, pdf: bytes }
}

/** Colin signs as Buyer and sends. Returns one link per seller (only now: we keep hashes). */
export async function sendOffer(ports: ContractPorts, x: {
  leadId: string; terms: Record<string, unknown>; includeRecr: boolean; sellers: unknown
  buyerSignature?: string | null; actor: string; actorId?: string | null; ip?: string | null; ua?: string | null
}): Promise<Result<{ id: string; links: { position: number; name: string; url: string }[] }>> {
  const now = (ports.now ?? (() => new Date()))()
  const { terms, problems } = checkTerms(x.terms)
  const s = checkSellers(x.sellers)
  const all = [...problems, ...s.problems]
  if (all.length) return { ok: false, reason: all.join(' ') }
  const id = crypto.randomUUID()
  const png = pngFromDataUrl(x.buyerSignature)
  let sigPath: string | null = null
  if (png) {
    sigPath = `${id}/buyer.png`
    await ports.storage.put(sigPath, png, 'image/png')
  }
  const { bytes } = await fillWb11(ports.lib, ports.template, terms, { buyer: { name: terms.buyerName, date: centralDate(now), png } })
  const offerPath = `${id}/offer.pdf`
  const offerSha = await sha256Hex(bytes)
  await ports.storage.put(offerPath, bytes, 'application/pdf')
  const tokens = s.sellers.map(() => newToken())
  const signers = await Promise.all(s.sellers.map(async (sel, i) => ({ position: i + 1, name: sel.name, email: sel.email, phone: sel.phone,
    token_hash: await hashToken(tokens[i]) })))
  const expires = new Date(now.getTime() + LINK_DAYS * 86_400_000)
  const r = await ports.rpc('contract_create', {
    p_lead_id: x.leadId, p_form: FORM_VERSION, p_terms: terms, p_include_recr: x.includeRecr, p_buyer_name: terms.buyerName,
    p_buyer_signature_path: sigPath, p_offer_path: offerPath, p_offer_sha256: offerSha, p_signers: signers,
    p_actor: x.actor, p_actor_id: x.actorId ?? null, p_ip: x.ip ?? null, p_ua: x.ua ?? null, p_expires: expires.toISOString(),
    p_now: now.toISOString(), p_id: id,
  })
  const d = r.data as { ok: boolean; reason?: string } | null
  if (r.error || !d?.ok) return { ok: false, reason: r.error?.message ?? d?.reason ?? 'could not save the contract' }
  return { ok: true, id, links: s.sellers.map((sel, i) => ({ position: i + 1, name: sel.name, url: signUrl(ports.appUrl, tokens[i]) })) }
}

export const signUrl = (appUrl: string, token: string) => `${appUrl.replace(/\/$/, '')}/sign/${token}`

export async function newLink(ports: ContractPorts, signerId: string, actor: string): Promise<Result<{ url: string }>> {
  const now = (ports.now ?? (() => new Date()))()
  const token = newToken()
  const r = await ports.rpc('contract_new_link', { p_signer_id: signerId, p_token_hash: await hashToken(token),
    p_expires: new Date(now.getTime() + LINK_DAYS * 86_400_000).toISOString(), p_actor: actor, p_now: now.toISOString() })
  const d = r.data as { ok: boolean; reason?: string } | null
  if (r.error || !d?.ok) return { ok: false, reason: r.error?.message ?? d?.reason ?? 'could not make a link' }
  return { ok: true, url: signUrl(ports.appUrl, token) }
}

export type OpenView = {
  contract_id: string; signer_id: string; status: string; form: string; terms: Wb11Terms; include_recr: boolean
  recr: RecrAnswers | null; buyer_name: string; signer: { name: string; position: number; signed_at: string | null }
  others: { name: string; signed: boolean }[]; offer_url: string; final_url: string | null
}

export async function openForSigner(ports: ContractPorts, token: string, ip?: string | null, ua?: string | null): Promise<Result<{ view: OpenView }>> {
  const now = (ports.now ?? (() => new Date()))()
  if (!/^[A-Za-z0-9_-]{30,60}$/.test(token)) return { ok: false, reason: 'This link is not valid. Ask Colin for a new one.' }
  const r = await ports.rpc('contract_open', { p_token_hash: await hashToken(token), p_ip: ip ?? null, p_ua: ua ?? null, p_now: now.toISOString() })
  const d = r.data as (Record<string, unknown> & { ok: boolean; reason?: string }) | null
  if (r.error || !d?.ok) return { ok: false, reason: d?.reason ?? 'Something went wrong. Try again in a minute.' }
  const view = {
    ...(d as unknown as OpenView),
    offer_url: await ports.storage.signedUrl(String(d.offer_path), 3600),
    final_url: d.final_path ? await ports.storage.signedUrl(String(d.final_path), 3600) : null,
  }
  delete (view as Record<string, unknown>).offer_path
  delete (view as Record<string, unknown>).final_path
  delete (view as Record<string, unknown>).ok
  return { ok: true, view }
}

/** A seller signs. Seals when they were the last one. */
export async function signAsSeller(ports: ContractPorts, x: {
  token: string; consent: boolean; name: string; signature?: string | null; recr?: RecrAnswers | null; ip?: string | null; ua?: string | null
}): Promise<Result<{ allSigned: boolean; sealed: boolean; finalUrl: string | null }>> {
  const now = (ports.now ?? (() => new Date()))()
  if (x.consent !== true) return { ok: false, reason: 'Tick the box to agree to sign electronically.' }
  if (!str(x.name, 120).trim()) return { ok: false, reason: 'Type your full name.' }
  if (x.recr) {
    const p = recrProblems(x.recr)
    if (p.length) return { ok: false, reason: p.join(' ') }
  }
  const hash = await hashToken(x.token)
  const png = pngFromDataUrl(x.signature)
  let path: string | null = null
  if (png) {
    path = `signatures/${hash}.png`
    await ports.storage.put(path, png, 'image/png')
  }
  const recr = x.recr ? { answers: x.recr.answers, explain: x.recr.explain ?? {}, years: x.recr.years ?? {} } : null
  const r = await ports.rpc('contract_sign', { p_token_hash: hash, p_signed_name: str(x.name, 120).trim(), p_signature_path: path,
    p_recr: recr, p_ip: x.ip ?? null, p_ua: x.ua ?? null, p_now: now.toISOString() })
  const d = r.data as { ok: boolean; reason?: string; contract_id?: string; all_signed?: boolean } | null
  if (r.error || !d?.ok) return { ok: false, reason: d?.reason ?? r.error?.message ?? 'Could not sign. Try again.' }
  if (!d.all_signed) return { ok: true, allSigned: false, sealed: false, finalUrl: null }
  const s = await seal(ports, d.contract_id!)
  return { ok: true, allSigned: true, sealed: s.ok, finalUrl: s.ok ? await ports.storage.signedUrl(s.path, 3600) : null }
}

type Bundle = {
  contract: { id: string; lead_id: string; form: string; status: string; terms: Wb11Terms; include_recr: boolean; recr: RecrAnswers | null
    buyer_name: string; buyer_signature_path: string | null; buyer_signed_at: string; offer_sha256: string; final_path: string | null }
  lead: { owner_name: string; property_address: string | null }
  signers: { id: string; position: number; name: string; signed_at: string | null; signed_name: string | null; signature_path: string | null }[]
  events: { at: string; actor: string; kind: string; ip: string | null; user_agent: string | null; detail: Record<string, unknown> | null }[]
}

const WHAT: Record<string, string> = {
  buyer_signed: 'Signed the Offer as Buyer and sent it for signature',
  created: 'Signing link created',
  link_new: 'A new signing link replaced the old one',
  opened: 'Opened the signing link',
  consented: 'Agreed to use electronic records and signatures',
  recr: 'Completed the Real Estate Condition Report',
  signed: 'Signed the Offer (acceptance) and the Condition Report',
  emailed: 'Copy emailed',
}

/** Build the sealed PDF from what was signed, store it, and close the loop. Safe to retry. */
export async function seal(ports: ContractPorts, contractId: string): Promise<{ ok: true; path: string } | { ok: false; reason: string }> {
  const now = (ports.now ?? (() => new Date()))()
  const r = await ports.rpc('contract_bundle', { p_id: contractId })
  const b = r.data as Bundle | null
  if (r.error || !b?.contract) return { ok: false, reason: r.error?.message ?? 'no such contract' }
  const c = b.contract
  if (c.status === 'signed' && c.final_path) return { ok: true, path: c.final_path }
  if (b.signers.some((s) => !s.signed_at)) return { ok: false, reason: 'not everyone has signed' }
  const img = async (p: string | null) => (p ? await ports.storage.get(p) : null)
  const buyer: SignatureMark = { name: c.buyer_name, date: centralDate(new Date(c.buyer_signed_at)), png: await img(c.buyer_signature_path) }
  const sellers: SignatureMark[] = []
  for (const s of b.signers) sellers.push({ name: s.signed_name || s.name, date: centralDate(new Date(s.signed_at!)), png: await img(s.signature_path) })
  const offer = (await fillWb11(ports.lib, ports.template, c.terms, { buyer, sellers })).bytes
  const parts = [offer]
  let recrSha: string | null = null
  if (c.include_recr && c.recr) {
    const recrAt = b.events.find((e) => e.kind === 'recr')?.at ?? b.signers[0].signed_at!
    const recr = await renderRecr(ports.lib, { street: c.terms.street, muniType: c.terms.muniType, muniName: c.terms.muniName,
      county: c.terms.county, asOf: longDate(new Date(recrAt)), buyerReceived: centralStamp(now) }, c.recr, { sellers })
    recrSha = await sha256Hex(recr)
    parts.push(recr)
  }
  const rows: AuditRow[] = b.events.filter((e) => WHAT[e.kind]).map((e) => ({
    at: centralStamp(new Date(e.at)), who: e.actor, what: WHAT[e.kind] + (e.kind === 'signed' && e.detail?.typed_name ? ` as "${e.detail.typed_name}"` : ''),
    ip: e.ip, device: e.user_agent,
  }))
  rows.push({ at: centralStamp(now), who: 'WPIE', what: 'Sealed this PDF and delivered copies to the buyer and the sellers' })
  const cert = await renderCertificate(ports.lib, { id: c.id, title: `${c.form} for ${c.terms.street}, ${c.terms.muniName}`,
    offerSha256: c.offer_sha256, recrSha256: recrSha, version: c.form, rows })
  parts.push(cert)
  const final = await mergePdfs(ports.lib, parts)
  const sha = await sha256Hex(final)
  const path = `${c.id}/signed-${sha.slice(0, 12)}.pdf`
  await ports.storage.put(path, final, 'application/pdf')
  const done = await ports.rpc('contract_sealed', { p_id: c.id, p_final_path: path, p_final_sha256: sha, p_now: now.toISOString() })
  const dd = done.data as { ok: boolean; reason?: string; already?: boolean } | null
  if (done.error || !dd?.ok) return { ok: false, reason: done.error?.message ?? dd?.reason ?? 'could not finish' }
  if (!dd.already && ports.notify) {
    await ports.notify({ title: `Contract signed: ${c.terms.street}`,
      body: `Every seller signed. Contract + earnest money to ${c.terms.earnestHolder} today.`,
      url: `${ports.appUrl.replace(/\/$/, '')}/lead/${c.lead_id}`, tag: `contract-${c.id}` }).catch(() => undefined)
  }
  return { ok: true, path }
}
