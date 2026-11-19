// card_files (0256; Muse, desk 311, 2026-11-19, from Colin: "Muse must be able to read ALL files stored in WPIE").
// The agent door's reading of the files on a card. Today that is contracts: the database gives each contract whole
// (agent_card_files), and this turns it into what an agent can read without opening a PDF: the terms word for word,
// the same terms in plain sentences, the seller's "yes" answers on the condition report, who signed, and a
// short-lived link to the PDF itself. Storage paths never leave the server. Pure: the link maker is passed in.
import { RECR } from './recrForm.generated.ts'

type Json = Record<string, unknown>
export type LinkMaker = (path: string) => Promise<string | null>
export const LINK_SECONDS = 600

const str = (v: unknown) => (typeof v === 'string' && v.trim() ? v.trim() : null)
const num = (v: unknown) => (typeof v === 'number' && Number.isFinite(v) ? v : typeof v === 'string' && v.trim() && Number.isFinite(Number(v)) ? Number(v) : null)
const usd = (n: number) => '$' + n.toLocaleString('en-US', { maximumFractionDigits: 2 })
const day = (iso: unknown) => {
  const s = str(iso)
  if (!s) return null
  const d = new Date(s)
  return Number.isNaN(d.getTime()) ? s : d.toLocaleDateString('en-US', { timeZone: 'America/Chicago', month: 'long', day: 'numeric', year: 'numeric' })
}

/** The contract's terms as sentences, in the order a title company asks about them. Nothing here is a guess: a term
 * the contract does not state is left out, and the added provisions are given word for word. */
export function contractPlainWords(c: Json): string[] {
  const t = (c.terms && typeof c.terms === 'object' ? c.terms : {}) as Json
  const out: string[] = []
  const place = [str(t.street), str(t.street2)].filter(Boolean).join(', ')
  const muni = str(t.muniName) ? `${str(t.muniType) ?? 'City'} of ${str(t.muniName)}` : null
  out.push(`Offer to purchase ${[place || 'the property', muni, str(t.county) ? `${str(t.county)} County` : null, 'Wisconsin'].filter(Boolean).join(', ')}. Form ${str(c.form) ?? 'unknown'}.`)

  const sellers = (Array.isArray(c.sellers) ? c.sellers : []) as Json[]
  const status = str(c.status)
  if (status === 'signed') out.push(`Status: signed by every seller on ${day(c.signed_at) ?? 'a date not recorded'}. This is a binding contract.`)
  else if (status === 'void') out.push(`Status: voided${day(c.voided_at) ? ` on ${day(c.voided_at)}` : ''}${str(c.void_reason) ? `: ${str(c.void_reason)}` : ''}. Not a contract.`)
  else {
    const waiting = sellers.filter((s) => !s.signed_at).map((s) => str(s.name) ?? 'a seller')
    out.push(`Status: ${status ?? 'unknown'}, not signed by every seller${waiting.length ? ` (waiting on ${waiting.join(', ')})` : ''}. Not a contract yet.`)
  }

  const buyer = str(t.buyerName) ?? str(c.buyer)
  if (buyer) out.push(`Buyer: ${buyer}${str(t.buyerSigner) ? `, signed by ${str(t.buyerSigner)}${str(t.buyerSignerTitle) ? ` (${str(t.buyerSignerTitle)})` : ''}` : ''}.`)
  if (sellers.length) {
    out.push('Seller' + (sellers.length > 1 ? 's' : '') + ': ' + sellers.map((s) =>
      `${str(s.name) ?? 'unnamed'}${s.signed_at ? ` (signed ${day(s.signed_at)}${str(s.signed_name) && str(s.signed_name) !== str(s.name) ? ` as "${str(s.signed_name)}"` : ''})` : ' (not signed)'}`).join('; ') + '.')
  }

  const price = num(t.price)
  if (price != null) out.push(`Price: ${usd(price)}.`)
  if (str(t.closing) || str(t.closingOn)) out.push(`Closing: ${str(t.closing) ?? day(t.closingOn)}.`)

  const em = num(t.earnestMoney)
  const holder = str(t.earnestHolder)
  if (em != null) {
    out.push(`Earnest money: ${usd(em)}${num(t.earnestDays) != null ? `, due within ${num(t.earnestDays)} days of acceptance` : ''}${holder ? `, held by ${holder}` : ''}.`)
  }
  if (holder && /^the title company/i.test(holder)) out.push('Title company: none is named in the contract. The buyer picks it.')
  else if (holder) out.push(`Title company named in the contract: ${holder}.`)

  if (num(t.proofOfFundsDays) != null) out.push(`Proof of funds: the buyer gives it within ${num(t.proofOfFundsDays)} days of acceptance.`)
  out.push(t.inspection === true
    ? `Inspection contingency: yes${num(t.inspectionDays) != null ? `, ${num(t.inspectionDays)} days` : ''}${str(t.inspectionComponents) ? ` (${str(t.inspectionComponents)})` : ''}.`
    : 'Inspection contingency: none.')
  if (str(t.included)) out.push(`Included in the price: ${str(t.included)}.`)
  if (str(t.excluded)) out.push(`Not included: ${str(t.excluded)}.`)
  if (str(t.leaseTerms)) out.push(`Leases: ${str(t.leaseTerms)}.`)
  if (str(t.bindingDeadline)) out.push(`The offer had to be accepted by ${str(t.bindingDeadline)}.`)
  if (c.condition_report_included === true) out.push("The seller's Real Estate Condition Report was filled in and signed with this offer.")
  if (str(t.additional)) out.push(`Added provisions, word for word (they override the printed form where they say so): ${str(t.additional)}`)
  else out.push('Added provisions: none. The printed form decides who pays which closing cost.')
  return out
}

