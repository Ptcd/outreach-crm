// Web Push without a library: RFC 8291 (aes128gcm message encryption) and RFC 8292 (VAPID),
// on Web Crypto only, so it runs the same in Deno (Edge Functions) and Node (tests).
// tests/notify.test.ts decrypts what this produces as the browser would, and checks the
// VAPID signature with the public key.

export interface PushSubscriptionKeys { endpoint: string; p256dh: string; auth: string }
export interface Vapid { publicKey: string; privateJwk: JsonWebKey; subject: string }
export interface PushOutcome { ok: boolean; gone: boolean; status: number | null }

const enc = new TextEncoder()

export function b64u(buf: ArrayBuffer | Uint8Array): string {
  const bytes = buf instanceof Uint8Array ? buf : new Uint8Array(buf)
  let s = ''
  for (const b of bytes) s += String.fromCharCode(b)
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

export function fromB64u(s: string): Uint8Array {
  const t = s.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((s.length + 3) % 4)
  const bin = atob(t)
  const out = new Uint8Array(bin.length)
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i)
  return out
}

function concat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0))
  let i = 0
  for (const p of parts) { out.set(p, i); i += p.length }
  return out
}

async function hkdf(salt: Uint8Array, ikm: Uint8Array, info: Uint8Array, bytes: number): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey('raw', ikm, 'HKDF', false, ['deriveBits'])
  return new Uint8Array(await crypto.subtle.deriveBits({ name: 'HKDF', hash: 'SHA-256', salt, info }, key, bytes * 8))
}

/** RFC 8291 encryption of one push message. `ephemeral` and `salt` only for tests. */
export async function encryptPayload(payload: Uint8Array, sub: PushSubscriptionKeys,
  opts: { ephemeral?: CryptoKeyPair; salt?: Uint8Array } = {}): Promise<Uint8Array> {
  const uaPublic = fromB64u(sub.p256dh)
  const authSecret = fromB64u(sub.auth)
  const as = opts.ephemeral ?? (await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']) as CryptoKeyPair)
  const asPublic = new Uint8Array(await crypto.subtle.exportKey('raw', as.publicKey))
  const uaKey = await crypto.subtle.importKey('raw', uaPublic, { name: 'ECDH', namedCurve: 'P-256' }, false, [])
  const shared = new Uint8Array(await crypto.subtle.deriveBits({ name: 'ECDH', public: uaKey }, as.privateKey, 256))
  const ikm = await hkdf(authSecret, shared, concat(enc.encode('WebPush: info\0'), uaPublic, asPublic), 32)
  const salt = opts.salt ?? crypto.getRandomValues(new Uint8Array(16))
  const cek = await hkdf(salt, ikm, enc.encode('Content-Encoding: aes128gcm\0'), 16)
  const nonce = await hkdf(salt, ikm, enc.encode('Content-Encoding: nonce\0'), 12)
  const key = await crypto.subtle.importKey('raw', cek, 'AES-GCM', false, ['encrypt'])
  const cipher = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce }, key, concat(payload, new Uint8Array([2]))))
  const rs = new Uint8Array([0, 0, 0x10, 0])          // record size 4096
  return concat(salt, rs, new Uint8Array([asPublic.length]), asPublic, cipher)
}

/** RFC 8292 VAPID JWT for one push service origin, valid 12 hours. */
export async function vapidJwt(audience: string, vapid: Vapid, now = new Date()): Promise<string> {
  const header = b64u(enc.encode(JSON.stringify({ typ: 'JWT', alg: 'ES256' })))
  const body = b64u(enc.encode(JSON.stringify({ aud: audience, exp: Math.floor(now.getTime() / 1000) + 12 * 3600, sub: vapid.subject })))
  const key = await crypto.subtle.importKey('jwk', vapid.privateJwk, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign'])
  const sig = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, enc.encode(`${header}.${body}`))
  return `${header}.${body}.${b64u(sig)}`
}

export async function sendPush(sub: PushSubscriptionKeys, message: object, vapid: Vapid, fetchFn: typeof fetch,
  now = new Date()): Promise<PushOutcome> {
  try {
    const body = await encryptPayload(enc.encode(JSON.stringify(message)), sub)
    const jwt = await vapidJwt(new URL(sub.endpoint).origin, vapid, now)
    const res = await fetchFn(sub.endpoint, {
      method: 'POST',
      headers: {
        TTL: '86400', Urgency: 'high', 'Content-Encoding': 'aes128gcm', 'Content-Type': 'application/octet-stream',
        Authorization: `vapid t=${jwt}, k=${vapid.publicKey}`,
      },
      body,
    })
    return { ok: res.status >= 200 && res.status < 300, gone: res.status === 404 || res.status === 410, status: res.status }
  } catch {
    return { ok: false, gone: false, status: null }
  }
}

export function vapidFromEnv(get: (n: string) => string | undefined): Vapid | null {
  const pub = get('VAPID_PUBLIC_KEY')
  const priv = get('VAPID_PRIVATE_JWK')
  if (!pub || !priv) return null
  try {
    return { publicKey: pub, privateJwk: JSON.parse(priv), subject: get('VAPID_SUBJECT') || 'https://deals.junkcarsmequon.com' }
  } catch {
    return null
  }
}
