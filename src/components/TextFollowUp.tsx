// Follow-ups from a text thread, and the text follow-ups due (0200; Colin 2026-11-07: "They need some way to set
// followups from texting ... cross method followup structure"). One follow-up per card per caller whatever it was set
// from; it carries how (text or call), which number and the one line to open with. A text follow-up comes back to the
// caller on the Texts page when due, line prefilled, one tap to send; a call follow-up goes to the dialer as before.
// The seller moving first wins: a text from them after the follow-up was set is flagged, and answering in the thread
// closes the follow-up by itself.
import { useState } from 'react'
import { Link } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { Button } from '@/components/ui/button'
import { Badge, ErrorNote, Textarea } from '@/components/ui/form'
import { WhenPicker } from '@/components/NextStep'
import { api, useWrite } from '@/lib/queries'
import { supabase } from '@/lib/supabaseClient'
import { fmtDateTime, fmtPhone, fullAddress } from '@/lib/format'
import { cn } from '@/lib/utils'

export type DueText = {
  task_id: string; lead_id: string; due_at: string; owner: string; note: string | null; title: string | null
  say: string | null; phone10: string; owner_name: string | null; property_address: string | null; municipality: string | null
  stage: string; overdue: boolean; they_texted_first: boolean; last_in: string | null; last_in_at: string | null
}

export const DUE_KEYS = (leadId: string | null) => [['text_followups_due'], ['tasks'], ['my_piles'], ['power_dial'], ['texts_live'], ['lead', leadId ?? ''], ['card_brief', leadId ?? '']]

/** My text follow-ups due by the end of today, overdue first (Colin sees everyone's). Refreshes every minute. */
export function useTextFollowupsDue(enabled = true) {
  return useQuery({
    queryKey: ['text_followups_due'],
    enabled,
    refetchInterval: 60_000,
    queryFn: async () => {
      const r = await supabase.rpc('text_followups_due')
      if (r.error) throw new Error(r.error.message)
      return (r.data ?? []) as DueText[]
    },
  })
}

const unwrap = (r: { data: unknown; error: { message: string } | null }) => {
  const d = r.data as { ok?: boolean; reason?: string } | null
  return { error: r.error ?? (d && d.ok === false ? { message: d.reason ?? 'not saved' } : null) }
}

const toggle = 'min-h-9 rounded-md border px-2.5 text-xs font-medium hover:bg-accent'

/** Set a follow-up from a thread: how (text them back / call them back), the line, when. `beforeSet` runs first
 *  (the Texts page takes the thread over so Muse stays off it). */
export function FollowUpPanel({ leadId, phone, defaultSay, beforeSet, onSet }: {
  leadId: string; phone: string | null; defaultSay?: string | null
  beforeSet?: () => Promise<unknown>; onSet?: (how: 'text' | 'call', atIso: string) => void
}) {
  const [how, setHow] = useState<'text' | 'call'>('text')
  const [say, setSay] = useState(defaultSay ?? '')
  const [msg, setMsg] = useState<string | null>(null)
  const set = useWrite(async (atIso: string) => {
    if (beforeSet) await beforeSet()
    const r = unwrap(await api.followupSetHow(leadId, atIso, how, say.trim() || null, phone))
    if (!r.error) {
      setMsg(how === 'text' ? `Set. It comes back to you on Texts under "Follow-ups due" ${fmtDateTime(atIso)}, the line ready to send.`
        : `Set. It is in your dialer ${fmtDateTime(atIso)}.`)
      onSet?.(how, atIso)
    }
    return r
  }, DUE_KEYS(leadId))
  return (
    <div className="space-y-2 rounded-md bg-muted p-2">
      <div className="flex flex-wrap items-center gap-1.5">
        <span className="text-xs font-medium">How you'll reach back:</span>
        <button type="button" className={cn(toggle, how === 'text' && 'bg-accent')} onClick={() => setHow('text')}>Text them</button>
        <button type="button" className={cn(toggle, how === 'call' && 'bg-accent')} onClick={() => setHow('call')}>Call them</button>
      </div>
      <Textarea rows={2} value={say} onChange={(e) => setSay(e.target.value)} aria-label={how === 'text' ? 'The text to send then' : 'When you call back, say'}
        placeholder={how === 'text'
          ? 'The text that goes then, e.g. "Hi Jolene, Tyler here. Checking in on the HOA fight; any change on your end?"'
          : 'When you call back, say: "you said the tenant leaves in March; did that happen?"'} />
      <WhenPicker onPick={(iso) => set.mutate(iso)} busy={set.isPending} label={how === 'text' ? 'Text them then' : 'Call them then'} />
      {msg && <p className="text-sm">{msg}</p>}
      <ErrorNote error={set.error} />
      <p className="text-xs text-muted-foreground">
        One follow-up per card: setting another moves it. If they text first, it shows here flagged and your answer in the thread closes it.
      </p>
    </div>
  )
}

