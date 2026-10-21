import { useEffect, useMemo, useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge, Select, Textarea } from '@/components/ui/form'
import { ConfirmButton } from '@/components/ui/confirm'
import { api } from '@/lib/queries'
import { fmtDateTime, fmtPhone, isoToLocalInput, localInputToIso } from '@/lib/format'
import { CALL_OUTCOMES, NEXT_STEP, PHONE_SCRIPT, callScript, scriptLine, type CallQuestion } from '@/lib/callScript'
import { answerOf, answerText, gateFromCall, stopsFromCall, type CallFacts, type CallValue } from '@/lib/callGate'
import { DECISION_LABEL, GATE_ITEMS, HARD_STOPS, SELLER_FACTS, STAGE_LABEL } from '@/lib/wpie'
import { cn } from '@/lib/utils'
import type { Contact, GateScore, Lead, Message } from '@/lib/types'

const LABELS: Record<string, string> = Object.fromEntries(
  [...callScript(), { ...NEXT_STEP, qid: 'booking', gate: [], say: [] } as CallQuestion].flatMap((q) => (q.choices ?? []).map((c) => [c.id, c.label])))

const title = (s: string) => s.toLowerCase().replace(/\b([a-z])/g, (m) => m.toUpperCase())
const ENTITY = /\b(LLC|INC|TRUST|ESTATE|CORP|COMPANY|PROPERTIES|HOLDINGS|BANK|CHURCH)\b/i

/** Names for the script's {placeholders}: the street, the owner's first name, the signer. */
function scriptVars(lead: Lead, facts: CallFacts): Record<string, string> {
  const street = (lead.property_address ?? '').replace(/,.*$/, '').trim()
  const first = ENTITY.test(lead.owner_name) || /^New caller/.test(lead.owner_name) ? '' : title(lead.owner_name.split(/\s+/)[0] ?? '')
  const dm = answerOf(facts, 'decision_makers')?.text?.trim()
  return { street: street ? title(street) : 'the property', first_name: first || 'there', signer: dm || 'everyone who signs',
    day: answerOf(facts, 'next_step')?.when ? new Date(answerOf(facts, 'next_step')!.when!).toLocaleDateString('en-US', { weekday: 'long', timeZone: 'America/Chicago' }) : 'tomorrow' }
}

// Read top to bottom while on the phone: what we already know, then each question to ask with the
// exact words and one-tap answers (saved to the lead as you tap), then "log this call".
export function CallScript({ lead, contacts, messages, replyFacts, latestGate, phone, startOpen }: {
  lead: Lead; contacts: Contact[]; messages: Message[]; replyFacts: Record<string, unknown>; latestGate: GateScore | null
  phone: string | null; startOpen: boolean
}) {
  const qc = useQueryClient()
  const [open, setOpen] = useState(startOpen)
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
  const opener = messages.find((m) => m.is_opener && m.direction === 'out')
  const replies = messages.filter((m) => m.direction === 'in' && m.channel === 'sms')
  const known = SELLER_FACTS.map((f) => ({ ...f, v: replyFacts[f.id] })).filter((f) => typeof f.v === 'string' && (f.v as string).trim())
  const vars = scriptVars(lead, facts)
  const questions = callScript(vars)
  const answered = questions.filter((q) => answerOf(facts, q.id)).length

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
        <p className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">Pick up with</p>
        <p className="mt-1 text-lg font-semibold">&ldquo;{PHONE_SCRIPT.pickup}&rdquo;</p>
        <p className="text-sm text-muted-foreground">(Adil: &ldquo;This is Adil, I work with Colin.&rdquo;) {PHONE_SCRIPT.voice}</p>
      </div>
      <details className="rounded-md border p-3">
        <summary className="cursor-pointer font-semibold">Before you pick up</summary>
        <ul className="mt-2 list-disc space-y-1 pl-5 text-sm">{PHONE_SCRIPT.before_pickup.map((l) => <li key={l}>{l}</li>)}</ul>
      </details>

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
          <QuestionCard key={q.qid} n={i + 1} q={q} facts={facts} replyFacts={replyFacts} onSave={save} />
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

      <div className="space-y-2 rounded-md border-2 border-emerald-300 p-3">
        <p className="font-semibold">Close: book the visit</p>
        <ScriptLines lines={PHONE_SCRIPT.booking.map((l) => scriptLine(l, vars))} />
        <QuestionCard n={0} q={{ ...NEXT_STEP, qid: 'booking', gate: [], say: [] }} facts={facts} replyFacts={replyFacts} onSave={save} />
      </div>
      <div className="space-y-2 rounded-md border p-3">
        <p className="font-semibold">Close: not ready yet</p>
        <ScriptLines lines={PHONE_SCRIPT.not_ready.map((l) => scriptLine(l, vars))} />
      </div>

      <div className="rounded-md border p-3">
        <p className="font-semibold">Gate items this call settles</p>
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
        <p className="mt-1 text-xs text-muted-foreground">These fill in the walk gate below; Colin saves the score.</p>
      </div>

      <LogCall lead={lead} contacts={contacts} phone={phone} />
    </section>
  )
}

