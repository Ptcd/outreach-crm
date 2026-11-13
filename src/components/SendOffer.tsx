import { useEffect, useMemo, useState } from 'react'
import * as Dialog from '@radix-ui/react-dialog'
import { useQueryClient } from '@tanstack/react-query'
import { Check, ChevronDown, Eye, FileSignature, Loader2, Lock, Mail, Send, Settings2, X } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Select, Textarea } from '@/components/ui/form'
import { SignaturePad } from '@/components/SignaturePad'
import { api, useOfferSetup, type OfferSetup, type OfferStandards } from '@/lib/queries'
import { useAuth } from '@/providers/AuthProvider'
import { useOnPhone } from '@/lib/onPhone'
import { fmtPhone } from '@/lib/format'
import { sellersFrom, type SellerRow } from '@/lib/offer'
import { cn } from '@/lib/utils'
import type { Contact, Lead } from '@/lib/types'
import { CLOSE_MAX_DAYS, CLOSE_MIN_DAYS, muniOf } from '../../supabase/functions/_shared/contracts.ts'

// Send offer (Colin 2026-11-12): from the card to the seller's inbox in a couple of clicks. Who (the seller's email,
// asked only when the card has none), how much (Colin's number), when (the closing date, two weeks to 90 days out).
// Everything else is the standing terms Colin set once: buyer WeLiveWI LLC, $500 earnest money to the title company,
// buyer pays the closing costs, as is, the walk-through approval as the only out, the state WB-11 with the seller's
// condition report, his signature and today's date already on it.

const TZ = 'America/Chicago'
const todayIso = () => new Date().toLocaleDateString('en-CA', { timeZone: TZ })
const addDays = (iso: string, n: number) => {
  const [y, m, d] = iso.split('-').map(Number)
  return new Date(Date.UTC(y, m - 1, d + n)).toISOString().slice(0, 10)
}
const daysFromToday = (iso: string) => Math.round((Date.parse(`${iso}T00:00:00Z`) - Date.parse(`${todayIso()}T00:00:00Z`)) / 86_400_000)
const niceDay = (iso: string, weekday = true) => new Date(`${iso}T12:00:00Z`).toLocaleDateString('en-US',
  { timeZone: 'UTC', weekday: weekday ? 'long' : undefined, month: 'long', day: 'numeric', year: 'numeric' })
const shortDay = (iso: string) => new Date(`${iso}T12:00:00Z`).toLocaleDateString('en-US', { timeZone: 'UTC', month: 'short', day: 'numeric' })
const usd = (n: number) => n.toLocaleString('en-US', { style: 'currency', currency: 'USD', maximumFractionDigits: n % 1 ? 2 : 0 })
const EMAIL = /^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$/i
const digits = (s: string) => s.replace(/[^\d.]/g, '')
const withCommas = (s: string) => {
  const [a, b] = digits(s).split('.')
  const whole = a ? Number(a).toLocaleString('en-US') : ''
  return b !== undefined ? `${whole}.${b.slice(0, 2)}` : whole
}

const CLOSE_CHIPS: { days: number; label: string }[] = [
  { days: 14, label: '2 weeks' }, { days: 21, label: '3 weeks' }, { days: 30, label: '30 days' },
  { days: 45, label: '45 days' }, { days: 60, label: '60 days' }, { days: 90, label: '90 days' },
]

type Sent = { position: number; name: string; url: string; emailed_to?: string; email_error?: string }

/** The button and its panel. `hideButton` hides only the button (an offer is already out): the panel, once open,
 *  stays until it is closed, so the "sent" screen survives the card refreshing underneath it. */
export function SendOfferButton({ lead, contacts, disabled, hideButton, className }: {
  lead: Lead; contacts: Contact[]; disabled?: boolean; hideButton?: boolean; className?: string
}) {
  const [open, setOpen] = useState(false)
  return (
    <Dialog.Root open={open} onOpenChange={setOpen}>
      {!hideButton && (
        <Dialog.Trigger asChild>
          <Button size="sm" disabled={disabled} className={className}><FileSignature className="h-4 w-4" aria-hidden />Send offer</Button>
        </Dialog.Trigger>
      )}
      <Dialog.Portal>
        <Dialog.Overlay className="offer-backdrop fixed inset-0 z-50 bg-slate-950/50 backdrop-blur-[2px]" />
        <Dialog.Content
          className="offer-sheet fixed inset-x-0 bottom-0 z-50 flex max-h-[94dvh] flex-col rounded-t-3xl border border-border/70 bg-card shadow-2xl outline-none sm:inset-x-auto sm:bottom-auto sm:left-1/2 sm:top-1/2 sm:max-h-[90dvh] sm:w-[560px] sm:-translate-x-1/2 sm:-translate-y-1/2 sm:rounded-3xl">
          {open && <SendOfferSheet lead={lead} contacts={contacts} onClose={() => setOpen(false)} />}
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  )
}

