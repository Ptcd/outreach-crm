import { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { Link, useNavigate } from 'react-router-dom'
import { Button } from '@/components/ui/button'
import { Badge, Empty, ErrorNote, Section, Select } from '@/components/ui/form'
import { api, useDueTasks, useFollowupDebt, useMyStops, useReplyTasks, useSellerRecovery, useUnseenReplies, useWrite } from '@/lib/queries'
import { ReplyTaskCard } from '@/components/ReplyTaskCard'
import { BeltHealthStrip } from '@/components/BeltHealthStrip'
import { StopCard } from '@/components/StopCard'
import { NextStep } from '@/components/NextStep'
import { endOfTodayIso, fmtDateTime, fullAddress } from '@/lib/format'
import { STAGE_LABEL, TASK_KIND_LABEL, personLabel } from '@/lib/wpie'
import { useAuth } from '@/providers/AuthProvider'
import { PackagesToday } from '@/components/DealPackage'
import { MissedCalls } from '@/components/MissedCalls'
import { ownerFilterFor, useOnPhone, workerFor, type TaskOwner } from '@/lib/onPhone'
import { OnPhonePrompt, useColinHere } from '@/components/OnPhonePicker'
import { StatTiles } from '@/components/StatTiles'
import { BellRing, ClipboardList, MessageCircle, Moon, PhoneCall, Sparkles, Zap } from 'lucide-react'
import { supabase } from '@/lib/supabaseClient'
import { Nudges } from '@/components/Nudges'
import { CardLine } from '@/components/CardRow'
import { WalkControl } from '@/components/WalkControl'
import { PILES, groupPiles, type PileCard } from '@/lib/piles'

type Day = { dials: number; reached: number; packages: number; done: number; set: number; left_today: number; nudges?: number; resting?: number }

/** A caller's Today (0186; Colin 2026-11-04: "build the full shit so the system isnt stupid anymore"; Thalia: "five
 *  pages all claim to be my to-do list"): ONE list. Heads-ups for you, Call today, Booked and hot, Waiting on Colin,
 *  This week. Everything Colin's (packages, STOPs, recovery, debt, stops) stays off this screen. */
function CallerToday({ me, day }: { me: 'thalia' | 'adil'; day: Day | undefined }) {
  const q = useQuery({
    queryKey: ['my_piles', null],
    refetchInterval: 60_000,
    queryFn: async () => {
      const r = await supabase.rpc('my_piles', {})
      if (r.error) throw new Error(r.error.message)
      return r.data as { person: string; cards: PileCard[] }
    },
  })
  const piles = groupPiles(q.data?.cards ?? [])
  const show: { id: 'call_now' | 'booked' | 'colin' | 'this_week'; title: string }[] = [
    { id: 'call_now', title: 'Call today' }, { id: 'booked', title: 'Booked and hot' }, { id: 'colin', title: 'Waiting on Colin' }, { id: 'this_week', title: 'This week' },
  ]
  const name = me.charAt(0).toUpperCase() + me.slice(1)
  const navigate = useNavigate()
  // Today tells her the calls exist; Power hour makes them. "Dial these" hands Today's Call-today rows to Power hour in
  // this order (Colin 2026-11-04: Today and Power hour are two things on purpose, but one button closes the gap)
  const dialThese = (ids: string[]) => {
    try { sessionStorage.setItem('power:list', JSON.stringify({ label: 'Call today', ids, at: Date.now() })) } catch { /* private window: the queue's own order */ }
    navigate('/calls?mode=power&list=today')
  }
  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold tracking-tight">Today, {name}</h1>
          <p className="text-sm text-muted-foreground">{new Date().toLocaleDateString('en-US', { weekday: 'long', month: 'long', day: 'numeric' })}</p>
        </div>
        <Button asChild size="lg" className="h-12 px-5 text-base">
          <Link to="/calls?mode=power"><Zap className="mr-2 h-5 w-5" aria-hidden />Power hour</Link>
        </Button>
      </div>
      <OnPhonePrompt />
      <StatTiles tiles={[
        { label: 'Dials today', value: day?.dials, icon: PhoneCall, tone: 'indigo', to: '/calls' },
        { label: 'Reached', value: day?.reached, icon: Sparkles, tone: 'emerald' },
        { label: 'Left today', value: day?.left_today, icon: Zap, tone: 'rose', to: '/mine' },
        { label: 'Heads-ups', value: day?.nudges ?? 0, icon: BellRing, tone: 'amber' },
        { label: 'Resting', value: day?.resting ?? 0, icon: Moon, tone: 'indigo', to: '/mine#pile-resting' },
      ]} />
      <MissedCalls />
      <Nudges />
      <ErrorNote error={q.error} />
      {show.map((s) => {
        const rows = piles[s.id]
        const hint = PILES.find((p) => p.id === s.id)?.hint
        return (
          <Section key={s.id} title={`${s.title}${q.data ? ` (${rows.length})` : ''}`}>
            <p className="mb-2 text-sm text-muted-foreground">{hint}</p>
            {s.id === 'call_now' && rows.length > 0 && (
              <Button className="mb-2 h-11 w-full sm:w-auto" onClick={() => dialThese(rows.map((c) => c.lead_id))}>
                <Zap className="mr-2 h-4 w-4" aria-hidden />Dial these ({rows.length}) in Power hour
              </Button>
            )}
            {q.isLoading && <Empty>Loading...</Empty>}
            {q.data && rows.length === 0 && <Empty>{s.id === 'call_now' ? 'Nothing due. Power hour, or a card from This week.' : 'Nothing here.'}</Empty>}
            <ul className="divide-y">
              {rows.slice(0, 40).map((c) => {
                const booked = !!c.walk_at && (c.belt === 'visit_booked' || c.belt === 'call_booked' || c.stage === 'walkthrough_booked')
                const task = c.task_id && c.next_at
                  ? { id: c.task_id, lead_id: c.lead_id, due_at: c.next_at, kind: c.task_kind ?? 'call', owner: me, done_at: null, note: null, created_at: '', source: c.task_source }
                  : null
                return (
                  <li key={c.lead_id} className="flex flex-col gap-2 py-3 sm:flex-row sm:items-start sm:justify-between">
                    <CardLine c={c} />
                    {booked ? <WalkControl leadId={c.lead_id} kind={c.belt === 'visit_booked' || c.stage === 'walkthrough_booked' ? 'walk' : 'call'} />
                      : <NextStep leadId={c.lead_id} task={task} compact />}
                  </li>
                )
              })}
            </ul>
            {rows.length > 40 && <p className="mt-2 text-sm"><Link to={`/mine#pile-${s.id}`} className="underline">All {rows.length} on My cards</Link></p>}
          </Section>
        )
      })}
      <p className="text-sm text-muted-foreground">Everything else is on <Link to="/mine" className="underline">My cards</Link>: later, tried, not called, resting.</p>
    </div>
  )
}

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
  // a caller's day (0173): dials, reached, packages, what is left; Colin sees the lists' counts as before
  const mine = who === 'thalia' || who === 'adil' ? who : null
  const day = useQuery({
    queryKey: ['my_day', mine],
    enabled: mine != null,
    refetchInterval: 60_000,
    queryFn: async () => { const r = await api.myDay(mine); if (r.error) throw new Error(r.error.message); return r.data as Day },
  })
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

  // a caller gets her own one-list Today (0186); Colin, and the shared login set to Colin, keep the full page
  if (member?.role === 'caller' && (member.person === 'thalia' || member.person === 'adil')) return <CallerToday me={member.person} day={day.data} />

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
      {mine ? (
        <StatTiles tiles={[
          { label: 'Dials today', value: day.data?.dials, icon: PhoneCall, tone: 'indigo', to: '/calls' },
          { label: 'Reached', value: day.data?.reached, icon: Sparkles, tone: 'emerald' },
          { label: 'Packages', value: day.data?.packages, icon: ClipboardList, tone: 'amber' },
          { label: 'Left today', value: day.data?.left_today, icon: Zap, tone: 'rose', to: '/mine' },
        ]} />
      ) : (
        <StatTiles tiles={[
          { label: 'New replies', value: replies.data?.length, icon: MessageCircle, tone: 'indigo', to: '/inbox' },
          { label: 'Calls due', value: stops.data?.length, icon: PhoneCall, tone: 'emerald', to: '/calls' },
          { label: 'Tasks due', value: tasks.data?.length, icon: ClipboardList, tone: 'amber' },
          { label: 'Seller asks', value: replyTasks.data?.length, icon: Sparkles, tone: 'rose' },
        ]} />
      )}
      {isOwner && <BeltHealthStrip />}
      <MissedCalls />
      <Nudges />
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
            <option value="adil">Tyler</option>
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
                <NextStep leadId={t.lead_id} task={t} compact />
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
            <option value="adil">Tyler</option>
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
