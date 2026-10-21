import { useEffect, useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge, Empty, ErrorNote, Section, Select, Textarea } from '@/components/ui/form'
import { GateChecklist, type GateSave } from '@/components/GateChecklist'
import { api, useDeals, useLead, useWrite } from '@/lib/queries'
import { fmtDate, fmtDateTime, fmtPhone, isoToLocalInput, localInputToIso } from '@/lib/format'
import { DEAL_STATUS_LABEL, MILESTONES, STAGES, STAGE_LABEL, TASK_KINDS, TASK_KIND_LABEL } from '@/lib/wpie'
import { useAuth } from '@/providers/AuthProvider'
import type { Contact, Deal, DealStatus, Lead, LeadStage, Person } from '@/lib/types'

export default function LeadDetail() {
  const { id = '' } = useParams()
  const q = useLead(id)
  const { isOwner } = useAuth()

  if (q.isLoading) return <Empty>Loading...</Empty>
  if (q.error) return <ErrorNote error={q.error} />
  if (!q.data) return <Empty>Lead not found.</Empty>
  const { lead, contacts, messages, tasks, gates, milestones } = q.data

  return (
    <div className="space-y-4">
      <div>
        <Link to="/pipeline" className="inline-flex min-h-11 items-center text-sm underline">
          Back to pipeline
        </Link>
        <h1 className="mt-1 text-xl font-semibold">{lead.owner_name}</h1>
        <div className="mt-1 flex flex-wrap gap-2">
          <Badge>{STAGE_LABEL[lead.stage]}</Badge>
          {lead.lane && <Badge tone="info">{lead.lane === 'hold' ? 'Hold lane' : 'Flip lane'}</Badge>}
          {lead.county && <Badge>{lead.county} County</Badge>}
        </div>
      </div>

      <NextAction lead={lead} />
      <Facts lead={lead} />
      <Contacts contacts={contacts} leadId={lead.id} />
      <Milestones leadId={lead.id} done={milestones} />
      <History leadId={lead.id} messages={messages} />
      <Tasks leadId={lead.id} tasks={tasks} />
      <Section title="Walk / don't-walk gate">
        <GateBlock leadId={lead.id} latest={gates[0] ?? null} canEdit={isOwner} />
      </Section>
      {isOwner && <DealBlock leadId={lead.id} />}
      <Notes lead={lead} />
    </div>
  )
}

function NextAction({ lead }: { lead: Lead }) {
  const [stage, setStage] = useState<LeadStage>(lead.stage)
  const [when, setWhen] = useState(isoToLocalInput(lead.next_action_at))
  const [what, setWhat] = useState(lead.next_action ?? '')
  const [who, setWho] = useState<Person | ''>(lead.assigned_to ?? '')
  const [deadReason, setDeadReason] = useState(lead.dead_reason ?? '')
  useEffect(() => {
    setStage(lead.stage)
    setWhen(isoToLocalInput(lead.next_action_at))
    setWhat(lead.next_action ?? '')
    setWho(lead.assigned_to ?? '')
    setDeadReason(lead.dead_reason ?? '')
  }, [lead])
  const save = useWrite(
    () =>
      api.updateLead(lead.id, {
        stage,
        next_action_at: localInputToIso(when),
        next_action: what.trim() || null,
        assigned_to: who || null,
        dead_reason: stage === 'dead' ? deadReason.trim() || null : lead.dead_reason,
      }),
    [['lead', lead.id], ['leads'], ['pipeline_counts'], ['followup_debt']],
  )
  return (
    <Section title="Stage and next action">
      <p className="mb-3 text-sm text-muted-foreground">Every lead has one stage and one next date.</p>
      <div className="grid gap-3 sm:grid-cols-2">
        <label className="text-sm font-medium">
          Stage
          <Select value={stage} onChange={(e) => setStage(e.target.value as LeadStage)} className="mt-1">
            {STAGES.map((s) => (
              <option key={s.id} value={s.id}>
                {s.label}
              </option>
            ))}
          </Select>
        </label>
        <label className="text-sm font-medium">
          Who has it
          <Select value={who} onChange={(e) => setWho(e.target.value as Person | '')} className="mt-1">
            <option value="">Nobody yet</option>
            <option value="colin">Colin</option>
            <option value="thalia">Thalia</option>
          </Select>
        </label>
        <label className="text-sm font-medium">
          Next action date and time
          <Input type="datetime-local" value={when} onChange={(e) => setWhen(e.target.value)} className="mt-1" />
        </label>
        <label className="text-sm font-medium">
          Next action
          <Input placeholder="e.g. call back after 5" value={what} onChange={(e) => setWhat(e.target.value)} className="mt-1" />
        </label>
        {stage === 'dead' && (
          <label className="text-sm font-medium sm:col-span-2">
            Why dead
            <Input value={deadReason} onChange={(e) => setDeadReason(e.target.value)} className="mt-1" />
          </label>
        )}
      </div>
      <div className="mt-3 flex items-center gap-3">
        <Button disabled={save.isPending} onClick={() => save.mutate(undefined)}>
          {save.isPending ? 'Saving...' : 'Save'}
        </Button>
        {save.isSuccess && <span className="text-sm text-emerald-700">Saved</span>}
      </div>
      <ErrorNote error={save.error} />
    </Section>
  )
}