function SheetHead({ title, sub, onClose }: { title: string; sub?: string; onClose: () => void }) {
  return (
    <div className="flex items-start justify-between gap-3 border-b border-border/70 px-5 pb-3 pt-4">
      <div className="min-w-0">
        <Dialog.Title className="text-lg font-bold tracking-tight">{title}</Dialog.Title>
        <Dialog.Description className="truncate text-sm text-muted-foreground">{sub ?? ' '}</Dialog.Description>
      </div>
      <button type="button" aria-label="Close" onClick={onClose}
        className="-mr-1 grid h-10 w-10 shrink-0 place-items-center rounded-full text-muted-foreground hover:bg-accent hover:text-foreground">
        <X className="h-5 w-5" />
      </button>
    </div>
  )
}

function Field({ label, hint, children }: { label: string; hint?: React.ReactNode; children: React.ReactNode }) {
  return (
    <label className="block">
      <span className="flex items-baseline justify-between gap-2 text-sm font-semibold">{label}{hint && <span className="text-xs font-normal text-muted-foreground">{hint}</span>}</span>
      <div className="mt-1.5">{children}</div>
    </label>
  )
}

function SendOfferSheet({ lead, contacts, onClose }: { lead: Lead; contacts: Contact[]; onClose: () => void }) {
  const qc = useQueryClient()
  const setup = useOfferSetup(lead.id, true)
  const { member } = useAuth()
  const [picked] = useOnPhone()
  // on the shared login a caller's phone sends as that caller: at Colin's number, never a typed one
  const asPerson = member?.role === 'caller' ? null : picked && picked !== 'colin' ? picked : null
  const isCaller = member?.role === 'caller' || asPerson != null
  const st = setup.data?.standards
  const canPrice = Boolean(setup.data?.can_set_price) && !isCaller
  const colinNumber = setup.data?.colin_number ?? null

  const cardEmail = contacts.find((c) => c.kind === 'email' && !c.dnc_app)?.value ?? ''
  const cardPhone = contacts.find((c) => c.kind === 'phone' && c.status !== 'bad' && !c.dnc_app && !c.suppressed)?.value ?? ''
  const m0 = useMemo(() => muniOf(lead.municipality), [lead.municipality])
  const [sellers, setSellers] = useState<SellerRow[]>(() => sellersFrom(lead.owner_name).map((s, i) => (i === 0 ? { ...s, email: cardEmail, phone: cardPhone } : s)))
  const [price, setPrice] = useState('')
  const [closingOn, setClosingOn] = useState(() => addDays(todayIso(), 30))
  const [prop, setProp] = useState({ street: lead.property_address ?? '', muniType: m0.type as string, muniName: m0.name, county: (lead.county ?? '').replace(/\s+County$/i, '') })
  const [includeRecr, setIncludeRecr] = useState(true)
  const [showDetails, setShowDetails] = useState(false)
  const [view, setView] = useState<'form' | 'standards'>('form')
  const [busy, setBusy] = useState<'preview' | 'send' | null>(null)
  const [msg, setMsg] = useState<string | null>(null)
  const [sent, setSent] = useState<Sent[] | null>(null)

  useEffect(() => {
    if (colinNumber != null) setPrice((p) => (p && canPrice ? p : withCommas(String(colinNumber))))
  }, [colinNumber, canPrice])

  const email = sellers[0]?.email.trim() ?? ''
  const priceNum = Number(digits(price))
  const closeDays = closingOn ? daysFromToday(closingOn) : NaN
  const who: string[] = []       // what is missing about the seller (a preview does not need it)
  const what: string[] = []      // what is missing about the offer
  if (!sellers[0]?.name.trim()) who.push("Add the seller's name.")
  if (!EMAIL.test(email)) who.push(email ? 'That email does not look right.' : "Add the seller's email.")
  if (sellers[1] && sellers[1].email.trim() && !EMAIL.test(sellers[1].email.trim())) who.push("The second seller's email does not look right.")
  if (isCaller && colinNumber == null) what.push('Colin has not put his number on this card yet.')
  else if (!(priceNum > 0)) what.push('Add the price.')
  if (!(closeDays >= CLOSE_MIN_DAYS && closeDays <= CLOSE_MAX_DAYS)) what.push(`Closing must be ${CLOSE_MIN_DAYS} to ${CLOSE_MAX_DAYS} days out.`)
  if (!prop.street.trim() || !prop.muniName.trim() || !prop.county.trim()) what.push('Fill in the property address, municipality and county (open "The property as the form prints it").')
  const problems = [...who, ...what]

  const body = (action: string) => ({
    action, lead_id: lead.id, price: priceNum, closing_on: closingOn, include_recr: includeRecr, property: prop, as_person: asPerson,
    sellers: sellers.filter((s) => s.name.trim()).map((s) => ({ name: s.name.trim(), email: s.email.trim(), phone: s.phone.replace(/\D/g, '') })),
  })
  const preview = async () => {
    setBusy('preview')
    setMsg(null)
    const w = window.open('', '_blank')
    const r = await api.contract(body('quick_preview'))
    setBusy(null)
    if (!r.ok || typeof r.pdf_b64 !== 'string') { w?.close(); setMsg(r.reason ?? 'No preview.'); return }
    const bytes = Uint8Array.from(atob(r.pdf_b64), (ch) => ch.charCodeAt(0))
    const url = URL.createObjectURL(new Blob([bytes], { type: 'application/pdf' }))
    if (w) w.location.href = url; else window.location.href = url
  }
  const send = async () => {
    setBusy('send')
    setMsg(null)
    const r = await api.contract(body('quick_send'))
    setBusy(null)
    if (!r.ok) { setMsg(r.reason ?? 'Not sent.'); return }
    setSent(r.links as Sent[])
    // an email typed here goes on the card, so the next offer does not ask again
    for (const s of sellers) {
      const e = s.email.trim()
      if (e && !contacts.some((c) => c.kind === 'email' && c.value.toLowerCase() === e.toLowerCase())) {
        await api.contactAdd(lead.id, 'email', e, s.name.trim() || null, 'typed when the offer was sent')
      }
    }
    for (const k of ['contracts', 'lead', 'deals']) void qc.invalidateQueries({ queryKey: [k] })
  }

  const where = [prop.street, prop.muniName].filter(Boolean).join(', ')
  if (sent) return <SentView sent={sent} sellers={sellers} deadline={st ? addDays(todayIso(), st.accept_days) : null} onClose={onClose} />
  if (view === 'standards' && setup.data) return <StandardsEditor setup={setup.data} onBack={() => { setView('form'); void setup.refetch() }} onClose={onClose} />

  return (
    <>
      <SheetHead title="Send offer" sub={where || lead.owner_name} onClose={onClose} />
      <div className="flex-1 space-y-5 overflow-y-auto px-5 py-4">
        {setup.isLoading && <p className="flex items-center gap-2 text-sm text-muted-foreground"><Loader2 className="h-4 w-4 animate-spin" />Getting the standards...</p>}
        {setup.error != null && <p className="rounded-xl bg-rose-50 p-3 text-sm text-rose-800">Could not load the offer standards. Close this and try again.</p>}
        {setup.data && !setup.data.can_send && <p className="rounded-xl bg-amber-50 p-3 text-sm text-amber-900">This login does not send contracts.</p>}

        {/* 1. who */}
        <div className="space-y-3">
          {sellers.map((s, i) => (
            <div key={i} className="grid gap-3 sm:grid-cols-2">
              <Field label={sellers.length > 1 ? `Seller ${i + 1}` : 'Seller'}>
                <Input aria-label={`Seller ${i + 1} name`} placeholder="Full name, as on title" value={s.name} autoComplete="off"
                  onChange={(e) => setSellers(sellers.map((x, j) => (j === i ? { ...x, name: e.target.value } : x)))} />
              </Field>
              <Field label="Email" hint={i === 0 && cardEmail && s.email === cardEmail ? 'from the card' : i === 1 ? 'optional' : undefined}>
                <Input aria-label={`Seller ${i + 1} email`} type="email" inputMode="email" autoComplete="off" autoFocus={i === 0 && !cardEmail}
                  placeholder={i === 0 ? 'Where the offer goes' : 'Or share their link yourself'} value={s.email}
                  className={cn(i === 0 && !s.email && 'border-primary ring-4 ring-ring/15')}
                  onChange={(e) => setSellers(sellers.map((x, j) => (j === i ? { ...x, email: e.target.value } : x)))} />
              </Field>
            </div>
          ))}
          <button type="button" className="text-sm font-medium text-primary hover:underline"
            onClick={() => setSellers(sellers.length < 2 ? [...sellers, { name: '', email: '', phone: '' }] : sellers.slice(0, 1))}>
            {sellers.length < 2 ? '+ A second owner signs too' : 'Remove the second seller'}
          </button>
        </div>

        {/* 2. how much */}
        <Field label="Offer price" hint={!canPrice ? <span className="inline-flex items-center gap-1"><Lock className="h-3 w-3" />Colin&apos;s number</span> : colinNumber != null ? `Your number on the card: ${usd(Number(colinNumber))}` : undefined}>
          <div className="relative">
            <span className="pointer-events-none absolute left-4 top-1/2 -translate-y-1/2 text-xl font-semibold text-muted-foreground">$</span>
            <Input aria-label="Offer price" inputMode="decimal" value={price} readOnly={!canPrice} placeholder={isCaller ? 'Waiting on Colin' : '0'}
              className={cn('h-14 pl-9 text-2xl font-bold tracking-tight sm:h-14 sm:text-2xl', !canPrice && 'bg-muted')}
              onChange={(e) => setPrice(withCommas(e.target.value))} />
          </div>
        </Field>

        {/* 3. when */}
        <div>
          <p className="text-sm font-semibold">Closing date <span className="font-normal text-muted-foreground">(the seller&apos;s pick, 2 weeks to 90 days)</span></p>
          <div className="mt-2 grid grid-cols-3 gap-2 sm:grid-cols-6" role="radiogroup" aria-label="Closing date">
            {CLOSE_CHIPS.map((c) => {
              const iso = addDays(todayIso(), c.days)
              const on = closingOn === iso
              return (
                <button key={c.days} type="button" role="radio" aria-checked={on} onClick={() => setClosingOn(iso)}
                  className={cn('rounded-xl border px-2 py-2 text-center transition-all active:scale-[0.97]',
                    on ? 'border-primary bg-primary text-primary-foreground shadow-[var(--shadow-lift)]' : 'border-border bg-card hover:border-primary/40')}>
                  <span className="block text-sm font-semibold">{c.label}</span>
                  <span className={cn('block text-xs', on ? 'text-primary-foreground/80' : 'text-muted-foreground')}>{shortDay(iso)}</span>
                </button>
              )
            })}
          </div>
          <div className="mt-2 flex items-center gap-3">
            <Input aria-label="Closing date" type="date" className="w-44" value={closingOn} min={addDays(todayIso(), CLOSE_MIN_DAYS)} max={addDays(todayIso(), CLOSE_MAX_DAYS)}
              onChange={(e) => setClosingOn(e.target.value)} />
            <p className="text-sm text-muted-foreground">{closingOn && Number.isFinite(closeDays) ? `${niceDay(closingOn)} (${closeDays} days)` : 'Pick a day'}</p>
          </div>
        </div>

        {/* what every offer says */}
        {st && (
          <div className="rounded-2xl bg-muted/60 p-4">
            <div className="flex items-center justify-between gap-2">
              <p className="text-sm font-semibold">Every offer says</p>
              {setup.data?.can_edit_standards && !isCaller && (
                <button type="button" className="inline-flex items-center gap-1 text-sm font-medium text-primary hover:underline" onClick={() => setView('standards')}>
                  <Settings2 className="h-3.5 w-3.5" />Standards
                </button>
              )}
            </div>
            <ul className="mt-2 space-y-1.5 text-sm">
              {[
                `Buyer: ${st.buyer_name}, already signed by ${st.signer_name} and dated today`,
                `${usd(Number(st.earnest_money))} earnest money to ${st.earnest_holder}`,
                'Buyer pays the closing costs',
                'Sold as is, where is: the seller makes no warranties on condition',
                "Only out: the buyer's walk-through and approval of the condition, until closing",
                includeRecr ? 'State forms: the WB-11 offer, and the seller fills in the Real Estate Condition Report as they sign' : 'State form: the WB-11 offer (seller exempt from the condition report)',
                `The seller has until ${niceDay(addDays(todayIso(), st.accept_days), false)} to sign`,
              ].map((line) => (
                <li key={line} className="flex gap-2"><Check className="mt-0.5 h-4 w-4 shrink-0 text-emerald-600" aria-hidden /><span>{line}</span></li>
              ))}
            </ul>
          </div>
        )}

        <div>
          <button type="button" className="inline-flex items-center gap-1 text-sm font-medium text-muted-foreground hover:text-foreground" aria-expanded={showDetails}
            onClick={() => setShowDetails(!showDetails)}>
            <ChevronDown className={cn('h-4 w-4 transition-transform', showDetails && 'rotate-180')} />The property as the form prints it
          </button>
          {showDetails && (
            <div className="mt-3 grid gap-3 sm:grid-cols-2">
              <div className="sm:col-span-2"><Field label="Street address"><Input value={prop.street} onChange={(e) => setProp({ ...prop, street: e.target.value })} /></Field></div>
              <Field label="City / Village / Town">
                <Select value={prop.muniType} onChange={(e) => setProp({ ...prop, muniType: e.target.value })}><option>City</option><option>Village</option><option>Town</option></Select>
              </Field>
              <Field label="Of"><Input value={prop.muniName} onChange={(e) => setProp({ ...prop, muniName: e.target.value })} /></Field>
              <Field label="County"><Input value={prop.county} onChange={(e) => setProp({ ...prop, county: e.target.value })} /></Field>
              <label className="flex items-start gap-2 text-sm sm:col-span-2">
                <input type="checkbox" className="mt-0.5 h-5 w-5" checked={!includeRecr} onChange={(e) => setIncludeRecr(!e.target.checked)} />
                <span>The seller is exempt from the condition report (an estate&apos;s personal representative or a trustee who never lived there).</span>
              </label>
            </div>
          )}
        </div>
      </div>

      <div className="space-y-2 border-t border-border/70 bg-card px-5 pb-[max(1rem,env(safe-area-inset-bottom))] pt-3">
        {msg && <p role="alert" className="rounded-xl bg-rose-50 p-3 text-sm text-rose-800 ring-1 ring-inset ring-rose-200">{msg}</p>}
        {!msg && problems.length > 0 && <p className="text-sm text-muted-foreground">{problems[0]}</p>}
        <div className="flex gap-2">
          <Button variant="outline" className="h-12 shrink-0" disabled={busy != null || what.length > 0} onClick={() => void preview()}>
            {busy === 'preview' ? <Loader2 className="h-4 w-4 animate-spin" /> : <Eye className="h-4 w-4" />}Preview
          </Button>
          <Button className="h-12 min-w-0 flex-1 text-base" disabled={busy != null || problems.length > 0 || setup.data?.can_send === false} onClick={() => void send()}>
            {busy === 'send' ? <><Loader2 className="h-4 w-4 animate-spin" />Sending...</> : <><Send className="h-4 w-4" /><span className="truncate">{EMAIL.test(email) ? `Send to ${email}` : 'Send offer'}</span></>}
          </Button>
        </div>
      </div>
    </>
  )
}

