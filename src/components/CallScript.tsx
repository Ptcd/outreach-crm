import { Fragment, useEffect, useMemo, useState } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge, Select, Textarea } from '@/components/ui/form'
import { ConfirmButton } from '@/components/ui/confirm'
import { api, useOfferSettings } from '@/lib/queries'
import { fmtDateTime, fmtPhone, isoToLocalInput, localInputToIso, todayLocal } from '@/lib/format'
import { CALL_OUTCOMES, NEXT_STEP, PHONE_SCRIPT, callScript, clearlyHot, scriptLine, type CallQuestion } from '@/lib/callScript'
import { answerOf, answerText, gateFromCall, stopsFromCall, type CallFacts, type CallValue } from '@/lib/callGate'
import { bookingVerdict, type BookingVerdict } from '@/lib/bookingVerdict'
import { VerdictBox } from '@/components/BookingVerdict'
import { DECISION_LABEL, GATE_ITEMS, HARD_STOPS, SELLER_FACTS, STAGE_LABEL } from '@/lib/wpie'
import { cn } from '@/lib/utils'
import { OddHourHint } from '@/components/OddHourHint'
import { useAuth } from '@/providers/AuthProvider'
import { useOnPhone, workerFor } from '@/lib/onPhone'
import type { Contact, GateScore, Lead, Message } from '@/lib/types'

const LABELS: Record<string, string> = Object.fromEntries(
  [...callScript(), { ...NEXT_STEP, qid: 'booking', gate: [], say: [] } as CallQuestion].flatMap((q) => (q.choices ?? []).map((c) => [c.id, c.label])))

const title = (s: string) => s.toLowerCase().replace(/\b([a-z])/g, (m) => m.toUpperCase())
const ENTITY = /\b(LLC|INC|TRUST|ESTATE|CORP|COMPANY|PROPERTIES|HOLDINGS|BANK|CHURCH)\b/i

/** Names for the script's {placeholders}: the street, the owner's first name, the signer. */
function scriptVars(lead: Lead, facts: CallFacts, caller = 'thalia'): Record<string, string> {
  const street = (lead.property_address ?? '').replace(/,.*$/, '').trim()
  const first = ENTITY.test(lead.owner_name) || /^New caller/.test(lead.owner_name) ? '' : title(lead.owner_name.split(/\s+/)[0] ?? '')
  const dm = answerOf(facts, 'decision_makers')?.text?.trim()
  return { street: street ? title(street) : 'the property', first_name: first || 'there', signer: dm || 'everyone who signs',
    day: answerOf(facts, 'next_step')?.when ? new Date(answerOf(facts, 'next_step')!.when!).toLocaleDateString('en-US', { weekday: 'long', timeZone: 'America/Chicago' }) : 'tomorrow',
    time: answerOf(facts, 'next_step')?.when ? new Date(answerOf(facts, 'next_step')!.when!).toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit', timeZone: 'America/Chicago' }) : '{a time that works}',
    caller: caller.charAt(0).toUpperCase() + caller.slice(1) }
}

