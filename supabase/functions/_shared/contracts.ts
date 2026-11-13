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
  /** downloadAs: the link saves the file under that name instead of opening it */
  signedUrl: (path: string, seconds: number, downloadAs?: string) => Promise<string>
}
/** Which mailbox an email actually left from, and why not the company one when it fell back. */
export type MailSent = { from: string; fallback?: string }
export type OutMail = { to: string; subject: string; text: string; html: string; fromName?: string; replyTo?: string
  attachments?: { filename: string; contentType: string; bytes: Uint8Array }[] }
export interface ContractPorts {
  rpc: Rpc
  storage: Storage
  lib: PdfLib
  template: Uint8Array
  notify?: (m: { title: string; body: string; url: string; tag: string }) => Promise<void>
  /** the system's own email (the signing link, the signed copy); absent = nothing is emailed */
  mail?: (m: OutMail) => Promise<void | MailSent>
  /** where a seller's signing link lives (offers.welivewi.com) */
  appUrl: string
  /** where the team's own links go (the app's address they are signed in on); appUrl when not given */
  teamUrl?: string
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
    draftedBy: str(raw.draftedBy, 120).trim() || undefined,
    buyerSigner: str(raw.buyerSigner, 80).trim() || undefined,
    buyerSignerTitle: str(raw.buyerSignerTitle, 60).trim() || undefined,
    buyerPhone: str(raw.buyerPhone, 30).trim() || undefined,
    recrWithOffer: raw.recrWithOffer === true || undefined,
    closingOn: /^\d{4}-\d{2}-\d{2}$/.test(str(raw.closingOn, 10)) ? str(raw.closingOn, 10) : undefined,
    acceptBy: /^\d{4}-\d{2}-\d{2}$/.test(str(raw.acceptBy, 10)) ? str(raw.acceptBy, 10) : undefined,
    quick: raw.quick === true || undefined,
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

// ------------------------------------------------------------------ Send offer (0217): the card + the standards

/** The standing terms (public.offer_standards). */
export type Standards = {
  buyer_name: string; signer_name: string; signer_title: string; buyer_email: string | null; buyer_address: string | null
  buyer_phone: string; earnest_money: number; earnest_days: number; earnest_holder: string; accept_days: number
  proof_of_funds_days: number; included: string | null; excluded: string | null; additional: string; signature_png: string | null
}
export type LeadFacts = {
  id: string; owner_name: string; property_address: string | null; municipality: string | null; county: string | null
  mailing_street: string | null; mailing_city: string | null; mailing_state: string | null; mailing_zip: string | null; stage?: string | null
}
export type OfferContext = {
  standards: Standards | null; lead: LeadFacts | null; colin_number: number | null
  me: { person: string; role: string; display_name: string } | null; open_contract: string | null
}
export type QuickAsk = {
  price?: unknown; closingOn?: unknown; sellers?: unknown; includeRecr?: boolean
  property?: { street?: string; muniType?: string; muniName?: string; county?: string }
}

export const CLOSE_MIN_DAYS = 14
export const CLOSE_MAX_DAYS = 90
const isoDay = (d: Date) => d.toLocaleDateString('en-CA', { timeZone: TZ })
const addDays = (iso: string, n: number) => {
  const [y, m, d] = iso.split('-').map(Number)
  return new Date(Date.UTC(y, m - 1, d + n)).toISOString().slice(0, 10)
}
const daysBetween = (a: string, b: string) => Math.round((Date.parse(`${b}T00:00:00Z`) - Date.parse(`${a}T00:00:00Z`)) / 86_400_000)
const longDay = (iso: string) => new Date(`${iso}T12:00:00Z`).toLocaleDateString('en-US', { timeZone: 'UTC', month: 'long', day: 'numeric', year: 'numeric' })
/** 11:59:59 p.m. Central on that day, whichever of CST/CDT applies. */
export function centralEndOfDay(iso: string): Date {
  for (const off of ['-05:00', '-06:00']) {
    const d = new Date(`${iso}T23:59:59${off}`)
    if (isoDay(d) === iso && d.toLocaleTimeString('en-GB', { timeZone: TZ }) === '23:59:59') return d
  }
  return new Date(`${iso}T23:59:59-06:00`)
}

const titleCase = (s: string) => s.toLowerCase().replace(/\b([a-z])/g, (m) => m.toUpperCase())
/** "VILLAGE OF PADDOCK LAKE", "Pewaukee (Village)", "Town of Delafield", "West Allis" -> the two blanks on line 6. */
export function muniOf(raw: string | null | undefined): { type: 'City' | 'Village' | 'Town'; name: string } {
  const v = (raw ?? '').trim()
  const pre = v.match(/^(city|village|town)\s+of\s+(.+)$/i)
  const post = v.match(/^(.+?)\s*\((city|village|town)\)$/i)
  const kind = (pre?.[1] ?? post?.[2] ?? 'City').toLowerCase()
  const name = (pre?.[2] ?? post?.[1] ?? v).trim()
  return { type: (kind === 'village' ? 'Village' : kind === 'town' ? 'Town' : 'City'), name: name === name.toUpperCase() ? titleCase(name) : name }
}

/** The card, the standards and the three answers (who, how much, when) -> the same terms the long form makes. */
export function quickTerms(ctx: { standards: Standards; lead: LeadFacts }, ask: QuickAsk, now: Date):
  { raw: Record<string, unknown>; includeRecr: boolean; expires: Date; problems: string[] } {
  const st = ctx.standards
  const l = ctx.lead
  const today = isoDay(now)
  const problems: string[] = []
  const closingOn = String(ask.closingOn ?? '')
  if (!/^\d{4}-\d{2}-\d{2}$/.test(closingOn)) problems.push('Pick the closing date.')
  else {
    const n = daysBetween(today, closingOn)
    if (n < CLOSE_MIN_DAYS || n > CLOSE_MAX_DAYS) problems.push(`The closing date must be ${CLOSE_MIN_DAYS} to ${CLOSE_MAX_DAYS} days from today.`)
  }
  const acceptBy = addDays(today, st.accept_days)
  const m = muniOf(l.municipality)
  const pr = ask.property ?? {}
  const sellers = checkSellers(ask.sellers).sellers
  const includeRecr = ask.includeRecr !== false
  const raw = {
    quick: true, draftDate: longDate(now), buyerName: st.buyer_name, buyerSigner: st.signer_name, buyerSignerTitle: st.signer_title,
    buyerPhone: st.buyer_phone, street: (pr.street ?? l.property_address ?? '').trim(), muniType: pr.muniType ?? m.type,
    muniName: (pr.muniName ?? m.name).trim(), county: (pr.county ?? l.county ?? '').trim(),
    price: ask.price, included: st.included ?? '', excluded: st.excluded ?? '',
    bindingDeadline: `${longDay(acceptBy)} at 11:59 p.m.`, acceptBy, closing: /^\d{4}-/.test(closingOn) ? longDay(closingOn) : '', closingOn,
    earnestMoney: st.earnest_money, earnestDays: st.earnest_days, earnestHolder: st.earnest_holder,
    inspection: false, proofOfFundsDays: st.proof_of_funds_days, additional: st.additional, recrWithOffer: includeRecr,
    sellerAddress: [l.mailing_street, l.mailing_city, [l.mailing_state, l.mailing_zip].filter(Boolean).join(' ')].filter(Boolean).join(', '),
    sellerEmail: sellers[0]?.email ?? '', buyerAddress: st.buyer_address ?? '', buyerEmail: st.buyer_email ?? '',
  }
  return { raw, includeRecr, expires: centralEndOfDay(acceptBy), problems }
}

const ADDR = /^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$/i
export const isEmail = (s: string | null | undefined) => ADDR.test((s ?? '').trim())

/** Who may send what. Colin: any price. A caller: only Colin's number on the card. Muse: never. */
export function quickGate(ctx: OfferContext, ask: QuickAsk, forSend: boolean): { price: number; problems: string[] } {
  const p: string[] = []
  if (!ctx.me) return { price: NaN, problems: ['You are not on the team.'] }
  if (ctx.me.person === 'muse') return { price: NaN, problems: ['An agent does not send contracts. Colin or a caller sends this one.'] }
  if (!ctx.lead) return { price: NaN, problems: ['No such card.'] }
  if (!ctx.standards) return { price: NaN, problems: ['The offer standards are missing. Tell Colin.'] }
  if (ctx.lead.stage === 'dnc') p.push('This card is Do Not Contact. No offer goes out.')
  const typed = ask.price == null || ask.price === '' ? NaN : num(ask.price)   // a caller's panel sends no price of its own
  let price = typed
  if (ctx.me.role !== 'owner') {
    if (ctx.colin_number == null) p.push('Colin has not put his number on this card yet. Ask him for it, then send.')
    else if (Number.isFinite(typed) && Math.abs(typed - Number(ctx.colin_number)) > 0.005) p.push(`The offer goes out at Colin's number: $${Number(ctx.colin_number).toLocaleString('en-US')}.`)
    price = Number(ctx.colin_number ?? NaN)
  }
  if (forSend) {
    if (ctx.open_contract) p.push('An offer is already out for signature on this card. Withdraw it before sending a new one.')
    const sellers = checkSellers(ask.sellers).sellers
    if (!sellers.length) p.push("Add the seller's name.")
    else if (!isEmail(sellers[0].email)) p.push("Add the seller's email: the offer is emailed to them.")
    for (const s of sellers.slice(1)) if (s.email && !isEmail(s.email)) p.push(`${s.name}'s email does not look right.`)
  }
  return { price, problems: p }
}

export async function quickPreview(ports: ContractPorts, ctx: OfferContext, ask: QuickAsk): Promise<Result<{ pdf: Uint8Array }>> {
  const now = (ports.now ?? (() => new Date()))()
  const g = quickGate(ctx, ask, false)
  if (g.problems.length) return { ok: false, reason: g.problems.join(' ') }
  const q = quickTerms({ standards: ctx.standards!, lead: ctx.lead! }, { ...ask, price: g.price }, now)
  if (q.problems.length) return { ok: false, reason: q.problems.join(' ') }
  return previewOffer(ports, q.raw)
}

/** Send offer: built from the card and the standards, signed with Colin's kept signature, emailed to each seller. */
export async function quickSend(ports: ContractPorts, ctx: OfferContext, ask: QuickAsk,
  by: { actor: string; actorId?: string | null; ip?: string | null; ua?: string | null }) {
  const now = (ports.now ?? (() => new Date()))()
  const g = quickGate(ctx, ask, true)
  if (g.problems.length) return { ok: false as const, reason: g.problems.join(' ') }
  const q = quickTerms({ standards: ctx.standards!, lead: ctx.lead! }, { ...ask, price: g.price }, now)
  if (q.problems.length) return { ok: false as const, reason: q.problems.join(' ') }
  if (!ports.mail) return { ok: false as const, reason: 'Email is not set up, so the offer cannot be emailed.' }
  return sendOffer(ports, { leadId: ctx.lead!.id, terms: q.raw, includeRecr: q.includeRecr, sellers: ask.sellers,
    buyerSignature: ctx.standards!.signature_png, expires: q.expires, emailLinks: true, ...by })
}

const esc = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')
const usd0 = (n: number) => n.toLocaleString('en-US', { style: 'currency', currency: 'USD', maximumFractionDigits: n % 1 ? 2 : 0 })
const first = (name: string) => titleCase(name.trim().split(/\s+/)[0] ?? '')
const sender = (t: Wb11Terms) => t.buyerSigner || t.buyerName
const senderLine = (t: Wb11Terms) => (t.buyerSigner ? `${t.buyerSigner}, ${t.buyerName}` : t.buyerName)
const phoneLine = (t: Wb11Terms) => (t.buyerPhone ? ` Questions? Call or text ${first(sender(t))} at ${t.buyerPhone}.` : '')

function shell(title: string, lines: string[], button: { label: string; url: string } | null, foot: string): string {
  return `<div style="font-family:Arial,Helvetica,sans-serif;font-size:16px;line-height:1.5;color:#111;max-width:560px;margin:0 auto;padding:8px">
<h2 style="font-size:20px;margin:0 0 12px">${esc(title)}</h2>
${lines.map((l) => `<p style="margin:0 0 12px">${esc(l)}</p>`).join('\n')}
${button ? `<p style="margin:20px 0"><a href="${esc(button.url)}" style="display:inline-block;background:#0f5132;color:#fff;text-decoration:none;font-weight:bold;padding:14px 26px;border-radius:8px;font-size:17px">${esc(button.label)}</a></p>
<p style="margin:0 0 12px;font-size:13px;color:#555">If the button does not work, copy this into your browser:<br><span style="word-break:break-all">${esc(button.url)}</span></p>` : ''}
<p style="margin:16px 0 0;font-size:14px;color:#555">${esc(foot)}</p>
</div>`
}

/** The email that carries a seller's private signing link. */
export function linkMail(t: Wb11Terms, seller: { name: string; email: string }, url: string): OutMail {
  const where = [t.street, t.muniName].filter(Boolean).join(', ')
  const lines = [
    `Hi ${first(seller.name)},`,
    `Here is the written offer for ${where}: ${usd0(t.price)}, closing on ${t.closing}.`,
    'You can read it, download it and sign it on your phone or computer. No account and no app: the button below is your own private link.',
    `It is good until ${t.bindingDeadline.replace(/\.$/, '')}.`,
  ]
  const foot = `${senderLine(t)}.${phoneLine(t)}`
  return {
    to: seller.email.trim(), subject: `Offer to purchase ${t.street}: review and sign`, fromName: senderLine(t), replyTo: t.buyerEmail,
    text: [...lines.slice(0, 3), `Open the offer: ${url}`, lines[3], '', foot].join('\n\n'),
    html: shell(`Offer to purchase ${where}`, lines, { label: 'Review and sign the offer', url }, foot),
  }
}

/** The email that carries the signed PDF to a party once everyone has signed. */
export function signedMail(t: Wb11Terms, to: { name: string; email: string }, pdf: Uint8Array, withRecr: boolean): OutMail {
  const where = [t.street, t.muniName].filter(Boolean).join(', ')
  const lines = [
    `Hi ${first(to.name)},`,
    `Everyone has signed the offer for ${where}. Your copy is attached: the signed offer${withRecr ? ', the condition report' : ''} and the signature certificate, in one PDF.`,
    `Next: the title company (${t.earnestHolder}) opens the file and will be in touch about the closing on ${t.closing}.`,
  ]
  const foot = `${senderLine(t)}.${phoneLine(t)}`
  return {
    to: to.email.trim(), subject: `Signed offer: ${t.street}`, fromName: senderLine(t), replyTo: t.buyerEmail,
    text: [...lines, '', foot].join('\n\n'), html: shell(`Signed: ${where}`, lines, null, foot),
    attachments: [{ filename: `Signed offer - ${t.street.replace(/[^A-Za-z0-9 .#-]/g, '')}.pdf`, contentType: 'application/pdf', bytes: pdf }],
  }
}

/** Send one email and write down that it went (or why it did not). Never throws. */
async function mailAndLog(ports: ContractPorts, m: OutMail, log: { id: string; signerId: string | null; what: 'link' | 'signed'; actor: string; now: Date }):
  Promise<{ to: string; ok: boolean; reason?: string }> {
  let reason: string | undefined
  let sent: MailSent | void = undefined
  try {
    if (!ports.mail) throw new Error('email is not set up')
    sent = await ports.mail(m)
  } catch (e) {
    reason = String(e instanceof Error ? e.message : e).slice(0, 200)
  }
  await ports.rpc('contract_mailed', { p_id: log.id, p_signer_id: log.signerId, p_what: log.what, p_to: m.to, p_actor: log.actor,
    p_ok: !reason, p_error: reason ?? null, p_now: log.now.toISOString() })
  // which mailbox it left from goes in the audit trail, so a fall-back to the old sender is never silent
  if (sent) {
    await ports.rpc('contract_log', { p_id: log.id, p_actor: 'WPIE', p_kind: 'email_sender',
      p_detail: { to: m.to, from: sent.from, ...(sent.fallback ? { fallback: sent.fallback.slice(0, 200) } : {}) }, p_now: log.now.toISOString() })
  }
  return { to: m.to, ok: !reason, reason }
}

/** The buyer's mark: a company signs by its person ("WeLiveWI LLC, by Colin Merrill, Authorized Representative"). */
export function buyerMark(t: Wb11Terms, date: string, png: Uint8Array | null): SignatureMark {
  if (!t.buyerSigner) return { name: t.buyerName, date, png }
  return { name: t.buyerSigner, date, png, printName: [`${t.buyerName}, by ${t.buyerSigner}`, t.buyerSignerTitle].filter(Boolean).join(', ') }
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
  expires?: Date; emailLinks?: boolean
}): Promise<Result<{ id: string; links: { position: number; name: string; url: string; emailed_to?: string; email_error?: string }[] }>> {
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
  const { bytes } = await fillWb11(ports.lib, ports.template, terms, { buyer: buyerMark(terms, centralDate(now), png) })
  const offerPath = `${id}/offer.pdf`
  const offerSha = await sha256Hex(bytes)
  await ports.storage.put(offerPath, bytes, 'application/pdf')
  const tokens = s.sellers.map(() => newToken())
  const signers = await Promise.all(s.sellers.map(async (sel, i) => ({ position: i + 1, name: sel.name, email: sel.email, phone: sel.phone,
    token_hash: await hashToken(tokens[i]) })))
  const expires = x.expires && x.expires > now ? x.expires : new Date(now.getTime() + LINK_DAYS * 86_400_000)
  const r = await ports.rpc('contract_create', {
    p_lead_id: x.leadId, p_form: FORM_VERSION, p_terms: terms, p_include_recr: x.includeRecr, p_buyer_name: terms.buyerName,
    p_buyer_signature_path: sigPath, p_offer_path: offerPath, p_offer_sha256: offerSha, p_signers: signers,
    p_actor: x.actor, p_actor_id: x.actorId ?? null, p_ip: x.ip ?? null, p_ua: x.ua ?? null, p_expires: expires.toISOString(),
    p_now: now.toISOString(), p_id: id,
  })
  const d = r.data as { ok: boolean; reason?: string; signers?: { id: string; position: number }[] } | null
  if (r.error || !d?.ok) return { ok: false, reason: r.error?.message ?? d?.reason ?? 'could not save the contract' }
  const links: { position: number; name: string; url: string; emailed_to?: string; email_error?: string }[] = []
  for (const [i, sel] of s.sellers.entries()) {
    const link: (typeof links)[number] = { position: i + 1, name: sel.name, url: signUrl(ports.appUrl, tokens[i]) }
    if (x.emailLinks && isEmail(sel.email)) {
      const m = await mailAndLog(ports, linkMail(terms, { name: sel.name, email: sel.email! }, link.url),
        { id, signerId: d.signers?.find((g) => g.position === i + 1)?.id ?? null, what: 'link', actor: x.actor, now })
      if (m.ok) link.emailed_to = m.to; else link.email_error = m.reason
    }
    links.push(link)
  }
  return { ok: true, id, links }
}

