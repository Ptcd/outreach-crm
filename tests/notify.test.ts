// Approval notifications: Web Push encryption (decrypted here exactly as a phone would), the
// VAPID signature, the SMTP conversation, and the rules on the real migrations: only candidate
// drafts, once each, one reminder after 2 hours, never in quiet hours, nothing claimed when
// nobody can be told, and a dead subscription forgotten.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { webcrypto } from 'node:crypto'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, beforeEach, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'
import { b64u, encryptPayload, fromB64u, sendPush, vapidJwt, type PushSubscriptionKeys, type Vapid } from '../supabase/functions/_shared/webpush'
import { sendMail, type SmtpConn } from '../supabase/functions/_shared/smtp'
import { emailFor, firstName, pushMessage, runNotifications, type ClaimedDraft } from '../supabase/functions/_shared/notify'
import type { Rpc } from '../supabase/functions/_shared/sending'

const subtle = webcrypto.subtle as unknown as SubtleCrypto
const enc = new TextEncoder()

async function hkdf(salt: Uint8Array, ikm: Uint8Array, info: Uint8Array, n: number) {
  const k = await subtle.importKey('raw', ikm, 'HKDF', false, ['deriveBits'])
  return new Uint8Array(await subtle.deriveBits({ name: 'HKDF', hash: 'SHA-256', salt, info }, k, n * 8))
}

/** The browser's side of RFC 8291. */
async function decrypt(body: Uint8Array, ua: CryptoKeyPair, auth: Uint8Array): Promise<string> {
  const salt = body.slice(0, 16)
  const idlen = body[20]
  const asPublic = body.slice(21, 21 + idlen)
  const cipher = body.slice(21 + idlen)
  const uaPublic = new Uint8Array(await subtle.exportKey('raw', ua.publicKey))
  const asKey = await subtle.importKey('raw', asPublic, { name: 'ECDH', namedCurve: 'P-256' }, false, [])
  const shared = new Uint8Array(await subtle.deriveBits({ name: 'ECDH', public: asKey }, ua.privateKey, 256))
  const info = new Uint8Array([...enc.encode('WebPush: info\0'), ...uaPublic, ...asPublic])
  const ikm = await hkdf(auth, shared, info, 32)
  const cek = await hkdf(salt, ikm, enc.encode('Content-Encoding: aes128gcm\0'), 16)
  const nonce = await hkdf(salt, ikm, enc.encode('Content-Encoding: nonce\0'), 12)
  const key = await subtle.importKey('raw', cek, 'AES-GCM', false, ['decrypt'])
  const plain = new Uint8Array(await subtle.decrypt({ name: 'AES-GCM', iv: nonce }, key, cipher))
  expect(plain[plain.length - 1]).toBe(2)                     // last-record delimiter
  return new TextDecoder().decode(plain.slice(0, -1))
}

async function phoneSubscription(): Promise<{ sub: PushSubscriptionKeys; ua: CryptoKeyPair; auth: Uint8Array }> {
  const ua = await subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']) as CryptoKeyPair
  const auth = webcrypto.getRandomValues(new Uint8Array(16))
  return { ua, auth, sub: { endpoint: 'https://fcm.googleapis.com/fcm/send/abc', p256dh: b64u(await subtle.exportKey('raw', ua.publicKey)), auth: b64u(auth) } }
}

async function vapidKeys(): Promise<{ vapid: Vapid; publicKey: CryptoKey }> {
  const k = await subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']) as CryptoKeyPair
  return { publicKey: k.publicKey, vapid: { publicKey: b64u(await subtle.exportKey('raw', k.publicKey)),
    privateJwk: await subtle.exportKey('jwk', k.privateKey), subject: 'https://deals.junkcarsmequon.com' } }
}

