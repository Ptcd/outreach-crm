import { useEffect, useMemo, useRef, useState } from 'react'
import { useParams } from 'react-router-dom'
import { ArrowLeft, ArrowRight, CalendarDays, Check, Download, FileText, Landmark, Loader2, Lock, PenLine, Phone, ShieldCheck } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Textarea } from '@/components/ui/form'
import { SignaturePad } from '@/components/SignaturePad'
import { api } from '@/lib/queries'
import { cn } from '@/lib/utils'
import { RECR } from '../../supabase/functions/_shared/recrForm.generated.ts'
import { emptyRecr, recrProblems, RECR_QUESTIONS, type RecrAnswers, type Ynna } from '../../supabase/functions/_shared/recr.ts'

type View = {
  contract_id: string; status: string; form: string; include_recr: boolean; recr: RecrAnswers | null; buyer_name: string
  terms: { street: string; muniName: string; county: string; price: number; earnestMoney: number; earnestHolder: string; closing: string
    bindingDeadline: string; inspection: boolean; inspectionDays?: number; proofOfFundsDays?: number; included?: string; additional?: string
    buyerSigner?: string; buyerPhone?: string; earnestDays?: number }
  signer: { name: string; position: number; signed_at: string | null }
  others: { name: string; signed: boolean }[]; offer_url: string; final_url: string | null
  offer_download_url?: string; final_download_url?: string | null
}
type Done = { allSigned: boolean; finalUrl: string | null; finalDownloadUrl: string | null; copies: string[] }
type Step = 'review' | 'report' | 'sign'

const usd = (n: number) => n.toLocaleString('en-US', { style: 'currency', currency: 'USD', maximumFractionDigits: n % 1 ? 2 : 0 })
const today = () => new Date().toLocaleDateString('en-US', { timeZone: 'America/Chicago', month: 'long', day: 'numeric', year: 'numeric' })
const firstName = (s: string) => (s.trim().split(/\s+/)[0] ?? '').replace(/^(.)(.*)$/, (_m, a: string, b: string) => a.toUpperCase() + b.toLowerCase())

function loadDraft(key: string): RecrAnswers {
  try {
    const v = JSON.parse(localStorage.getItem(key) ?? 'null') as RecrAnswers | null
    return v && v.answers ? { answers: v.answers, explain: v.explain ?? {}, years: v.years ?? {} } : emptyRecr()
  } catch {
    return emptyRecr()
  }
}

// The seller's page. No login: the private link is the key. Three short steps, one thing on the screen at a time:
// read the offer in plain words (the full PDF one tap away), answer the state's condition report, sign.
export default function SignContract() {
  const { token = '' } = useParams()
  const [view, setView] = useState<View | null>(null)
  const [error, setError] = useState<string | null>(null)
  const opened = useRef(false)

  useEffect(() => {
    if (opened.current) return
    opened.current = true
    void api.contractSign({ action: 'open', token }).then((r) => {
      if (r.ok) setView(r.view as View)
      else setError(r.reason ?? 'Something went wrong.')
    })
  }, [token])

  const who = view?.terms.buyerSigner ?? 'Colin Merrill'
  const phone = view?.terms.buyerPhone ?? '(262) 999-6513'
  return (
    <div className="min-h-dvh bg-gradient-to-b from-[hsl(245_60%_97%)] to-background text-base">
      <header className="sticky top-0 z-20 border-b border-border/60 bg-card/90 backdrop-blur">
        <div className="mx-auto flex max-w-xl items-center gap-3 px-4 py-2.5">
          <img src="/icon.svg" alt="" className="h-8 w-8" />
          <div className="min-w-0 flex-1">
            <p className="truncate text-sm font-semibold">Offer to purchase</p>
            <p className="truncate text-xs text-muted-foreground">Sent by {who}{view ? `, ${view.buyer_name}` : ''}</p>
          </div>
          <a href={`tel:${phone.replace(/\D/g, '')}`} className="inline-flex h-10 items-center gap-1.5 rounded-full border border-border bg-card px-3 text-sm font-semibold">
            <Phone className="h-4 w-4" aria-hidden /><span className="hidden sm:inline">{phone}</span><span className="sm:hidden">Call</span>
          </a>
        </div>
      </header>
      <main className="mx-auto max-w-xl px-4 pb-32 pt-4">
        {!view && !error && <p className="flex items-center gap-2 py-10 text-muted-foreground"><Loader2 className="h-5 w-5 animate-spin" />Opening your offer...</p>}
        {error && (
          <div className="rounded-2xl border border-rose-200 bg-rose-50 p-4 text-rose-900">
            <p className="font-semibold">{error}</p>
            <p className="mt-1 text-sm">Call or text {who} at {phone} and he will send a fresh link.</p>
          </div>
        )}
        {view && <Signing view={view} token={token} who={who} phone={phone} />}
      </main>
    </div>
  )
}

