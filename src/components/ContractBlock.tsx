import { useMemo, useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge, Empty, ErrorNote, Section, Select, Textarea } from '@/components/ui/form'
import { ConfirmButton } from '@/components/ui/confirm'
import { SignaturePad } from '@/components/SignaturePad'
import { api, useContracts, useDeals, type ContractRow } from '@/lib/queries'
import { fmtDateTime, fmtPhone } from '@/lib/format'
import type { Contact, Lead } from '@/lib/types'

// "Send contract": the official WB-11, filled from the lead and Colin's terms, signed by Colin, with a
// private signing link per seller. Colin sends the link himself (text or email from his phone).
// Nothing here suggests a price: the offer is whatever Colin types.

const DEFAULTS_KEY = 'wpie-offer-defaults'
type Defaults = { buyerName: string; buyerAddress: string; buyerEmail: string; earnestHolder: string; earnestMoney: string; additional: string }
function loadDefaults(): Defaults {
  const base: Defaults = { buyerName: 'Colin Merrill', buyerAddress: '', buyerEmail: '', earnestHolder: '', earnestMoney: '1000', additional: '' }
  try { return { ...base, ...(JSON.parse(localStorage.getItem(DEFAULTS_KEY) ?? '{}') as Partial<Defaults>) } } catch { return base }
}
function saveDefaults(d: Defaults) {
  try { localStorage.setItem(DEFAULTS_KEY, JSON.stringify(d)) } catch { /* private mode */ }
}

const long = (d: Date) => d.toLocaleDateString('en-US', { timeZone: 'America/Chicago', month: 'long', day: 'numeric', year: 'numeric' })
const isoDay = (d: Date) => d.toLocaleDateString('en-CA', { timeZone: 'America/Chicago' })
const fromIsoDay = (s: string) => (s ? long(new Date(`${s}T12:00:00`)) : '')
const titleCase = (s: string) => s.toLowerCase().replace(/\b([a-z])/g, (m) => m.toUpperCase()).replace(/\bLlc\b/g, 'LLC')

function sellersFrom(owner: string): { name: string; email: string; phone: string }[] {
  const parts = owner.split(/\s+(?:&|AND)\s+/i).map((p) => p.trim()).filter(Boolean).slice(0, 2)
  return (parts.length ? parts : [owner]).map((n) => ({ name: titleCase(n), email: '', phone: '' }))
}

export function ContractBlock({ lead, contacts }: { lead: Lead; contacts: Contact[] }) {
  const q = useContracts(lead.id)
  const [writing, setWriting] = useState(false)
  const active = q.data?.find((c) => c.status === 'sent')
  return (
    <Section title="Contract (WB-11)" right={!writing && !active ? <Button size="sm" onClick={() => setWriting(true)}>Write an offer</Button> : undefined}>
      <ErrorNote error={q.error} />
      {q.data?.length === 0 && !writing && <Empty>No contract yet.</Empty>}
      <div className="space-y-3">
        {q.data?.map((c) => <ContractCard key={c.id} c={c} />)}
      </div>
      {writing && <OfferForm lead={lead} contacts={contacts} onDone={() => setWriting(false)} />}
    </Section>
  )
}