function SentView({ sent, sellers, deadline, onClose }: { sent: Sent[]; sellers: SellerRow[]; deadline: string | null; onClose: () => void }) {
  const allMailed = sent.every((l) => l.emailed_to)
  return (
    <>
      <SheetHead title={allMailed ? 'Offer sent' : 'Offer ready'} sub="Signed by the buyer and dated today" onClose={onClose} />
      <div className="flex-1 space-y-4 overflow-y-auto px-5 py-5">
        <div className="flex flex-col items-center gap-3 py-2 text-center">
          <span className="offer-pop grid h-16 w-16 place-items-center rounded-full bg-emerald-100 text-emerald-700">
            <svg viewBox="0 0 24 24" className="h-9 w-9" fill="none" stroke="currentColor" strokeWidth="2.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
              <path className="offer-tick" d="M5 12.5l4.5 4.5L19 7.5" />
            </svg>
          </span>
          <p className="text-sm text-muted-foreground">
            The seller opens a private link (no sign-in), fills in the condition report, and signs on their phone.
            {deadline ? ` It is good until ${niceDay(deadline, false)}.` : ''} You get an alert the moment it is signed, and everyone is emailed the signed PDF.
          </p>
        </div>
        {sent.map((l) => {
          const s = sellers[l.position - 1]
          return (
            <div key={l.position} className="rounded-2xl border border-border/70 p-3">
              <p className="font-semibold">{l.name}</p>
              {l.emailed_to
                ? <p className="mt-0.5 flex items-center gap-1.5 text-sm text-emerald-700"><Mail className="h-4 w-4" />Emailed to {l.emailed_to}</p>
                : <p className="mt-0.5 text-sm text-amber-800">{l.email_error ? `The email did not go (${l.email_error}). Send their link yourself:` : 'No email for this seller. Send their link yourself:'}</p>}
              <ShareLink url={l.url} name={l.name} phone={s?.phone.replace(/\D/g, '')} email={l.emailed_to ? null : s?.email} quiet={Boolean(l.emailed_to)} />
            </div>
          )
        })}
      </div>
      <div className="border-t border-border/70 px-5 pb-[max(1rem,env(safe-area-inset-bottom))] pt-3">
        <Button className="h-12 w-full" onClick={onClose}>Done</Button>
      </div>
    </>
  )
}