describe('web push', () => {
  it('encrypts so the phone can decrypt it (RFC 8291)', async () => {
    const { sub, ua, auth } = await phoneSubscription()
    const body = await encryptPayload(enc.encode(JSON.stringify({ title: 'Sam needs you', body: 'Dale' })), sub)
    expect(JSON.parse(await decrypt(body, ua, auth))).toEqual({ title: 'Sam needs you', body: 'Dale' })
  })

  it('signs a VAPID token the push service can verify (RFC 8292)', async () => {
    const { vapid, publicKey } = await vapidKeys()
    const jwt = await vapidJwt('https://fcm.googleapis.com', vapid, new Date('2026-10-22T17:00:00Z'))
    const [h, p, s] = jwt.split('.')
    expect(JSON.parse(new TextDecoder().decode(fromB64u(p)))).toMatchObject({ aud: 'https://fcm.googleapis.com', sub: vapid.subject })
    expect(await subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, publicKey, fromB64u(s), enc.encode(`${h}.${p}`))).toBe(true)
  })

  it('posts with the right headers and reports a dead subscription', async () => {
    const { sub } = await phoneSubscription()
    const { vapid } = await vapidKeys()
    const seen: RequestInit[] = []
    const ok = await sendPush(sub, { t: 1 }, vapid, (async (_u: string, init: RequestInit) => { seen.push(init); return new Response(null, { status: 201 }) }) as typeof fetch)
    expect(ok).toEqual({ ok: true, gone: false, status: 201 })
    const h = seen[0].headers as Record<string, string>
    expect(h['Content-Encoding']).toBe('aes128gcm')
    expect(h.Authorization).toMatch(new RegExp(`^vapid t=[^,]+, k=${vapid.publicKey}$`))
    expect(await sendPush(sub, {}, vapid, (async () => new Response(null, { status: 410 })) as unknown as typeof fetch))
      .toEqual({ ok: false, gone: true, status: 410 })
  })
})

describe('smtp', () => {
  function fakeServer(script: Record<string, string>, fail?: string) {
    const said: string[] = []
    let out = '220 smtp.gmail.com ready\r\n'
    const conn: SmtpConn = {
      async write(d) {
        const t = new TextDecoder().decode(d)
        said.push(t)
        if (t.endsWith('\r\n.\r\n')) out += '250 2.0.0 OK queued\r\n'
        else {
          const cmd = t.trim().split(' ')[0]
          out += fail && t.startsWith(fail) ? '535 5.7.8 Username and Password not accepted\r\n' : (script[cmd] ?? '334 go\r\n')
        }
        return d.length
      },
      async read(buf) {
        if (!out) return null
        const b = new TextEncoder().encode(out)
        buf.set(b.subarray(0, buf.length))
        const n = Math.min(b.length, buf.length)
        out = new TextDecoder().decode(b.subarray(n))
        return n
      },
      close() {},
    }
    return { conn, said }
  }
  const script = { EHLO: '250-smtp.gmail.com\r\n250-AUTH LOGIN PLAIN\r\n250 SMTPUTF8\r\n', AUTH: '334 VXNlcm5hbWU6\r\n', MAIL: '250 OK\r\n', RCPT: '250 OK\r\n',
    DATA: '354 Go ahead\r\n', QUIT: '221 bye\r\n' }
  const mail = { from: 'sender@example.com', to: 'colin@example.com', subject: 'Sam needs you: Dale', text: 'Hi\n.leading dot', html: '<p>Hi</p>' }

  it('authenticates and sends one message', async () => {
    const s = { ...script }
    const f = fakeServer(s)
    // the password line is answered 235 after the username's 334
    let n = 0
    const orig = f.conn.write.bind(f.conn)
    f.conn.write = async (d) => { n += 1; if (n === 4) { const r = await orig(d); return r } return orig(d) }
    s['c2VjcmV0'] = '235 2.7.0 Accepted\r\n'
    await sendMail(f.conn, { user: 'sender@example.com', pass: 'secret' }, mail)
    expect(f.said.map((x) => x.trim().split(/\s+/)[0]).slice(0, 7)).toEqual(['EHLO', 'AUTH', btoa('sender@example.com'), btoa('secret'), 'MAIL', 'RCPT', 'DATA'])
    expect(f.said.some((x) => x.includes('Subject: =?UTF-8?B?'))).toBe(true)
  })

  it('stops on a rejected password', async () => {
    const f = fakeServer(script, btoa('secret'))
    await expect(sendMail(f.conn, { user: 'u', pass: 'secret' }, mail)).rejects.toThrow(/SMTP 535/)
  })
})

