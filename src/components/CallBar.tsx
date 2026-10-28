// The in-call bar: who you're talking to, how long, mute, hang up. Sits above the bottom nav on phones.
// A call that came in from a number the list does not know offers the call desk's "New caller" card.
import { useEffect, useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { Button } from '@/components/ui/button'
import { callerDigits, fmtDuration, useDialer } from '@/lib/dialer'
import { fmtPhone } from '@/lib/format'
import { api } from '@/lib/queries'

const WORDS = { connecting: 'Connecting...', ringing: 'Ringing...', in_call: 'In call', ended: 'Call ended', error: 'Call failed', idle: '' }

export function CallBar() {
  const { active, hangUp, toggleMute, dismiss } = useDialer()
  const nav = useNavigate()
  const [, tick] = useState(0)
  const [busy, setBusy] = useState(false)
  const [msg, setMsg] = useState<string | null>(null)
  useEffect(() => {
    if (active?.status !== 'in_call') return
    const t = setInterval(() => tick((n) => n + 1), 1000)
    return () => clearInterval(t)
  }, [active?.status])
  if (!active) return null
  const live = active.status === 'connecting' || active.status === 'ringing' || active.status === 'in_call'
  const digits = callerDigits(active.to)
  const unknownCaller = active.inbound && !active.leadId && digits.length === 10

  // The call desk's new-caller path (migration 0013): a card with just the phone, then its call script.
  const newCaller = async () => {
    setBusy(true)
    setMsg(null)
    const r = await api.newCaller(digits)
    setBusy(false)
    const out = r.data as { ok: boolean; lead_id?: string; reason?: string } | null
    if (r.error || !out?.ok || !out.lead_id) { setMsg(r.error?.message ?? out?.reason ?? 'Could not make the card.'); return }
    if (!live) dismiss()
    nav(`/lead/${out.lead_id}?call=1&phone=${digits}`)
  }

  // A finished call asks for its outcome right here (Colin 2026-10-24: a call that ends with nothing logged leaves the
  // card stuck on "call started"). The quick ones log in one tap; a real conversation opens the card's script to log.
  const quickLog = async (outcome: 'no_answer', note: string) => {
    if (!active.leadId) return
    setBusy(true)
    setMsg(null)
    const r = await api.logCall(active.leadId, digits || null, outcome, note)
    setBusy(false)
    if (r.error) { setMsg(r.error.message); return }
    dismiss()
  }
  const askOutcome = !live && !!active.leadId && !active.inbound && !active.quiet

  const where = active.inbound
    ? `calling in from ${fmtPhone(active.to) || 'a withheld number'}${active.line ? ` on ${fmtPhone(active.line)}` : ''}`
    : `from ${fmtPhone(active.to)}`
  return (
    <div role="status" aria-live="polite"
      className="pb-safe fixed inset-x-0 bottom-[4.5rem] z-40 border-t bg-background shadow-lg md:bottom-0">
      <div className="mx-auto flex max-w-5xl items-center gap-3 px-4 py-2">
        <div className="min-w-0 flex-1">
          <p className="truncate font-medium">{active.label}</p>
          <p className="text-xs text-muted-foreground">
            {WORDS[active.status]}{active.status === 'in_call' && active.startedAt ? ` ${fmtDuration(Date.now() - active.startedAt)}` : ''}
            {' '}{where}{active.error ? ` - ${active.error}` : ''}{msg ? ` - ${msg}` : ''}
          </p>
        </div>
        {active.status === 'in_call' && active.leadId && active.inbound && (
          <Button size="sm" variant="outline" asChild><Link to={`/lead/${active.leadId}?call=1&phone=${digits}`}>Open card</Link></Button>
        )}
        {unknownCaller && (
          <Button size="sm" variant={live ? 'outline' : 'default'} disabled={busy} onClick={() => void newCaller()}>New caller</Button>
        )}
        {active.status === 'in_call' && (
          <Button size="sm" variant="outline" onClick={toggleMute}>{active.muted ? 'Unmute' : 'Mute'}</Button>
        )}
        {live ? (
          <Button size="sm" variant="destructive" onClick={hangUp}>Hang up</Button>
        ) : (
          <>
            {askOutcome ? (
              <div className="flex flex-wrap items-center justify-end gap-1.5">
                <span className="w-full text-right text-xs font-medium sm:w-auto">How did it go?</span>
                <Button size="sm" disabled={busy} onClick={() => void quickLog('no_answer', 'No answer (logged from the call bar)')}>No answer</Button>
                <Button size="sm" disabled={busy} onClick={() => void quickLog('no_answer', "Connected but we couldn't hear each other (logged from the call bar)")}>Couldn't hear</Button>
                <Button size="sm" asChild><Link to={`/lead/${active.leadId}?call=1#call-script`} onClick={dismiss}>We talked: log it</Link></Button>
              </div>
            ) : active.leadId && active.answered ? (
              <Button size="sm" asChild><Link to={`/lead/${active.leadId}?call=1#call-script`} onClick={dismiss}>Log the call</Link></Button>
            ) : null}
            <Button size="sm" variant="outline" onClick={dismiss}>{askOutcome ? 'Later' : 'Close'}</Button>
          </>
        )}
      </div>
    </div>
  )
}
