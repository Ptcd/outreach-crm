import { useState } from 'react'
import { Link } from 'react-router-dom'
import { Button } from '@/components/ui/button'
import { Badge, Empty, ErrorNote, Section, Select } from '@/components/ui/form'
import { api, useDueTasks, useFollowupDebt, useMyStops, useReplyTasks, useSellerRecovery, useUnseenReplies, useWrite } from '@/lib/queries'
import { ReplyTaskCard } from '@/components/ReplyTaskCard'
import { BeltHealthStrip } from '@/components/BeltHealthStrip'
import { StopCard } from '@/components/StopCard'
import { endOfTodayIso, fmtDateTime, fullAddress } from '@/lib/format'
import { STAGE_LABEL, TASK_KIND_LABEL, personLabel } from '@/lib/wpie'
import { useAuth } from '@/providers/AuthProvider'
import { PackagesToday } from '@/components/DealPackage'
import { MissedCalls } from '@/components/MissedCalls'
import { ownerFilterFor, useOnPhone, workerFor, type TaskOwner } from '@/lib/onPhone'
import { OnPhonePrompt, useColinHere } from '@/components/OnPhonePicker'
import { StatTiles } from '@/components/StatTiles'
import { ClipboardList, MessageCircle, PhoneCall, Sparkles, Zap } from 'lucide-react'

