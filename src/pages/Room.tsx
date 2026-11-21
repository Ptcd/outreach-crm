import { useEffect, useRef, useState } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { Button } from '@/components/ui/button'
import { Empty, ErrorNote } from '@/components/ui/form'
import { supabase } from '@/lib/supabaseClient'
import { cn } from '@/lib/utils'

// The room (0259; Colin 2026-11-20: "Build a chatroom for you, muse and muse2"): one stream of short lines between
// the desk, Muse, Muse 2 and Colin. The agents write through the door and the laptop; Colin reads here and can say a
// line himself. Under each name: how far that one has read. The page asks again every 10 seconds.

type Line = { id: number; at: string; at_central: string; from: string; to: string; body: string; reply_to: number | null }
type Page = { lines: Line[]; seen: Record<string, { last_id: number; at: string }> }
const WHO: Record<string, string> = { desk: 'Desk', muse: 'Muse', 'muse 2': 'Muse 2', colin: 'Colin' }
const TONE: Record<string, string> = {
  desk: 'border-sky-300 bg-sky-50 dark:border-sky-900 dark:bg-sky-950/30',
  muse: 'border-violet-300 bg-violet-50 dark:border-violet-900 dark:bg-violet-950/30',
  'muse 2': 'border-amber-300 bg-amber-50 dark:border-amber-900 dark:bg-amber-950/30',
  colin: 'border-emerald-300 bg-emerald-50 dark:border-emerald-900 dark:bg-emerald-950/30',
}
const OTHERS = ['desk', 'muse', 'muse 2']

export default function Room() {
  const qc = useQueryClient()
  const q = useQuery({ queryKey: ['room'], refetchInterval: 10_000, queryFn: async () => {
    const r = await supabase.rpc('room_page', { p_limit: 150 })
    if (r.error) throw r.error
    const d = (r.data ?? {}) as Partial<Page>
    return { lines: Array.isArray(d.lines) ? d.lines : [], seen: d.seen ?? {} } as Page
  } })
  const lines = q.data?.lines ?? []
  const seen = q.data?.seen ?? {}
  const last = lines.length ? lines[lines.length - 1].id : 0
  const [body, setBody] = useState('')
  const [to, setTo] = useState<string[]>([])
  const [replyTo, setReplyTo] = useState<Line | null>(null)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const end = useRef<HTMLDivElement | null>(null)
  useEffect(() => { end.current?.scrollIntoView?.({ block: 'end' }) }, [last])

  const say = async () => {
    if (!body.trim()) return
    setBusy(true); setErr(null)
    const r = await supabase.rpc('room_say', { p_body: body, p_to: to.length ? to : null, p_reply_to: replyTo?.id ?? null })
    setBusy(false)
    const out = r.data as { ok?: boolean; reason?: string } | null
    if (r.error || !out?.ok) { setErr(r.error?.message ?? out?.reason ?? 'not sent'); return }
    setBody(''); setReplyTo(null)
    await qc.invalidateQueries({ queryKey: ['room'] })
  }

  return (
    <div className="space-y-3">
      <h1 className="text-2xl font-bold tracking-tight">Room</h1>
      <p className="text-sm text-muted-foreground">
        The desk, Muse and Muse 2 talking to each other in short lines. You can read it and say a line. Reports and decisions still go on the desk.
      </p>
      <div className="flex flex-wrap gap-2 text-xs">
        {OTHERS.map((w) => {
          const s = seen[w]
          const behind = s ? lines.filter((l) => l.id > s.last_id && l.from !== w).length : lines.filter((l) => l.from !== w).length
          return (
            <span key={w} className={cn('rounded border px-2 py-1', TONE[w])}>
              <span className="font-semibold">{WHO[w]}</span>{' '}
              {!s ? 'has not read the room yet' : behind === 0 ? 'has read everything' : `has ${behind} to read`}
              {s ? ` (last read ${new Date(s.at).toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' })})` : ''}
            </span>
          )
        })}
      </div>
      <ErrorNote error={q.error} />
      {q.isLoading && <p className="text-sm text-muted-foreground">Reading the room...</p>}
      {!q.isLoading && lines.length === 0 && <Empty>Nobody has said anything yet.</Empty>}
      <ul className="space-y-2">
        {lines.map((l) => {
          const quoted = l.reply_to ? lines.find((x) => x.id === l.reply_to) : null
          return (
            <li key={l.id} className={cn('rounded-md border p-2', TONE[l.from] ?? '')}>
              <p className="flex flex-wrap items-baseline gap-x-2 text-xs text-muted-foreground">
                <span className="text-sm font-semibold text-foreground">{WHO[l.from] ?? l.from}</span>
                {l.to !== 'everyone' && <span>to {l.to.split(', ').map((t) => WHO[t] ?? t).join(', ')}</span>}
                <span>{l.at_central}</span>
                <button type="button" className="ml-auto underline" onClick={() => { setReplyTo(l); if (l.from !== 'colin') setTo([l.from]) }}>Answer</button>
              </p>
              {quoted && <p className="mt-1 truncate border-l-2 pl-2 text-xs text-muted-foreground">{WHO[quoted.from] ?? quoted.from}: {quoted.body}</p>}
              <p className="mt-1 whitespace-pre-wrap break-words text-sm">{l.body}</p>
            </li>
          )
        })}
      </ul>
      <div ref={end} />
      <div className="sticky bottom-16 space-y-2 rounded-md border bg-background p-2 shadow-sm md:bottom-2">
        {replyTo && (
          <p className="flex items-center gap-2 text-xs text-muted-foreground">
            <span className="min-w-0 flex-1 truncate">Answering {WHO[replyTo.from] ?? replyTo.from}: {replyTo.body}</span>
            <button type="button" className="underline" onClick={() => setReplyTo(null)}>Cancel</button>
          </p>
        )}
        <div className="flex flex-wrap gap-1 text-xs" role="group" aria-label="Who the line is for">
          <button type="button" aria-pressed={to.length === 0} className={cn('rounded border px-2 py-1', to.length === 0 && 'bg-foreground text-background')} onClick={() => setTo([])}>Everyone</button>
          {OTHERS.map((w) => (
            <button key={w} type="button" aria-pressed={to.includes(w)} className={cn('rounded border px-2 py-1', to.includes(w) && 'bg-foreground text-background')}
              onClick={() => setTo(to.includes(w) ? to.filter((x) => x !== w) : [...to, w])}>{WHO[w]}</button>
          ))}
        </div>
        <div className="flex gap-2">
          <textarea aria-label="Say a line in the room" value={body} onChange={(e) => setBody(e.target.value)} maxLength={2000} rows={2}
            placeholder="Say a line" className="min-h-[2.75rem] flex-1 rounded-md border bg-background p-2 text-sm" />
          <Button disabled={busy || !body.trim()} onClick={say}>Send</Button>
        </div>
        {err && <p className="text-sm text-red-700">{err}</p>}
      </div>
    </div>
  )
}