function Row({ label, children }: { label: string; children: React.ReactNode }) {
  if (children === null || children === undefined || children === '') return null
  return (
    <div className="grid grid-cols-3 gap-2 py-1 text-sm">
      <dt className="text-muted-foreground">{label}</dt>
      <dd className="col-span-2">{children}</dd>
    </div>
  )
}

function Facts({ lead }: { lead: Lead }) {
  const mailing = [lead.mailing_street, lead.mailing_city, [lead.mailing_state, lead.mailing_zip].filter(Boolean).join(' ')]
    .filter(Boolean)
    .join(', ')
  return (
    <Section title="WPIE facts">
      <dl>
        <Row label="Owner">
          {lead.owner_name}
          {lead.owner_type ? ` (${lead.owner_type})` : ''}
        </Row>
        <Row label="Mailing address">{mailing}</Row>
        <Row label="Property">
          {lead.property_address}
          {lead.municipality ? `, ${lead.municipality}` : ''} {lead.property_zip}
        </Row>
        <Row label="County">{lead.county}</Row>
        <Row label="Type">
          {[lead.property_type, lead.units ? `${lead.units} units` : null].filter(Boolean).join(', ')}
        </Row>
        <Row label="Parcel">{lead.parcel_id}</Row>
        <Row label="Reasons to sell">
          {lead.reasons_to_sell.length ? (
            <span className="flex flex-wrap gap-1">
              {lead.reasons_to_sell.map((r) => (
                <Badge key={r} tone="warn">
                  {r}
                </Badge>
              ))}
            </span>
          ) : null}
        </Row>
        <Row label="WPIE signal score">{lead.score !== null ? Math.round(Number(lead.score)) : null}</Row>
        <Row label="Mailed">
          {lead.mailed_on ? `${fmtDate(lead.mailed_on)}${lead.mail_channel ? ` (${lead.mail_channel})` : ''}` : null}
        </Row>
        <Row label="WPIE ids">
          {lead.wpie_owner_id ? `owner ${lead.wpie_owner_id}` : ''}
          {lead.wpie_property_id ? `, property ${lead.wpie_property_id}` : ''}
        </Row>
      </dl>
      <p className="mt-2 text-xs text-muted-foreground">
        Never mention taxes, sheriff sales, code cases or a death to the owner before they raise it.
      </p>
    </Section>
  )
}

function contactFlags(c: Contact) {
  const flags: { label: string; tone: 'bad' | 'warn' | 'muted' | 'good' }[] = []
  if (c.status === 'bad') flags.push({ label: 'Bad number', tone: 'bad' })
  if (c.dnc_app) flags.push({ label: 'Do not contact', tone: 'bad' })
  if (c.suppressed) flags.push({ label: 'Texted STOP', tone: 'bad' })
  if (c.dnc_vendor || c.dnc_scrub === 'dnc') flags.push({ label: 'On DNC list', tone: 'bad' })
  else if (c.dnc_scrub === 'clear') flags.push({ label: 'DNC checked: clear', tone: 'good' })
  else if (c.kind === 'phone') flags.push({ label: 'DNC not checked', tone: 'warn' })
  return flags
}