export default function Today() {
  const { member, user } = useAuth()
  const isOwner = useColinHere()   // Colin's view: on the shared login, the phone set to Colin (not Thalia on his login)
  const [picked] = useOnPhone()
  const worker = workerFor(member, picked)
  const [chosen, setWho] = useState<TaskOwner | null>(null)
  const who: TaskOwner = chosen ?? ownerFilterFor(worker, member?.person)
  const until = endOfTodayIso()
  const tasks = useDueTasks(until, who)
  const stops = useMyStops(until, who)
  const replies = useUnseenReplies()
  const debt = useFollowupDebt()
  const recovery = useSellerRecovery()
  const missingDate = recovery.data?.filter((c) => c.reason === 'missing_next_action' || c.reason === 'missing_next_stop') ?? []
  const otherRecovery = recovery.data?.filter((c) => c.reason !== 'missing_next_action' && c.reason !== 'missing_next_stop') ?? []
  const replyTasks = useReplyTasks()
  const done = useWrite((id: string) => api.finishTask(id), [['tasks'], ['lead']])
  const seen = useWrite((id: string) => api.markSeen(id, user!.id), [['messages'], ['lead']])
  const now = Date.now()
  // a caller's Today shows what she acts on (found walking the app as Thalia, 2026-10-27): STOPs need nothing from
  // her, and cards waiting on a text are Muse's, not hers
  const stopReplies = (replies.data ?? []).filter((m) => m.is_opt_out)
  const shownReplies = (replies.data ?? []).filter((m) => !m.is_opt_out)
  const debtRows = (debt.data ?? []).filter((d) => isOwner || !['opener_queued', 'opener_sent', 'postcard_mailed'].includes(d.stage))
  const markAllStops = async () => { for (const m of stopReplies) await seen.mutateAsync(m.id) }

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold tracking-tight">Today</h1>
          <p className="text-sm text-muted-foreground">{new Date().toLocaleDateString('en-US', { weekday: 'long', month: 'long', day: 'numeric' })}</p>
        </div>
        {/* straight into Power hour from the day's front page (Colin 2026-10-29) */}
        <Button asChild size="lg" className="h-12 px-5 text-base">
          <Link to="/calls?mode=power"><Zap className="mr-2 h-5 w-5" aria-hidden />Power hour</Link>
        </Button>
      </div>
      <OnPhonePrompt />
      <StatTiles tiles={[
        { label: 'New replies', value: replies.data?.length, icon: MessageCircle, tone: 'indigo', to: '/inbox' },
        { label: 'Calls due', value: stops.data?.length, icon: PhoneCall, tone: 'emerald', to: '/calls' },
        { label: 'Tasks due', value: tasks.data?.length, icon: ClipboardList, tone: 'amber' },
        { label: 'Seller asks', value: replyTasks.data?.length, icon: Sparkles, tone: 'rose' },
      ]} />
      {isOwner && <BeltHealthStrip />}
      <MissedCalls />
      <PackagesToday />
      <Section title={`Tasks from replies${replyTasks.data ? ` (${replyTasks.data.length})` : ''}`}>
        <p className="mb-2 text-sm text-muted-foreground">Things a seller asked for that a text can&apos;t do. Adil by default.</p>
        <ErrorNote error={replyTasks.error} />
        {replyTasks.data?.length === 0 && <Empty>Nothing waiting.</Empty>}
        <ul className="space-y-3">
          {replyTasks.data?.map((t) => <ReplyTaskCard key={t.id} t={t} />)}
        </ul>
      </Section>

      <Section
        title={`New replies${replies.data ? ` (${shownReplies.length})` : ''}`}
      >
        <ErrorNote error={replies.error} />
        {replies.data && shownReplies.length === 0 && <Empty>No new replies.</Empty>}
        {stopReplies.length > 0 && (
          <div className="mb-2 flex flex-wrap items-center gap-2 rounded-md bg-muted p-2 text-sm">
            <span>{stopReplies.length} STOP {stopReplies.length === 1 ? 'reply' : 'replies'}: already blocked, nothing to do.</span>
            <Button size="sm" variant="outline" disabled={seen.isPending} onClick={() => void markAllStops()}>Clear them</Button>
          </div>
        )}
        <ul className="divide-y">
          {shownReplies.map((m) => (
            <li key={m.id} className="flex flex-col gap-1 py-3 sm:flex-row sm:items-start sm:justify-between">
              <div className="min-w-0">
                <Link to={`/lead/${m.lead_id}`} className="inline-flex min-h-11 items-center font-medium underline">
                  {m.lead?.owner_name ?? 'Lead'}
                </Link>
                <span className="text-sm text-muted-foreground"> - {fullAddress(m.lead)}</span>
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
          <Select value={who} onChange={(e) => setWho(e.target.value as TaskOwner)} className="w-32" aria-label="Whose follow-ups">
            <option value="callers">Thalia + Adil</option>
            <option value="all">Everyone</option>
            <option value="colin">Colin</option>
            <option value="adil">Adil</option>
            <option value="thalia">Thalia</option>
          </Select>
        }
      >
        <ErrorNote error={tasks.error ?? done.error} />
        {tasks.data?.filter((t) => !['belt', 'call_list', 'after_stop'].includes(t.source ?? '')).length === 0 && <Empty>Nothing due today.</Empty>}
        <ul className="divide-y">
          {tasks.data?.filter((t) => !['belt', 'call_list', 'after_stop'].includes(t.source ?? '')).map((t) => {
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
                      {t.lead.owner_name} - {fullAddress(t.lead)}
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

      <Section title={`Follow-up debt${debt.data ? ` (${debtRows.length})` : ''}`}>
        <p className="mb-2 text-sm text-muted-foreground">Leads 2 or more days past their next action. Goal: zero by Friday.{isOwner ? '' : ' Cards waiting on a text are Muse’s and are left out.'}</p>
        <ErrorNote error={debt.error} />
        {debt.data && debtRows.length === 0 && <Empty>None. Good.</Empty>}
        <ul className="divide-y">
          {debtRows.map((d) => (
            <li key={d.lead_id} className="py-2 text-sm">
              <Link to={`/lead/${d.lead_id}`} className="inline-flex min-h-11 items-center font-medium underline">
                {d.owner_name}
              </Link>{' '}
              - {STAGE_LABEL[d.stage]} - {d.days_late} days late{d.next_action ? ` (${d.next_action})` : ''}
            </li>
          ))}
        </ul>
        <p className="mt-3 mb-1 text-sm font-medium">Missing date / next stop{recovery.data ? ` (${missingDate.length})` : ''}</p>
        <p className="mb-1 text-xs text-muted-foreground">Touched cards with no dated next action or no belt stop. Closed and suppressed cards stay out.</p>
        <ErrorNote error={recovery.error} />
        {recovery.data && missingDate.length === 0 && <p className="text-sm text-muted-foreground">Every touched card has a dated next step.</p>}
        <ul className="divide-y">
          {missingDate.map((c) => (
            <li key={c.lead_id} className="py-2 text-sm">
              <Link to={`/lead/${c.lead_id}`} className="inline-flex min-h-11 items-center font-medium underline">{c.owner_name}</Link>{' '}
              - {STAGE_LABEL[c.stage]} - <Badge tone="warn">missing date</Badge>{' '}<Badge>{personLabel(c.recovery_owner)}</Badge>
            </li>
          ))}
        </ul>
        <p className="mt-3 mb-1 text-sm font-medium">Conversation recovery{recovery.data ? ` (${otherRecovery.length})` : ''}</p>
        <p className="mb-1 text-xs text-muted-foreground">Calls needing an outcome and overdue belt stops.</p>
        {recovery.data && otherRecovery.length === 0 && <p className="text-sm text-muted-foreground">No conversations need recovery.</p>}
        <ul className="divide-y">
          {otherRecovery.map((c) => (
            <li key={c.lead_id} className="py-2 text-sm">
              <Link to={`/lead/${c.lead_id}`} className="inline-flex min-h-11 items-center font-medium underline">{c.owner_name}</Link>{' '}
              - {STAGE_LABEL[c.stage]} - <Badge tone={c.reason === 'call_outcome_needed' ? 'bad' : 'warn'}>
                {c.reason === 'call_outcome_needed' ? 'log call outcome' : 'overdue'}
              </Badge>{' '}<Badge>{personLabel(c.recovery_owner)}</Badge>
              {c.human_takeover_by && <span className="text-muted-foreground"> started by {c.human_takeover_by}</span>}
            </li>
          ))}
        </ul>
      </Section>

      <Section
        title={`Your stops${stops.data ? ` (${stops.data.length})` : ''}`}
        right={
          <Select value={who} onChange={(e) => setWho(e.target.value as TaskOwner)} className="w-32" aria-label="Whose stops">
            <option value="callers">Thalia + Adil</option>
            <option value="all">Everyone</option>
            <option value="colin">Colin</option>
            <option value="adil">Adil</option>
            <option value="thalia">Thalia</option>
          </Select>
        }
      >
        <p className="mb-2 text-sm text-muted-foreground">The belt&apos;s next stop on each card, and the day&apos;s call list: log the outcome and the next stop sets itself. The Calls page works these one at a time.</p>
        <ErrorNote error={stops.error} />
        {stops.data?.length === 0 && <Empty>No stops due. A hot reply pings you the moment it lands.</Empty>}
        <ul className="space-y-3">
          {stops.data?.map((t) => <StopCard key={t.id} t={t} now={now} />)}
        </ul>
      </Section>
    </div>
  )
}
