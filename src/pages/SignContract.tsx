import { useEffect, useMemo, useRef, useState } from 'react'
import { useParams } from 'react-router-dom'
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
    bindingDeadline: string; inspection: boolean; inspectionDays?: number; proofOfFundsDays?: number; included?: string; additional?: string }
  signer: { name: string; position: number; signed_at: string | null }
  others: { name: string; signed: boolean }[]; offer_url: string; final_url: string | null
}

const usd = (n: number) => n.toLocaleString('en-US', { style: 'currency', currency: 'USD', maximumFractionDigits: n % 1 ? 2 : 0 })

function loadDraft(key: string): RecrAnswers {
  try {
    const v = JSON.parse(localStorage.getItem(key) ?? 'null') as RecrAnswers | null
    return v && v.answers ? { answers: v.answers, explain: v.explain ?? {}, years: v.years ?? {} } : emptyRecr()
  } catch {
    return emptyRecr()
  }
}

// The seller's page. No login: the private link is the key. Plain words first, the full PDF one tap away.
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

  return (
    <div className="mx-auto min-h-dvh max-w-2xl space-y-4 bg-background p-4 pb-24 text-base">
      <header className="flex items-center gap-2 border-b pb-3">
        <img src="/icon.svg" alt="" className="h-8 w-8" />
        <div>
          <p className="font-semibold">Offer to purchase</p>
          <p className="text-sm text-muted-foreground">Sent by Colin Merrill, (262) 999-6513</p>
        </div>
      </header>
      {!view && !error && <p>Loading...</p>}
      {error && <p className="rounded-md bg-red-50 p-3 text-red-800">{error}</p>}
      {view && <Signing view={view} token={token} onSigned={(v) => setView(v)} />}
    </div>
  )
}