// Read top to bottom while on the phone: what we already know, then each question to ask with the
// exact words and one-tap answers (saved to the lead as you tap), then the close the card decided on
// (book / one more call / not ready; src/lib/bookingVerdict.ts), then "log this call". Only Colin
// (canOverride) can book a walk-through the card did not earn.
export function CallScript({ lead, contacts, messages, replyFacts, latestGate, phone, startOpen, canOverride, onLogged }: {
  lead: Lead; contacts: Contact[]; messages: Message[]; replyFacts: Record<string, unknown>; latestGate: GateScore | null
  phone: string | null; startOpen: boolean; canOverride?: boolean
  onLogged?: (outcome: string) => void     // the call queue: a logged call finishes the task and brings the next card
}) {
  const { member } = useAuth()
  const [picked] = useOnPhone()
  const caller = workerFor(member, picked) ?? 'colin'
  const qc = useQueryClient()
  const [open, setOpen] = useState(startOpen)
  useEffect(() => { if (startOpen) setOpen(true) }, [startOpen])   // the panel's "open the script" tap
  const [facts, setFacts] = useState<CallFacts>(() => (lead.call_facts ?? {}) as CallFacts)
  const [err, setErr] = useState<string | null>(null)
  useEffect(() => setFacts((lead.call_facts ?? {}) as CallFacts), [lead.call_facts])

  const save = async (key: string, value: CallValue | null) => {
    setFacts((f) => {
      const n = { ...f }
      if (value) n[key] = { value, at: new Date().toISOString() }
      else delete n[key]
      return n
    })
    setErr(null)
    const r = await api.callAnswer(lead.id, key, value)
    const d = r.data as { ok: boolean; reason?: string } | null
    if (r.error || !d?.ok) setErr(r.error?.message ?? d?.reason ?? 'Not saved')
    void qc.invalidateQueries({ queryKey: ['lead', lead.id] })
  }

  const hints = useMemo(() => gateFromCall(facts, replyFacts), [facts, replyFacts])
  const stops = useMemo(() => stopsFromCall(facts), [facts])
  const verdict = useMemo(() => bookingVerdict(facts, replyFacts, lead), [facts, replyFacts, lead])
  const opener = messages.find((m) => m.is_opener && m.direction === 'out')
  const replies = messages.filter((m) => m.direction === 'in' && m.channel === 'sms')
  const known = SELLER_FACTS.map((f) => ({ ...f, v: replyFacts[f.id] })).filter((f) => typeof f.v === 'string' && (f.v as string).trim())
  const vars = scriptVars(lead, facts, caller)
  // which call this is (the packet's three): they called us just now, they texted us, or a cold call
  const callKind: CallKind = messages.some((m) => m.channel === 'call' && m.direction === 'in' && Date.now() - new Date(m.sent_at).getTime() < 3 * 3600_000)
    ? 'inbound' : replies.length > 0 ? 'hot_text' : 'cold'
  const hot = clearlyHot(facts as never)
  const questions = callScript(vars)
  const answered = questions.filter((q) => answerOf(facts, q.id)).length
  // the exit anchor (0149): off unless Colin turned it on in Settings
  const offer = useOfferSettings()
  const anchorMode = offer.data?.mode ?? 'off'

  if (!open) {
    return (
      <Button className="h-12 w-full text-base" onClick={() => setOpen(true)}>
        On a call? Open the call script{answered ? ` (${answered} of ${questions.length} answered)` : ''}
      </Button>
    )
  }

  return (
    <section id="call-script" className="space-y-3 rounded-lg border-2 border-primary/40 bg-card p-3">
      <div className="flex items-center justify-between gap-2">
        <h2 className="text-lg font-semibold">Call script</h2>
        <Button variant="ghost" size="sm" onClick={() => setOpen(false)}>Hide</Button>
      </div>
      {phone && <p className="text-sm">Calling from <strong>{fmtPhone(phone)}</strong>{lead.property_address ? ` - ${lead.property_address}` : ''}</p>}

      <div className="rounded-md bg-muted p-3">
        <p className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">{CALL_KIND_LABEL[callKind]}: open with</p>
        <p className="mt-1 text-lg font-semibold">&ldquo;{pickupLine(caller, callKind, vars)}&rdquo;</p>
        <p className="text-sm text-muted-foreground">{PHONE_SCRIPT.voice}</p>
        {caller !== 'colin' && <details className="mt-1 text-sm">
          <summary className="cursor-pointer text-muted-foreground">The other openers</summary>
          <ul className="mt-1 space-y-1">
            {(['hot_text', 'inbound', 'cold'] as CallKind[]).filter((k) => k !== callKind).map((k) => (
              <li key={k}><span className="font-medium">{CALL_KIND_LABEL[k]}:</span> &ldquo;{pickupLine(caller, k, vars)}&rdquo;</li>
            ))}
          </ul>
        </details>}
      </div>
      {caller === 'colin' && (
        <details className="rounded-md border p-3">
          <summary className="cursor-pointer font-semibold">Before you pick up</summary>
          <ul className="mt-2 list-disc space-y-1 pl-5 text-sm">{PHONE_SCRIPT.before_pickup.map((l) => <li key={l}>{l}</li>)}</ul>
        </details>
      )}

      <details open className="rounded-md border p-3">
        <summary className="cursor-pointer font-semibold">What we already know</summary>
        <div className="mt-2 space-y-2 text-sm">
          <p><strong>{lead.owner_name}</strong>{lead.property_address ? `, ${lead.property_address}` : ''}{lead.municipality ? `, ${lead.municipality}` : ''}
            {' '}- {STAGE_LABEL[lead.stage]}{lead.lane ? `, ${lead.lane} lane` : ''}</p>
          {lead.reasons_to_sell.length > 0 && <p className="text-muted-foreground">Why they are on the list (never say this to them): {lead.reasons_to_sell.join(', ')}</p>}
          {opener ? (
            <div><p className="font-medium">Our text, {fmtDateTime(opener.sent_at)}:</p><p className="rounded bg-muted p-2">{opener.body}</p></div>
          ) : <p className="text-muted-foreground">We have not texted this owner.</p>}
          {replies.slice(-3).map((m) => (
            <div key={m.id}><p className="font-medium">They texted, {fmtDateTime(m.sent_at)}:</p><p className="rounded bg-blue-50 p-2">{m.body}</p></div>
          ))}
          {known.length > 0 && (
            <div>
              <p className="font-medium">From their texts:</p>
              <ul className="list-disc pl-5">{known.map((f) => <li key={f.id}>{f.label}: {String(f.v)}</li>)}</ul>
            </div>
          )}
          {latestGate && <p>Gate last scored {latestGate.total}/12: {DECISION_LABEL[latestGate.decision]}.</p>}
          {facts.last_call && <p>Last call: {LABEL_OUTCOME[String(facts.last_call.value)] ?? String(facts.last_call.value)}, {fmtDateTime(facts.last_call.at)}{facts.last_call.by ? ` (${facts.last_call.by})` : ''}.</p>}
        </div>
      </details>

      <ol className="space-y-3">
        {questions.map((q, i) => (
          <Fragment key={q.qid}>
            <QuestionCard n={i + 1} q={q} facts={facts} replyFacts={replyFacts} onSave={save} showGates={caller === 'colin'} />
            {q.id === 'price' && anchorMode !== 'off' && (
              <AnchorCard lead={lead} facts={facts} mode={anchorMode} onSaid={(v) => {
                setFacts((f) => ({ ...f, our_number: { value: v, at: new Date().toISOString() } }))
                void qc.invalidateQueries({ queryKey: ['lead', lead.id] })
              }} />
            )}
          </Fragment>
        ))}
      </ol>
      {err && <p className="rounded bg-red-50 p-2 text-sm text-red-800">Not saved: {err}</p>}

      <details className="rounded-md border p-3">
        <summary className="cursor-pointer font-semibold">If they say... ({PHONE_SCRIPT.objections.length} answers)</summary>
        <ul className="mt-2 space-y-1">
          {PHONE_SCRIPT.objections.map((o) => (
            <li key={o.id}>
              <details className="rounded-md bg-muted/60 p-2">
                <summary className="min-h-9 cursor-pointer text-sm font-medium">{o.trigger}</summary>
                <p className="mt-1 text-base leading-snug">&ldquo;{scriptLine(o, vars).say}&rdquo;</p>
                {o.note && <p className="mt-1 text-xs text-muted-foreground">{o.note}</p>}
              </details>
            </li>
          ))}
        </ul>
      </details>

      {caller === 'colin' && <VerdictBox v={verdict} />}
      <Close verdict={verdict} hot={hot} vars={vars} facts={facts} replyFacts={replyFacts} onSave={save} canOverride={!!canOverride} />

      {caller === 'colin' && <details className="rounded-md border p-3">
        <summary className="cursor-pointer font-semibold">Gate items this call settles</summary>
        <ul className="mt-1 space-y-1 text-sm">
          {GATE_ITEMS.map((g) => {
            const h = hints[g.id]
            return (
              <li key={g.id} className="flex items-start gap-2">
                <span className={cn('mt-0.5 inline-flex h-5 w-5 shrink-0 items-center justify-center rounded-full text-xs font-bold',
                  h ? 'bg-emerald-600 text-white' : 'bg-muted text-muted-foreground')}>{h ? '✓' : ''}</span>
                <span>{g.label}{h ? `: ${h.score} - ${h.why}` : g.id === 'numbers_close' ? ': Colin decides (his own number)' : ': not yet'}</span>
              </li>
            )
          })}
          {stops.map((s) => <li key={s} className="font-medium text-red-700">Hard stop: {HARD_STOPS.find((h) => h.id === s)?.label ?? s}</li>)}
        </ul>
        <p className="mt-1 text-xs text-muted-foreground">These fill in Colin&apos;s score on the card; the booking decision above is the card&apos;s.</p>
      </details>}

      <LogCall lead={lead} contacts={contacts} phone={phone} onLogged={onLogged}
        voicemailLine={`Hi ${vars.first_name}, it's ${vars.caller}. I had a quick question about the place on ${vars.street}. Give me a call when you get a minute.`} />
    </section>
  )
}

