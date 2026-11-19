import { useEffect, useState } from 'react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge, ErrorNote, Section } from '@/components/ui/form'
import { api, useClosingSteps, useDeals, useWrite } from '@/lib/queries'
import { fmtDate, fmtPhone, todayLocal } from '@/lib/format'
import { cn } from '@/lib/utils'
import type { ClosingStep, Deal, Lead } from '@/lib/types'

// The closing track (0253): everything between a signed offer and the closing, as dated steps written from the
// contract's own terms. Colin ticks them; his one task for the deal is always the next step due. Shown only once a
// contract is signed, and only to Colin: a caller's login reads no steps.

const dayDiff = (iso: string, from: string) => Math.round((Date.parse(`${iso}T12:00:00Z`) - Date.parse(`${from}T12:00:00Z`)) / 86_400_000)
const shortDay = (iso: string) => fmtDate(iso).replace(/, \d{4}$/, '')
type RpcRes = { data: unknown; error: { message: string } | null }
const rpc = async (r: RpcRes) => {
  const d = r.data as { ok?: boolean; reason?: string } | null
  return { error: r.error ?? (d && d.ok === false ? { message: d.reason ?? 'not done' } : null) }
}

export function ClosingTrack({ lead }: { lead: Lead }) {
  const deals = useDeals(lead.id, true)
  const deal: Deal | undefined = deals.data?.[deals.data.length - 1]
  const q = useClosingSteps(lead.id, true)
  const steps = q.data ?? []
  if (!deal || steps.length === 0) return <ErrorNote error={q.error} />
  const today = todayLocal()
  const open = steps.filter((s) => !s.done_at && !s.skipped)
  const done = steps.filter((s) => s.done_at).length
  const counted = steps.filter((s) => !s.skipped).length
  const late = open.filter((s) => s.due_on && s.due_on < today).length
  const left = deal.closing_on ? dayDiff(deal.closing_on, today) : null
  const closed = deal.status === 'closed'
  return (
    <Section title="Closing" right={closed ? <Badge tone="good">Closed</Badge>
      : deal.status === 'dead' ? <Badge tone="bad">Deal dead</Badge>
      : left !== null ? <Badge tone={left <= 7 ? 'warn' : 'info'}>{left > 0 ? `${left} days left` : left === 0 ? 'Today' : `${-left} days past`}</Badge> : undefined}>
      <p className="text-sm">
        {deal.price != null && <span className="font-semibold">{Number(deal.price).toLocaleString('en-US', { style: 'currency', currency: 'USD', maximumFractionDigits: 0 })}</span>}
        {deal.closing_on && <span>{deal.price != null ? ', ' : ''}closing {fmtDate(deal.closing_on)}</span>}
        <span className="text-muted-foreground"> · {done} of {counted} steps done{late > 0 ? `, ${late} late` : ''}</span>
      </p>
      <TitleCompany deal={deal} leadId={lead.id} />
      <ul className="mt-3 divide-y">
        {steps.map((s) => <StepRow key={s.id} s={s} leadId={lead.id} today={today} />)}
      </ul>
      {!closed && <AddStep dealId={deal.id} leadId={lead.id} />}
      <p className="mt-3 text-xs text-muted-foreground">Your task list shows one line for this deal: the next step due. Ticking Closing closes the deal and the card.</p>
    </Section>
  )
}

function TitleCompany({ deal, leadId }: { deal: Deal; leadId: string }) {
  const [edit, setEdit] = useState(!deal.title_company)
  const [f, setF] = useState({ company: deal.title_company ?? '', contact: deal.title_contact ?? '', phone: deal.title_phone ?? '', email: deal.title_email ?? '' })
  useEffect(() => {
    setF({ company: deal.title_company ?? '', contact: deal.title_contact ?? '', phone: deal.title_phone ?? '', email: deal.title_email ?? '' })
    setEdit(!deal.title_company)
  }, [deal.title_company, deal.title_contact, deal.title_phone, deal.title_email])
  const save = useWrite(() => api.saveDeal({ id: deal.id, lead_id: leadId, title_company: f.company.trim() || null, title_contact: f.contact.trim() || null,
    title_phone: f.phone.replace(/\D/g, '') || null, title_email: f.email.trim() || null }), [['deals', leadId]])
  if (!edit) {
    return (
      <div className="mt-2 flex flex-wrap items-center gap-x-3 gap-y-1 rounded-md bg-muted/50 p-2 text-sm">
        <span><span className="text-muted-foreground">Title: </span><span className="font-medium">{deal.title_company}</span>{deal.title_contact ? `, ${deal.title_contact}` : ''}</span>
        {deal.title_phone && <a className="font-medium underline" href={`tel:${deal.title_phone}`}>{fmtPhone(deal.title_phone)}</a>}
        {deal.title_email && <a className="underline" href={`mailto:${deal.title_email}`}>{deal.title_email}</a>}
        <button type="button" className="ml-auto text-xs font-medium underline" onClick={() => setEdit(true)}>Change</button>
      </div>
    )
  }
  return (
    <div className={cn('mt-2 space-y-2 rounded-md border p-2', !deal.title_company && 'border-amber-300 bg-amber-50')}>
      {!deal.title_company && <p className="text-sm font-medium">No title company yet. The contract says the buyer picks one; nothing starts until they have the signed contract.</p>}
      <div className="grid gap-2 sm:grid-cols-2">
        <Input aria-label="Title company" placeholder="Title company" value={f.company} onChange={(e) => setF({ ...f, company: e.target.value })} />
        <Input aria-label="Title contact" placeholder="Who is on the file (optional)" value={f.contact} onChange={(e) => setF({ ...f, contact: e.target.value })} />
        <Input aria-label="Title phone" placeholder="Phone (optional)" inputMode="tel" value={f.phone} onChange={(e) => setF({ ...f, phone: e.target.value })} />
        <Input aria-label="Title email" placeholder="Email (optional)" type="email" value={f.email} onChange={(e) => setF({ ...f, email: e.target.value })} />
      </div>
      <div className="flex gap-2">
        <Button size="sm" disabled={!f.company.trim() || save.isPending} onClick={() => save.mutate(undefined, { onSuccess: () => setEdit(false) })}>Save</Button>
        {deal.title_company && <Button size="sm" variant="ghost" onClick={() => setEdit(false)}>Cancel</Button>}
      </div>
      <ErrorNote error={save.error} />
    </div>
  )
}

