import { useEffect, useRef, useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { Link } from 'react-router-dom'
import { Button } from '@/components/ui/button'
import { Badge, Textarea } from '@/components/ui/form'
import { api, type WaitingDraft } from '@/lib/queries'
import { fmtDateTime, fmtPhone } from '@/lib/format'
import { intentText } from '@/lib/inbox'
import { cn } from '@/lib/utils'

type Result = { kind: 'sent' | 'dry' | 'queued' | 'skipped' | 'error'; text: string }

function resultOf(outcome: string | undefined, reason: string | undefined, action: 'approve' | 'skip'): Result {
  if (action === 'skip') return { kind: 'skipped', text: 'Skipped. Nothing was sent.' }
  if (outcome === 'sent') return { kind: 'sent', text: 'Sent.' }
  if (outcome === 'dry_sent') return { kind: 'dry', text: 'Approved. Live sending is off, so it was recorded as "would send".' }
  if (outcome === 'queued') return { kind: 'queued', text: `Approved. ${reason ?? 'It goes out at 8am.'}` }
  return { kind: 'error', text: reason ?? outcome ?? 'Not sent.' }
}

const RESULT_TONE: Record<Result['kind'], string> = {
  sent: 'bg-emerald-600 text-white',
  dry: 'bg-emerald-600 text-white',
  queued: 'bg-blue-600 text-white',
  skipped: 'bg-slate-600 text-white',
  error: 'bg-red-600 text-white',
}

function displayName(d: WaitingDraft): string {
  if (d.is_test) return 'TEST - your phone'
  return d.owner_name?.trim() || fmtPhone(d.phone10)
}

// The main phone screen: one reply waiting for Colin at a time. The seller's latest text is
// big, the draft is right under it, and Approve / Edit / Skip sit above the bottom bar where
// the thumb is. After a tap the card leaves, the next one slides in and a line says what happened; swipe works too.
export function ReviewDeck({ drafts, startId }: { drafts: WaitingDraft[]; startId?: string | null }) {
  const qc = useQueryClient()
  // Order fixed for this visit; drafts that arrive later join the end.
  const [ids, setIds] = useState(() => drafts.map((d) => d.id))
  const seen = useRef(new Map<string, WaitingDraft>())
  for (const x of drafts) seen.current.set(x.id, x)
  const byId = seen.current
  const [idx, setIdx] = useState(() => Math.max(0, startId ? ids.indexOf(startId) : 0))
  const [texts, setTexts] = useState<Record<string, string>>({})
  const [editing, setEditing] = useState(false)
  const [busy, setBusy] = useState(false)
  // drafts approved or skipped on this screen: they leave the deck at once (Colin 2026-10-23: "skipping it doesn't
  // get rid of it"); the bar above the next card says what happened to the last one
  const [handled, setHandled] = useState<Record<string, true>>({})
  const [last, setLast] = useState<{ name: string; result: Result } | null>(null)
  // A draft that stopped waiting elsewhere (skipped on another phone, its lead marked do not contact, they texted
  // again) leaves the deck too. The phone's saved copy can be hours old (Colin 2026-10-23: a skipped draft for a
  // dnc lead was back in Needs you).
  useEffect(() => {
    const live = new Set(drafts.map((x) => x.id))
    setIds((prev) => [...prev.filter((x) => live.has(x)), ...drafts.map((x) => x.id).filter((x) => !prev.includes(x))])
  }, [drafts])
  const open = ids.filter((x) => !handled[x])
  useEffect(() => { setIdx((i) => Math.max(0, Math.min(i, open.length - 1))) }, [open.length])
  const touch = useRef<number | null>(null)
  const area = useRef<HTMLTextAreaElement>(null)
  const [carding, setCarding] = useState(false)
  const [cardError, setCardError] = useState<string | null>(null)

  const id = open[idx]
  const d = id ? byId.get(id) : undefined
  useEffect(() => { setEditing(false); setCardError(null) }, [idx, id])
  useEffect(() => { if (editing) area.current?.focus() }, [editing])
  if (!open.length && !last) return null

  const go = (n: number) => setIdx((i) => Math.min(open.length - 1, Math.max(0, i + n)))
  const text = id ? (texts[id] ?? d?.body ?? '') : ''
  // A text from a number with no card (a broker, someone answering a letter): make the card from here
  const makeCard = async () => {
    if (!d) return
    setCarding(true); setCardError(null)
    try {
      const r = await api.cardFromText(d.id)
      const data = r.data as { ok?: boolean; lead_id?: string; reason?: string } | null
      if (r.error || !data?.ok || !data.lead_id) { setCardError(r.error?.message ?? data?.reason ?? 'Could not make the card.'); return }
      byId.set(d.id, { ...d, lead_id: data.lead_id })
      void qc.invalidateQueries({ queryKey: ['reply_drafts'] })
      void qc.invalidateQueries({ queryKey: ['inbox'] })
    } finally {
      setCarding(false)
    }
  }
  // earlier texts for context (your opener, their last few), not the one being answered
  const prior = d ? d.thread.filter((l) => !(l.who === 'them' && l.body === d.inbound_body)).slice(-3) : []

  const act = async (action: 'approve' | 'skip') => {
    if (!id) return
    setBusy(true)
    try {
      const r = await api.replyAction(id, action, action === 'approve' ? text : undefined)
      const data = (r as { data?: { outcome: string; reason?: string } }).data
      const res: Result = r.error ? { kind: 'error', text: r.error.message } : resultOf(data?.outcome, data?.reason, action)
      const name = d ? displayName(d) : ''
      setLast({ name, result: res })
      // an error keeps the card so it can be tried again; anything else is done with it
      if (res.kind !== 'error') setHandled((m) => ({ ...m, [id]: true }))
      void qc.invalidateQueries({ queryKey: ['reply_waiting'] })
      void qc.invalidateQueries({ queryKey: ['reply_drafts'] })
      void qc.invalidateQueries({ queryKey: ['inbox'] })
    } catch (e) {
      setLast({ name: d ? displayName(d) : '', result: { kind: 'error', text: e instanceof Error ? e.message : String(e) } })
    } finally {
      setBusy(false)
      setEditing(false)
    }
  }

  return (
    <section aria-label="Replies waiting for you" className="space-y-3 pb-28 sm:pb-0"
      onTouchStart={(e) => { touch.current = e.touches[0].clientX }}
      onTouchEnd={(e) => {
        if (touch.current == null || editing) return
        const dx = e.changedTouches[0].clientX - touch.current
        touch.current = null
        if (dx < -70) go(1)
        if (dx > 70) go(-1)
      }}>
      <div className="flex items-center justify-between gap-2">
        <h2 className="text-lg font-semibold">Needs you <span className="text-muted-foreground">· {open.length ? `${idx + 1} of ${open.length}` : 'all done'}</span></h2>
        <div className="flex gap-1">
          <Button variant="outline" className="h-11 w-12 text-2xl" aria-label="Previous" disabled={idx === 0} onClick={() => go(-1)}>‹</Button>
          <Button variant="outline" className="h-11 w-12 text-2xl" aria-label="Next" disabled={idx >= open.length - 1} onClick={() => go(1)}>›</Button>
        </div>
      </div>

      {last && (
        <p role="status" className={cn('rounded-lg px-3 py-2 text-sm font-medium', RESULT_TONE[last.result.kind])}>
          {last.name ? `${last.name}: ` : ''}{last.result.text}
        </p>
      )}

      {d ? (
        <article id={`draft-${d.id}`} className="rounded-xl border bg-card p-4 shadow-sm">
          <div className="flex flex-wrap items-baseline gap-x-2">
            <h3 className="text-lg font-semibold">
              {d.lead_id ? <Link to={`/lead/${d.lead_id}#history`} className="underline underline-offset-4">{displayName(d)}</Link> : displayName(d)}
            </h3>
            {d.is_test && <Badge tone="bad">TEST</Badge>}
          </div>
          <p className="text-sm text-muted-foreground">
            {d.property_address ? `${d.property_address} · ` : ''}{fmtPhone(d.phone10)}
          </p>
          {d.lead_id ? (
            <Link to={`/lead/${d.lead_id}#history`} className="mt-1 inline-flex min-h-11 items-center text-sm font-medium text-primary underline">
              Everything with them (texts, calls, notes)
            </Link>
          ) : !d.is_test && (
            <div className="mt-1">
              <p className="text-sm text-muted-foreground">This number has no card yet.</p>
              <Button variant="outline" className="mt-1 h-11" disabled={carding} onClick={() => void makeCard()}>
                {carding ? 'Making the card...' : 'Make a card for this number'}
              </Button>
              {cardError && <p className="mt-1 text-sm text-red-600">{cardError}</p>}
            </div>
          )}

          {prior.length > 0 && (
            <div className="mt-3 space-y-1.5">
              {prior.map((l) => (
                <div key={l.key} className={cn('rounded-lg px-3 py-1.5 text-sm text-muted-foreground', l.who === 'us' ? 'ml-8 bg-primary/10' : 'mr-8 bg-muted')}>
                  <p className="line-clamp-2"><span className="sr-only">{l.who === 'us' ? 'You: ' : 'Them: '}</span>{l.body}</p>
                </div>
              ))}
            </div>
          )}
          <div className="mt-3 rounded-xl bg-muted p-3">
            <p className="text-xl leading-snug">{d.inbound_body}</p>
            <p className="mt-1 text-xs text-muted-foreground">
              {fmtDateTime(d.inbound_at)}{d.intent ? ` · read as: ${intentText(d.intent)}` : ''}
            </p>
          </div>

          <div className="mt-3">
            <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
              {d.body ? 'Draft reply' : 'No draft - write the reply'}
            </p>
            {editing || !d.body ? (
              <Textarea ref={area} value={text} rows={4} className="mt-1 text-lg"
                onChange={(e) => setTexts((m) => ({ ...m, [d.id]: e.target.value }))} aria-label="Reply text" />
            ) : (
              <p className="mt-1 rounded-xl border-2 border-primary/30 p-3 text-lg leading-snug">{text}</p>
            )}
          </div>
        </article>
      ) : (
        <p className="rounded-xl border bg-card p-4 text-base">Nothing else needs you right now.</p>
      )}

      {/* thumb bar: sits above the bottom navigation on a phone */}
      {d && <div className="fixed inset-x-0 bottom-[calc(4rem+env(safe-area-inset-bottom))] z-20 !m-0 border-t bg-background p-3 shadow-[0_-4px_12px_rgba(0,0,0,0.06)] sm:static sm:border-0 sm:bg-transparent sm:p-0">
        <div className="mx-auto max-w-5xl">
          {d ? (
            <div className="grid grid-cols-3 gap-2">
              <Button className="h-12 text-base" disabled={busy || !text.trim()} onClick={() => void act('approve')}>Approve</Button>
              <Button className="h-12 text-base" variant="outline" disabled={busy} onClick={() => setEditing((e) => !e)}>
                {editing ? 'Done' : 'Edit'}
              </Button>
              <Button className="h-12 text-base" variant="outline" disabled={busy} onClick={() => void act('skip')}>Skip</Button>
            </div>
          ) : null}
        </div>
      </div>}
    </section>
  )
}