const LABEL_OUTCOME: Record<string, string> = Object.fromEntries(CALL_OUTCOMES.map((o) => [o.id, o.label]))

type Shot = {
  ok: boolean; reason?: string; mode: string; number?: number; say?: string; value?: number; value_basis?: string
  sqft?: number; sqft_basis?: string; tier?: string; tier_basis?: string; repairs?: number; pct?: number; mao?: number; lao?: number; their_number?: string | null
}
const REACTIONS = [
  { id: 'gave_number', label: 'They said a number' }, { id: 'open', label: 'Open to it' }, { id: 'no', label: 'No / hung up' }, { id: 'later', label: 'Later' },
]
const REACTION_LABEL: Record<string, string> = Object.fromEntries(REACTIONS.map((r) => [r.id, r.label]))
const dollars = (n: number) => '$' + Math.round(n).toLocaleString('en-US')

/** The exit anchor (migration 0149; Colin 2026-10-30). For a seller who has refused a number twice, said "make me an
 *  offer", or is leaving, the one low, non-firm figure the caller may say so the seller names their own. The figure is
 *  the database's arithmetic on the county's value and the condition answers, never the caller's guess; the caller
 *  logs what the seller said back. In exit-only mode the card stays folded until the seller has refused or is going. */
function AnchorCard({ lead, facts, mode, onSaid }: { lead: Lead; facts: CallFacts; mode: string; onSaid: (v: CallValue) => void }) {
  const theirs = answerOf(facts, 'price')
  const leaving = !!theirs?.choices?.some((c) => ['refused', 'refused_once', 'make_offer'].includes(c))
  const said = facts.our_number?.value as (CallValue & { counter?: number | null }) | undefined
  const [open, setOpen] = useState(mode === 'live' || leaving)
  useEffect(() => { if (leaving) setOpen(true) }, [leaving])
  const inputs = JSON.stringify([facts.condition?.value, facts.happened?.value, facts.layout?.value])
  const shot = useQuery({
    queryKey: ['offer_shot', lead.id, inputs],
    queryFn: async () => { const r = await api.offerShoot(lead.id); if (r.error) throw r.error; return r.data as Shot },
    enabled: open && !said,
  })
  const [reaction, setReaction] = useState('')
  const [counter, setCounter] = useState('')
  const [note, setNote] = useState('')
  const [err, setErr] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  if (said) return (
    <li className="rounded-md border border-emerald-300 bg-emerald-50/40 p-3">
      <p className="font-semibold">The anchor <Badge tone="good">Said</Badge></p>
      <p className="text-sm">Around {dollars(Number(said.number))}, non-firm. They: {REACTION_LABEL[said.choices?.[0] ?? ''] ?? said.choices?.[0]}
        {said.counter ? `, ${dollars(Number(said.counter))}` : ''}{said.text ? ` (${said.text})` : ''}.</p>
    </li>
  )
  if (!open) return (
    <li className="rounded-md border border-dashed p-3">
      <Button variant="outline" className="h-auto min-h-11 w-full whitespace-normal py-2" onClick={() => setOpen(true)}>
        They won&apos;t say a number, or they&apos;re leaving? Open the anchor
      </Button>
    </li>
  )
  const d = shot.data
  const sayIt = async () => {
    if (!d?.ok || d.number == null || !reaction) return
    setBusy(true); setErr(null)
    const c = reaction === 'gave_number' ? Number(counter.replace(/[^0-9.]/g, '')) : null
    const r = await api.offerSaid(lead.id, d.number, reaction, c, note.trim() || null)
    const res = r.data as { ok?: boolean; reason?: string } | null
    setBusy(false)
    if (r.error || !res?.ok) { setErr(r.error?.message ?? res?.reason ?? 'Not saved'); return }
    onSaid({ number: String(d.number), choices: [reaction], text: note.trim() || undefined, ...(c ? { counter: c } : {}) } as CallValue)
  }
  return (
    <li className="rounded-md border-2 border-amber-400 p-3">
      <div className="flex items-start justify-between gap-2">
        <p className="font-semibold">The anchor: one low number, non-firm, so they say theirs</p>
        <Badge tone="warn">Only if they won&apos;t</Badge>
      </div>
      {shot.isLoading && <p className="mt-1 text-sm text-muted-foreground">Working it out from the county&apos;s value and what they said…</p>}
      {shot.error && <p className="mt-1 text-sm text-red-700">Could not work it out: {String((shot.error as Error).message)}</p>}
      {d && !d.ok && <p className="mt-1 text-sm text-muted-foreground">No number to say: {d.reason}. Ask for theirs once more, then book Colin.</p>}
      {d?.ok && (
        <div className="mt-2 space-y-2">
          <p className="rounded-md bg-muted p-2 text-base leading-snug">&ldquo;{d.say}&rdquo;</p>
          <p className="text-xs text-muted-foreground">
            {dollars(d.value ?? 0)} ({d.value_basis}), {d.tier} repairs about {dollars(d.repairs ?? 0)} ({d.sqft} sq ft, {d.sqft_basis}; {d.tier_basis}),
            times {Math.round((d.pct ?? 0) * 100)}% = {dollars(d.mao ?? 0)}; the anchor sits under that. Say only {dollars(d.number ?? 0)}, and say it is rough.
          </p>
          <p className="text-sm font-medium">What they said back</p>
          <div className="grid grid-cols-2 gap-2">
            {REACTIONS.map((r) => (
              <button key={r.id} type="button" aria-pressed={reaction === r.id} onClick={() => setReaction(r.id)}
                className={cn('min-h-11 rounded-md border px-2 py-2 text-sm font-medium', reaction === r.id ? 'border-primary bg-primary text-primary-foreground' : 'bg-background')}>
                {r.label}
              </button>
            ))}
          </div>
          {reaction === 'gave_number' && <Input className="h-11" inputMode="decimal" placeholder="Their number ($), as said" value={counter} onChange={(e) => setCounter(e.target.value)} />}
          <Input className="h-11" placeholder="Their words (optional)" value={note} onChange={(e) => setNote(e.target.value)} />
          <Button disabled={busy || !reaction || (reaction === 'gave_number' && !counter.trim())} onClick={() => void sayIt()}>I said it: log what they said</Button>
          {err && <p className="text-sm text-red-700">{err}</p>}
        </div>
      )}
    </li>
  )
}

