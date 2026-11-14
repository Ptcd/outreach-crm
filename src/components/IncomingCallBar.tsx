// "Call coming in": a seller is calling a seller line and the app is open (Colin 2026-10-22: "if a lead
// calls in should the app ring or have a call coming in thing and then show the property card stuff").
// Shows the number, the owner and property the call desk matched (phone_lookup), and Answer / Decline.
// Answer runs the call in the in-call bar and opens the lead card with the call script; Decline leaves
// Colin's cell ringing as before. Nothing here while no call is ringing (and never outside DialerProvider).
// Rung in while she is on a call (2026-10-28): Answer says it ends the call she is on; a seller calling us comes first.
//
// It takes over the whole screen (Colin 2026-11-14: "I heard it ring but didn't see a fast way to answer on the app").
// It used to be a thin bar across the top, the same height as the menu, with two small buttons. Now nothing else is on
// screen while a seller rings: who it is, and one big green Answer. While it rings the tab's title says so, and an app
// that is not in front puts up an alert with Answer on it; tapping it brings the app forward without reloading it (a
// reload hangs the softphone up, which ends the seller's call).
import { useEffect, useRef, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { PhoneIncoming } from 'lucide-react'
import { inboundLabel, pickInbound, useDialer } from '@/lib/dialer'
import { fmtPhone } from '@/lib/format'

export const RING_NOTE_TAG = 'wpie-call-coming-in'   // public/sw.js uses the same tag for the server's "X is calling now"
const RING_BUZZ = [500, 250, 500, 250, 500, 250, 900]

export function IncomingCallBar() {
  const { incoming, active, accept, decline } = useDialer()
  const nav = useNavigate()
  const [busy, setBusy] = useState(false)
  const ringing = useRef(false)
  ringing.current = !!incoming
  const take = async () => {
    setBusy(true)
    const r = await accept()
    setBusy(false)
    if (r?.leadId) nav(`/lead/${r.leadId}?call=1&phone=${r.phone}`)
  }
  // Answer tapped on an alert, not on this screen. The app may still be coming forward, and a softphone that is told
  // to answer before it can open the microphone drops the call for good. So: wait until the app is on screen, try the
  // microphone first, and if that fails leave the call ringing with Answer on screen for a tap (2026-11-14).
  const takeFromAlert = async () => {
    for (let i = 0; i < 30 && document.visibilityState === 'hidden'; i++) await new Promise((r) => setTimeout(r, 100))
    try {
      const mic = await navigator.mediaDevices.getUserMedia({ audio: true })
      mic.getTracks().forEach((t) => t.stop())
    } catch { return }
    if (ringing.current) await take()
  }
  const takeRef = useRef(takeFromAlert)
  takeRef.current = takeFromAlert
  // Answer was tapped on an alert before the call reached this app (it was asleep): the call is answered when it arrives
  const answerUntil = useRef(0)

  // An alert that was tapped (public/sw.js). The app is already open, so the service worker asks it to act instead of
  // loading the page again: Answer on a ringing call's alert answers it; anything else goes to the alert's page, except
  // while a call rings, when nothing moves because Answer is already on screen.
  useEffect(() => {
    if (typeof navigator === 'undefined' || !('serviceWorker' in navigator)) return
    const onMsg = (e: MessageEvent) => {
      const d = e.data as { type?: string; url?: string } | null
      if (d?.type !== 'wpie-open' && d?.type !== 'wpie-answer') return
      e.ports?.[0]?.postMessage('ok')
      if (d.type === 'wpie-answer') {
        if (ringing.current) void takeRef.current()
        else answerUntil.current = Date.now() + 45_000
        return
      }
      if (ringing.current || !d.url) return
      try {
        const u = new URL(d.url, window.location.origin)
        if (u.origin === window.location.origin) nav(u.pathname + u.search + u.hash)
      } catch { /* not a link */ }
    }
    navigator.serviceWorker.addEventListener('message', onMsg)
    return () => navigator.serviceWorker.removeEventListener('message', onMsg)
  }, [nav])

  // While it rings: the tab says so, and an app that is not in front (another tab, another window, another app on the
  // phone) puts up an alert that buzzes again every few seconds like a phone, with Answer on it (Colin 2026-11-14: "it
  // should ring even if it's not the priority thing open"). The alert goes when the app comes forward or the ringing stops.
  const from = incoming?.from ?? null
  useEffect(() => {
    if (from === null) return
    if (Date.now() < answerUntil.current) { answerUntil.current = 0; void takeRef.current(); return }
    const was = document.title
    const who = fmtPhone(from) || 'A seller'
    let flip = false
    document.title = 'CALL COMING IN'
    const t = setInterval(() => { flip = !flip; document.title = flip ? `${who} is calling` : 'CALL COMING IN' }, 1000)
    let gone = false
    let reg: ServiceWorkerRegistration | null = null
    const away = () => document.visibilityState === 'hidden' || !document.hasFocus()
    const close = () => { void reg?.getNotifications({ tag: RING_NOTE_TAG }).then((ns) => ns.forEach((n) => n.close())).catch(() => undefined) }
    const buzz = () => {
      if (gone || !reg) return
      if (!away()) { close(); return }
      void reg.showNotification(`${who} is calling now`, {
        body: 'Tap Answer, or open the app.', tag: RING_NOTE_TAG, requireInteraction: true, renotify: true, vibrate: RING_BUZZ,
        actions: [{ action: 'answer', title: 'Answer' }],
        icon: '/icons/house-192.png', badge: '/icons/house-badge-96.png', data: { url: window.location.href, ring: true },
      } as NotificationOptions).catch(() => undefined)
    }
    if ('Notification' in window && Notification.permission === 'granted' && 'serviceWorker' in navigator) {
      void navigator.serviceWorker.getRegistration().then((r) => { reg = r ?? null; if (gone) close(); else buzz() }).catch(() => undefined)
    }
    const again = setInterval(buzz, 5000)
    window.addEventListener('focus', buzz)
    document.addEventListener('visibilitychange', buzz)
    return () => {
      gone = true
      clearInterval(t); clearInterval(again)
      window.removeEventListener('focus', buzz); document.removeEventListener('visibilitychange', buzz)
      document.title = was
      close()
    }
  }, [from])

  if (!incoming) return null
  const m = incoming.matches
  const pick = pickInbound(m)
  const extra = m && m.length > 1 ? m.length - 1 : 0
  const who = m === null ? 'Looking them up...'
    : pick ? inboundLabel(incoming.from, m)
    : incoming.lookupError ? `Could not look them up: ${incoming.lookupError}`
    : 'Not in the list - a new caller'

  const onCall = incoming.busy && !!active && ['connecting', 'ringing', 'in_call'].includes(active.status)
  return (
    // solid in both themes: under .dark the app turns bg-emerald-50 into a 14% tint (index.css), which is see-through
    <div role="alert" aria-live="assertive"
      className="pt-safe pb-safe fixed inset-0 z-[60] flex items-center justify-center bg-black/80 p-4">
      <div className="w-full max-w-md rounded-3xl border-4 border-emerald-500 bg-[#ecfdf5] p-6 text-center shadow-2xl dark:bg-[#06281d]">
        <PhoneIncoming className="mx-auto h-16 w-16 animate-pulse text-emerald-700" aria-hidden />
        <p className="mt-3 text-sm font-semibold uppercase tracking-wide text-emerald-800">
          Call coming in{incoming.line ? ` on ${fmtPhone(incoming.line)}` : ''}{onCall ? ' while you are on a call: take it' : ''}
        </p>
        <p className="mt-2 break-words text-2xl font-bold leading-tight">{pick ? who : fmtPhone(incoming.from) || 'Withheld number'}</p>
        <p className="mt-1 break-words text-base text-muted-foreground">
          {pick ? fmtPhone(incoming.from) : who}
          {extra ? ` - ${extra} more lead${extra > 1 ? 's' : ''} with this number` : ''}
          {pick?.blocked ? ' - marked do not contact' : ''}
        </p>
        {incoming.micError && <p role="status" className="mt-4 rounded-xl bg-red-600 p-3 text-base font-semibold text-white">{incoming.micError}</p>}
        <button type="button" disabled={busy} onClick={() => void take()}
          className="mt-6 flex h-24 w-full items-center justify-center gap-3 rounded-2xl bg-emerald-600 text-3xl font-bold text-white shadow-lg transition active:scale-[0.98] hover:bg-emerald-700 disabled:opacity-60">
          <PhoneIncoming className="h-8 w-8" aria-hidden />{onCall ? 'Hang up and answer' : 'Answer'}
        </button>
        <button type="button" disabled={busy} onClick={decline}
          className="mt-3 h-12 w-full rounded-xl border border-emerald-700/40 text-base font-medium text-emerald-800 transition hover:bg-emerald-600/10 disabled:opacity-60">
          {onCall ? 'Let it go to Colin' : 'Decline'}
        </button>
      </div>
    </div>
  )
}
