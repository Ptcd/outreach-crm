import { useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { api, callTranscript, useCallNotes, type CallNote } from '@/lib/queries'
import { fmtDateTime, localInputToIso } from '@/lib/format'

// Call notes (Colin 2026-10-26: calls kept going unlogged; "take the notes for them"). A recorded call through the app
// comes back here a minute or two after it ends: the summary, the four pillars plus who signs, the outcome, the next
// step, and the mark the notes suggest. One tap confirms it, which logs the call exactly like "Save the call"; a call
// already logged by hand just shows its notes. The words themselves stay behind "What was said" (team only).

export const MARKS: { id: string; label: string }[] = [
  { id: 'hot', label: 'Hot' },
  { id: 'not_now', label: 'Not now' },
  { id: 'held', label: 'Held' },
  { id: 'dead', label: 'Dead' },
  { id: 'reached', label: 'Reached, nothing settled' },
  { id: 'no_answer', label: 'No answer' },
  { id: 'wrong_number', label: 'Wrong number' },
  { id: 'dnc', label: 'Do not contact' },
]
const LABEL = Object.fromEntries(MARKS.map((m) => [m.id, m.label])) as Record<string, string>
const PILLAR_ROWS: [keyof CallNote['pillars'], string][] = [
  ['motivation', 'Why selling'], ['condition', 'Condition'], ['timeline', 'Timeline'], ['price', 'Their number'], ['signers', 'Who signs'],
]
const day = (iso: string) => new Date(iso).toLocaleDateString('en-CA', { timeZone: 'America/Chicago' })
const dayLabel = (iso: string) => new Date(iso).toLocaleDateString('en-US', { timeZone: 'America/Chicago', weekday: 'short', month: 'short', day: 'numeric' })

/** "Not now until Jan 5", "Held (probate)", "Hot". */
export function markText(mark: string, until: string | null, reason: string | null): string {
  return `${LABEL[mark] ?? mark}${until ? ` until ${dayLabel(until)}` : ''}${reason ? ` (${reason})` : ''}`
}

/** Whether a call outcome was logged on the card since this call started (then there is nothing to confirm). */
export function loggedSince(note: Pick<CallNote, 'started_at' | 'created_at' | 'logged_before'>, messages: { channel: string; status: string | null; sent_at: string }[]): string | null {
  if (note.logged_before) return note.logged_before
  const since = note.started_at ?? note.created_at
  const OUTCOMES = ['interested', 'not_now', 'not_interested', 'wrong_number', 'dnc', 'no_answer', 'reached_no_decision']
  const hit = messages.filter((m) => m.channel === 'call' && OUTCOMES.includes(m.status ?? '') && m.sent_at >= since)
    .sort((a, b) => b.sent_at.localeCompare(a.sent_at))[0]
  return hit?.status ?? null
}

export function CallNotes({ leadId, messages }: { leadId: string; messages: { channel: string; status: string | null; sent_at: string }[] }) {
  const q = useCallNotes(leadId)
  const notes = q.data?.notes ?? []
  if (!q.data || (!notes.length && !q.data.pending)) return null
  return (
    <section className="space-y-3 rounded-2xl border border-sky-200 bg-sky-50/60 p-4" aria-label="Call notes">
      <div className="flex items-baseline justify-between gap-2">
        <h2 className="font-semibold">Call notes</h2>
        {q.data.pending > 0 && <p className="text-sm text-muted-foreground">Notes for the last call are being written…</p>}
      </div>
      {notes.slice(0, 3).map((n, i) => <NoteCard key={n.id} n={n} open={i === 0} messages={messages} />)}
    </section>
  )
}

function NoteCard({ n, open, messages }: { n: CallNote; open: boolean; messages: { channel: string; status: string | null; sent_at: string }[] }) {
  const qc = useQueryClient()
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const [changing, setChanging] = useState(false)
  const [mark, setMark] = useState(n.suggested_mark ?? 'reached')
  const [until, setUntil] = useState(n.suggested_until ? day(n.suggested_until) : '')
  const [reason, setReason] = useState(n.suggested_reason ?? '')
  const [words, setWords] = useState<string | null>(null)
  const [expanded, setExpanded] = useState(open)
  const logged = loggedSince(n, messages)
  const when = n.started_at ?? n.created_at
  const head = `${n.direction === 'out' ? `${n.caller ?? 'We'} called` : 'They called us'} ${fmtDateTime(when)}` +
    `${n.duration_s ? ` · ${Math.max(1, Math.round(n.duration_s / 60))} min` : ''}`

  const confirm = async (m: string, u: string, r: string) => {
    setBusy(true); setErr(null)
    const res = await api.confirmCallNote(n.id, m, m === 'not_now' || m === 'held' ? (u ? localInputToIso(`${u}T12:00`) : null) : null, r.trim() || null)
    setBusy(false)
    const data = res.data as { ok?: boolean; reason?: string } | null
    if (res.error || !data?.ok) { setErr(res.error?.message ?? data?.reason ?? 'Not saved'); void qc.invalidateQueries({ queryKey: ['call_notes', n.lead_id] }); return }
    setChanging(false)
    for (const key of [['call_notes', n.lead_id], ['lead', n.lead_id], ['hot_alerts', n.lead_id]]) void qc.invalidateQueries({ queryKey: key })
  }
  const showWords = async () => {
    if (words !== null) { setWords(null); return }
    try { setWords(await callTranscript(n.call_sid) || '(no words were kept for this call)') } catch (e) { setErr(e instanceof Error ? e.message : String(e)) }
  }

  return (
    <article className="space-y-2 rounded-xl border bg-card p-3">
      <button type="button" className="flex w-full items-baseline justify-between gap-2 text-left" onClick={() => setExpanded((x) => !x)}>
        <span className="text-sm font-medium">{head}</span>
        <span className="text-xs text-muted-foreground">{expanded ? 'Hide' : 'Show'}</span>
      </button>
      {expanded && (
        <>
          <p className="text-base">{n.summary}</p>
          {n.quote && <p className="text-sm italic text-muted-foreground">&ldquo;{n.quote}&rdquo;</p>}
          <dl className="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-sm">
            {PILLAR_ROWS.map(([k, label]) => (
              <div key={k} className="contents">
                <dt className="font-medium text-muted-foreground">{label}</dt>
                <dd>{n.pillars?.[k] || <span className="text-muted-foreground">not covered</span>}</dd>
              </div>
            ))}
            {n.outcome && <><dt className="font-medium text-muted-foreground">Outcome</dt><dd>{n.outcome}</dd></>}
            {n.next_step && <><dt className="font-medium text-muted-foreground">Next</dt>
              <dd>{n.next_step}{n.next_step_at ? ` (${fmtDateTime(n.next_step_at)})` : ''}</dd></>}
          </dl>
          {n.facts_written?.length > 0 && (
            <p className="text-xs text-muted-foreground">Filled in the call script: {n.facts_written.length} answer{n.facts_written.length === 1 ? '' : 's'}.</p>
          )}
        </>
      )}

      {n.confirmed_at ? (
        <p className="text-sm font-medium text-emerald-800">
          {n.confirmed_mark?.startsWith('logged:') ? `Logged by hand: ${n.confirmed_mark.slice(7).replace(/_/g, ' ')}`
            : `Confirmed: ${LABEL[n.confirmed_mark ?? ''] ?? n.confirmed_mark}${n.confirmed_by ? ` by ${n.confirmed_by}` : ''}`}
        </p>
      ) : logged ? (
        <p className="text-sm text-muted-foreground">This call is already logged ({logged.replace(/_/g, ' ')}).</p>
      ) : (
        <div className="space-y-2">
          {!changing && n.suggested_mark && (
            <div className="flex flex-wrap items-center gap-2">
              <Button className="h-11" disabled={busy} onClick={() => void confirm(n.suggested_mark!, until, reason)}>
                Confirm: {markText(n.suggested_mark, n.suggested_until, n.suggested_reason)}
              </Button>
              <Button variant="outline" className="h-11" disabled={busy} onClick={() => setChanging(true)}>Change</Button>
            </div>
          )}
          {(changing || !n.suggested_mark) && (
            <div className="space-y-2 rounded-lg border p-2">
              <div className="flex flex-wrap gap-1.5" role="radiogroup" aria-label="Mark">
                {MARKS.map((m) => (
                  <Button key={m.id} size="sm" variant={mark === m.id ? 'default' : 'outline'} aria-pressed={mark === m.id}
                    onClick={() => setMark(m.id)}>{m.label}</Button>
                ))}
              </div>
              {(mark === 'not_now' || mark === 'held') && (
                <div className="flex flex-wrap items-center gap-2">
                  <label className="text-sm">Check back <Input type="date" className="inline-block h-10 w-auto" value={until} onChange={(e) => setUntil(e.target.value)} /></label>
                  <Input className="h-10 flex-1" placeholder={mark === 'held' ? 'Waiting on (required)' : 'Or what has to change first'}
                    value={reason} onChange={(e) => setReason(e.target.value)} />
                </div>
              )}
              <div className="flex gap-2">
                <Button className="h-11" disabled={busy} onClick={() => void confirm(mark, until, reason)}>Save: {LABEL[mark]}</Button>
                {n.suggested_mark && <Button variant="ghost" className="h-11" onClick={() => setChanging(false)}>Back</Button>}
              </div>
            </div>
          )}
        </div>
      )}
      {err && <p role="alert" className="text-sm text-red-700">{err}</p>}
      {expanded && (
        <div>
          <Button variant="ghost" size="sm" onClick={() => void showWords()}>{words === null ? 'What was said' : 'Hide what was said'}</Button>
          {words !== null && <pre className="mt-1 max-h-80 overflow-auto whitespace-pre-wrap rounded bg-muted p-2 text-xs">{words}</pre>}
        </div>
      )}
    </article>
  )
}