/** The close (docs/THALIA_TRAINING.md): every good call ends in a package for Colin. A clearly hot seller (a need and a
 *  rough house, or a sale or move date) gets Colin's walk booked now; everyone else a callback at a set time, when the
 *  caller books Colin's walk if he said walk it. No number on the phone, ever: Colin gives his at the house (0114).
 *  Not ready: the not-ready lines and a dated check-back. */
function Close({ verdict, hot, vars, facts, replyFacts, onSave, canOverride }: {
  verdict: BookingVerdict; hot: boolean; vars: Record<string, string>; facts: CallFacts; replyFacts: Record<string, unknown>
  onSave: (k: string, v: CallValue | null) => Promise<void>; canOverride: boolean
}) {
  const booked = answerOf(facts, 'next_step')
  const walkAllowed = hot || verdict.verdict === 'book' || canOverride || !!booked?.choices?.includes('walk')
  const step: CallQuestion = { ...NEXT_STEP, qid: 'booking', gate: [], say: [],
    choices: (NEXT_STEP.choices ?? []).filter((c) => c.id !== 'walk' || walkAllowed).map((c) => c.id === 'walk' ? { ...c, label: "Colin's walk" } : c) }
  const stepCard = <QuestionCard n={0} q={step} facts={facts} replyFacts={replyFacts} onSave={onSave} showGates={false} />
  const lines = (keep: (id: string) => boolean) => PHONE_SCRIPT.booking.filter((l) => keep(l.id)).map((l) => scriptLine(l, vars))
  const notReady = PHONE_SCRIPT.not_ready.map((l) => scriptLine(l, vars))
  const toPackage = (
    <Button variant="outline" className="h-auto min-h-11 w-full whitespace-normal py-2" onClick={() => document.getElementById('package')?.scrollIntoView({ behavior: 'smooth' })}>
      Then send the package to Colin (it fills in from these answers)
    </Button>
  )
  if (verdict.verdict === 'no' && !hot) return (
    <div className="space-y-2 rounded-md border-2 border-red-300 p-3">
      <p className="font-semibold">Close: not ready yet</p>
      <ScriptLines lines={notReady} />
      {(booked || canOverride) && stepCard}
    </div>
  )
  return (
    <div className="space-y-3">
      {hot && (
        <div className="space-y-2 rounded-md border-2 border-emerald-400 p-3">
          <p className="font-semibold">Hot: book Colin&apos;s walk on this call</p>
          <p className="text-sm text-muted-foreground">A need and a rough house, or a sale or move date. Book it now: Colin gives his number at the house, never on the phone.</p>
          <ScriptLines lines={lines((id) => id !== 'b8_call_instead')} />
        </div>
      )}
      <div className="space-y-2 rounded-md border-2 border-amber-300 p-3">
        <p className="font-semibold">{hot ? 'Or, if they would rather wait: the package and a callback' : 'Close: the package and a callback'}</p>
        <ScriptLines lines={lines((id) => id === 'b8_call_instead')} />
        {stepCard}
        {toPackage}
      </div>
      <details className="rounded-md border p-3">
        <summary className="cursor-pointer text-sm font-medium">Not ready: the not-ready lines</summary>
        <div className="mt-2"><ScriptLines lines={notReady} /></div>
      </details>
    </div>
  )
}

