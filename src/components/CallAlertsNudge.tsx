// "A seller's call cannot alert you when this app is not in front" (Colin 2026-11-14: "it should ring even if it's not
// the priority thing open"). A web app that is behind another app or tab can only reach its person through the
// phone's or computer's own notifications, and those are off until the person allows them. On 2026-11-14 one of the
// three people had them on. So whoever's softphone is ready and whose alerts are off sees this under the menu until
// they turn them on: one tap asks the permission and saves this phone for the "X is calling now" alert.
import { useEffect, useState } from 'react'
import { useDialer } from '@/lib/dialer'
import { enablePush, isInstalled, pushState, type PushState } from '@/lib/push'

export function CallAlertsNudge() {
  const { ready } = useDialer()
  const [state, setState] = useState<PushState | null>(null)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  useEffect(() => {
    if (!ready) return
    let on = true
    void pushState().then((s) => { if (on) setState(s) }).catch(() => undefined)
    return () => { on = false }
  }, [ready])
  if (!ready || state === null || state === 'on') return null
  const iphone = typeof navigator !== 'undefined' && /iPhone|iPad/.test(navigator.userAgent)
  if (state === 'unsupported' && !(iphone && !isInstalled())) return null

  const turnOn = async () => {
    setBusy(true); setErr(null)
    try { setState(await enablePush()) } catch (e) { setErr(e instanceof Error ? e.message : String(e)) }
    setBusy(false)
  }
  return (
    <div role="status" className="border-b border-amber-300 bg-amber-100 px-4 py-2 text-center text-sm text-amber-950 dark:border-amber-800 dark:bg-amber-950 dark:text-amber-100">
      {state === 'off' && <>
        A seller&apos;s call cannot alert you when this app is not in front.{' '}
        <button type="button" disabled={busy} onClick={() => void turnOn()}
          className="ml-1 rounded-lg bg-amber-600 px-3 py-1 font-semibold text-white hover:bg-amber-700 disabled:opacity-60">Turn on call alerts</button>
        {err && <span className="ml-2">Could not turn them on: {err}</span>}
      </>}
      {state === 'denied' && <>Call alerts are blocked for this app. Allow notifications for it in the browser&apos;s site settings, or a seller&apos;s call cannot alert you when the app is not in front.</>}
      {state === 'unsupported' && <>To be alerted to calls on an iPhone: tap Share, then Add to Home Screen, and open the app from there.</>}
    </div>
  )
}
