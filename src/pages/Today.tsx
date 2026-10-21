import { useState } from 'react'
import { Link } from 'react-router-dom'
import { Button } from '@/components/ui/button'
import { Badge, Empty, ErrorNote, Section, Select } from '@/components/ui/form'
import { api, useDueTasks, useFollowupDebt, useReplyTasks, useUnseenReplies, useWrite } from '@/lib/queries'
import { ReplyTaskCard } from '@/components/ReplyTaskCard'
import { endOfTodayIso, fmtDateTime } from '@/lib/format'
import { STAGE_LABEL, TASK_KIND_LABEL, personLabel } from '@/lib/wpie'
import { useAuth } from '@/providers/AuthProvider'
import type { Person } from '@/lib/types'

export default function Today() {
  const { member, user } = useAuth()
  const [who, setWho] = useState<Person | 'all'>(member?.person ?? 'all')
  const until = endOfTodayIso()
  const tasks = useDueTasks(until, who)
  const replies = useUnseenReplies()
  const debt = useFollowupDebt()
  const replyTasks = useReplyTasks()
  const done = useWrite((id: string) => api.finishTask(id), [['tasks'], ['lead']])
  const seen = useWrite((id: string) => api.markSeen(id, user!.id), [['messages'], ['lead']])
  const now = Date.now()

  return (
    <div className="space-y-4">
      <h1 className="text-xl font-semibold">Today</h1>

      <Section title={`Tasks from replies${replyTasks.data ? ` (${replyTasks.data.length})` : ''}`}>
        <p className="mb-2 text-sm text-muted-foreground">Things a seller asked for that a text can&apos;t do. Adil by default.</p>
        <ErrorNote error={replyTasks.error} />
        {replyTasks.data?.length === 0 && <Empty>Nothing waiting.</Empty>}
        <ul className="space-y-3">
          {replyTasks.data?.map((t) => <ReplyTaskCard key={t.id} t={t} />)}
        </ul>
      </Section>

      <Section
        title={`New replies${replies.data ? ` (${replies.data.length})` : ''}`}
      >
        <ErrorNote error={replies.error} />
        {replies.data?.length === 0 && <Empty>No new replies.</Empty>}
        <ul className="divide-y">
          {replies.data?.map((m) => (
            <li key={m.id} className="flex flex-col gap-1 py-3 sm:flex-row sm:items-start sm:justify-between">
              <div className="min-w-0">
                <Link to={`/lead/${m.lead_id}`} className="inline-flex min-h-11 items-center font-medium underline">
                  {m.lead?.owner_name ?? 'Lead'}
                </Link>
                <span className="text-sm text-muted-foreground"> - {m.lead?.property_address}</span>
                <p className="mt-1 whitespace-pre-wrap text-sm">{m.body}</p>
                <p className="text-xs text-muted-foreground">
                  {fmtDateTime(m.sent_at)} {m.is_opt_out && <Badge tone="bad">STOP</Badge>}
                </p>
              </div>
              <Button size="sm" variant="outline" disabled={seen.isPending} onClick={() => seen.mutate(m.id)}>
                Mark seen
              </Button>
            </li>
          ))}
        </ul>
      </Section>

      <Section
        title="Follow-ups due"
        right={
          <Select value={who} onChange={(e) => setWho(e.target.value as Person | 'all')} className="w-32">
            <option value="all">Everyone</option>
            <option value="colin">Colin</option>
            <option value="adil">Adil</option>
            <option value="thalia">Thalia</option>
          </Select>
        }
      >
        <ErrorNote error={tasks.error ?? done.error} />
        {tasks.data?.length === 0 && <Empty>Nothing due today.</Empty>}
        <ul className="divide-y">
          {tasks.data?.map((t) => {
            const late = new Date(t.due_at).getTime() < now - 60_000
            return (
              <li key={t.id} className="flex items-start justify-between gap-2 py-3">
                <div className="min-w-0">
                  <div className="flex flex-wrap items-center gap-2">
                    <span className="font-medium">{TASK_KIND_LABEL[t.kind] ?? t.kind}</span>
                    {late ? <Badge tone="bad">Overdue</Badge> : <Badge tone="info">Due today</Badge>}
                    <Badge>{personLabel(t.owner)}</Badge>
                  </div>
                  {t.lead && (
                    <Link to={`/lead/${t.lead.id}`} className="inline-flex min-h-11 items-center text-sm underline">
                      {t.lead.owner_name} - {t.lead.property_address}
                    </Link>
                  )}
                  <p className="text-xs text-muted-foreground">
                    {fmtDateTime(t.due_at)} {t.note ? `- ${t.note}` : ''}
                  </p>
                </div>
                <Button size="sm" disabled={done.isPending} onClick={() => done.mutate(t.id)}>
                  Done
                </Button>
              </li>
            )
          })}
        </ul>
      </Section>

      <Section title={`Follow-up debt${debt.data ? ` (${debt.data.length})` : ''}`}>
        <p className="mb-2 text-sm text-muted-foreground">Leads 2 or more days past their next action. Goal: zero by Friday.</p>
        <ErrorNote error={debt.error} />
        {debt.data?.length === 0 && <Empty>None. Good.</Empty>}
        <ul className="divide-y">
          {debt.data?.map((d) => (
            <li key={d.lead_id} className="py-2 text-sm">
              <Link to={`/lead/${d.lead_id}`} className="inline-flex min-h-11 items-center font-medium underline">
                {d.owner_name}
              </Link>{' '}
              - {STAGE_LABEL[d.stage]} - {d.days_late} days late{d.next_action ? ` (${d.next_action})` : ''}
            </li>
          ))}
        </ul>
      </Section>
    </div>
  )
}