function StepRow({ s, leadId, today }: { s: ClosingStep; leadId: string; today: string }) {
  const [openRow, setOpenRow] = useState(false)
  const [due, setDue] = useState(s.due_on ?? '')
  const [note, setNote] = useState(s.note ?? '')
  useEffect(() => { setDue(s.due_on ?? ''); setNote(s.note ?? '') }, [s.due_on, s.note])
  const keys = [['closing_steps', leadId], ['deals', leadId], ['lead', leadId], ['tasks'], ['scoreboard']]
  const set = useWrite(async (x: { done?: boolean; skipped?: boolean; due?: string | null; note?: string | null }) => rpc(await api.closingStepSet(s.id, x)), keys)
  const isDone = !!s.done_at
  const days = s.due_on ? dayDiff(s.due_on, today) : null
  const when = isDone ? `done ${fmtDate(s.done_at)}${s.done_by ? ` by ${s.done_by}` : ''}`
    : s.skipped ? 'not needed'
    : days === null ? 'no date'
    : days < 0 ? `${shortDay(s.due_on!)} · ${-days} ${days === -1 ? 'day' : 'days'} late`
    : days === 0 ? 'today' : days === 1 ? 'tomorrow' : shortDay(s.due_on!)
  return (
    <li className="py-2">
      <div className="flex items-start gap-3">
        <button type="button" aria-label={isDone ? `Untick: ${s.label}` : `Tick: ${s.label}`} disabled={set.isPending}
          className={cn('mt-0.5 flex h-9 w-9 shrink-0 items-center justify-center rounded-md border-2 text-lg font-bold',
            isDone ? 'border-emerald-600 bg-emerald-600 text-white' : 'border-muted-foreground/40 bg-background')}
          onClick={() => set.mutate({ done: !isDone })}>{isDone ? '✓' : ''}</button>
        <button type="button" className="min-w-0 flex-1 text-left" onClick={() => setOpenRow(!openRow)}>
          <span className={cn('block text-sm font-medium', (isDone || s.skipped) && 'text-muted-foreground line-through')}>{s.label}</span>
          <span className={cn('block text-xs', !isDone && !s.skipped && days !== null && days < 0 ? 'font-semibold text-rose-700'
            : !isDone && !s.skipped && days !== null && days <= 1 ? 'font-semibold text-amber-700' : 'text-muted-foreground')}>{when}</span>
          {s.note && <span className="mt-0.5 block text-xs">{s.note}</span>}
        </button>
      </div>
      {openRow && (
        <div className="ml-12 mt-2 space-y-2 rounded-md bg-muted/50 p-2">
          {s.why && <p className="text-xs text-muted-foreground">{s.why}</p>}
          <div className="grid gap-2 sm:grid-cols-[10rem_1fr]">
            <Input aria-label="Due" type="date" value={due} onChange={(e) => setDue(e.target.value)} />
            <Input aria-label="Note" placeholder="Note (who you spoke to, what they said)" value={note} onChange={(e) => setNote(e.target.value)} />
          </div>
          <div className="flex flex-wrap gap-2">
            <Button size="sm" disabled={set.isPending} onClick={() => set.mutate({ due: due || null, note }, { onSuccess: () => setOpenRow(false) })}>Save</Button>
            {!isDone && <Button size="sm" variant="outline" disabled={set.isPending} onClick={() => set.mutate({ skipped: !s.skipped }, { onSuccess: () => setOpenRow(false) })}>
              {s.skipped ? 'Needed after all' : 'Not needed'}</Button>}
          </div>
          <ErrorNote error={set.error} />
        </div>
      )}
      {!openRow && <ErrorNote error={set.error} />}
    </li>
  )
}

function AddStep({ dealId, leadId }: { dealId: string; leadId: string }) {
  const [label, setLabel] = useState('')
  const [due, setDue] = useState('')
  const add = useWrite(async () => rpc(await api.closingStepAdd(dealId, label.trim(), due || null)), [['closing_steps', leadId], ['tasks']])
  return (
    <div className="mt-2 grid gap-2 sm:grid-cols-[1fr_10rem_auto]">
      <Input aria-label="A step of your own" placeholder="Add a step of your own" value={label} onChange={(e) => setLabel(e.target.value)} />
      <Input aria-label="Its date" type="date" value={due} onChange={(e) => setDue(e.target.value)} />
      <Button size="sm" variant="outline" className="h-10" disabled={!label.trim() || add.isPending}
        onClick={() => add.mutate(undefined, { onSuccess: () => { setLabel(''); setDue('') } })}>Add</Button>
      <ErrorNote error={add.error} />
    </div>
  )
}
