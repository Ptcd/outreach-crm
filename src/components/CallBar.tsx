// The in-call bar: who you're calling, how long, mute, hang up. Sits above the bottom nav on phones.
import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { Button } from '@/components/ui/button'
import { fmtDuration, useDialer } from '@/lib/dialer'
import { fmtPhone } from '@/lib/format'

const WORDS = { connecting: 'Connecting...', ringing: 'Ringing...', in_call: 'In call', ended: 'Call ended', error: 'Call failed', idle: '' }

export function CallBar() {
  const { active, hangUp, toggleMute, dismiss } = useDialer()
  const [, tick] = useState(0)
  useEffect(() => {
    if (active?.status !== 'in_call') return
    const t = setInterval(() => tick((n) => n + 1), 1000)
    return () => clearInterval(t)
  }, [active?.status])
  if (!active) return null
  const live = active.status === 'connecting' || active.status === 'ringing' || active.status === 'in_call'
  return (
    <div role="status" aria-live="polite"
      className="pb-safe fixed inset-x-0 bottom-[4.5rem] z-40 border-t bg-background shadow-lg sm:bottom-0">
      <div className="mx-auto flex max-w-5xl items-center gap-3 px-4 py-2">
        <div className="min-w-0 flex-1">
          <p className="truncate font-medium">{active.label}</p>
          <p className="text-xs text-muted-foreground">
            {WORDS[active.status]}{active.status === 'in_call' && active.startedAt ? ` ${fmtDuration(Date.now() - active.startedAt)}` : ''}
            {' '}from {fmtPhone(active.to)}{active.error ? ` - ${active.error}` : ''}
          </p>
        </div>
        {active.status === 'in_call' && (
          <Button size="sm" variant="outline" onClick={toggleMute}>{active.muted ? 'Unmute' : 'Mute'}</Button>
        )}
        {live ? (
          <Button size="sm" variant="destructive" onClick={hangUp}>Hang up</Button>
        ) : (
          <>
            {active.leadId && active.answered && (
              <Button size="sm" asChild><Link to={`/lead/${active.leadId}#call`} onClick={dismiss}>Log the call</Link></Button>
            )}
            <Button size="sm" variant="outline" onClick={dismiss}>Close</Button>
          </>
        )}
      </div>
    </div>
  )
}