/** One text follow-up that is due: the line prefilled, one tap to send; or move it, or close it without sending. */
export function DueTextCard({ d }: { d: DueText }) {
  const [text, setText] = useState(d.say ?? '')
  const [panel, setPanel] = useState<'move' | null>(null)
  const [msg, setMsg] = useState<string | null>(null)
  const keys = DUE_KEYS(d.lead_id)
  const send = useWrite(async (body: string) => {
    const r = await api.sendCardText(d.lead_id, d.phone10, body)
    if (r.error) return r
    const res = (r as { data?: { outcome: string; reason?: string } }).data
    if (res?.outcome === 'refused') return { error: { message: res.reason ?? 'not sent' } }
    // the team text closes the follow-up through the database trigger; close it here too in case it was dry-sent
    await api.followupDone(d.task_id, 'done', 'sent the follow-up text')
    setMsg(res?.outcome === 'sent' ? 'Sent. Follow-up closed.' : res?.outcome === 'queued' ? `Held for the morning (${res.reason ?? 'quiet hours'}). Follow-up closed.` : 'Recorded. Follow-up closed.')
    return { error: null }
  }, keys)
  const done = useWrite(async () => unwrap(await api.followupDone(d.task_id, 'done', 'closed from Texts without sending')), keys)
  const move = useWrite(async (atIso: string) => unwrap(await api.followupMove(d.task_id, atIso, 'moved from Texts')), keys)
  const name = d.owner_name || fmtPhone(d.phone10)
  const addr = fullAddress({ property_address: d.property_address, municipality: d.municipality })
  return (
    <li className={cn('rounded-2xl border bg-card p-4 shadow-[var(--shadow-soft)]', d.overdue && 'border-destructive/50')}>
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div className="min-w-0">
          <p className="truncate text-base font-semibold"><Link className="hover:underline" to={`/lead/${d.lead_id}#texts`}>{name}</Link></p>
          <p className="truncate text-sm text-muted-foreground">{addr || '-'} · {fmtPhone(d.phone10)}</p>
        </div>
        <div className="flex flex-wrap items-center gap-1.5">
          <Badge tone={d.overdue ? 'bad' : 'info'}>{d.overdue ? `overdue · ${fmtDateTime(d.due_at)}` : `due ${fmtDateTime(d.due_at)}`}</Badge>
          {d.they_texted_first && <Badge tone="warn">they texted first</Badge>}
        </div>
      </div>
      {d.they_texted_first && d.last_in && (
        <div className="mt-2 flex flex-col items-start">
          <p className="max-w-[90%] whitespace-pre-wrap rounded-2xl rounded-bl-md bg-muted px-3 py-2 text-sm">{d.last_in}</p>
          <span className="mt-0.5 px-1 text-[11px] text-muted-foreground">them · {d.last_in_at ? fmtDateTime(d.last_in_at) : ''} · answer them first; your answer closes this</span>
        </div>
      )}
      {d.note && d.note !== d.say && <p className="mt-2 text-xs text-muted-foreground">{d.note}</p>}
      <div className="mt-3 space-y-2">
        <Textarea rows={2} value={text} onChange={(e) => { setText(e.target.value); setMsg(null) }} aria-label="The text to send" placeholder="The text to send now" />
        <div className="flex flex-wrap items-center gap-2">
          <Button className="h-11 px-6" disabled={!text.trim() || send.isPending} onClick={() => send.mutate(text.trim())}>{send.isPending ? 'Sending...' : 'Send text'}</Button>
          <Button variant="outline" className="h-11" disabled={done.isPending} onClick={() => done.mutate(undefined as never)}>Done without sending</Button>
          <Button variant="outline" className="h-11" onClick={() => setPanel(panel === 'move' ? null : 'move')}>Move</Button>
          <Link to={`/lead/${d.lead_id}#texts`} className="text-sm underline-offset-2 hover:underline">The thread</Link>
          {msg && <span className="text-sm">{msg}</span>}
        </div>
        {panel === 'move' && <WhenPicker onPick={(iso) => { move.mutate(iso); setPanel(null) }} busy={move.isPending} label="Move it" />}
        <ErrorNote error={send.error ?? done.error ?? move.error} />
      </div>
    </li>
  )
}