function Contacts({ contacts, leadId }: { contacts: Contact[]; leadId: string }) {
  const upd = useWrite(
    ({ id, patch }: { id: string; patch: Partial<Pick<Contact, 'status' | 'dnc_app'>> }) => api.updateContact(id, patch),
    [['lead', leadId]],
  )
  return (
    <Section title={`Phones and emails (${contacts.length})`}>
      <p className="mb-2 text-xs text-muted-foreground">Red flags mean do not call or text that number.</p>
      {contacts.length === 0 && <Empty>No phones or emails on file.</Empty>}
      <ul className="divide-y">
        {contacts.map((c) => (
          <li key={c.id} className="py-2">
            <div className="flex flex-wrap items-center gap-2">
              <span className="font-medium">{c.kind === 'phone' ? fmtPhone(c.value) : c.value}</span>
              {c.line_type && <Badge>{c.line_type}</Badge>}
              {contactFlags(c).map((f) => (
                <Badge key={f.label} tone={f.tone}>
                  {f.label}
                </Badge>
              ))}
            </div>
            <div className="text-xs text-muted-foreground">
              {[c.person_name, c.source].filter(Boolean).join(' - ')}
            </div>
            <div className="mt-1 flex gap-2">
              <Button
                size="sm"
                variant="outline"
                disabled={upd.isPending}
                onClick={() => upd.mutate({ id: c.id, patch: { status: c.status === 'bad' ? 'ok' : 'bad' } })}
              >
                {c.status === 'bad' ? 'Number is fine' : 'Wrong / bad number'}
              </Button>
              <Button
                size="sm"
                variant="outline"
                disabled={upd.isPending}
                onClick={() => upd.mutate({ id: c.id, patch: { dnc_app: !c.dnc_app } })}
              >
                {c.dnc_app ? 'Clear do-not-contact' : 'Do not contact'}
              </Button>
            </div>
          </li>
        ))}
      </ul>
      <ErrorNote error={upd.error} />
    </Section>
  )
}

function Milestones({ leadId, done }: { leadId: string; done: { id: number; kind: string; at: string }[] }) {
  const add = useWrite((kind: (typeof MILESTONES)[number]['id']) => api.addMilestone(leadId, kind), [['lead', leadId], ['scoreboard']])
  const del = useWrite((id: number) => api.removeMilestone(id), [['lead', leadId], ['scoreboard']])
  return (
    <Section title="Scoreboard checkpoints">
      <p className="mb-2 text-xs text-muted-foreground">Tick each one the first time it happens. These feed the weekly scoreboard.</p>
      <ul className="space-y-2">
        {MILESTONES.map((m) => {
          const row = done.find((d) => d.kind === m.id)
          return (
            <li key={m.id}>
              <label className="flex items-start gap-2 text-sm">
                <input
                  type="checkbox"
                  className="mt-1"
                  checked={Boolean(row)}
                  disabled={add.isPending || del.isPending}
                  onChange={() => (row ? del.mutate(row.id) : add.mutate(m.id))}
                />
                <span>
                  <span className="font-medium">{m.label}</span> <span className="text-muted-foreground">- {m.hint}</span>
                  {row && <span className="text-xs text-muted-foreground"> ({fmtDateTime(row.at)})</span>}
                </span>
              </label>
            </li>
          )
        })}
      </ul>
      <ErrorNote error={add.error ?? del.error} />
    </Section>
  )
}