function Signing({ view, token, onSigned }: { view: View; token: string; onSigned: (v: View) => void }) {
  const t = view.terms
  const draftKey = `recr-draft-${view.contract_id}`
  const needRecr = view.include_recr && !view.recr
  const [recr, setRecr] = useState<RecrAnswers>(() => (needRecr ? loadDraft(draftKey) : emptyRecr()))
  const [consent, setConsent] = useState(false)
  const [agree, setAgree] = useState(false)
  const [name, setName] = useState(view.signer.name)
  const [sig, setSig] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [msg, setMsg] = useState<string | null>(null)
  const [done, setDone] = useState<{ allSigned: boolean; finalUrl: string | null } | null>(null)

  useEffect(() => {
    if (!needRecr) return
    try { localStorage.setItem(draftKey, JSON.stringify(recr)) } catch { /* private mode */ }
  }, [recr, needRecr, draftKey])

  const problems = useMemo(() => (needRecr ? recrProblems(recr) : []), [recr, needRecr])
  const answered = RECR_QUESTIONS.filter((q) => recr.answers[q.id]).length

  if (view.signer.signed_at || done) {
    const finalUrl = done?.finalUrl ?? view.final_url
    const waiting = view.others.filter((o) => !o.signed).map((o) => o.name)
    return (
      <section className="space-y-3 rounded-lg border bg-card p-4">
        <h1 className="text-2xl font-bold tracking-tight">Signed. Thank you.</h1>
        {finalUrl ? (
          <>
            <p>Everyone has signed. Here is your copy of the signed offer{view.include_recr ? ' and condition report' : ''}:</p>
            <a href={finalUrl} target="_blank" rel="noreferrer" className="inline-flex h-12 items-center rounded-md bg-primary px-5 font-medium text-primary-foreground">
              Download the signed PDF
            </a>
          </>
        ) : (
          <p>{waiting.length ? `Waiting for ${waiting.join(' and ')} to sign.` : 'Finishing up.'} Keep this link: your signed copy will be here once everyone has signed.</p>
        )}
        <p className="text-sm text-muted-foreground">Questions? Call or text Colin at (262) 999-6513.</p>
      </section>
    )
  }

  const sign = async () => {
    setBusy(true)
    setMsg(null)
    const r = await api.contractSign({ action: 'sign', token, consent, name, signature: sig, recr: needRecr ? recr : null })
    setBusy(false)
    if (!r.ok) { setMsg(r.reason ?? 'Could not sign. Try again.'); return }
    try { localStorage.removeItem(draftKey) } catch { /* ignore */ }
    setDone({ allSigned: Boolean(r.allSigned), finalUrl: (r.finalUrl as string | null) ?? null })
    if (r.allSigned) onSigned({ ...view, signer: { ...view.signer, signed_at: new Date().toISOString() }, final_url: (r.finalUrl as string | null) ?? null })
  }

  return (
    <>
      <section className="space-y-2 rounded-lg border bg-card p-4">
        <h1 className="text-2xl font-bold tracking-tight">{t.street}, {t.muniName}</h1>
        <p>{view.buyer_name} offers to buy this property on these main terms:</p>
        <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1">
          <dt className="text-muted-foreground">Price</dt><dd className="font-semibold">{usd(t.price)}</dd>
          <dt className="text-muted-foreground">Closing</dt><dd>{t.closing}</dd>
          <dt className="text-muted-foreground">Earnest money</dt><dd>{usd(t.earnestMoney)}, held by {t.earnestHolder}</dd>
          <dt className="text-muted-foreground">Inspection</dt><dd>{t.inspection ? `Yes, within ${t.inspectionDays ?? 15} days` : 'No inspection contingency'}</dd>
          <dt className="text-muted-foreground">Financing</dt><dd>No financing contingency. Proof of funds within {t.proofOfFundsDays ?? 7} days.</dd>
          <dt className="text-muted-foreground">Accept by</dt><dd>{t.bindingDeadline}</dd>
        </dl>
        <p className="text-sm text-muted-foreground">This summary is for convenience. The full Offer (the Wisconsin WB-11 form) is what you sign.</p>
        <a href={view.offer_url} target="_blank" rel="noreferrer" className="inline-flex h-12 items-center rounded-md border px-4 font-medium underline">
          Read the full Offer (PDF)
        </a>
        {view.others.length > 0 && (
          <p className="text-sm">Also signing: {view.others.map((o) => `${o.name}${o.signed ? ' (signed)' : ''}`).join(', ')}.</p>
        )}
      </section>

      <section className="space-y-2 rounded-lg border bg-card p-4">
        <h2 className="text-lg font-semibold">1. Signing electronically</h2>
        <p className="text-sm">
          You can sign this offer on this page instead of on paper. Your electronic signature means the same as signing by hand
          (Wisconsin Statutes chapter 137). You can ask Colin for a paper copy at any time, at no cost, and you can choose to sign
          on paper instead: just do not sign here and tell Colin. You need a device that can open a PDF; you will get the signed
          PDF on this page when everyone has signed.
        </p>
        <label className="flex items-start gap-3 rounded-md bg-muted p-3">
          <input type="checkbox" className="mt-1 h-5 w-5" checked={consent} onChange={(e) => setConsent(e.target.checked)} />
          <span>I agree to use electronic records and signatures for this offer.</span>
        </label>
      </section>

      {view.include_recr && (
        <section className="space-y-3 rounded-lg border bg-card p-4">
          <h2 className="text-lg font-semibold">2. Real Estate Condition Report</h2>
          {needRecr ? (
            <RecrForm value={recr} onChange={setRecr} answered={answered} />
          ) : (
            <RecrDone recr={view.recr!} />
          )}
        </section>
      )}

      <section className="space-y-3 rounded-lg border bg-card p-4">
        <h2 className="text-lg font-semibold">{view.include_recr ? '3' : '2'}. Sign</h2>
        <label className="block text-sm font-medium">Your full legal name
          <Input value={name} onChange={(e) => setName(e.target.value)} className="mt-1 h-12" autoComplete="name" />
        </label>
        <SignaturePad onChange={setSig} />
        <label className="flex items-start gap-3 rounded-md bg-muted p-3">
          <input type="checkbox" className="mt-1 h-5 w-5" checked={agree} onChange={(e) => setAgree(e.target.checked)} />
          <span>
            I have read the Offer{view.include_recr ? ' and the Condition Report' : ''}. I accept the Offer and sign it
            {view.include_recr ? ', and I certify the Condition Report is true and correct to the best of my knowledge' : ''}.
          </span>
        </label>
        {problems.length > 0 && <ul className="list-disc pl-5 text-sm text-amber-800">{problems.map((p) => <li key={p}>{p}</li>)}</ul>}
        <Button className="h-14 w-full text-lg" disabled={busy || !consent || !agree || !name.trim() || problems.length > 0} onClick={() => void sign()}>
          {busy ? 'Signing...' : 'Accept and sign'}
        </Button>
        {msg && <p className="rounded-md bg-red-50 p-3 text-sm text-red-800">{msg}</p>}
      </section>
    </>
  )
}

