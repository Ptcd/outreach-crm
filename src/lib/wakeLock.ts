// Stay awake (2026-11-07; Adil in Pakistan: a seller's call "rings like a blip, or it doesn't ring"). The app's
// softphone rings only while the page is awake in the foreground; a phone that goes to sleep drops off and Twilio
// cannot reach it. The Screen Wake Lock API keeps the screen on while the switch is on and the app is on screen; the
// browser releases the lock when the page is hidden, so it is taken again when the app comes back. The choice is
// remembered on this phone. Pure helpers here (testable); the switch is components/StayAwake.tsx.
const KEY = 'wpie.stay_awake'

type Sentinel = { release: () => Promise<void>; addEventListener: (t: 'release', f: () => void) => void }
type WakeLockApi = { request: (type: 'screen') => Promise<Sentinel> }

export function wakeLockSupported(nav: { wakeLock?: unknown } = typeof navigator === 'undefined' ? {} : (navigator as unknown as { wakeLock?: unknown })): boolean {
  return !!nav.wakeLock && typeof (nav.wakeLock as WakeLockApi).request === 'function'
}

export function readStayAwake(): boolean {
  try { return globalThis.localStorage?.getItem(KEY) === '1' } catch { return false }
}

export function writeStayAwake(on: boolean) {
  try { if (on) globalThis.localStorage?.setItem(KEY, '1'); else globalThis.localStorage?.removeItem(KEY) } catch { /* private window */ }
}

/** Holds a screen wake lock while `on` and the page is visible; re-takes it when the page comes back. Returns stop(). */
export function holdWakeLock(opts: { onChange?: (held: boolean) => void; nav?: { wakeLock?: unknown }; doc?: Document } = {}): () => void {
  const nav = (opts.nav ?? navigator) as { wakeLock?: WakeLockApi }
  const doc = opts.doc ?? document
  let sentinel: Sentinel | null = null
  let alive = true
  const set = (held: boolean) => opts.onChange?.(held)
  const take = async () => {
    if (!alive || sentinel || !nav.wakeLock || doc.visibilityState === 'hidden') return
    try {
      const s = await nav.wakeLock.request('screen')
      if (!alive) { void s.release(); return }
      sentinel = s
      s.addEventListener('release', () => { sentinel = null; set(false) })
      set(true)
    } catch { set(false) }
  }
  const onVisible = () => { if (doc.visibilityState === 'visible') void take() }
  doc.addEventListener('visibilitychange', onVisible)
  void take()
  return () => {
    alive = false
    doc.removeEventListener('visibilitychange', onVisible)
    if (sentinel) { void sentinel.release(); sentinel = null }
    set(false)
  }
}