describe('messages', () => {
  const d: ClaimedDraft = { id: 'd1', kind: 'first', is_test: false, phone10: '4145550177', inbound_body: 'Maybe. Depends on the price, the roof needs work and the tenants leave in March',
    intent: 'price_first', note: 'a real conversation', body: 'Thanks - is the place still yours?', owner_name: 'DALE NOVAK', property_address: '2847 N Burleigh St',
    thread: [{ who: 'us', body: 'Hi Dale, Colin here.', at: '' }, { who: 'them', body: 'Maybe.', at: '' }] }
  it('reads "Sam needs you / Dale, street: what they said" and opens the card', () => {
    const m = pushMessage(d, 'https://deals.junkcarsmequon.com')
    expect(m.title).toBe('Sam needs you')
    expect(m.body).toMatch(/^Dale, 2847 N Burleigh St: Maybe\. Depends on the price/)
    expect(m.body.length).toBeLessThan(100)
    expect(m.url).toBe('https://deals.junkcarsmequon.com/inbox#draft-d1')
    expect(firstName('ACME HOLDINGS LLC', '4145550177')).toBe('ACME HOLDINGS LLC')
    expect(firstName(null, '4145550177')).toBe('(414) 555-0177')
  })
  it('emails the thread, the suggestion and why, with a link that only opens the card', () => {
    const e = emailFor(d, 'https://deals.junkcarsmequon.com')
    expect(e.subject).toBe('Sam needs you: DALE NOVAK, 2847 N Burleigh St')
    expect(e.text).toMatch(/Them: Maybe\./)
    expect(e.text).toMatch(/Sam suggests: Thanks - is the place still yours\?/)
    expect(e.html).toMatch(/href="https:\/\/deals\.junkcarsmequon\.com\/inbox#draft-d1"/)
    expect([...e.html.matchAll(/href="([^"]+)"/g)].map((m) => m[1])).toEqual(['https://deals.junkcarsmequon.com/inbox#draft-d1'])
    expect(e.text).toMatch(/Nothing is sent from this email/)
  })
})

describe('notify rules on the database', () => {
  const MIGRATION = readdirSync(path.resolve(__dirname, '../supabase/migrations')).filter((f) => f.endsWith('.sql')).sort()
    .map((f) => readFileSync(path.resolve(__dirname, '../supabase/migrations', f), 'utf8')).join('\n')
  let db: PGlite
  const rpc: Rpc = async (fn, args) => {
    const names = Object.keys(args)
    try {
      const r = await db.query<{ r: unknown }>(`select public.${fn}(${names.map((n, i) => `${n} => $${i + 1}`).join(', ')}) as r`, names.map((n) => args[n]))
      return { data: r.rows[0]?.r, error: null }
    } catch (e) { return { data: null, error: { message: String(e) } } }
  }
  const pushes: { endpoint: string; title: string }[] = []
  const emails: string[] = []
  const deps = (opts: { subs?: number; email?: boolean; gone?: boolean } = {}) => ({
    rpc, appUrl: 'https://deals.junkcarsmequon.com', emailTo: opts.email === false ? null : 'colin@example.com',
    subscriptions: async () => Array.from({ length: opts.subs ?? 1 }, (_, i) => ({ endpoint: `https://push.example/${i}`, p256dh: 'x', auth: 'y' })),
    push: async (s: PushSubscriptionKeys, m: object) => { pushes.push({ endpoint: s.endpoint, title: (m as { title: string }).title }); return { ok: !opts.gone, gone: Boolean(opts.gone), status: opts.gone ? 410 : 201 } },
    email: opts.email === false ? null : async (m: { subject: string }) => { emails.push(m.subject) },
  })
  const at = (iso: string) => () => new Date(iso)

  beforeAll(async () => {
    db = new PGlite()
    await db.exec(SUPABASE_STUB)
    await db.exec(MIGRATION)
  })
  beforeEach(async () => {
    pushes.length = 0
    emails.length = 0
    await db.exec(`truncate public.reply_drafts, public.twilio_inbound, public.push_subscriptions cascade;
      insert into public.push_subscriptions (endpoint, p256dh, auth) values ('https://push.example/0', 'x', 'y');
      insert into public.twilio_inbound (sid, from10, to_number, body, received_at) values
        ('SM1', '4145550177', '+12629996513', 'Maybe, what would you pay?', '2026-10-22T16:00:00Z'),
        ('SM2', '4145550188', '+12629996513', 'wrong number', '2026-10-22T16:00:00Z');
      insert into public.reply_drafts (inbound_sid, phone10, inbound_body, inbound_at, kind, status, body) values
        ('SM1', '4145550177', 'Maybe, what would you pay?', '2026-10-22T16:00:00Z', 'candidate', 'awaiting_approval', 'Thanks - still yours?'),
        ('SM2', '4145550188', 'wrong number', '2026-10-22T16:00:00Z', 'routine', 'would_send', 'Sorry about that');`)
  })

  it('one push and one email per waiting draft, never for a routine reply, never twice', async () => {
    const s = await runNotifications({ ...deps(), now: at('2026-10-22T17:00:00Z') })
    expect(s).toMatchObject({ drafts: 1, pushes_ok: 1, emails: 1 })
    expect(pushes).toEqual([{ endpoint: 'https://push.example/0', title: 'Sam needs you' }])
    expect(emails).toEqual(['Sam needs you: (414) 555-0177'])
    await runNotifications({ ...deps(), now: at('2026-10-22T17:05:00Z') })
    expect(pushes.length).toBe(1)
  })

  it('reminds once after 2 hours if still waiting (push only), and only once', async () => {
    await runNotifications({ ...deps(), now: at('2026-10-22T17:00:00Z') })
    await runNotifications({ ...deps(), now: at('2026-10-22T18:30:00Z') })
    expect(pushes.length).toBe(1)
    await runNotifications({ ...deps(), now: at('2026-10-22T19:01:00Z') })
    expect(pushes.map((p) => p.title)).toEqual(['Sam needs you', 'Still waiting: Sam needs you'])
    expect(emails.length).toBe(1)
    await runNotifications({ ...deps(), now: at('2026-10-22T23:00:00Z') })
    expect(pushes.length).toBe(2)
  })

  it('waits for 8am in quiet hours', async () => {
    await runNotifications({ ...deps(), now: at('2026-10-23T03:30:00Z') })        // 22:30 Central
    expect(pushes).toEqual([])
    await runNotifications({ ...deps(), now: at('2026-10-23T13:00:30Z') })        // 08:00 Central
    expect(pushes.length).toBe(1)
  })

  it('claims nothing while nobody can be told, and forgets a dead phone', async () => {
    await runNotifications({ ...deps({ subs: 0, email: false }), now: at('2026-10-22T17:00:00Z') })
    expect((await db.query(`select count(*)::int as n from public.reply_drafts where notified_at is not null`)).rows).toEqual([{ n: 0 }])
    await runNotifications({ ...deps({ gone: true, email: false }), now: at('2026-10-22T17:00:00Z') })
    expect((await db.query(`select count(*)::int as n from public.push_subscriptions`)).rows).toEqual([{ n: 0 }])
  })
})