function ContractCard({ c }: { c: ContractRow }) {
  const qc = useQueryClient()
  const [links, setLinks] = useState<Record<string, string>>({})
  const [msg, setMsg] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const run = async (body: Record<string, unknown>) => {
    setBusy(true)
    setMsg(null)
    const r = await api.contract(body)
    setBusy(false)
    if (!r.ok) setMsg(r.reason ?? 'That did not work.')
    void qc.invalidateQueries({ queryKey: ['contracts'] })
    void qc.invalidateQueries({ queryKey: ['lead'] })
    return r
  }
  const openPdf = async (which: 'offer' | 'final') => {
    const w = window.open('', '_blank')
    const r = await run({ action: 'pdf', id: c.id, which })
    if (r.ok && typeof r.url === 'string') { if (w) w.location.href = r.url; else window.location.href = r.url } else w?.close()
  }
  const signers = [...c.contract_signers].sort((a, b) => a.position - b.position)
  const allSigned = signers.every((s) => s.signed_at)
  const tone = c.status === 'signed' ? 'good' : c.status === 'void' ? 'bad' : 'warn'
  return (
    <div className="rounded-lg border p-3">
      <div className="flex flex-wrap items-center gap-2">
        <Badge tone={tone}>{c.status === 'signed' ? 'Signed: to title' : c.status === 'void' ? 'Withdrawn' : 'Out for signature'}</Badge>
        <span className="font-medium">{c.terms.price.toLocaleString('en-US', { style: 'currency', currency: 'USD', maximumFractionDigits: 0 })}</span>
        <span className="text-sm text-muted-foreground">closing {c.terms.closing} - sent {fmtDateTime(c.created_at)}</span>
      </div>
      <ul className="mt-2 space-y-2">
        {signers.map((s) => (
          <li key={s.id} className="text-sm">
            <span className="font-medium">{s.name}</span>{' '}
            {s.signed_at ? <Badge tone="good">signed {fmtDateTime(s.signed_at)}</Badge>
              : s.opened_at ? <Badge tone="info">opened {fmtDateTime(s.opened_at)}</Badge>
              : <Badge>not opened</Badge>}
            {c.status === 'sent' && !s.signed_at && (
              <div className="mt-1">
                {links[s.id] ? <ShareLink url={links[s.id]} name={s.name} phone={s.phone} email={s.email} /> : (
                  <Button size="sm" variant="outline" disabled={busy} onClick={async () => {
                    const r = await run({ action: 'new_link', signer_id: s.id })
                    if (r.ok && typeof r.url === 'string') setLinks((l) => ({ ...l, [s.id]: r.url as string }))
                  }}>New signing link</Button>
                )}
              </div>
            )}
          </li>
        ))}
      </ul>
      <div className="mt-3 flex flex-wrap gap-2">
        <Button size="sm" variant="outline" disabled={busy} onClick={() => void openPdf('offer')}>Offer as sent</Button>
        {c.final_path && <Button size="sm" disabled={busy} onClick={() => void openPdf('final')}>Signed PDF</Button>}
        {c.status === 'sent' && allSigned && <Button size="sm" disabled={busy} onClick={() => void run({ action: 'seal', id: c.id })}>Finish sealing</Button>}
        {c.status === 'sent' && (
          <ConfirmButton variant="outline" disabled={busy} yes="Yes, withdraw it" question="Withdraw this offer? The signing links stop working."
            onConfirm={() => void run({ action: 'void', id: c.id, reason: '' })}>Withdraw</ConfirmButton>
        )}
      </div>
      {c.void_reason && <p className="mt-1 text-xs text-muted-foreground">Withdrawn: {c.void_reason}</p>}
      {msg && <p className="mt-2 text-sm text-red-700">{msg}</p>}
    </div>
  )
}

function ShareLink({ url, name, phone, email }: { url: string; name: string; phone?: string | null; email?: string | null }) {
  const [copied, setCopied] = useState(false)
  const first = name.split(/\s+/)[0]
  const text = `Hi ${first}, here is the offer to sign on your phone: ${url}`
  return (
    <div className="space-y-2 rounded-md bg-muted p-2">
      <p className="break-all text-xs">{url}</p>
      <div className="flex flex-wrap gap-2">
        <Button size="sm" onClick={() => { void navigator.clipboard?.writeText(url).then(() => setCopied(true)) }}>{copied ? 'Copied' : 'Copy link'}</Button>
        {phone && <a className="inline-flex h-9 items-center rounded-md border bg-background px-3 text-sm" href={`sms:${phone}?&body=${encodeURIComponent(text)}`}>Text from my phone</a>}
        {email && <a className="inline-flex h-9 items-center rounded-md border bg-background px-3 text-sm" href={`mailto:${email}?subject=${encodeURIComponent('Offer to sign')}&body=${encodeURIComponent(text)}`}>Email it</a>}
        {typeof navigator.share === 'function' && <Button size="sm" variant="outline" onClick={() => void navigator.share({ text, url }).catch(() => undefined)}>Share</Button>}
      </div>
      <p className="text-xs text-muted-foreground">Works for 14 days. Only this link opens the offer for {name}.</p>
    </div>
  )
}

