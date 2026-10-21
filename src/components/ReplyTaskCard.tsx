import { useState } from 'react'
import { Link } from 'react-router-dom'
import { Button } from '@/components/ui/button'
import { Badge, ErrorNote, Select } from '@/components/ui/form'
import { EmailComposer } from '@/components/EmailComposer'
import { api, useWrite } from '@/lib/queries'
import { fmtDateTime, fmtPhone } from '@/lib/format'
import { PEOPLE, REPLY_TASK_LABEL, personLabel } from '@/lib/wpie'
import type { Person, Task } from '@/lib/types'

export type ReplyTask = Task & { lead?: { id: string; owner_name: string; property_address: string | null } | null }

// A task the reply agent opened because the seller asked for something no text can do.
// The seller's exact words are quoted; Adil (or Colin) does it and taps Done.
export function ReplyTaskCard({ t, showLead = true }: { t: ReplyTask; showLead?: boolean }) {
  const [emailing, setEmailing] = useState(false)
  const done = useWrite((id: string) => api.finishTask(id), [['tasks'], ['lead'], ['reply_waiting']])
  const assign = useWrite((p: Person) => api.assignTask(t.id, p), [['tasks'], ['lead']])
  const name = t.lead?.owner_name ?? (t.phone10 ? fmtPhone(t.phone10) : 'Unknown number')
  return (
    <li id={`task-${t.id}`} className="scroll-mt-20 rounded-lg border bg-card p-3 target:ring-2 target:ring-amber-500">
      <div className="flex flex-wrap items-center gap-1.5">
        <Badge tone="warn">{REPLY_TASK_LABEL[t.kind] ?? t.kind}</Badge>
        <Badge>{personLabel(t.owner)}</Badge>
        <span className="text-xs text-muted-foreground">{fmtDateTime(t.created_at)}</span>
      </div>
      <p className="mt-2 font-medium">{t.title ?? t.note}</p>
      {showLead && (
        <p className="text-sm text-muted-foreground">
          {t.lead ? <Link to={`/lead/${t.lead.id}`} className="inline-flex min-h-11 items-center underline">{name}{t.lead.property_address ? `, ${t.lead.property_address}` : ''}</Link> : name}
        </p>
      )}
      {t.quote && <blockquote className="mt-2 rounded-md border-l-4 border-amber-400 bg-muted p-2 text-base">&ldquo;{t.quote}&rdquo;</blockquote>}
      <div className="mt-3 grid grid-cols-2 gap-2 sm:flex sm:flex-wrap">
        <Button className="h-12" onClick={() => setEmailing((e) => !e)} variant={emailing ? 'outline' : 'default'}>
          {emailing ? 'Close email' : 'Send email'}
        </Button>
        <Button className="h-12" variant="outline" disabled={done.isPending} onClick={() => done.mutate(t.id)}>Done</Button>
        <label className="col-span-2 flex items-center gap-2 text-sm sm:col-span-1">
          Who
          <Select value={t.owner} onChange={(e) => assign.mutate(e.target.value as Person)} aria-label="Who does it" className="w-32">
            {PEOPLE.map((p) => <option key={p.id} value={p.id}>{p.label}</option>)}
          </Select>
        </label>
      </div>
      {emailing && (
        <EmailComposer leadId={t.lead_id} taskId={t.id} to={t.email_to} ownerName={t.lead?.owner_name}
          address={t.lead?.property_address} onDone={() => setEmailing(false)} />
      )}
      <ErrorNote error={done.error ?? assign.error} />
    </li>
  )
}