function Steps({ steps, at }: { steps: Step[]; at: number }) {
  const LABEL: Record<Step, string> = { review: 'Review', report: 'Report', sign: 'Sign' }
  return (
    <ol className="mb-4 flex items-center gap-2" aria-label="Steps">
      {steps.map((s, i) => (
        <li key={s} className={cn('flex min-w-0 items-center gap-2', i < steps.length - 1 && 'flex-1')} aria-current={i === at ? 'step' : undefined}>
          <span className={cn('grid h-7 w-7 shrink-0 place-items-center rounded-full text-xs font-bold transition-colors',
            i < at ? 'bg-emerald-600 text-white' : i === at ? 'bg-primary text-primary-foreground' : 'bg-muted text-muted-foreground')}>
            {i < at ? <Check className="h-4 w-4" aria-hidden /> : i + 1}
          </span>
          <span className={cn('whitespace-nowrap text-sm', i === at ? 'font-semibold' : 'text-muted-foreground')}>{LABEL[s]}</span>
          {i < steps.length - 1 && <span className={cn('h-0.5 min-w-2 flex-1 rounded-full', i < at ? 'bg-emerald-500' : 'bg-border')} aria-hidden />}
        </li>
      ))}
    </ol>
  )
}

function Bar({ children }: { children: React.ReactNode }) {
  return (
    <div className="fixed inset-x-0 bottom-0 z-20 border-t border-border/70 bg-card/95 backdrop-blur">
      <div className="mx-auto flex max-w-xl items-center gap-2 px-4 pb-[max(0.75rem,env(safe-area-inset-bottom))] pt-3">{children}</div>
    </div>
  )
}

function Fact({ icon, label, children }: { icon: React.ReactNode; label: string; children: React.ReactNode }) {
  return (
    <div className="flex gap-3 py-2.5">
      <span className="mt-0.5 grid h-9 w-9 shrink-0 place-items-center rounded-xl bg-secondary text-secondary-foreground">{icon}</span>
      <div className="min-w-0"><p className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">{label}</p><p className="font-medium">{children}</p></div>
    </div>
  )
}

