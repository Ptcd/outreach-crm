// The Stay awake switch in the header (2026-11-07): on, the screen stays on while the app is open so the softphone
// stays registered and a seller's call rings here. The ring also re-checks the softphone every half minute while on.
// Off, the phone sleeps as usual (and seller calls go to the second ring, then voicemail). Remembered per phone.
import { useEffect, useState } from 'react'
import { holdWakeLock, readStayAwake, wakeLockSupported, writeStayAwake } from '@/lib/wakeLock'
import { cn } from '@/lib/utils'

export function StayAwake() {
  const [on, setOn] = useState(() => readStayAwake())
  const [held, setHeld] = useState(false)
  const supported = wakeLockSupported()
  useEffect(() => {
    if (!on || !supported) { setHeld(false); return }
    const stop = holdWakeLock({ onChange: setHeld })
    // nudge the softphone to re-register while awake (lib/dialer listens for this)
    const t = window.setInterval(() => window.dispatchEvent(new Event('wpie-kick-dialer')), 30_000)
    return () => { stop(); window.clearInterval(t) }
  }, [on, supported])
  if (!supported) return null
  const toggle = () => { const v = !on; setOn(v); writeStayAwake(v) }
  return (
    <button type="button" onClick={toggle} aria-pressed={on}
      title={on ? (held ? 'Staying awake: the screen stays on and seller calls ring here' : 'Stay awake is on; the lock is taken when the app is on screen') : 'Tap while you work: keeps the screen on so seller calls ring here'}
      className={cn('flex h-10 items-center gap-1.5 rounded-xl px-2.5 text-xs font-medium transition-colors',
        on ? 'bg-amber-50 text-amber-800 ring-1 ring-inset ring-amber-200' : 'text-muted-foreground hover:bg-accent hover:text-accent-foreground')}>
      <span aria-hidden className={cn('inline-block h-2 w-2 rounded-full', on && held ? 'bg-amber-500' : on ? 'bg-amber-300' : 'bg-muted-foreground/40')} />
      <span className="hidden sm:inline">{on ? 'Staying awake' : 'Stay awake'}</span>
      <span className="sr-only sm:hidden">{on ? 'Staying awake' : 'Stay awake'}</span>
    </button>
  )
}