/** The seller's "yes" answers on the condition report, each with its question and the section's explanation. */
export function conditionReportYes(recr: unknown): { answered: number; yes: { id: string; question: string; explanation: string | null }[]; years: Json } | null {
  if (!recr || typeof recr !== 'object') return null
  const a = recr as { answers?: Record<string, string>; explain?: Record<string, string>; years?: Json }
  const answers = a.answers ?? {}
  const yes: { id: string; question: string; explanation: string | null }[] = []
  for (const s of RECR.sections) {
    const explainId = s.items.find((i) => i.kind === 'explain')?.id
    for (const i of s.items) {
      if (i.kind === 'ynna' && answers[i.id] === 'yes') yes.push({ id: i.id, question: i.text, explanation: explainId ? str(a.explain?.[explainId]) : null })
    }
  }
  return { answered: Object.keys(answers).length, yes, years: a.years ?? {} }
}

/** What the door hands an agent: the database's answer with links in place of paths and the plain reading added. */
export async function shapeCardFiles(raw: unknown, link: LinkMaker): Promise<Json> {
  const r = (raw && typeof raw === 'object' ? raw : {}) as Json
  if (r.ok !== true) return { ok: false, reason: str(r.reason) ?? 'could not read the card' }
  const files: Json[] = []
  for (const f of (Array.isArray(r.files) ? r.files : []) as Json[]) {
    const { offer_path, offer_sha256, final_path, final_sha256, condition_report, ...rest } = f
    const signedPath = str(final_path)
    const path = signedPath ?? str(offer_path)
    const url = path ? await link(path) : null
    files.push({
      ...rest,
      in_plain_words: contractPlainWords(f),
      condition_report: f.condition_report_included === true ? conditionReportYes(condition_report) : null,
      pdf: path
        ? { which: signedPath ? 'signed' : 'offer_as_sent', url, expires_in_seconds: url ? LINK_SECONDS : null,
            sha256: signedPath ? str(final_sha256) : str(offer_sha256),
            note: url ? "The whole document: the state form's printed lines, the filled blanks, the signatures and (when signed) the certificate. Download it within 10 minutes; call card_files again for a fresh link."
                      : 'The file could not be linked right now. The terms above are the contract as filled in.' }
        : null,
    })
  }
  return { ok: true, lead_id: r.lead_id, owner_name: r.owner_name, address: r.address, municipality: r.municipality, county: r.county,
    stage: r.stage, deal: r.deal ?? null, files,
    none: files.length ? undefined : 'No contract has been made on this card. WPIE stores no other file on a card today.' }
}