function L({ label, children, wide }: { label: string; children: React.ReactNode; wide?: boolean }) {
  return <label className={`block text-sm font-medium ${wide ? 'sm:col-span-2' : ''}`}>{label}<div className="mt-1">{children}</div></label>
}

function OfferForm({ lead, contacts, onDone }: { lead: Lead; contacts: Contact[]; onDone: () => void }) {
  const qc = useQueryClient()
  const deals = useDeals(lead.id, true)
  const d0 = useMemo(loadDefaults, [])
  const now = new Date()
  const email = contacts.find((c) => c.kind === 'email' && !c.dnc_app)?.value ?? ''
  const phone = contacts.find((c) => c.kind === 'phone' && c.status !== 'bad' && !c.dnc_app && !c.suppressed)?.value ?? ''
  const typedOffer = deals.data?.[deals.data.length - 1]?.colin_offer
  const [sellers, setSellers] = useState(() => sellersFrom(lead.owner_name).map((s, i) => (i === 0 ? { ...s, email, phone: phone ? fmtPhone(phone) : '' } : s)))
  const [f, setF] = useState({
    street: lead.property_address ?? '', muniType: 'City', muniName: lead.municipality ?? '', county: (lead.county ?? '').replace(/\s+County$/i, ''),
    price: typedOffer != null ? String(typedOffer) : '', earnestMoney: d0.earnestMoney, earnestDays: '3', earnestHolder: d0.earnestHolder,
    acceptBy: isoDay(new Date(now.getTime() + 3 * 86_400_000)), closingOn: isoDay(new Date(now.getTime() + 30 * 86_400_000)),
    inspection: true, inspectionDays: '10', inspectionComponents: '', proofOfFundsDays: '5', included: '', excluded: '', leaseTerms: '',
    additional: d0.additional, buyerName: d0.buyerName, buyerAddress: d0.buyerAddress, buyerEmail: d0.buyerEmail,
    sellerAddress: [lead.mailing_street, lead.mailing_city, [lead.mailing_state, lead.mailing_zip].filter(Boolean).join(' ')].filter(Boolean).join(', '),
    includeRecr: true,
  })
  const [sig, setSig] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [msg, setMsg] = useState<string | null>(null)
  const [sent, setSent] = useState<{ position: number; name: string; url: string }[] | null>(null)
  const set = (k: keyof typeof f) => (e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement>) => setF({ ...f, [k]: e.target.value })

  const terms = () => ({
    draftDate: long(now), buyerName: f.buyerName, street: f.street, muniType: f.muniType, muniName: f.muniName, county: f.county,
    price: f.price, included: f.included, excluded: f.excluded, bindingDeadline: f.acceptBy ? `${fromIsoDay(f.acceptBy)} at 11:59 p.m.` : '',
    closing: fromIsoDay(f.closingOn), earnestMoney: f.earnestMoney, earnestDays: f.earnestDays, earnestHolder: f.earnestHolder,
    inspection: f.inspection, inspectionDays: f.inspectionDays, inspectionComponents: f.inspectionComponents, proofOfFundsDays: f.proofOfFundsDays,
    leaseTerms: f.leaseTerms, additional: f.additional, sellerAddress: f.sellerAddress, sellerEmail: sellers[0]?.email ?? '',
    buyerAddress: f.buyerAddress, buyerEmail: f.buyerEmail,
  })
  const preview = async () => {
    setBusy(true)
    setMsg(null)
    const w = window.open('', '_blank')
    const r = await api.contract({ action: 'preview', terms: terms() })
    setBusy(false)
    if (!r.ok || typeof r.pdf_b64 !== 'string') { w?.close(); setMsg(r.reason ?? 'No preview.'); return }
    const bytes = Uint8Array.from(atob(r.pdf_b64), (ch) => ch.charCodeAt(0))
    const url = URL.createObjectURL(new Blob([bytes], { type: 'application/pdf' }))
    if (w) w.location.href = url; else window.location.href = url
  }
  const send = async () => {
    setBusy(true)
    setMsg(null)
    saveDefaults({ buyerName: f.buyerName, buyerAddress: f.buyerAddress, buyerEmail: f.buyerEmail, earnestHolder: f.earnestHolder,
      earnestMoney: f.earnestMoney, additional: f.additional })
    const r = await api.contract({ action: 'send', lead_id: lead.id, terms: terms(), include_recr: f.includeRecr,
      sellers: sellers.filter((s) => s.name.trim()).map((s) => ({ ...s, phone: s.phone.replace(/\D/g, '') })), signature: sig })
    setBusy(false)
    if (!r.ok) { setMsg(r.reason ?? 'Not sent.'); return }
    setSent(r.links as { position: number; name: string; url: string }[])
    void qc.invalidateQueries({ queryKey: ['contracts'] })
    void qc.invalidateQueries({ queryKey: ['lead'] })
    void qc.invalidateQueries({ queryKey: ['deals'] })
  }

  if (sent) {
    return (
      <div className="mt-3 space-y-3 rounded-lg border border-emerald-300 bg-emerald-50 p-3">
        <p className="font-medium">Signed by you. Send each seller their own link:</p>
        {sent.map((l) => {
          const s = sellers[l.position - 1]
          return <div key={l.position}><p className="text-sm font-medium">{l.name}</p><ShareLink url={l.url} name={l.name} phone={s?.phone.replace(/\D/g, '')} email={s?.email} /></div>
        })}
        <p className="text-xs text-muted-foreground">Copy them now: for security the app keeps only a fingerprint of each link. You can make a new one any time.</p>
        <Button variant="outline" onClick={onDone}>Done</Button>
      </div>
    )
  }

  return (
    <div className="mt-3 space-y-4 rounded-lg border p-3">
      <p className="text-sm text-muted-foreground">The official Wisconsin WB-11 Residential Offer to Purchase (10-1-2026). You type every number; nothing is suggested.</p>
      <div className="space-y-2">
        <p className="text-sm font-semibold">Sellers (everyone on title who signs)</p>
        {sellers.map((s, i) => (
          <div key={i} className="grid gap-2 sm:grid-cols-3">
            <Input aria-label={`Seller ${i + 1} name`} placeholder="Full name" value={s.name} onChange={(e) => setSellers(sellers.map((x, j) => (j === i ? { ...x, name: e.target.value } : x)))} />
            <Input aria-label={`Seller ${i + 1} email`} placeholder="Email (optional)" value={s.email} onChange={(e) => setSellers(sellers.map((x, j) => (j === i ? { ...x, email: e.target.value } : x)))} />
            <Input aria-label={`Seller ${i + 1} phone`} placeholder="Mobile (optional)" value={s.phone} onChange={(e) => setSellers(sellers.map((x, j) => (j === i ? { ...x, phone: e.target.value } : x)))} />
          </div>
        ))}
        <div className="flex gap-2">
          {sellers.length < 2 && <Button size="sm" variant="outline" onClick={() => setSellers([...sellers, { name: '', email: '', phone: '' }])}>Add a second seller</Button>}
          {sellers.length > 1 && <Button size="sm" variant="ghost" onClick={() => setSellers(sellers.slice(0, 1))}>Remove second seller</Button>}
        </div>
      </div>
      <div className="grid gap-3 sm:grid-cols-2">
        <L label="Property address" wide><Input value={f.street} onChange={set('street')} /></L>
        <L label="City / Village / Town"><Select value={f.muniType} onChange={set('muniType')}><option>City</option><option>Village</option><option>Town</option></Select></L>
        <L label="Of (name)"><Input value={f.muniName} onChange={set('muniName')} /></L>
        <L label="County"><Input value={f.county} onChange={set('county')} /></L>
        <L label="Price ($)"><Input inputMode="decimal" value={f.price} onChange={set('price')} /></L>
        <L label="Earnest money ($)"><Input inputMode="decimal" value={f.earnestMoney} onChange={set('earnestMoney')} /></L>
        <L label="Earnest money due within (days)"><Input inputMode="numeric" value={f.earnestDays} onChange={set('earnestDays')} /></L>
        <L label="Earnest money held by (title company)" wide><Input value={f.earnestHolder} onChange={set('earnestHolder')} /></L>
        <L label="Seller must accept by (11:59 p.m.)"><Input type="date" value={f.acceptBy} onChange={set('acceptBy')} /></L>
        <L label="Closing date"><Input type="date" value={f.closingOn} onChange={set('closingOn')} /></L>
        <label className="flex items-center gap-2 text-sm font-medium sm:col-span-2">
          <input type="checkbox" className="h-5 w-5" checked={f.inspection} onChange={(e) => setF({ ...f, inspection: e.target.checked })} />
          Inspection contingency (home inspection)
        </label>
        {f.inspection && <>
          <L label="Inspection deadline (days after acceptance)"><Input inputMode="numeric" value={f.inspectionDays} onChange={set('inspectionDays')} /></L>
          <L label="Also inspect separately (optional)"><Input placeholder="e.g. roof, sewer lateral" value={f.inspectionComponents} onChange={set('inspectionComponents')} /></L>
        </>}
        <L label="Proof of funds within (days)"><Input inputMode="numeric" value={f.proofOfFundsDays} onChange={set('proofOfFundsDays')} /></L>
        <L label="Included items (beyond fixtures)" wide><Input value={f.included} onChange={set('included')} placeholder="e.g. range, refrigerator" /></L>
        <L label="Not included" wide><Input value={f.excluded} onChange={set('excluded')} /></L>
        <L label="Lease terms, if tenants stay (optional)" wide><Input value={f.leaseTerms} onChange={set('leaseTerms')} /></L>
        <L label="Additional provisions (lines 570-590; more goes to Addendum A)" wide><Textarea rows={5} value={f.additional} onChange={set('additional')} /></L>
        <L label="Seller's address (for notices)" wide><Input value={f.sellerAddress} onChange={set('sellerAddress')} /></L>
        <L label="Buyer name"><Input value={f.buyerName} onChange={set('buyerName')} /></L>
        <L label="Buyer email"><Input type="email" value={f.buyerEmail} onChange={set('buyerEmail')} /></L>
        <L label="Buyer address (for notices)" wide><Input value={f.buyerAddress} onChange={set('buyerAddress')} /></L>
      </div>
      <fieldset className="space-y-2 rounded-md bg-muted p-3 text-sm">
        <legend className="font-semibold">Real Estate Condition Report</legend>
        <label className="flex items-start gap-2"><input type="radio" className="mt-1" checked={f.includeRecr} onChange={() => setF({ ...f, includeRecr: true })} />
          <span>The seller fills it in before signing (required for 1-4 unit homes).</span></label>
        <label className="flex items-start gap-2"><input type="radio" className="mt-1" checked={!f.includeRecr} onChange={() => setF({ ...f, includeRecr: false })} />
          <span>Seller is exempt (Wis. Stat. 709.01): a personal representative, trustee or conservator who never lived there, a property never lived in, or a transfer-fee-exempt sale.</span></label>
      </fieldset>
      <Button variant="outline" className="h-12 w-full sm:w-auto" disabled={busy} onClick={() => void preview()}>Preview the PDF</Button>
      <div className="space-y-2 border-t pt-3">
        <p className="text-sm font-semibold">Your signature as Buyer</p>
        <SignaturePad onChange={setSig} label={`Sign as ${f.buyerName || 'Buyer'}`} />
        <Button className="h-12 w-full" disabled={busy} onClick={() => void send()}>{busy ? 'Working...' : 'Sign and get the signing links'}</Button>
        <Button variant="ghost" className="w-full" onClick={onDone}>Cancel</Button>
      </div>
      {msg && <p className="rounded-md bg-red-50 p-2 text-sm text-red-800">{msg}</p>}
    </div>
  )
}
