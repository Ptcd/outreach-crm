import { useEffect, useState } from 'react'
import { Button } from '@/components/ui/button'
import {
  canPromptInstall, enablePush, isInstalled, onInstallChange, promptInstall, pushState, sendTestNotification, type PushState,
} from '@/lib/push'
import { useAuth } from '@/providers/AuthProvider'

// Top of the Inbox: install the app on the phone, turn on notifications, test them. Every team member:
// Colin gets "reply needs you"; everyone gets the hot-lead alerts (Colin 2026-10-22).
export function NotifyPanel() {
  const { member } = useAuth()
  const [state, setState] = useState<PushState | null>(null)
  const [installable, setInstallable] = useState(canPromptInstall())
  const [msg, setMsg] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    void pushState().then(setState).catch(() => setState('unsupported'))
    return onInstallChange(() => setInstallable(canPromptInstall()))
  }, [])

  if (!member) return null
  const run = async (f: () => Promise<string | PushState>) => {
    setBusy(true)
    setMsg(null)
    try {
      const r = await f()
      if (r === 'on' || r === 'off' || r === 'denied' || r === 'unsupported') setState(r)
      else setMsg(r)
    } catch (e) {
      setMsg(e instanceof Error ? e.message : String(e))
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="rounded-lg border bg-card p-3 text-sm shadow-sm">
      {!isInstalled() && (
        <p className="mb-2">
          <b>Put WPIE on your home screen:</b>{' '}
          {installable
            ? <Button size="sm" className="ml-1" onClick={() => void promptInstall()}>Install the app</Button>
            : <>on a phone, in Chrome tap the <b>three-dot menu</b>, then <b>Add to Home screen</b> (or <b>Install app</b>).</>}
        </p>
      )}
      <p className="mb-2 text-xs text-muted-foreground">
        On a computer, Chrome can show pings while the browser is running; installing the app is only needed for phone notifications when the browser is closed.
      </p>
      <div className="flex flex-wrap items-center gap-2">
        {state === 'on' && <span>Notifications are on: a ping for every hot lead{member.role === 'owner' ? ' and when a reply needs you' : ''}.</span>}
        {state === 'off' && <Button size="sm" disabled={busy} onClick={() => void run(enablePush)}>Turn on notifications</Button>}
        {state === 'denied' && <span>Notifications are blocked. Chrome ⋮ &gt; Settings &gt; Notifications (or the lock icon) &gt; allow this site.</span>}
        {state === 'unsupported' && <span>This browser can&apos;t show notifications. Use Chrome on your phone.</span>}
        <Button size="sm" variant="outline" disabled={busy} onClick={() => void run(sendTestNotification)}>Send a test notification</Button>
      </div>
      {msg && <p className="mt-2 text-xs font-medium">{msg}</p>}
    </div>
  )
}