const CHOICES: { v: Ynna; label: string }[] = [{ v: 'yes', label: 'Yes' }, { v: 'no', label: 'No' }, { v: 'na', label: 'N/A' }]

function RecrForm({ value, onChange, answered }: { value: RecrAnswers; onChange: (v: RecrAnswers) => void; answered: number }) {
  const set = (id: string, v: Ynna) => onChange({ ...value, answers: { ...value.answers, [id]: v } })
  return (
    <div className="space-y-4">
      <p className="text-sm">
        Wisconsin law (Wis. Stat. 709.02) asks the owner to answer every question below as Yes, No, or N/A, and to explain every
        Yes. &ldquo;Aware&rdquo; means you have notice or knowledge. This is not a warranty. {answered} of {RECR_QUESTIONS.length} answered.
      </p>
      <details className="text-sm">
        <summary className="cursor-pointer font-medium">Definitions and notices (A1-A6)</summary>
        <div className="mt-2 space-y-2 text-muted-foreground">
          {RECR.sections[0].items.map((i) => <p key={i.id}>{i.id}. {i.text}</p>)}
        </div>
      </details>
      {RECR.sections.slice(1).map((s) => {
        const anyYes = s.items.some((i) => i.kind === 'ynna' && value.answers[i.id] === 'yes')
        return (
          <fieldset key={s.id} className="min-w-0 space-y-3 border-t pt-3 [overflow-wrap:anywhere]">
            <legend className="text-base font-semibold">{s.id}. {s.title}</legend>
            {s.items.map((i) => {
              if (i.kind === 'note') return <p key={i.id} className="text-sm text-muted-foreground">{i.text}</p>
              if (i.kind === 'ynna') {
                return (
                  <div key={i.id} role="radiogroup" aria-label={i.id}>
                    <p className="text-sm"><span className="font-semibold">{i.id}.</span> {i.text}</p>
                    {i.hint && <p className="text-xs text-muted-foreground">{i.hint}</p>}
                    <div className="mt-1 grid grid-cols-3 gap-2">
                      {CHOICES.map((c) => (
                        <button key={c.v} type="button" role="radio" aria-checked={value.answers[i.id] === c.v} onClick={() => set(i.id, c.v)}
                          className={cn('h-11 rounded-md border text-sm font-medium',
                            value.answers[i.id] === c.v ? 'border-primary bg-primary text-primary-foreground' : 'bg-background')}>
                          {c.label}
                        </button>
                      ))}
                    </div>
                  </div>
                )
              }
              if (i.kind === 'explain') {
                return (
                  <label key={i.id} className="block text-sm font-medium">
                    {i.id}. Explain each &ldquo;yes&rdquo; above{anyYes ? ' (required)' : ''}
                    <Textarea value={value.explain[i.id] ?? ''} rows={3} className="mt-1"
                      onChange={(e) => onChange({ ...value, explain: { ...value.explain, [i.id]: e.target.value } })} />
                  </label>
                )
              }
              return (
                <label key={i.id} className="flex items-center justify-between gap-3 text-sm">
                  <span>{i.id}. {i.text.replace(' ___ years.', '')} (years)</span>
                  <Input inputMode="decimal" className="h-11 w-24" value={value.years[i.id] ?? ''}
                    onChange={(e) => onChange({ ...value, years: { ...value.years, [i.id]: e.target.value } })} />
                </label>
              )
            })}
          </fieldset>
        )
      })}
      <p className="text-xs text-muted-foreground">{RECR.certification}</p>
    </div>
  )
}

function RecrDone({ recr }: { recr: RecrAnswers }) {
  const yes = RECR_QUESTIONS.filter((q) => recr.answers[q.id] === 'yes')
  const explains = Object.entries(recr.explain ?? {}).filter(([, v]) => v?.trim())
  return (
    <div className="space-y-2 text-sm">
      <p>Another owner has filled in the condition report. By signing, you certify it too. Read it before you sign:</p>
      {yes.length === 0 ? <p>Every question was answered No or N/A.</p> : (
        <ul className="list-disc pl-5">{yes.map((q) => <li key={q.id}><strong>{q.id} Yes:</strong> {q.text}</li>)}</ul>
      )}
      {explains.map(([k, v]) => <p key={k}><strong>{k}:</strong> {v}</p>)}
      <p>Owned {recr.years?.G6 ?? '?'} years; lived there {recr.years?.G7 ?? '?'} years.</p>
      <p className="text-muted-foreground">If anything is wrong, do not sign: call Colin at (262) 999-6513.</p>
    </div>
  )
}
