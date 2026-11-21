import { useEffect, useRef, useState } from 'react'
import { Link } from 'react-router-dom'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { LifeBuoy } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Empty, ErrorNote } from '@/components/ui/form'
import { supabase } from '@/lib/supabaseClient'
import { cn } from '@/lib/utils'
import { AttachButton, LineFiles, PickedFiles, useAttach, type RoomFile } from '@/components/RoomFiles'

// Help (0263; Colin 2026-11-20: "give Tyler and thalia access to the chat too so they can ask for help"): a caller's
// own line into the room where the desk, Muse and Colin talk. A caller sees what they wrote and what was written to
// them, nothing else: a card has one owner, so the other caller's questions and Colin's deals are not shown here.

type Line = { id: number; at: string; at_central: string; from: string; from_caller: boolean; to: string; body: string; reply_to: number | null; files?: RoomFile[] }
// what a caller most often needs: a tap fills the box, and they add the name or the address
const QUICK = ['I need more cards to call. I have worked my list.', 'A number on this card is wrong: ', 'What do I say to this seller? ', 'This card should not be on my list: ', 'The app is doing something odd: ']
const WHO: Record<string, string> = { desk: 'The desk', muse: 'Muse', 'muse 2': 'Muse 2', colin: 'Colin', thalia: 'Thalia', tyler: 'Tyler' }

export default function Help() {
  const qc = useQueryClient()
  const q = useQuery({ queryKey: ['room_mine'], refetchInterval: 10_000, queryFn: async () => {
    const r = await supabase.rpc('room_mine', { p_limit: 150 })
    if (r.error) throw r.error
    const d = (r.data ?? {}) as { you?: string; lines?: Line[] }
    return { you: d.you ?? '', lines: Array.isArray(d.lines) ? d.lines : [] }
  } })
  const lines = q.data?.lines ?? []
  const me = q.data?.you ?? ''
  const last = lines.length ? lines[lines.length - 1].id : 0
  const [body, setBody] = useState('')
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const end = useRef<HTMLDivElement | null>(null)
  useEffect(() => { end.current?.scrollIntoView?.({ block: 'end' }); void qc.invalidateQueries({ queryKey: ['room_mine_unread'] }) }, [last, qc])

  const attach = useAttach()
  const ask = async () => {
    if (!body.trim() && attach.picked.length === 0) return
    setBusy(true); setErr(null)
    // the files go up first; the question then names them
    const up = attach.picked.length ? await attach.send() : { ids: [] as string[] }
    if ('error' in up) { setBusy(false); setErr(up.error); return }
    const r = await supabase.rpc('room_ask', { p_body: body, p_files: up.ids.length ? up.ids : null })
    setBusy(false)
    const out = r.data as { ok?: boolean; reason?: string } | null
    if (r.error || !out?.ok) { setErr(r.error?.message ?? out?.reason ?? 'not sent'); return }
    setBody(''); attach.clear()
    await qc.invalidateQueries({ queryKey: ['room_mine'] })
  }

  return (
    <div className="space-y-3">
      <h1 className="text-2xl font-bold tracking-tight">Help</h1>
      <p className="text-sm text-muted-foreground">
        Ask here when you are stuck: a card that looks wrong, what to say, how something in the app works, or more cards to call. You can attach a screenshot or a photo with the paperclip.
        Your question goes to Muse and the desk, and Colin can see it.
        Only you see this page. An answer can take a few minutes; for something that cannot wait, call Colin.
      </p>
      <ErrorNote error={q.error} />
      {q.isLoading && <p className="text-sm text-muted-foreground">Reading...</p>}
      {!q.isLoading && lines.length === 0 && <Empty>Nothing asked yet. Write your question below.</Empty>}
      <ul className="space-y-2">
        {lines.map((l) => {
          const mine = l.from === me
          return (
            <li key={l.id} className={cn('rounded-md border p-2', mine ? 'ml-6 border-emerald-300 bg-emerald-50 dark:border-emerald-900 dark:bg-emerald-950/30' : 'mr-6 border-sky-300 bg-sky-50 dark:border-sky-900 dark:bg-sky-950/30')}>
              <p className="flex flex-wrap items-baseline gap-x-2 text-xs text-muted-foreground">
                <span className="text-sm font-semibold text-foreground">{mine ? 'You' : WHO[l.from] ?? l.from}</span>
                <span>{l.at_central}</span>
              </p>
              <p className="mt-1 whitespace-pre-wrap break-words text-sm">{l.body}</p>
              <LineFiles files={l.files} />
            </li>
          )
        })}
      </ul>
      <div ref={end} />
      <div className="sticky bottom-20 space-y-2 rounded-md border bg-background p-2 shadow-sm md:bottom-2">
        <div className="flex flex-wrap gap-1 text-xs" role="group" aria-label="Common asks">
          {QUICK.map((qk) => (
            <button key={qk} type="button" className="rounded border px-2 py-1 text-muted-foreground hover:bg-accent" onClick={() => setBody(qk)}>{qk.replace(/[:.]\s*$/, '').replace(/\. I have worked my list$/, '')}</button>
          ))}
        </div>
        <PickedFiles files={attach.picked} onRemove={attach.remove} />
        <div className="flex gap-2">
          <AttachButton onPick={attach.add} disabled={busy} />
          <textarea aria-label="Ask for help" value={body} onChange={(e) => setBody(e.target.value)} maxLength={2000} rows={2}
            placeholder="What do you need help with? Give the seller's name or address if it is about a card." className="min-h-[2.75rem] flex-1 rounded-md border bg-background p-2 text-sm" />
          <Button disabled={busy || (!body.trim() && attach.picked.length === 0)} onClick={ask}>{busy ? 'Sending' : 'Ask'}</Button>
        </div>
        {(err || attach.error) && <p className="text-sm text-red-700">{err ?? attach.error}</p>}
      </div>
    </div>
  )
}

/** The Help button in the header, for a caller only, with how many answers are unread. */
export function HelpLink() {
  const q = useQuery({ queryKey: ['room_mine_unread'], refetchInterval: 30_000, queryFn: async () => {
    const r = await supabase.rpc('room_mine_unread')
    return r.error ? 0 : Number(r.data ?? 0)
  } })
  const n = q.data ?? 0
  return (
    <Link to="/help" aria-label={n > 0 ? `Help: ${n} new` : 'Help'} title="Ask Muse, the desk or Colin for help"
      className="relative flex h-10 items-center gap-1.5 rounded-xl px-2.5 text-muted-foreground transition-colors hover:bg-accent hover:text-accent-foreground">
      <LifeBuoy className="h-5 w-5" aria-hidden /><span className="hidden sm:inline">Help</span>
      {n > 0 && <span className="absolute -right-0.5 -top-0.5 rounded-full bg-rose-500 px-1.5 py-px text-[11px] font-bold text-white">{n}</span>}
    </Link>
  )
}