function History({ leadId, messages }: { leadId: string; messages: import('@/lib/types').Message[] }) {
  const [kind, setKind] = useState<'note' | 'call'>('note')
  const [body, setBody] = useState('')
  const add = useWrite(
    () => api.addMessage({ lead_id: leadId, channel: kind, direction: 'out', body: body.trim() }),
    [['lead', leadId]],
  )
  return (
    <Section title={`Texts, calls and notes (${messages.length})`}>
      <div className="mb-3 space-y-2">
        <div className="flex gap-2">
          <Select value={kind} onChange={(e) => setKind(e.target.value as 'note' | 'call')} className="w-40">
            <option value="note">Note</option>
            <option value="call">Call log</option>
          </Select>
        </div>
        <Textarea
          placeholder={kind === 'call' ? 'What happened on the call' : 'Note'}
          value={body}
          onChange={(e) => setBody(e.target.value)}
        />
        <Button
          size="sm"
          disabled={!body.trim() || add.isPending}
          onClick={() => add.mutate(undefined, { onSuccess: () => setBody('') })}
        >
          Add
        </Button>
        <p className="text-xs text-muted-foreground">Texts are sent from WPIE, not from here.</p>
        <ErrorNote error={add.error} />
      </div>
      {messages.length === 0 && <Empty>Nothing yet.</Empty>}
      <ul className="space-y-2">
        {messages.map((m) => (
          <li
            key={m.id}
            className={`rounded-md p-2 text-sm ${m.direction === 'in' ? 'bg-blue-50' : m.channel === 'sms' ? 'bg-muted' : 'border'}`}
          >
            <div className="mb-1 flex flex-wrap items-center gap-2 text-xs text-muted-foreground">
              <span>
                {m.channel === 'sms' ? (m.direction === 'in' ? 'Text from owner' : m.is_opener ? 'Opener text' : 'Text') : m.channel === 'call' ? 'Call' : 'Note'}
              </span>
              <span>{fmtDateTime(m.sent_at)}</span>
              {m.status && m.channel === 'sms' && <Badge>{m.status.replace(/_/g, ' ')}</Badge>}
              {m.is_opt_out && <Badge tone="bad">STOP</Badge>}
            </div>
            <p className="whitespace-pre-wrap">{m.body}</p>
          </li>
        ))}
      </ul>
    </Section>
  )
}

function Tasks({ leadId, tasks }: { leadId: string; tasks: import('@/lib/types').Task[] }) {
  const { member } = useAuth()
  const [when, setWhen] = useState('')
  const [kind, setKind] = useState('call')
  const [owner, setOwner] = useState<Person>(member?.person ?? 'colin')
  const [note, setNote] = useState('')
  const add = useWrite(
    () => api.addTask({ lead_id: leadId, due_at: localInputToIso(when)!, kind, owner, note: note.trim() || null }),
    [['lead', leadId], ['tasks']],
  )
  const done = useWrite((id: string) => api.finishTask(id), [['lead', leadId], ['tasks']])
  const open = tasks.filter((t) => !t.done_at)
  const closed = tasks.filter((t) => t.done_at)
  return (
    <Section title="Follow-ups">
      {open.length === 0 && <Empty>No open follow-ups.</Empty>}
      <ul className="divide-y">
        {open.map((t) => (
          <li key={t.id} className="flex items-center justify-between gap-2 py-2 text-sm">
            <span>
              <strong>{TASK_KIND_LABEL[t.kind] ?? t.kind}</strong> - {fmtDateTime(t.due_at)} - {t.owner === 'colin' ? 'Colin' : 'Thalia'}
              {t.note ? ` - ${t.note}` : ''}
            </span>
            <Button size="sm" variant="outline" disabled={done.isPending} onClick={() => done.mutate(t.id)}>
              Done
            </Button>
          </li>
        ))}
      </ul>
      <div className="mt-3 grid gap-2 sm:grid-cols-2">
        <Input type="datetime-local" value={when} onChange={(e) => setWhen(e.target.value)} aria-label="Due" />
        <Select value={kind} onChange={(e) => setKind(e.target.value)} aria-label="Kind">
          {TASK_KINDS.map((k) => (
            <option key={k.id} value={k.id}>
              {k.label}
            </option>
          ))}
        </Select>
        <Select value={owner} onChange={(e) => setOwner(e.target.value as Person)} aria-label="Who">
          <option value="colin">Colin</option>
          <option value="thalia">Thalia</option>
        </Select>
        <Input placeholder="Note (optional)" value={note} onChange={(e) => setNote(e.target.value)} />
      </div>
      <Button
        size="sm"
        className="mt-2"
        disabled={!when || add.isPending}
        onClick={() => add.mutate(undefined, { onSuccess: () => { setWhen(''); setNote('') } })}
      >
        Add follow-up
      </Button>
      <ErrorNote error={add.error ?? done.error} />
      {closed.length > 0 && <p className="mt-2 text-xs text-muted-foreground">{closed.length} done.</p>}
    </Section>
  )
}