/** A seller's private link, to copy or send by hand. Shown once: the app keeps only its fingerprint. */
export function ShareLink({ url, name, phone, email, quiet }: { url: string; name: string; phone?: string | null; email?: string | null; quiet?: boolean }) {
  const [copied, setCopied] = useState(false)
  const first = name.split(/\s+/)[0]
  const text = `Hi ${first}, here is the offer to sign on your phone: ${url}`
  return (
    <div className="mt-2 space-y-2">
      {!quiet && <p className="break-all rounded-lg bg-muted p-2 text-xs">{url}</p>}
      <div className="flex flex-wrap gap-2">
        <Button size="sm" variant={quiet ? 'outline' : 'default'} onClick={() => { void navigator.clipboard?.writeText(url).then(() => setCopied(true)) }}>{copied ? 'Copied' : 'Copy link'}</Button>
        {phone && <a className="inline-flex h-11 items-center rounded-lg border bg-card px-3 text-sm font-semibold sm:h-9" href={`sms:${phone}?&body=${encodeURIComponent(text)}`}>Text from my phone{phone.length === 10 ? ` (${fmtPhone(phone)})` : ''}</a>}
        {email && <a className="inline-flex h-11 items-center rounded-lg border bg-card px-3 text-sm font-semibold sm:h-9" href={`mailto:${email}?subject=${encodeURIComponent('Offer to sign')}&body=${encodeURIComponent(text)}`}>Email it myself</a>}
      </div>
      {!quiet && <p className="text-xs text-muted-foreground">Copy it now: for security the app keeps only a fingerprint of each link. You can make a new one any time.</p>}
    </div>
  )
}