export const signUrl = (appUrl: string, token: string) => `${appUrl.replace(/\/$/, '')}/sign/${token}`

export async function newLink(ports: ContractPorts, signerId: string, actor: string, email = false):
  Promise<Result<{ url: string; emailed_to?: string; email_error?: string }>> {
  const now = (ports.now ?? (() => new Date()))()
  const token = newToken()
  const r = await ports.rpc('contract_new_link', { p_signer_id: signerId, p_token_hash: await hashToken(token),
    p_expires: new Date(now.getTime() + LINK_DAYS * 86_400_000).toISOString(), p_actor: actor, p_now: now.toISOString() })
  const d = r.data as { ok: boolean; reason?: string; contract_id?: string } | null
  if (r.error || !d?.ok) return { ok: false, reason: r.error?.message ?? d?.reason ?? 'could not make a link' }
  const url = signUrl(ports.appUrl, token)
  if (!email || !d.contract_id) return { ok: true, url }
  const b = (await ports.rpc('contract_bundle', { p_id: d.contract_id })).data as Bundle | null
  const sg = b?.signers.find((x) => x.id === signerId)
  if (!b || !sg || !isEmail(sg.email)) return { ok: true, url, email_error: 'no email address for this seller' }
  const m = await mailAndLog(ports, linkMail(b.contract.terms, { name: sg.name, email: sg.email! }, url),
    { id: b.contract.id, signerId, what: 'link', actor, now })
  return m.ok ? { ok: true, url, emailed_to: m.to } : { ok: true, url, email_error: m.reason }
}