function Signing({ view, token, who, phone }: { view: View; token: string; who: string; phone: string }) {
  const t = view.terms
  const draftKey = `recr-draft-${view.contract_id}`
  const needRecr = view.include_recr && !view.recr
  const steps = useMemo<Step[]>(() => ['review', ...(view.include_recr ? ['report' as Step] : []), 'sign'], [view.include_recr])
  const [at, setAt] = useState(0)
  const [recr, setRecr] = useState<RecrAnswers>(() => (needRecr ? loadDraft(draftKey) : emptyRecr()))
  const [consent, setConsent] = useState(false)
  const [agree, setAgree] = useState(false)
  const [name, setName] = useState(view.signer.name)
  const [sig, setSig] = useState<string | null>(null)
  const [mode, setMode] = useState<'draw' | 'type'>('draw')
  const [busy, setBusy] = useState(false)
  const [msg, setMsg] = useState<string | null>(null)
  const [done, setDone] = useState<Done | null>(null)

  useEffect(() => {
    if (!needRecr) return
    try { localStorage.setItem(draftKey, JSON.stringify(recr)) } catch { /* private mode */ }
  }, [recr, needRecr, draftKey])
  useEffect(() => { window.scrollTo?.({ top: 0 }) }, [at, done])

  const problems = useMemo(() => (needRecr ? recrProblems(recr) : []), [recr, needRecr])
  const where = `${t.street}, ${t.muniName}`

  if (view.signer.signed_at || done) {
    return <Finished view={view} done={done} who={who} phone={phone} />
  }

  const sign = async () => {
    setBusy(true)
    setMsg(null)
    const r = await api.contractSign({ action: 'sign', token, consent, name, signature: mode === 'draw' ? sig : null, recr: needRecr ? recr : null })
    setBusy(false)
    if (!r.ok) { setMsg(r.reason ?? 'Could not sign. Try again.'); return }
    try { localStorage.removeItem(draftKey) } catch { /* ignore */ }
    setDone({ allSigned: Boolean(r.allSigned), finalUrl: (r.finalUrl as string | null) ?? null,
      finalDownloadUrl: (r.finalDownloadUrl as string | null) ?? null, copies: (r.copies as string[] | undefined) ?? [] })
  }
  const step = steps[at]
  const provisions = (t.additional ?? '').split('\n').map((p) => p.trim()).filter(Boolean)

  return (
    <>
      <Steps steps={steps} at={at} />

      {step === 'review' && (
        <div className="offer-step space-y-4">
          <section className="overflow-hidden rounded-3xl border border-border/70 bg-card shadow-[var(--shadow-lift)]">
            <div className="bg-gradient-to-br from-[hsl(245_80%_62%)] to-primary px-5 pb-5 pt-4 text-primary-foreground">
              <p className="text-sm opacity-90">Hi {firstName(view.signer.name)}, {view.buyer_name} offers to buy</p>
              <h1 className="mt-0.5 text-xl font-bold leading-tight tracking-tight">{where}</h1>
              <p className="mt-3 text-4xl font-extrabold tracking-tight">{usd(t.price)}</p>
            </div>
            <div className="divide-y divide-border/60 px-5 py-1">
              <Fact icon={<CalendarDays className="h-4.5 w-4.5" aria-hidden />} label="Closing">{t.closing}</Fact>
              <Fact icon={<Landmark className="h-4.5 w-4.5" aria-hidden />} label="Earnest money">{usd(t.earnestMoney)}, held by {t.earnestHolder}</Fact>
              <Fact icon={<ShieldCheck className="h-4.5 w-4.5" aria-hidden />} label="Contingencies">
                {t.inspection ? `Home inspection within ${t.inspectionDays ?? 15} days.` : 'No home-inspection contingency.'} No financing contingency: proof of funds within {t.proofOfFundsDays ?? 7} days.
              </Fact>
              <Fact icon={<PenLine className="h-4.5 w-4.5" aria-hidden />} label="Sign by">{t.bindingDeadline}</Fact>
            </div>
          </section>

          {provisions.length > 0 && (
            <section className="rounded-3xl border border-border/70 bg-card p-5">
              <h2 className="font-semibold">Special terms in this offer</h2>
              <p className="mt-0.5 text-sm text-muted-foreground">Word for word from the offer (lines 570-590).</p>
              <div className="mt-3 space-y-3 text-sm leading-relaxed">
                {provisions.map((p) => {
                  const m = p.match(/^(\d+\.\s*[A-Z][A-Z' -]+\.)\s*(.*)$/)
                  return <p key={p}>{m ? <><span className="font-semibold">{m[1]}</span> {m[2]}</> : p}</p>
                })}
              </div>
            </section>
          )}

          <section className="rounded-3xl border border-border/70 bg-card p-5">
            <h2 className="font-semibold">The full offer</h2>
            <p className="mt-0.5 text-sm text-muted-foreground">
              The summary above is for convenience. What you sign is the Wisconsin WB-11 Residential Offer to Purchase, already signed by the buyer.
            </p>
            <div className="mt-3 flex flex-wrap gap-2">
              <a href={view.offer_url} target="_blank" rel="noreferrer"
                className="inline-flex h-12 items-center gap-2 rounded-xl border border-border bg-card px-4 font-semibold shadow-[var(--shadow-soft)] hover:border-primary/40">
                <FileText className="h-4.5 w-4.5" aria-hidden />Read the full Offer (PDF)
              </a>
              <a href={view.offer_download_url ?? view.offer_url} target="_blank" rel="noreferrer" download
                className="inline-flex h-12 items-center gap-2 rounded-xl border border-border bg-card px-4 font-semibold shadow-[var(--shadow-soft)] hover:border-primary/40">
                <Download className="h-4.5 w-4.5" aria-hidden />Download
              </a>
            </div>
            {view.others.length > 0 && (
              <p className="mt-3 text-sm">Also signing, each with their own link: {view.others.map((o) => `${o.name}${o.signed ? ' (signed)' : ''}`).join(', ')}.</p>
            )}
          </section>
          <p className="flex items-center justify-center gap-1.5 text-xs text-muted-foreground"><Lock className="h-3.5 w-3.5" aria-hidden />Private link. Nothing is signed until the last step.</p>
          <Bar>
            <Button className="h-14 flex-1 text-lg" onClick={() => setAt(1)}>Continue<ArrowRight className="h-5 w-5" aria-hidden /></Button>
          </Bar>
        </div>
      )}

      {step === 'report' && (
        needRecr
          ? <ReportStep value={recr} onChange={setRecr} problems={problems} onBack={() => setAt(at - 1)} onNext={() => setAt(at + 1)} />
          : (
            <div className="offer-step space-y-4">
              <section className="rounded-3xl border border-border/70 bg-card p-5"><h2 className="text-lg font-semibold">Real Estate Condition Report</h2><RecrDone recr={view.recr!} who={who} phone={phone} /></section>
              <Bar>
                <Button variant="outline" className="h-14" onClick={() => setAt(at - 1)}><ArrowLeft className="h-5 w-5" aria-hidden />Back</Button>
                <Button className="h-14 flex-1 text-lg" onClick={() => setAt(at + 1)}>Continue<ArrowRight className="h-5 w-5" aria-hidden /></Button>
              </Bar>
            </div>
          )
      )}

      {step === 'sign' && (
        <div className="offer-step space-y-4">
          <section className="rounded-3xl border border-border/70 bg-card p-5">
            <h2 className="text-lg font-semibold">Sign to accept</h2>
            <p className="mt-0.5 text-sm text-muted-foreground">You are accepting {usd(t.price)} for {where}, closing {t.closing}.</p>
            <label className="mt-4 block text-sm font-semibold">Your full legal name
              <Input value={name} onChange={(e) => setName(e.target.value)} className="mt-1.5 h-12 text-base" autoComplete="name" />
            </label>
            <div className="mt-4">
              <div className="mb-2 inline-flex rounded-xl bg-muted p-1" role="tablist" aria-label="How to sign">
                {(['draw', 'type'] as const).map((m) => (
                  <button key={m} type="button" role="tab" aria-selected={mode === m} onClick={() => setMode(m)}
                    className={cn('h-9 rounded-lg px-4 text-sm font-semibold transition-colors', mode === m ? 'bg-card shadow-[var(--shadow-soft)]' : 'text-muted-foreground')}>
                    {m === 'draw' ? 'Draw it' : 'Type it'}
                  </button>
                ))}
              </div>
              {mode === 'draw' ? <SignaturePad onChange={setSig} label="Sign with your finger" /> : (
                <div className="grid h-36 place-items-center rounded-md border-2 border-dashed bg-white px-3">
                  <span className="max-w-full truncate text-4xl text-[#0d1a73]" style={{ fontFamily: '"Times New Roman", Times, serif', fontStyle: 'italic', fontWeight: 700 }}>
                    {name.trim() || 'Your name'}
                  </span>
                </div>
              )}
            </div>
            <div className="mt-3 flex items-center justify-between rounded-xl bg-muted px-3 py-2.5 text-sm">
              <span className="text-muted-foreground">Date</span><span className="font-semibold">{today()}</span>
            </div>
          </section>

          <section className="space-y-3 rounded-3xl border border-border/70 bg-card p-5">
            <label className="flex items-start gap-3">
              <input type="checkbox" className="mt-1 h-6 w-6 shrink-0 accent-[hsl(245_72%_57%)]" checked={consent} onChange={(e) => setConsent(e.target.checked)} />
              <span>I agree to use electronic records and signatures for this offer.</span>
            </label>
            <details className="ml-9 text-sm text-muted-foreground">
              <summary className="cursor-pointer font-medium text-foreground">What that means</summary>
              <p className="mt-1">
                You can sign this offer on this page instead of on paper. Your electronic signature means the same as signing by hand
                (Wisconsin Statutes chapter 137). You can ask {firstName(who)} for a paper copy at any time, at no cost, and you can choose to sign
                on paper instead: just do not sign here and tell {firstName(who)}. You need a device that can open a PDF; you will get the signed
                PDF on this page and by email when everyone has signed.
              </p>
            </details>
            <label className="flex items-start gap-3">
              <input type="checkbox" className="mt-1 h-6 w-6 shrink-0 accent-[hsl(245_72%_57%)]" checked={agree} onChange={(e) => setAgree(e.target.checked)} />
              <span>
                I have read the Offer{view.include_recr ? ' and the Condition Report' : ''}. I accept the Offer and sign it
                {view.include_recr ? ', and I certify the Condition Report is true and correct to the best of my knowledge' : ''}.
              </span>
            </label>
            {problems.length > 0 && <ul className="list-disc pl-5 text-sm text-amber-800">{problems.map((p) => <li key={p}>{p}</li>)}</ul>}
            {msg && <p role="alert" className="rounded-xl bg-rose-50 p-3 text-sm text-rose-800">{msg}</p>}
          </section>
          <Bar>
            <Button variant="outline" className="h-14" disabled={busy} onClick={() => setAt(at - 1)}><ArrowLeft className="h-5 w-5" aria-hidden />Back</Button>
            <Button className="h-14 flex-1 text-lg" disabled={busy || !consent || !agree || !name.trim() || problems.length > 0} onClick={() => void sign()}>
              {busy ? <><Loader2 className="h-5 w-5 animate-spin" />Signing...</> : 'Accept and sign'}
            </Button>
          </Bar>
        </div>
      )}
    </>
  )
}

function Finished({ view, done, who, phone }: { view: View; done: Done | null; who: string; phone: string }) {
  const t = view.terms
  const finalUrl = done?.finalUrl ?? view.final_url
  const downloadUrl = done?.finalDownloadUrl ?? view.final_download_url ?? finalUrl
  const waiting = view.others.filter((o) => !o.signed).map((o) => o.name)
  const everyone = Boolean(finalUrl)
  return (
    <section className="offer-step space-y-4 rounded-3xl border border-border/70 bg-card p-6 text-center shadow-[var(--shadow-lift)]">
      <span className="offer-pop mx-auto grid h-20 w-20 place-items-center rounded-full bg-emerald-100 text-emerald-700">
        <svg viewBox="0 0 24 24" className="h-11 w-11" fill="none" stroke="currentColor" strokeWidth="2.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
          <path className="offer-tick" d="M5 12.5l4.5 4.5L19 7.5" />
        </svg>
      </span>
      <h1 className="text-2xl font-bold tracking-tight">Signed. Thank you, {firstName(view.signer.name)}.</h1>
      {everyone ? (
        <>
          <p>Everyone has signed. Here is your copy of the signed offer{view.include_recr ? ' and condition report' : ''}.</p>
          <div className="grid gap-2">
            <a href={downloadUrl ?? '#'} target="_blank" rel="noreferrer" download
              className="inline-flex h-14 items-center justify-center gap-2 whitespace-nowrap rounded-xl bg-gradient-to-b from-[hsl(245_80%_62%)] to-primary px-4 text-lg font-semibold text-primary-foreground shadow-[var(--shadow-soft)]">
              <Download className="h-5 w-5 shrink-0" aria-hidden />Download signed PDF
            </a>
            <a href={finalUrl ?? '#'} target="_blank" rel="noreferrer" className="inline-flex h-12 items-center justify-center rounded-xl border border-border px-5 font-semibold">Open it in the browser</a>
          </div>
          {done && done.copies.length > 0 && <p className="text-sm text-muted-foreground">A copy was also emailed to {done.copies.join(' and ')}.</p>}
          <div className="rounded-2xl bg-muted/60 p-4 text-left text-sm">
            <p className="font-semibold">What happens next</p>
            <ol className="mt-1 list-decimal space-y-1 pl-5">
              <li>The buyer sends the signed offer and {usd(t.earnestMoney)} earnest money to {t.earnestHolder}.</li>
              <li>The title company opens the file and contacts you about the paperwork.</li>
              <li>You close on {t.closing}.</li>
            </ol>
          </div>
        </>
      ) : (
        <p>{waiting.length ? `Waiting for ${waiting.join(' and ')} to sign with their own link.` : 'Finishing up.'} Keep this link: your signed copy will be here, and emailed, once everyone has signed.</p>
      )}
      <p className="text-sm text-muted-foreground">Questions? Call or text {firstName(who)} at <a className="font-semibold text-foreground underline" href={`tel:${phone.replace(/\D/g, '')}`}>{phone}</a>.</p>
    </section>
  )
}

const CHOICES: { v: Ynna; label: string }[] = [{ v: 'yes', label: 'Yes' }, { v: 'no', label: 'No' }, { v: 'na', label: 'N/A' }]
const REPORT_SECTIONS = RECR.sections.slice(1)

/** The condition report, one section of the state form at a time. */
function ReportStep({ value, onChange, problems, onBack, onNext }: {
  value: RecrAnswers; onChange: (v: RecrAnswers) => void; problems: string[]; onBack: () => void; onNext: () => void
}) {
  const firstOpen = REPORT_SECTIONS.findIndex((s) => s.items.some((i) => i.kind === 'ynna' && !value.answers[i.id]))
  const [si, setSi] = useState(firstOpen < 0 ? 0 : firstOpen)
  useEffect(() => { window.scrollTo?.({ top: 0 }) }, [si])
  const s = REPORT_SECTIONS[si]
  const answered = RECR_QUESTIONS.filter((q) => value.answers[q.id]).length
  const qs = s.items.filter((i) => i.kind === 'ynna')
  const open = qs.filter((q) => !value.answers[q.id])
  const anyYes = qs.some((q) => value.answers[q.id] === 'yes')
  const explain = s.items.find((i) => i.kind === 'explain')
  const years = s.items.filter((i) => i.kind === 'years')
  const yearsOk = years.every((y) => /^\d{1,3}(\.\d)?$/.test((value.years[y.id] ?? '').trim()))
  const sectionOk = open.length === 0 && (!anyYes || !explain || (value.explain[explain.id] ?? '').trim() !== '') && yearsOk
  const last = si === REPORT_SECTIONS.length - 1
  const set = (id: string, v: Ynna) => onChange({ ...value, answers: { ...value.answers, [id]: v } })
  const restNo = () => onChange({ ...value, answers: { ...value.answers, ...Object.fromEntries(open.map((q) => [q.id, 'no' as Ynna])) } })
  const hint = open.length ? `${open.length} left in this section` : anyYes && explain && !(value.explain[explain.id] ?? '').trim() ? 'Explain each Yes below'
    : !yearsOk ? 'Fill in the years' : last && problems.length ? problems[0] : ''

  return (
    <div className="offer-step space-y-4">
      <section className="rounded-3xl border border-border/70 bg-card p-5">
        <h2 className="text-lg font-semibold">Real Estate Condition Report</h2>
        <p className="mt-1 text-sm text-muted-foreground">
          Wisconsin law (Wis. Stat. 709.02) asks the owner to answer every question as Yes, No, or N/A, and to explain every Yes.
          &ldquo;Aware&rdquo; means you have notice or knowledge. This is a disclosure, not a warranty.
        </p>
        <div className="mt-3 flex items-center gap-3">
          <div className="h-2 flex-1 overflow-hidden rounded-full bg-muted" role="progressbar" aria-valuemin={0} aria-valuemax={RECR_QUESTIONS.length} aria-valuenow={answered}>
            <div className="h-full rounded-full bg-emerald-500 transition-all" style={{ width: `${(answered / RECR_QUESTIONS.length) * 100}%` }} />
          </div>
          <span className="text-sm font-medium tabular-nums">{answered} of {RECR_QUESTIONS.length}</span>
        </div>
        <details className="mt-3 text-sm">
          <summary className="cursor-pointer font-medium">Definitions and notices (A1-A6)</summary>
          <div className="mt-2 space-y-2 text-muted-foreground">
            {RECR.sections[0].items.map((i) => <p key={i.id}>{i.id}. {i.text}</p>)}
          </div>
        </details>
      </section>

      <fieldset key={s.id} className="offer-step min-w-0 space-y-3 [overflow-wrap:anywhere]">
        <legend className="sr-only">{s.id}. {s.title}</legend>
        <div className="flex items-end justify-between gap-3 px-1">
          <div>
            <p className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">Section {si + 1} of {REPORT_SECTIONS.length}</p>
            <h3 className="text-lg font-bold leading-tight">{s.title.charAt(0) + s.title.slice(1).toLowerCase()}</h3>
          </div>
          {open.length > 0 && (
            <button type="button" onClick={restNo} className="shrink-0 rounded-full border border-border bg-card px-3 py-2 text-sm font-semibold shadow-[var(--shadow-soft)] hover:border-primary/40">
              No to {open.length === qs.length ? `all ${qs.length}` : `the other ${open.length}`}
            </button>
          )}
        </div>
        {s.items.map((i) => {
          if (i.kind === 'note') return <p key={i.id} className="px-1 text-sm text-muted-foreground">{i.text}</p>
          if (i.kind === 'ynna') {
            const v = value.answers[i.id]
            return (
              <div key={i.id} role="radiogroup" aria-label={i.id}
                className={cn('rounded-2xl border bg-card p-4 transition-colors', v === 'yes' ? 'border-amber-300 bg-amber-50/50' : v ? 'border-border/60' : 'border-primary/40 shadow-[var(--shadow-soft)]')}>
                <p className="text-sm"><span className="font-semibold">{i.id}.</span> {i.text}</p>
                {i.hint && <p className="mt-1 text-xs text-muted-foreground">{i.hint}</p>}
                <div className="mt-3 grid grid-cols-3 gap-2">
                  {CHOICES.map((c) => (
                    <button key={c.v} type="button" role="radio" aria-checked={v === c.v} onClick={() => set(i.id, c.v)}
                      className={cn('h-12 rounded-xl border text-base font-semibold transition-all active:scale-[0.97]',
                        v === c.v ? (c.v === 'yes' ? 'border-amber-500 bg-amber-500 text-white' : 'border-primary bg-primary text-primary-foreground') : 'border-border bg-background hover:border-primary/40')}>
                      {c.label}
                    </button>
                  ))}
                </div>
              </div>
            )
          }
          if (i.kind === 'explain') {
            return (
              <label key={i.id} className={cn('block rounded-2xl border bg-card p-4 text-sm font-semibold', anyYes ? 'border-amber-300' : 'border-border/60')}>
                {i.id}. Explain each &ldquo;yes&rdquo; above{anyYes ? ' (required)' : ' (only if you answered Yes)'}
                <Textarea value={value.explain[i.id] ?? ''} rows={3} className="mt-2 font-normal"
                  onChange={(e) => onChange({ ...value, explain: { ...value.explain, [i.id]: e.target.value } })} />
              </label>
            )
          }
          return (
            <label key={i.id} className="flex items-center justify-between gap-3 rounded-2xl border border-border/60 bg-card p-4 text-sm">
              <span>{i.id}. {i.text.replace(' ___ years.', '')} (years)</span>
              <Input inputMode="decimal" className="h-12 w-24 text-base" value={value.years[i.id] ?? ''}
                onChange={(e) => onChange({ ...value, years: { ...value.years, [i.id]: e.target.value } })} />
            </label>
          )
        })}
        {last && <p className="px-1 text-xs text-muted-foreground">{RECR.certification}</p>}
      </fieldset>

      <Bar>
        <Button variant="outline" className="h-14" onClick={() => (si === 0 ? onBack() : setSi(si - 1))}><ArrowLeft className="h-5 w-5" aria-hidden />Back</Button>
        <div className="min-w-0 flex-1">
          <Button className="h-14 w-full text-lg" disabled={!sectionOk || (last && problems.length > 0)} onClick={() => (last ? onNext() : setSi(si + 1))}>
            {last ? 'Continue to sign' : 'Next section'}<ArrowRight className="h-5 w-5" aria-hidden />
          </Button>
          {hint && <p className="mt-1 truncate text-center text-xs text-muted-foreground">{hint}</p>}
        </div>
      </Bar>
    </div>
  )
}

function RecrDone({ recr, who, phone }: { recr: RecrAnswers; who: string; phone: string }) {
  const yes = RECR_QUESTIONS.filter((q) => recr.answers[q.id] === 'yes')
  const explains = Object.entries(recr.explain ?? {}).filter(([, v]) => v?.trim())
  return (
    <div className="mt-2 space-y-2 text-sm">
      <p>Another owner has filled in the condition report. By signing, you certify it too. Read it before you sign:</p>
      {yes.length === 0 ? <p>Every question was answered No or N/A.</p> : (
        <ul className="list-disc pl-5">{yes.map((q) => <li key={q.id}><strong>{q.id} Yes:</strong> {q.text}</li>)}</ul>
      )}
      {explains.map(([k, v]) => <p key={k}><strong>{k}:</strong> {v}</p>)}
      <p>Owned {recr.years?.G6 ?? '?'} years; lived there {recr.years?.G7 ?? '?'} years.</p>
      <p className="text-muted-foreground">If anything is wrong, do not sign: call {firstName(who)} at {phone}.</p>
    </div>
  )
}