function GateBlock({ leadId, latest, canEdit }: { leadId: string; latest: import('@/lib/types').GateScore | null; canEdit: boolean }) {
  const { member } = useAuth()
  const save = useWrite(
    (v: GateSave) =>
      api.addGate({
        lead_id: leadId,
        ...v.scores,
        hard_stops: v.hard_stops,
        decision: v.decision,
        note: v.note,
        decided_by_name: member?.display_name ?? null,
      }),
    [['lead', leadId]],
  )
  return (
    <>
      <GateChecklist key={latest?.id ?? 'new'} latest={latest} canEdit={canEdit} saving={save.isPending} onSave={(v) => save.mutate(v)} />
      <ErrorNote error={save.error} />
    </>
  )
}

function DealBlock({ leadId }: { leadId: string }) {
  const deals = useDeals(leadId, true)
  const deal: Deal | undefined = deals.data?.[deals.data.length - 1]
  const [status, setStatus] = useState<DealStatus>('offer')
  const [offer, setOffer] = useState('')
  const [contract, setContract] = useState('')
  const [close, setClose] = useState('')
  const [notes, setNotes] = useState('')
  useEffect(() => {
    if (!deal) return
    setStatus(deal.status)
    setOffer(deal.colin_offer !== null ? String(deal.colin_offer) : '')
    setContract(deal.contract_date ?? '')
    setClose(deal.close_date ?? '')
    setNotes(deal.notes ?? '')
  }, [deal])
  const save = useWrite(
    () =>
      api.saveDeal({
        id: deal?.id,
        lead_id: leadId,
        status,
        colin_offer: offer.trim() === '' ? null : Number(offer.replace(/[$,\s]/g, '')),
        contract_date: contract || null,
        close_date: close || null,
        notes: notes.trim() || null,
      }),
    [['deals', leadId], ['scoreboard']],
  )
  return (
    <Section title="Deal (Colin only)">
      <p className="mb-3 text-xs text-muted-foreground">You type your own numbers here. The app never suggests an offer or a value.</p>
      <ErrorNote error={deals.error} />
      <div className="grid gap-3 sm:grid-cols-2">
        <label className="text-sm font-medium">
          Status
          <Select value={status} onChange={(e) => setStatus(e.target.value as DealStatus)} className="mt-1">
            {(Object.keys(DEAL_STATUS_LABEL) as DealStatus[]).map((s) => (
              <option key={s} value={s}>
                {DEAL_STATUS_LABEL[s]}
              </option>
            ))}
          </Select>
        </label>
        <label className="text-sm font-medium">
          Your offer ($)
          <Input inputMode="decimal" value={offer} onChange={(e) => setOffer(e.target.value)} className="mt-1" />
        </label>
        <label className="text-sm font-medium">
          Contract signed
          <Input type="date" value={contract} onChange={(e) => setContract(e.target.value)} className="mt-1" />
        </label>
        <label className="text-sm font-medium">
          Closed
          <Input type="date" value={close} onChange={(e) => setClose(e.target.value)} className="mt-1" />
        </label>
        <label className="text-sm font-medium sm:col-span-2">
          Deal notes
          <Textarea value={notes} onChange={(e) => setNotes(e.target.value)} className="mt-1" />
        </label>
      </div>
      <Button
        className="mt-3"
        disabled={save.isPending || (offer.trim() !== '' && Number.isNaN(Number(offer.replace(/[$,\s]/g, ''))))}
        onClick={() => save.mutate(undefined)}
      >
        {deal ? 'Save deal' : 'Start deal record'}
      </Button>
      <ErrorNote error={save.error} />
    </Section>
  )
}

function Notes({ lead }: { lead: Lead }) {
  const [notes, setNotes] = useState(lead.notes ?? '')
  useEffect(() => setNotes(lead.notes ?? ''), [lead.notes])
  const save = useWrite(() => api.updateLead(lead.id, { notes: notes.trim() || null }), [['lead', lead.id]])
  return (
    <Section title="Lead notes">
      <Textarea value={notes} onChange={(e) => setNotes(e.target.value)} className="min-h-28" />
      <div className="mt-2 flex items-center gap-3">
        <Button size="sm" disabled={save.isPending} onClick={() => save.mutate(undefined)}>
          Save notes
        </Button>
        {save.isSuccess && <span className="text-sm text-emerald-700">Saved</span>}
      </div>
      <ErrorNote error={save.error} />
    </Section>
  )
}