export type OpenView = {
  contract_id: string; signer_id: string; status: string; form: string; terms: Wb11Terms; include_recr: boolean
  recr: RecrAnswers | null; buyer_name: string; signer: { name: string; position: number; signed_at: string | null }
  others: { name: string; signed: boolean }[]; offer_url: string; final_url: string | null
  offer_download_url: string; final_download_url: string | null
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
    offer_download_url: await ports.storage.signedUrl(String(d.offer_path), 3600, 'Offer to purchase.pdf'),
    final_download_url: d.final_path ? await ports.storage.signedUrl(String(d.final_path), 3600, 'Signed offer.pdf') : null,
  }
  delete (view as Record<string, unknown>).offer_path
  delete (view as Record<string, unknown>).final_path
  delete (view as Record<string, unknown>).ok
  return { ok: true, view }
}

/** A seller signs. Seals when they were the last one. */
export async function signAsSeller(ports: ContractPorts, x: {
  token: string; consent: boolean; name: string; signature?: string | null; recr?: RecrAnswers | null; ip?: string | null; ua?: string | null
}): Promise<Result<{ allSigned: boolean; sealed: boolean; finalUrl: string | null; finalDownloadUrl: string | null; copies: string[] }>> {
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
  if (!d.all_signed) return { ok: true, allSigned: false, sealed: false, finalUrl: null, finalDownloadUrl: null, copies: [] }
  const s = await seal(ports, d.contract_id!)
  return { ok: true, allSigned: true, sealed: s.ok, finalUrl: s.ok ? await ports.storage.signedUrl(s.path, 3600) : null,
    finalDownloadUrl: s.ok ? await ports.storage.signedUrl(s.path, 3600, 'Signed offer.pdf') : null, copies: s.ok ? s.copies : [] }
}