function QuestionCard({ n, q, facts, replyFacts, onSave, showGates = true }: {
  n: number; q: CallQuestion; facts: CallFacts; replyFacts: Record<string, unknown>; onSave: (k: string, v: CallValue | null) => Promise<void>
  showGates?: boolean
}) {
  const v = answerOf(facts, q.id)
  const [editing, setEditing] = useState(!v)
  const fromTexts = (q.reply ?? []).map((k) => replyFacts[k]).find((x) => typeof x === 'string' && x.trim()) as string | undefined
  const cur: CallValue = (facts[q.id]?.value as CallValue) ?? {}
  const put = (patch: Partial<CallValue>) => {
    const next: CallValue = { ...cur, ...patch }
    if (q.id === 'next_step') { next.kind = next.choices?.[0]; next.at = next.when }
    void onSave(q.id, next)
  }
  const tap = (id: string) => {
    const have = cur.choices ?? []
    const choices = q.multi ? (have.includes(id) ? have.filter((c) => c !== id) : [...have.filter((c) => c !== 'none'), id])
      : (have[0] === id ? [] : [id])
    put({ choices: id === 'none' && q.multi ? ['none'] : choices })
  }

  return (
    <li className={cn('rounded-md border p-3', v ? 'border-emerald-300 bg-emerald-50/40' : 'border-input')}>
      <div className="flex items-start justify-between gap-2">
        <p className="font-semibold">{n ? `${n}. ` : ''}{q.title}{' '}
          {showGates && q.gate.map((g) => <Badge key={g} tone="info" className="mr-1">Gate {g}: {PHONE_SCRIPT.gate_legend[String(g)]}</Badge>)}
        </p>
        {v ? <Badge tone="good">Answered</Badge> : fromTexts ? <Badge tone="warn">From texts</Badge> : <Badge>Ask</Badge>}
      </div>
      {v && !editing ? (
        <div className="mt-1">
          <p className="text-sm">{answerText(v, LABELS)}</p>
          <Button variant="ghost" size="sm" className="mt-1" onClick={() => setEditing(true)}>Change</Button>
        </div>
      ) : (
        <div className="mt-2 space-y-2">
          {q.say.map((s) => <p key={s} className="rounded-md bg-muted p-2 text-base leading-snug">&ldquo;{s}&rdquo;</p>)}
          {q.listen && <p className="text-xs text-muted-foreground"><strong>Listen for:</strong> {q.listen}</p>}
          {q.branch && <p className="text-xs text-muted-foreground"><strong>If:</strong> {q.branch}</p>}
          {fromTexts && (
            <p className="text-sm">They texted: <em>{fromTexts}</em>{' '}
              {!cur.text && <button type="button" className="underline" onClick={() => put({ text: fromTexts })}>Use this</button>}
            </p>
          )}
          {q.choices && (
            <div className="grid grid-cols-2 gap-2">
              {q.choices.map((c) => {
                const on = (cur.choices ?? []).includes(c.id)
                return (
                  <button key={c.id} type="button" aria-pressed={on} onClick={() => tap(c.id)}
                    className={cn('min-h-11 rounded-md border px-2 py-2 text-sm font-medium', on ? 'border-primary bg-primary text-primary-foreground' : 'bg-background')}>
                    {c.label}
                  </button>
                )
              })}
            </div>
          )}
          {q.number && <Field label={q.number} initial={cur.number ?? ''} inputMode="decimal" onCommit={(x) => put({ number: x })} />}
          {q.when && (
            <label className="block text-sm font-medium">{q.when}
              <Input key={cur.when ?? ''} type="datetime-local" className="mt-1 h-11" defaultValue={isoToLocalInput(cur.when ?? null)}
                onBlur={(e) => { const iso = localInputToIso(e.target.value); if (iso !== (cur.when ?? null)) put({ when: iso ?? undefined }) }} />
              <OddHourHint iso={cur.when} onFix={(fixed) => put({ when: fixed })} />
            </label>
          )}
          {q.text && <Field label={q.text} initial={cur.text ?? ''} multiline onCommit={(x) => put({ text: x })} />}
          {v && <Button variant="outline" size="sm" onClick={() => setEditing(false)}>Done</Button>}
        </div>
      )}
    </li>
  )
}