function StandardsEditor({ setup, onBack, onClose }: { setup: OfferSetup; onBack: () => void; onClose: () => void }) {
  const [f, setF] = useState<OfferStandards>(setup.standards)
  const [sig, setSig] = useState<string | null>(null)
  const [typed, setTyped] = useState(false)
  const [busy, setBusy] = useState(false)
  const [msg, setMsg] = useState<string | null>(null)
  const set = (k: keyof OfferStandards) => (e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>) => setF({ ...f, [k]: e.target.value })
  const save = async () => {
    setBusy(true)
    setMsg(null)
    const r = await api.offerStandardsSet({
      buyer_name: f.buyer_name, signer_name: f.signer_name, signer_title: f.signer_title, buyer_email: f.buyer_email ?? '', buyer_address: f.buyer_address ?? '',
      buyer_phone: f.buyer_phone, earnest_money: String(f.earnest_money), earnest_days: Number(f.earnest_days), earnest_holder: f.earnest_holder,
      accept_days: Number(f.accept_days), proof_of_funds_days: Number(f.proof_of_funds_days), included: f.included ?? '', excluded: f.excluded ?? '',
      additional: f.additional, ...(sig ? { signature_png: sig } : typed ? { signature_png: '' } : {}),
    })
    setBusy(false)
    if (!r.ok) { setMsg(r.reason ?? 'Not saved.'); return }
    onBack()
  }
  const current = typed ? null : sig ?? setup.signature_png
  return (
    <>
      <SheetHead title="Offer standards" sub="What every offer carries until you change it" onClose={onClose} />
      <div className="flex-1 space-y-4 overflow-y-auto px-5 py-4">
        <div className="grid gap-3 sm:grid-cols-2">
          <Field label="Buyer"><Input value={f.buyer_name} onChange={set('buyer_name')} /></Field>
          <Field label="Signed by"><Input value={f.signer_name} onChange={set('signer_name')} /></Field>
          <Field label="Signer's title"><Input value={f.signer_title} onChange={set('signer_title')} /></Field>
          <Field label="Phone sellers call"><Input value={f.buyer_phone} onChange={set('buyer_phone')} /></Field>
          <Field label="Buyer email" hint="gets the signed copy"><Input type="email" value={f.buyer_email ?? ''} onChange={set('buyer_email')} /></Field>
          <Field label="Buyer address for notices"><Input value={f.buyer_address ?? ''} onChange={set('buyer_address')} /></Field>
          <Field label="Earnest money ($)"><Input inputMode="decimal" value={String(f.earnest_money)} onChange={set('earnest_money')} /></Field>
          <Field label="Earnest money due" hint="days after acceptance"><Input inputMode="numeric" value={String(f.earnest_days)} onChange={set('earnest_days')} /></Field>
          <div className="sm:col-span-2"><Field label="Title company" hint="holds the earnest money, closes the sale"><Input value={f.earnest_holder} onChange={set('earnest_holder')} /></Field></div>
          <Field label="Days the seller has to sign"><Input inputMode="numeric" value={String(f.accept_days)} onChange={set('accept_days')} /></Field>
          <Field label="Proof of funds within" hint="days"><Input inputMode="numeric" value={String(f.proof_of_funds_days)} onChange={set('proof_of_funds_days')} /></Field>
          <div className="sm:col-span-2"><Field label="Included items beyond fixtures" hint="blank = none"><Input value={f.included ?? ''} onChange={set('included')} /></Field></div>
          <div className="sm:col-span-2">
            <Field label="Additional provisions" hint="WB-11 lines 570-590">
              <Textarea rows={9} value={f.additional} onChange={set('additional')} className="text-sm" />
            </Field>
          </div>
        </div>
        <div className="rounded-2xl bg-muted/60 p-4">
          <p className="text-sm font-semibold">Your signature on every offer</p>
          <div className="mt-2 grid h-20 place-items-center rounded-xl border bg-white">
            {current ? <img src={current} alt="Your signature" className="max-h-16 max-w-[80%]" />
              : <span className="text-3xl text-[#0d1a73]" style={{ fontFamily: '"Times New Roman", Times, serif', fontStyle: 'italic', fontWeight: 700 }}>{f.signer_name}</span>}
          </div>
          <p className="mt-1 text-xs text-muted-foreground">{current ? 'Your drawn signature.' : 'Your typed name is the signature until you draw one.'}</p>
          <div className="mt-3"><SignaturePad label="Draw a new one" onChange={(p) => { setSig(p); if (p) setTyped(false) }} /></div>
          {(setup.signature_png || sig) && !typed && (
            <button type="button" className="mt-1 text-sm font-medium text-primary hover:underline" onClick={() => { setTyped(true); setSig(null) }}>Use my typed name instead</button>
          )}
        </div>
      </div>
      <div className="space-y-2 border-t border-border/70 px-5 pb-[max(1rem,env(safe-area-inset-bottom))] pt-3">
        {msg && <p role="alert" className="rounded-xl bg-rose-50 p-3 text-sm text-rose-800">{msg}</p>}
        <div className="flex gap-2">
          <Button variant="outline" className="h-12" disabled={busy} onClick={onBack}>Back</Button>
          <Button className="h-12 flex-1" disabled={busy} onClick={() => void save()}>{busy ? 'Saving...' : 'Save the standards'}</Button>
        </div>
      </div>
    </>
  )
}
