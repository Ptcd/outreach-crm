import { useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { Button } from '@/components/ui/button'
import { Badge, Empty, ErrorNote, Textarea } from '@/components/ui/form'
import { CallButton } from '@/components/CallButton'
import { api, useTextsLive, useWrite, type LiveThread } from '@/lib/queries'
import { useAuth } from '@/providers/AuthProvider'
import { fmtDateTime, fmtPhone, fullAddress } from '@/lib/format'
import { cn } from '@/lib/utils'

// The texts as they happen (Colin 2026-10-30: "Adil and Thalia can't see the texts happening so they can't jump in").
// Every thread with a seller text in the last two days, newest first: their last text, our last answer and who gave it
// (Muse, a person, the automation), whether we owe an answer, and who owns the thread. "Take over" makes the thread a
// person's: Muse, the belt and the follow-ups leave that phone alone until it is handed back (migration 0146).
type Chip = 'waiting' | 'all' | 'mine'

const PERSON_LABEL: Record<string, string> = { colin: 'Colin', thalia: 'Thalia', adil: 'Adil' }
const who = (by: string | null | undefined) => {
  const b = (by ?? '').toLowerCase()
  if (!b) return 'us'
  if (b.startsWith('muse')) return 'Muse'
  if (b in PERSON_LABEL) return PERSON_LABEL[b]
  if (b === 'automation' || b === 'first text') return b === 'first text' ? 'the first text' : 'the automation'
  return by as string
}

export default function Texts() {
  const { member } = useAuth()
  const me = member?.person ?? null
  const q = useTextsLive(48)
  const [chip, setChip] = useState<Chip>('waiting')
  const rows = useMemo(() => (q.data ?? []).filter((t) =>
    chip === 'all' ? true : chip === 'mine' ? t.owner === me : (t.unanswered && !t.last_in.opt_out)), [q.data, chip, me])
  const waiting = (q.data ?? []).filter((t) => t.unanswered && !t.last_in.opt_out).length
  const mine = (q.data ?? []).filter((t) => t.owner === me).length

  return (
    <div className="space-y-4">
      <div className="flex items-baseline justify-between">
        <h1 className="text-2xl font-bold tracking-tight">Texts</h1>
        <span className="text-xs text-muted-foreground">{q.isFetching ? 'updating...' : q.dataUpdatedAt ? `as of ${fmtDateTime(new Date(q.dataUpdatedAt).toISOString())}` : ''}</span>
      </div>
      <p className="text-sm text-muted-foreground">
        Seller texts from the last two days, newest first. Muse answers them; take one over and Muse, the belt and the follow-ups leave that phone to you.
      </p>
      <div className="sticky top-0 z-10 -mx-1 flex gap-2 overflow-x-auto bg-background/95 px-1 py-2 backdrop-blur" role="tablist" aria-label="Filter">
        {([['waiting', `Waiting on us (${waiting})`], ['all', `All (${(q.data ?? []).length})`], ['mine', `Mine (${mine})`]] as [Chip, string][]).map(([id, label]) => (
          <button key={id} role="tab" aria-selected={chip === id} onClick={() => setChip(id)}
            className={cn('h-11 shrink-0 rounded-full border px-4 text-sm', chip === id ? 'border-primary bg-primary text-primary-foreground' : 'bg-background')}>
            {label}
          </button>
        ))}
      </div>
      <ErrorNote error={q.error} />
      {q.isLoading && <Empty>Loading the texts...</Empty>}
      {q.data && rows.length === 0 && <Empty>{chip === 'waiting' ? 'Nobody is waiting on an answer.' : chip === 'mine' ? 'You have not taken a thread over.' : 'No seller texts in the last two days.'}</Empty>}
      <ul className="space-y-3" aria-label="Text threads">
        {rows.map((t) => <ThreadCard key={t.phone10} t={t} me={me} />)}
      </ul>
    </div>
  )
}

function ThreadCard({ t, me }: { t: LiveThread; me: string | null }) {
  const [text, setText] = useState('')
  const [open, setOpen] = useState(false)
  const [note, setNote] = useState<string | null>(null)
  const mineNow = !!me && t.owner === me
  const someoneElse = !!t.owner && t.owner !== me
  const keys = [['texts_live'], ['inbox'], ['reply_drafts'], ...(t.lead_id ? [['lead', t.lead_id]] : [])]
  const take = useWrite(() => api.threadTake(t.lead_id, t.phone10, null), keys)
  const release = useWrite(() => api.threadRelease(t.phone10), keys)
  const send = useWrite((body: string) => (t.lead_id ? api.sendCardText(t.lead_id, t.phone10, body) : Promise.resolve({ error: { message: 'no card for this number' } }))
    .then((r) => {
      if (!r.error) {
        const d = (r as { data?: { outcome: string; reason?: string } }).data
        setNote(d?.outcome === 'sent' ? 'Sent.' : d?.outcome === 'queued' ? `Held for the morning: ${d.reason ?? 'quiet hours'}.` : (d?.reason ?? d?.outcome ?? ''))
        setText('')
      }
      return r
    }), keys)
  useEffect(() => { if (mineNow) setOpen(true) }, [mineNow])
  const name = t.owner_name || fmtPhone(t.phone10)
  const addr = fullAddress({ property_address: t.address, municipality: t.municipality })

  return (
    <li className={cn('rounded-2xl border bg-card p-4 shadow-[var(--shadow-soft)]', t.unanswered && !t.last_in.opt_out && 'border-primary/50')}>
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div className="min-w-0">
          <p className="truncate text-base font-semibold">
            {t.lead_id ? <Link className="hover:underline" to={`/lead/${t.lead_id}#texts`}>{name}</Link> : name}
          </p>
          <p className="truncate text-sm text-muted-foreground">{addr || 'no card for this number'}{t.address ? ` · ${fmtPhone(t.phone10)}` : ''}</p>
        </div>
        <div className="flex flex-wrap items-center gap-1.5">
          {t.last_in.opt_out ? <Badge tone="bad">opted out</Badge>
            : t.unanswered ? <Badge tone="warn">waiting on us</Badge> : <Badge tone="good">answered</Badge>}
          {t.owner ? <Badge tone={mineNow ? 'info' : 'muted'}>{mineNow ? 'yours' : `${PERSON_LABEL[t.owner] ?? t.owner} has it`}</Badge> : <Badge>Muse</Badge>}
          {t.hot && <Badge tone="bad">hot</Badge>}
          {t.callback_slot && <Badge tone="info">call: {t.callback_slot}</Badge>}
        </div>
      </div>
      <div className="mt-3 space-y-2 text-sm">
        <div className="flex flex-col items-start">
          <p className="max-w-[90%] whitespace-pre-wrap rounded-2xl rounded-bl-md bg-muted px-3 py-2">{t.last_in.body || '(empty)'}</p>
          <span className="mt-0.5 px-1 text-[11px] text-muted-foreground">them · {fmtDateTime(t.last_in.at)}</span>
        </div>
        {t.last_out && (
          <div className="flex flex-col items-end">
            <p className={cn('max-w-[90%] whitespace-pre-wrap rounded-2xl rounded-br-md px-3 py-2 text-white',
              t.last_out.at < t.last_in.at ? 'bg-muted-foreground/60' : 'bg-primary')}>{t.last_out.body || '(empty)'}</p>
            <span className="mt-0.5 px-1 text-[11px] text-muted-foreground">{who(t.last_out.by)} · {fmtDateTime(t.last_out.at)}{t.last_out.at < t.last_in.at ? ' (before their last text)' : ''}</span>
          </div>
        )}
      </div>
      <div className="mt-3 flex flex-wrap items-center gap-2">
        {!t.last_in.opt_out && !mineNow && !someoneElse && (
          <Button variant="outline" className="h-10" disabled={take.isPending || !me} onClick={() => take.mutate(undefined as never)}>
            {take.isPending ? 'Taking over...' : 'Take over'}
          </Button>
        )}
        {mineNow && (
          <Button variant="outline" className="h-10" disabled={release.isPending} onClick={() => release.mutate(undefined as never)}>
            {release.isPending ? 'Handing back...' : 'Hand back to Muse'}
          </Button>
        )}
        {someoneElse && <span className="text-sm text-muted-foreground">{PERSON_LABEL[t.owner!] ?? t.owner} is on this one.</span>}
        {t.lead_id && !t.last_in.opt_out && <CallButton to={t.phone10} leadId={t.lead_id} name={t.owner_name} address={t.address} size="sm" className="h-10" />}
        {t.lead_id && <Link to={`/lead/${t.lead_id}`} className="text-sm underline-offset-2 hover:underline">Open the card</Link>}
      </div>
      {(take.error || release.error) && <ErrorNote error={take.error ?? release.error} />}
      {mineNow && open && t.lead_id && !t.last_in.opt_out && (
        <div className="mt-3 space-y-2 border-t pt-3">
          <Textarea value={text} onChange={(e) => { setText(e.target.value); setNote(null) }} rows={2} placeholder={`Text ${fmtPhone(t.phone10)} as yourself`} aria-label="Your reply" />
          <div className="flex items-center gap-2">
            <Button className="h-11 px-6" disabled={!text.trim() || send.isPending} onClick={() => send.mutate(text.trim())}>
              {send.isPending ? 'Sending...' : 'Send text'}
            </Button>
            {note && <span className="text-sm">{note}</span>}
          </div>
          {send.error && <ErrorNote error={send.error} />}
          <p className="text-xs text-muted-foreground">Same rules as any text: no price, no business name; held until morning in quiet hours.</p>
        </div>
      )}
    </li>
  )
}
