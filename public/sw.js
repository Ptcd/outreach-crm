// WPIE service worker: installable app, "Reply needs you" notifications, and an app shell that
// opens on a weak signal. Only the app's own files are cached: the page itself network-first
// (falls back to the last copy when offline), hashed /assets/* cache-first. Data from Supabase
// is never cached here (the app keeps its own copy of the last loaded data).
const SHELL = 'wpie-shell-v1'
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
  event.waitUntil(self.registration.showNotification(data.title || 'Reply needs you', {
    body: data.body || '',
    tag: data.tag || undefined,
    renotify: Boolean(data.tag),
    icon: '/icons/house-192.png',
    badge: '/icons/house-badge-96.png',      // white house on transparent: Android's status-bar icon
    data: { url: data.url || '/inbox' },
  }))
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
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true })
    for (const w of windows) {
      if (new URL(w.url).origin !== self.location.origin) continue
      const front = (await w.focus().catch(() => null)) || w
      const heard = await new Promise((resolve) => {
        const ch = new MessageChannel()
        const t = setTimeout(() => resolve(false), 800)
        ch.port1.onmessage = () => { clearTimeout(t); resolve(true) }
        try { front.postMessage({ type: 'wpie-open', url }, [ch.port2]) } catch { clearTimeout(t); resolve(false) }
      })
      if (heard || ring) return
      return front.navigate(url)
    }
    return self.clients.openWindow(url)
  })())
})
