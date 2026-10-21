// Phone notifications (Web Push) and "install the app". The VAPID PUBLIC key is public by
// design; the private key is a Supabase function secret only.
import { supabase } from './supabaseClient'

export const VAPID_PUBLIC_KEY = 'BDCCqT1mXEV-7l8krzlOddh1huF-bhkN71HA0gsaEYnWelY42uN--MQ3wxDoLmIbZ_241Ljr5FOt1sO5zkyTLic'

export type PushState = 'unsupported' | 'denied' | 'off' | 'on'

function keyBytes(b64u: string): Uint8Array {
  const s = atob(b64u.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((b64u.length + 3) % 4))
  return Uint8Array.from(s, (c) => c.charCodeAt(0))
}

export function pushSupported(): boolean {
  return typeof window !== 'undefined' && 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window
}

export async function pushState(): Promise<PushState> {
  if (!pushSupported()) return 'unsupported'
  if (Notification.permission === 'denied') return 'denied'
  const reg = await navigator.serviceWorker.getRegistration()
  const sub = reg ? await reg.pushManager.getSubscription() : null
  return sub && Notification.permission === 'granted' ? 'on' : 'off'
}

/** Ask permission, subscribe this phone, and save it for the server. */
export async function enablePush(): Promise<PushState> {
  if (!pushSupported()) return 'unsupported'
  const permission = await Notification.requestPermission()
  if (permission !== 'granted') return permission === 'denied' ? 'denied' : 'off'
  const reg = (await navigator.serviceWorker.getRegistration()) ?? (await navigator.serviceWorker.register('/sw.js'))
  await navigator.serviceWorker.ready
  const sub = (await reg.pushManager.getSubscription())
    ?? (await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: keyBytes(VAPID_PUBLIC_KEY) as BufferSource }))
  const j = sub.toJSON() as { endpoint: string; keys: { p256dh: string; auth: string } }
  const { error } = await supabase.rpc('save_push_subscription', {
    p_endpoint: j.endpoint, p_p256dh: j.keys.p256dh, p_auth: j.keys.auth, p_user_agent: navigator.userAgent,
  })
  if (error) throw new Error(error.message)
  return 'on'
}

export async function sendTestNotification(): Promise<string> {
  const r = await supabase.functions.invoke('reply-send', { body: { action: 'test_notification' } })
  if (r.error) throw new Error(r.error.message)
  const d = r.data as { pushes_ok: number; pushes_failed: number; emails: number; email_errors: string[];
    push_configured: boolean; email_configured: boolean }
  const parts = [
    d.push_configured ? `${d.pushes_ok} phone${d.pushes_ok === 1 ? '' : 's'} notified${d.pushes_failed ? `, ${d.pushes_failed} failed` : ''}` : 'phone push is not set up on the server',
    d.email_configured ? (d.emails ? 'test email sent' : `email failed: ${d.email_errors[0] ?? 'unknown'}`) : 'email is not set up yet',
  ]
  return parts.join('; ')
}

// Chrome on Android offers "Install" through this event; keep it for our own button.
type InstallPrompt = Event & { prompt: () => Promise<void>; userChoice: Promise<{ outcome: string }> }
let deferred: InstallPrompt | null = null
const listeners = new Set<() => void>()
if (typeof window !== 'undefined') {
  window.addEventListener('beforeinstallprompt', (e) => {
    e.preventDefault()
    deferred = e as InstallPrompt
    listeners.forEach((f) => f())
  })
  window.addEventListener('appinstalled', () => { deferred = null; listeners.forEach((f) => f()) })
}
export function canPromptInstall(): boolean { return deferred != null }
export function onInstallChange(f: () => void): () => void { listeners.add(f); return () => listeners.delete(f) }
export async function promptInstall(): Promise<void> {
  if (!deferred) return
  await deferred.prompt()
  await deferred.userChoice
  deferred = null
  listeners.forEach((f) => f())
}
export function isInstalled(): boolean {
  return typeof window !== 'undefined' && window.matchMedia?.('(display-mode: standalone)').matches === true
}
