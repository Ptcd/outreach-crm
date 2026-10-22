// A Twilio access token for the app's in-browser dialer: a JWT (HS256) with one Voice grant, built the way
// twilio-node's AccessToken builds it. Pure WebCrypto, so it runs in the Edge Function and in the tests.
// The grant is both ways: outgoing through the TwiML App, and incoming so a seller calling the seller line
// rings this person's open app (pm-phone dials <Client>identity</Client> next to Colin's cell).
function b64url(bytes: Uint8Array): string {
  let s = ''
  for (const b of bytes) s += String.fromCharCode(b)
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

export interface VoiceTokenOpts {
  accountSid: string
  apiKeySid: string
  apiKeySecret: string
  appSid: string
  identity: string
  ttlSeconds?: number
  now?: number
}

export async function voiceToken(opts: VoiceTokenOpts): Promise<string> {
  const now = opts.now ?? Math.floor(Date.now() / 1000)
  const ttl = opts.ttlSeconds ?? 3600
  const enc = new TextEncoder()
  const header = { typ: 'JWT', alg: 'HS256', cty: 'twilio-fpa;v=1' }
  const payload = {
    jti: `${opts.apiKeySid}-${now}`, iss: opts.apiKeySid, sub: opts.accountSid, iat: now, nbf: now, exp: now + ttl,
    grants: { identity: opts.identity, voice: { outgoing: { application_sid: opts.appSid }, incoming: { allow: true } } },
  }
  const signingInput = `${b64url(enc.encode(JSON.stringify(header)))}.${b64url(enc.encode(JSON.stringify(payload)))}`
  const key = await crypto.subtle.importKey('raw', enc.encode(opts.apiKeySecret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'])
  const sig = new Uint8Array(await crypto.subtle.sign('HMAC', key, enc.encode(signingInput)))
  return `${signingInput}.${b64url(sig)}`
}

/** The payload of a token this module made (for tests and for showing when it expires). */
export function decodeToken(token: string): { header: Record<string, unknown>; payload: Record<string, unknown> } {
  const [h, p] = token.split('.')
  const dec = (s: string) => JSON.parse(atob(s.replace(/-/g, '+').replace(/_/g, '/')))
  return { header: dec(h), payload: dec(p) }
}