function Field({ label, initial, onCommit, multiline, inputMode }: {
  label: string; initial: string; onCommit: (v: string) => void; multiline?: boolean; inputMode?: 'decimal'
}) {
  const [v, setV] = useState(initial)
  useEffect(() => setV(initial), [initial])
  const commit = () => { if (v.trim() !== initial.trim()) onCommit(v.trim()) }
  return (
    <label className="block text-sm font-medium">{label}
      {multiline
        ? <Textarea rows={2} className="mt-1" value={v} onChange={(e) => setV(e.target.value)} onBlur={commit} />
        : <Input className="mt-1 h-11" inputMode={inputMode} value={v} onChange={(e) => setV(e.target.value)} onBlur={commit} />}
    </label>
  )
}

function LogCall({ lead, contacts, phone, onLogged, voicemailLine }: { lead: Lead; contacts: Contact[]; phone: string | null; onLogged?: (outcome: string) => void; voicemailLine?: string }) {
  const qc = useQueryClient()
  const phones = contacts.filter((c) => c.kind === 'phone').map((c) => c.value_normalized ?? c.value)
  const [from, setFrom] = useState<string>(phone ?? phones[0] ?? '')
  const [outcome, setOutcome] = useState<string>('')
  const [note, setNote] = useState('')
  // "Not now" carries the date they gave (Codex's walk, 2026-10-22: the generic 30 days lost the real date)
  const [until, setUntil] = useState('')
  const [notNowKind, setNotNowKind] = useState<'date' | 'condition'>('date')
  const [busy, setBusy] = useState(false)
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null)
  const save = async () => {
    setBusy(true)
    setMsg(null)
    const when = outcome === 'not_now' && notNowKind === 'date' && until ? localInputToIso(`${until}T12:00`) : null
    // a voicemail is a no-answer that left a message (the packet's outcome list)
    const sent = outcome === 'voicemail' ? 'no_answer' : outcome
    const words = outcome === 'voicemail' ? ['Left a voicemail.', note.trim()].filter(Boolean).join(' ') : note.trim()
    const r = await api.logCall(lead.id, from || null, sent, words || null, when)
    setBusy(false)
    const d = r.data as { ok: boolean; reason?: string } | null
    if (r.error || !d?.ok) { setMsg({ ok: false, text: r.error?.message ?? d?.reason ?? 'Not saved' }); return }
    setMsg({ ok: true, text: `Logged: ${outcome === 'voicemail' ? 'Voicemail' : LABEL_OUTCOME[outcome]}.` })
    const logged = outcome
    setOutcome('')
    setNote('')
    for (const k of [['lead', lead.id], ['leads'], ['pipeline_counts'], ['phone_lookup'], ['seller_recovery_queue']]) void qc.invalidateQueries({ queryKey: k })
    onLogged?.(logged)
  }
  const OUTCOMES = [...CALL_OUTCOMES.slice(0, 1), { id: 'voicemail', label: 'Voicemail', hint: 'Left a voicemail; under 20 seconds, your name and the street' } as const, ...CALL_OUTCOMES.slice(1)]
  const chosen = OUTCOMES.find((o) => o.id === outcome)
  return (
    <div className="space-y-2 rounded-md border-2 p-3">
      <p className="font-semibold">Log this call</p>
      {phones.length > 1 && (
        <label className="block text-sm font-medium">The number you talked on
          <Select className="mt-1" value={from} onChange={(e) => setFrom(e.target.value)}>
            {phone && !phones.includes(phone) && <option value={phone}>{fmtPhone(phone)}</option>}
            {phones.map((p) => <option key={p} value={p}>{fmtPhone(p)}</option>)}
          </Select>
        </label>
      )}
      <div className="grid grid-cols-2 gap-2">
        {OUTCOMES.map((o) => (
          <button key={o.id} type="button" aria-pressed={outcome === o.id} onClick={() => setOutcome(o.id)}
            className={cn('min-h-11 rounded-md border px-2 py-2 text-sm font-medium',
              outcome === o.id ? (o.id === 'dnc' ? 'border-red-700 bg-red-700 text-white' : 'border-primary bg-primary text-primary-foreground') : 'bg-background')}>
            {o.label}
          </button>
        ))}
      </div>
      {chosen && <p className="text-xs text-muted-foreground">{chosen.hint}</p>}
      {outcome === 'voicemail' && voicemailLine && (
        <p className="rounded-md bg-muted p-2 text-sm">Under 20 seconds: &ldquo;{voicemailLine}&rdquo;</p>
      )}
      {outcome === 'not_now' && (
        <div className="space-y-2 rounded-md bg-muted p-2">
          <label className="block text-sm font-medium">What did they give you?
            <Select className="mt-1" value={notNowKind} onChange={(e) => setNotNowKind(e.target.value as 'date' | 'condition')}>
              <option value="date">A specific date</option>
              <option value="condition">An event or condition, no date</option>
            </Select>
          </label>
          {notNowKind === 'date' && (
            <label className="block text-sm font-medium">Check back on (the exact date they gave)
              <Input type="date" className="mt-1 h-11" value={until} min={todayLocal()}
                onChange={(e) => setUntil(e.target.value)} />
            </label>
          )}
          {notNowKind === 'condition' && <p className="text-xs text-muted-foreground">Write the event in the notes below (for example, “after the tenant moves”). The 30-day date is only a review reminder, not a date the seller gave.</p>}
        </div>
      )}
      <Textarea rows={3} placeholder="Notes from the call" value={note} onChange={(e) => setNote(e.target.value)} />
      {outcome === 'dnc' ? (
        <ConfirmButton disabled={busy} question="Block every phone of this owner? Nobody calls or texts them again." yes="Yes, do not contact"
          onConfirm={() => void save()}>Save: do not contact</ConfirmButton>
      ) : (
        <Button className="h-12 w-full" disabled={busy || !outcome || (outcome === 'not_now' && ((notNowKind === 'date' && !until) || (notNowKind === 'condition' && !note.trim())))}
          onClick={() => void save()}>{busy ? 'Saving...' : 'Save the call'}</Button>
      )}
      {msg && <p className={msg.ok ? 'text-sm font-medium text-emerald-700' : 'text-sm text-red-700'}>{msg.text}</p>}
    </div>
  )
}

