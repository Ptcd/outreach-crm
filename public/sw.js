// WPIE service worker: installable app, "Reply needs you" notifications, and an app shell that
// opens on a weak signal. Only the app's own files are cached: the page itself network-first
// (falls back to the last copy when offline), hashed /assets/* cache-first. Data from Supabase
// is never cached here (the app keeps its own copy of the last loaded data).
const SHELL = 'wpie-shell-v1'
const RING_TAG = 'wpie-call-coming-in'               // the same tag the app uses (components/IncomingCallBar)
const RING_BUZZ = [500, 250, 500, 250, 500, 250, 900]
// A call's alert buzzes again like a ringing phone (Colin 2026-11-14: "make it so it rings a notification on our devices
// even when the app isn't open"): every RING_EVERY_MS, RING_REPEATS more times after the first, about 20 seconds. The
// phone server sends a second alert half way through its 45 seconds of ringing, which starts this again. It stops the
// moment the alert is tapped or swiped away, the app says the call was answered or ended, or the app is on screen
// (its own call screen has Answer on it).
const RING_EVERY_MS = 4000
const RING_REPEATS = 5
let ringStoppedAt = 0
const ringNotes = () => self.registration.getNotifications({ tag: RING_TAG }).catch(() => [])
const appInFront = async () => (await self.clients.matchAll({ type: 'window', includeUncontrolled: true }))
  .some((w) => w.focused && w.visibilityState === 'visible')
self.addEventListener('message', (event) => {
  if (!event.data || event.data.type !== 'wpie-ring-stop') return
  ringStoppedAt = Date.now()
  event.waitUntil(ringNotes().then((ns) => ns.forEach((n) => n.close())))
})
self.addEventListener('install', (event) => {
  event.waitUntil(caches.open(SHELL).then((c) => c.addAll(['/', '/manifest.webmanifest', '/icons/house-192.png'])).catch(() => {}))
  self.skipWaiting()
})
self.addEventListener('activate', (event) => event.waitUntil((async () => {
  for (const k of await caches.keys()) if (k !== SHELL) await caches.delete(k)
  await self.clients.claim()
})()))

self.addEventListener('fetch', (event) => {
  const req = event.request
  if (req.method !== 'GET') return
  const url = new URL(req.url)
  if (url.origin !== self.location.origin) return
  if (req.mode === 'navigate') {
    event.respondWith((async () => {
      try {
        const fresh = await fetch(req)
        const c = await caches.open(SHELL)
        c.put('/', fresh.clone())
        return fresh
      } catch {
        return (await caches.match('/')) || Response.error()
      }
    })())
    return
  }
  if (url.pathname.startsWith('/assets/') || url.pathname.startsWith('/icons/')) {
    event.respondWith((async () => {
      const hit = await caches.match(req)
      if (hit) return hit
      const res = await fetch(req)
      if (res.ok) (await caches.open(SHELL)).put(req, res.clone())
      return res
    })())
  }
})


self.addEventListener('push', (event) => {
  let data = {}
  try {
    data = event.data ? event.data.json() : {}
  } catch {
    data = { body: event.data ? event.data.text() : '' }
  }
  // "X is calling now" (ring-alert, url ends #ring-<call>): it stays up until tapped, buzzes like a call, carries an
  // Answer button, and shares one tag with the app's own alert for the same call so the two never stack (2026-11-14)
  const ring = /#ring-/.test(data.url || '')
  const options = {
    body: data.body || '',
    tag: ring ? RING_TAG : (data.tag || undefined),
    renotify: ring || Boolean(data.tag),
    icon: '/icons/house-192.png',
    badge: '/icons/house-badge-96.png',      // white house on transparent: Android's status-bar icon
    data: { url: data.url || '/inbox', ring },
  }
  if (!ring) {
    event.waitUntil(self.registration.showNotification(data.title || 'Reply needs you', options))
    return
  }
  Object.assign(options, { requireInteraction: true, vibrate: RING_BUZZ, actions: [{ action: 'answer', title: 'Answer' }] })
  event.waitUntil((async () => {
    const began = Date.now()
    await self.registration.showNotification(data.title || 'A seller is calling now', options)
    for (let i = 0; i < RING_REPEATS; i++) {
      await new Promise((r) => setTimeout(r, RING_EVERY_MS))
      if (ringStoppedAt >= began) return
      if (await appInFront()) return
      if (!(await ringNotes()).length) return          // tapped or swiped away
      await self.registration.showNotification(data.title || 'A seller is calling now', options)
    }
  })())
})

// A tapped notification. An app that is already open is brought forward and asked to go there itself (it answers
// 'ok' and moves without loading the page again): loading the page hangs up the softphone, and a softphone that is
// hung up while a seller rings ends their call (2026-11-14). An older copy of the app that does not answer is sent
// there the old way, except for a call that is ringing ("X is calling now"), which is never reloaded.
self.addEventListener('notificationclick', (event) => {
  event.notification.close()
  const data = event.notification.data || {}
  const url = new URL(data.url || '/inbox', self.location.origin).href
  const ring = data.ring === true || /#ring-/.test(url)
  if (ring) ringStoppedAt = Date.now()                  // tapped: it stops buzzing
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true })
    for (const w of windows) {
      if (new URL(w.url).origin !== self.location.origin) continue
      const front = (await w.focus().catch(() => null)) || w
      const heard = await new Promise((resolve) => {
        const ch = new MessageChannel()
        const t = setTimeout(() => resolve(false), 800)
        ch.port1.onmessage = () => { clearTimeout(t); resolve(true) }
        // Answer on a ringing call's alert asks the app to answer it (components/IncomingCallBar)
        try { front.postMessage({ type: event.action === 'answer' ? 'wpie-answer' : 'wpie-open', url }, [ch.port2]) } catch { clearTimeout(t); resolve(false) }
      })
      if (heard || ring) return
      return front.navigate(url)
    }
    // the app was shut. Answer on the alert opens it with a mark, so the app answers the call when it reaches it
    // instead of asking for a second tap (components/IncomingCallBar; installed app only)
    return self.clients.openWindow(event.action === 'answer' ? url + (url.includes('#') ? '&' : '#') + 'answer=1' : url)
  })())
})