const LABEL_OUTCOME: Record<string, string> = Object.fromEntries(CALL_OUTCOMES.map((o) => [o.id, o.label]))

function QuestionCard({ n, q, facts, replyFacts, onSave }: {
  n: number; q: CallQuestion; facts: CallFacts; replyFacts: Record<string, unknown>; onSave: (k: string, v: CallValue | null) => Promise<void>
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
          {q.gate.map((g) => <Badge key={g} tone="info" className="mr-1">Gate {g}: {PHONE_SCRIPT.gate_legend[String(g)]}</Badge>)}
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
              <Input type="datetime-local" className="mt-1 h-11" defaultValue={isoToLocalInput(cur.when ?? null)}
                onBlur={(e) => { const iso = localInputToIso(e.target.value); if (iso !== (cur.when ?? null)) put({ when: iso ?? undefined }) }} />
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

function LogCall({ lead, contacts, phone }: { lead: Lead; contacts: Contact[]; phone: string | null }) {
  const qc = useQueryClient()
  const phones = contacts.filter((c) => c.kind === 'phone').map((c) => c.value_normalized ?? c.value)
  const [from, setFrom] = useState<string>(phone ?? phones[0] ?? '')
  const [outcome, setOutcome] = useState<string>('')
  const [note, setNote] = useState('')
  const [busy, setBusy] = useState(false)
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null)
  const save = async () => {
    setBusy(true)
    setMsg(null)
    const r = await api.logCall(lead.id, from || null, outcome, note.trim() || null)
    setBusy(false)
    const d = r.data as { ok: boolean; reason?: string } | null
    if (r.error || !d?.ok) { setMsg({ ok: false, text: r.error?.message ?? d?.reason ?? 'Not saved' }); return }
    setMsg({ ok: true, text: `Logged: ${LABEL_OUTCOME[outcome]}.` })
    setOutcome('')
    setNote('')
    for (const k of [['lead', lead.id], ['leads'], ['pipeline_counts'], ['phone_lookup']]) void qc.invalidateQueries({ queryKey: k })
  }
  const chosen = CALL_OUTCOMES.find((o) => o.id === outcome)
  return (
    <div className="space-y-2 rounded-md border-2 p-3">
      <p className="font-semibold">Log this call</p>
      {phones.length > 1 && (
        <label className="block text-sm font-medium">They called from
          <Select className="mt-1" value={from} onChange={(e) => setFrom(e.target.value)}>
            {phone && !phones.includes(phone) && <option value={phone}>{fmtPhone(phone)}</option>}
            {phones.map((p) => <option key={p} value={p}>{fmtPhone(p)}</option>)}
          </Select>
        </label>
      )}
      <div className="grid grid-cols-2 gap-2">
        {CALL_OUTCOMES.map((o) => (
          <button key={o.id} type="button" aria-pressed={outcome === o.id} onClick={() => setOutcome(o.id)}
            className={cn('min-h-11 rounded-md border px-2 py-2 text-sm font-medium',
              outcome === o.id ? (o.id === 'dnc' ? 'border-red-700 bg-red-700 text-white' : 'border-primary bg-primary text-primary-foreground') : 'bg-background')}>
            {o.label}
          </button>
        ))}
      </div>
      {chosen && <p className="text-xs text-muted-foreground">{chosen.hint}</p>}
      <Textarea rows={3} placeholder="Notes from the call" value={note} onChange={(e) => setNote(e.target.value)} />
      {outcome === 'dnc' ? (
        <ConfirmButton disabled={busy} question="Block every phone of this owner? Nobody calls or texts them again." yes="Yes, do not contact"
          onConfirm={() => void save()}>Save: do not contact</ConfirmButton>
      ) : (
        <Button className="h-12 w-full" disabled={busy || !outcome} onClick={() => void save()}>{busy ? 'Saving...' : 'Save the call'}</Button>
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