type Bundle = {
  contract: { id: string; lead_id: string; form: string; status: string; terms: Wb11Terms; include_recr: boolean; recr: RecrAnswers | null
    buyer_name: string; buyer_signature_path: string | null; buyer_signed_at: string; offer_sha256: string; final_path: string | null }
  lead: { owner_name: string; property_address: string | null }
  signers: { id: string; position: number; name: string; email: string | null; signed_at: string | null; signed_name: string | null; signature_path: string | null }[]
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
export async function seal(ports: ContractPorts, contractId: string): Promise<{ ok: true; path: string; copies: string[] } | { ok: false; reason: string }> {
  const now = (ports.now ?? (() => new Date()))()
  const r = await ports.rpc('contract_bundle', { p_id: contractId })
  const b = r.data as Bundle | null
  if (r.error || !b?.contract) return { ok: false, reason: r.error?.message ?? 'no such contract' }
  const c = b.contract
  if (c.status === 'signed' && c.final_path) return { ok: true, path: c.final_path, copies: [] }
  if (b.signers.some((s) => !s.signed_at)) return { ok: false, reason: 'not everyone has signed' }
  const img = async (p: string | null) => (p ? await ports.storage.get(p) : null)
  const buyer: SignatureMark = buyerMark({ ...c.terms, buyerName: c.terms.buyerName || c.buyer_name }, centralDate(new Date(c.buyer_signed_at)), await img(c.buyer_signature_path))
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
  // Send offer (0217): the buyer's signature is the one its signer keeps on file for every offer; whoever pressed
  // Send (the signer himself or a caller at his number) is named as the sender, never as the signer.
  const kept = c.terms.quick && c.terms.buyerSigner
  const rows: AuditRow[] = b.events.filter((e) => WHAT[e.kind]).map((e) => ({
    at: centralStamp(new Date(e.at)), who: e.kind === 'buyer_signed' && kept ? c.buyer_name : e.actor,
    what: e.kind === 'buyer_signed' && kept
      ? `Signed the Offer as Buyer with the signature ${c.terms.buyerSigner} keeps on file for every offer; sent for signature by ${e.actor}`
      : WHAT[e.kind] + (e.kind === 'signed' && e.detail?.typed_name ? ` as "${e.detail.typed_name}"` : ''),
    ip: e.ip, device: e.user_agent,
  }))
  // who gets the signed copy by email: every seller with an address, and the buyer
  const copyTo = [...b.signers.filter((g) => isEmail(g.email)).map((g) => ({ name: g.signed_name || g.name, email: g.email!.trim(), signerId: g.id as string | null })),
    ...(isEmail(c.terms.buyerEmail) ? [{ name: c.terms.buyerSigner || c.buyer_name, email: c.terms.buyerEmail!.trim(), signerId: null }] : [])]
    .filter((x, i, all) => all.findIndex((y) => y.email.toLowerCase() === x.email.toLowerCase()) === i)
  rows.push({ at: centralStamp(now), who: 'WPIE', what: ports.mail && copyTo.length
    ? `Sealed this PDF. A copy is emailed to ${copyTo.map((x) => x.email).join(', ')} and stays available at each signing link`
    : 'Sealed this PDF. A copy is available at each signing link' })
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
  const copies: string[] = []
  if (!dd.already && ports.mail) {
    for (const to of copyTo) {
      const m = await mailAndLog(ports, signedMail(c.terms, to, final, Boolean(c.include_recr && c.recr)),
        { id: c.id, signerId: to.signerId, what: 'signed', actor: 'WPIE', now })
      if (m.ok) copies.push(m.to)
    }
  }
  if (!dd.already && ports.notify) {
    await ports.notify({ title: `Contract signed: ${c.terms.street}`,
      body: `Every seller signed. Contract + earnest money to ${c.terms.earnestHolder} today.`,
      url: `${(ports.teamUrl ?? ports.appUrl).replace(/\/$/, '')}/lead/${c.lead_id}`, tag: `contract-${c.id}` }).catch(() => undefined)
  }
  return { ok: true, path, copies }
}