function ScriptLines({ lines }: { lines: { id: string; say: string; note?: string }[] }) {
  return (
    <ol className="space-y-2">
      {lines.map((l) => (
        <li key={l.id}>
          <p className="rounded-md bg-muted p-2 text-base leading-snug">&ldquo;{l.say}&rdquo;</p>
          {l.note && <p className="mt-0.5 text-xs text-muted-foreground">{l.note}</p>}
        </li>
      ))}
    </ol>
  )
}

type CallKind = 'hot_text' | 'inbound' | 'cold'
const CALL_KIND_LABEL: Record<CallKind, string> = { hot_text: 'They texted us', inbound: 'They called us', cold: 'Cold call' }

/** The first words on a call (docs/THALIA_TRAINING.md): the caller's own name, the street, and the question that fits. */
// eslint-disable-next-line react-refresh/only-export-components
export function pickupLine(caller: string, kind: CallKind = 'cold', vars: Record<string, string> = {}): string {
  // the openers live in the script (phoneScript.json "openers", twin of WPIE docs/phone_script.json): every caller, Colin
  // included, says their own name; we usually make the call, so "they called us" is only for a call that just came in
  const name = caller.charAt(0).toUpperCase() + caller.slice(1)
  const first = vars.first_name && vars.first_name !== 'there' ? vars.first_name : 'the owner'
  const line = (PHONE_SCRIPT as unknown as { openers: Record<CallKind, string> }).openers[kind]
  return line.replace(/\{caller\}/g, name).replace(/\{first_name\}/g, first).replace(/\{street\}/g, vars.street ?? 'the property')
}
