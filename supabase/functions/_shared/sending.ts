// The send loop behind the send-openers Edge Function, written without Deno or
// network globals so vitest can run it against PGlite with a fake Twilio
// (tests/sendLoop.test.ts). Every decision about WHETHER a text may go is made in
// Postgres (claim_next_opener, migration 0003); this file only moves data between
// the database and Twilio and classifies Twilio's answers.
//
// Never-retry rule (same as WPIE's send.py): an entry is already 'sending' when it
// reaches here. A definite 4xx refusal is 'failed'; anything else that is not a
// clean success (network error, timeout, 5xx, unreadable answer) is 'uncertain' and
// is never tried again.
import { isOptOut } from './replyGuard.ts'

export { isOptOut }

export type Rpc = (fn: string, args: Record<string, unknown>) => Promise<{ data: unknown; error: { message: string } | null }>

export interface TwilioConfig {
  accountSid: string
  // Basic-auth user/password: an API key (SK...) and its secret, or the account SID and auth token.
  user: string
  password: string
  messagingServiceSid: string
  campaignNumber: string        // E.164 whose inbound texts are pulled before each run, or 'pool': every reply number
  statusCallbackUrl?: string    // set only when the auth token is available to verify callbacks
  // CAMPAIGN_OPENER_FROM: every text that has no number of its own (a first text, or a follow-up to
  // someone whose first number was never recorded) goes out from one of these pool numbers. A number
  // just added to the pool waits days for carrier registration (30024 until then) and must stay in
  // the pool for it, so without this list Twilio would pick it for real sellers. Empty = Twilio picks.
  openerFrom: string[]
}

export interface SendResult { ok: true; sid: string; status: string; from?: string | null }
export interface SendFailure { ok: false; httpStatus: number | null; code: string | null; message: string }

export interface InboundText { sid: string; from: string; to: string; body: string; dateSent: string }
export interface OutboundText { sid: string; to: string; from?: string | null; body: string; status: string; errorCode: string | null; dateCreated: string }

export interface TwilioPort {
  /** `from`: send from this exact number (a reply goes out from the number they texted).
   *  `statusCallback`: ask for delivery callbacks even with a `from` (a pinned first text). */
  send(to: string, body: string, from?: string | null, opts?: { statusCallback?: boolean }): Promise<SendResult | SendFailure>
  /** Inbound texts to `to` (default: the campaign number) since `since`. */
  inboundSince(since: Date, to?: string): Promise<InboundText[]>
  /** Texts we sent to `to` since `since` (Twilio's own record; used to reconcile a lost result). */
  outboundTo?(to: string, since: Date): Promise<OutboundText[]>
}

// ------------------------------------------------------------------ the env
export interface SenderEnv {
  live: boolean               // TWILIO_LIVE_SENDING=1 AND every Twilio setting present
  why: string                 // why a run is dry, for the run summary
  twilio: TwilioConfig | null
}

export function senderEnv(get: (name: string) => string | undefined, functionsBaseUrl: string): SenderEnv {
  const accountSid = (get('TWILIO_ACCOUNT_SID') ?? '').trim()
  const keySid = (get('TWILIO_API_KEY_SID') ?? '').trim()
  const keySecret = (get('TWILIO_API_KEY_SECRET') ?? '').trim()
  const authToken = (get('TWILIO_AUTH_TOKEN') ?? '').trim()
  const messagingServiceSid = (get('CAMPAIGN_MESSAGING_SERVICE_SID') ?? '').trim()
  const campaignNumber = (get('CAMPAIGN_FROM_NUMBER') ?? '').trim()
  const openerFrom = (get('CAMPAIGN_OPENER_FROM') ?? '').split(',').map((x) => x.trim()).filter((x) => /^\+1\d{10}$/.test(x))
  const user = keySid && keySecret ? keySid : accountSid
  const password = keySid && keySecret ? keySecret : authToken
  const missing = [
    !accountSid && 'TWILIO_ACCOUNT_SID',
    !password && 'TWILIO_AUTH_TOKEN (or TWILIO_API_KEY_SID + TWILIO_API_KEY_SECRET)',
    !messagingServiceSid && 'CAMPAIGN_MESSAGING_SERVICE_SID',
    !campaignNumber && 'CAMPAIGN_FROM_NUMBER',
  ].filter(Boolean) as string[]
  const twilio = missing.length
    ? null
    : {
        accountSid, user, password, messagingServiceSid, campaignNumber, openerFrom,
        statusCallbackUrl: authToken ? `${functionsBaseUrl.replace(/\/$/, '')}/opener-status` : undefined,
      }
  if ((get('TWILIO_LIVE_SENDING') ?? '').trim() !== '1') return { live: false, why: 'TWILIO_LIVE_SENDING is not 1', twilio }
  if (!twilio) return { live: false, why: `not set: ${missing.join(', ')}`, twilio }
  return { live: true, why: '', twilio }
}

// ---------------------------------------------------------------- Twilio over fetch
export function twilioPort(cfg: TwilioConfig, fetchFn: typeof fetch): TwilioPort {
  const base = `https://api.twilio.com/2010-04-01/Accounts/${cfg.accountSid}`
  const auth = 'Basic ' + btoa(`${cfg.user}:${cfg.password}`)
  return {
    async send(to, body, from, opts) {
      const form = new URLSearchParams({ To: to, Body: body, MessagingServiceSid: cfg.messagingServiceSid })
      // must be a number in the same Messaging Service; none of its own -> a proven one (CAMPAIGN_OPENER_FROM)
      const sender = from || openerFromFor(cfg.openerFrom ?? [], to)
      if (sender) form.set('From', sender)
      if (cfg.statusCallbackUrl && (!from || opts?.statusCallback)) form.set('StatusCallback', cfg.statusCallbackUrl)
      let res: Response
      try {
        res = await fetchFn(`${base}/Messages.json`, {
          method: 'POST', headers: { Authorization: auth, 'Content-Type': 'application/x-www-form-urlencoded' }, body: form,
        })
      } catch (e) {
        return { ok: false, httpStatus: null, code: null, message: `network: ${String(e)}`.slice(0, 300) }
      }
      let json: Record<string, unknown> = {}
      try {
        json = (await res.json()) as Record<string, unknown>
      } catch {
        // an unreadable answer is treated like no answer
      }
      if (res.status >= 200 && res.status < 300 && typeof json.sid === 'string') {
        return { ok: true, sid: json.sid, status: String(json.status ?? 'accepted'), from: typeof json.from === 'string' && json.from ? json.from : null }
      }
      return {
        ok: false, httpStatus: res.status,
        code: json.code != null ? String(json.code) : null,
        message: String(json.message ?? res.statusText ?? '').slice(0, 300),
      }
    },
    async outboundTo(to, since) {
      const day = since.toISOString().slice(0, 10)
      const url = `${base}/Messages.json?To=${encodeURIComponent(to)}&DateSent%3E=${day}&PageSize=50`
      const res = await fetchFn(url, { headers: { Authorization: auth } })
      if (!res.ok) throw new Error(`Twilio message list answered ${res.status}`)
      const json = (await res.json()) as { messages?: Record<string, unknown>[] }
      return (json.messages ?? [])
        .filter((m) => String(m.direction ?? '').startsWith('outbound'))
        .map((m) => ({
          sid: String(m.sid), to: String(m.to ?? ''), from: m.from ? String(m.from) : null, body: String(m.body ?? ''), status: String(m.status ?? ''),
          errorCode: m.error_code != null ? String(m.error_code) : null,
          dateCreated: new Date(String(m.date_created ?? m.date_sent ?? new Date().toISOString())).toISOString(),
        }))
    },
    async inboundSince(since, to) {
      const day = since.toISOString().slice(0, 10)
      const url = `${base}/Messages.json?To=${encodeURIComponent(to ?? cfg.campaignNumber)}&DateSent%3E=${day}&PageSize=200`
      const res = await fetchFn(url, { headers: { Authorization: auth } })
      if (!res.ok) throw new Error(`Twilio inbound list answered ${res.status}`)
      const json = (await res.json()) as { messages?: Record<string, unknown>[] }
      return (json.messages ?? [])
        .filter((m) => String(m.direction ?? '') === 'inbound')
        .map((m) => ({
          sid: String(m.sid), from: String(m.from ?? ''), to: String(m.to ?? ''), body: String(m.body ?? ''),
          dateSent: new Date(String(m.date_sent ?? m.date_created ?? new Date().toISOString())).toISOString(),
        }))
    },
  }
}

/** 'failed' only for a definite refusal (4xx); everything else is 'uncertain'. */
export function classifyFailure(f: SendFailure): 'failed' | 'uncertain' {
  return f.httpStatus != null && f.httpStatus >= 400 && f.httpStatus < 500 ? 'failed' : 'uncertain'
}

// --------------------------------------------------------------- the run
export interface RunSummary {
  mode: 'live' | 'dry'
  why_dry: string
  inbound_new: number
  inbound_error: string | null
  sent: number
  would_send: number
  skipped: { id: string; reason: string }[]
  failed: number
  uncertain: number
  stopped: string
  reconciled?: { id: string; outcome: 'found' | 'released' | 'error'; detail: string }[]
}

export async function runSendOpeners(opts: {
  rpc: Rpc
  env: SenderEnv
  twilio: TwilioPort | null
  now?: () => Date
  maxSends?: number            // campaign_control.max_per_run
  maxClaims?: number           // a hard bound on loop turns (skips included)
  lastInboundPollAt?: string | null
  inboundNumbers?: string[]    // with CAMPAIGN_FROM_NUMBER=pool: every number in the sender pool
  deadline?: number            // epoch ms: no new claim when less than `safetyMs` remains
  safetyMs?: number
  clock?: () => number         // wall clock for the deadline (tests)
  sleep?: (ms: number) => Promise<void>
}): Promise<RunSummary> {
  const now = opts.now ?? (() => new Date())
  const live = opts.env.live && opts.twilio != null
  const s: RunSummary = {
    mode: live ? 'live' : 'dry', why_dry: live ? '' : opts.env.why || 'no Twilio settings', inbound_new: 0, inbound_error: null,
    sent: 0, would_send: 0, skipped: [], failed: 0, uncertain: 0, stopped: '',
  }

  // 1. Fresh STOPs and replies first. A live run that cannot read them sends nothing.
  if (opts.twilio) {
    try {
      const since = opts.lastInboundPollAt ? new Date(new Date(opts.lastInboundPollAt).getTime() - 3600_000) : new Date(now().getTime() - 3 * 86400_000)
      // Sender pool: a STOP can arrive on any pool number, so every one is read; none known = no check.
      const pool = opts.env.twilio?.campaignNumber === 'pool'
      const numbers: (string | undefined)[] = pool ? (opts.inboundNumbers ?? []) : [undefined]
      if (!numbers.length) throw new Error('sender pool: no reply numbers to read STOPs from')
      const seen: InboundText[] = []
      for (const num of numbers) seen.push(...await opts.twilio.inboundSince(since, num))
      for (const m of seen) {
        const r = await opts.rpc('record_inbound', {
          p_sid: m.sid, p_from: m.from, p_to: m.to, p_body: m.body, p_is_opt_out: isOptOut(m.body), p_received_at: m.dateSent,
        })
        if (r.error) throw new Error(r.error.message)
        s.inbound_new += 1
      }
    } catch (e) {
      s.inbound_error = String(e instanceof Error ? e.message : e).slice(0, 300)
      if (live) {
        s.stopped = 'inbound_check_failed'
        return s
      }
    }
  }

  // 2. Lost results first: a row 'sending' for over two minutes is checked against Twilio. Found:
  //    recorded as sent (with its delivery status). Not found: it was never sent, so it goes back
  //    to 'planned'. If Twilio cannot be asked, the row is left alone (never released blind).
  const clock = opts.clock ?? (() => Date.now())
  const sleep = opts.sleep ?? ((ms: number) => new Promise<void>((r) => setTimeout(r, ms)))
  if (live && opts.twilio?.outboundTo) {
    const st = await opts.rpc('stuck_sending', { p_older_than_seconds: 120, p_now: now().toISOString() })
    for (const r of ((st.data as { id: string; phone: string; body: string; claimed_at: string }[] | null) ?? [])) {
      s.reconciled = s.reconciled ?? []
      try {
        const since = new Date(new Date(r.claimed_at).getTime() - 60_000)
        const sent = (await opts.twilio.outboundTo(r.phone, since))
          .filter((m) => m.body.trim() === r.body.trim() && new Date(m.dateCreated).getTime() >= since.getTime())
          .sort((a, b) => a.dateCreated.localeCompare(b.dateCreated))[0]
        if (sent) {
          const rec = await opts.rpc('record_send_result', { p_id: r.id, p_status: 'sent', p_sid: sent.sid, p_error_code: null,
            p_reason: 'reconciled: result was lost, Twilio has the text', p_now: sent.dateCreated })
          if (rec.error) throw new Error(rec.error.message)
          if (sent.from) await opts.rpc('record_from', { p_sid: sent.sid, p_from: sent.from })
          if (['delivered', 'undelivered', 'failed'].includes(sent.status)) {
            await opts.rpc('record_delivery', { p_sid: sent.sid, p_status: sent.status, p_error_code: sent.errorCode, p_now: now().toISOString() })
          }
          s.reconciled.push({ id: r.id, outcome: 'found', detail: `${sent.sid} ${sent.status}` })
        } else {
          const rel = await opts.rpc('release_stuck_opener', { p_id: r.id,
            p_reason: 'released: claimed but Twilio has no such text (never sent)', p_now: now().toISOString() })
          if (rel.error) throw new Error(rel.error.message)
          s.reconciled.push({ id: r.id, outcome: 'released', detail: 'not at Twilio; back to planned' })
        }
      } catch (e) {
        s.reconciled.push({ id: r.id, outcome: 'error', detail: String(e instanceof Error ? e.message : e).slice(0, 200) })
      }
    }
  }

  // 3. Claim, send, record - one text at a time, never starting a claim without time to finish it.
  const maxSends = opts.maxSends ?? 10
  const maxClaims = opts.maxClaims ?? 300
  const safety = opts.safetyMs ?? 10_000
  for (let turn = 0; turn < maxClaims; turn++) {
    if (s.sent + s.failed + s.uncertain + s.would_send >= maxSends) { s.stopped = 'max_per_run'; break }
    if (opts.deadline != null && opts.deadline - clock() < safety) { s.stopped = 'time_budget'; break }
    const c = await opts.rpc('claim_next_opener', { p_dry_run: !live, p_now: now().toISOString() })
    if (c.error) { s.stopped = `claim_error: ${c.error.message}`; break }
    const j = c.data as { outcome: string; reason?: string; opener?: { id: string; phone: string; body: string } }
    if (j.outcome === 'idle') { s.stopped = j.reason ?? 'idle'; break }
    if (j.outcome === 'skipped') { s.skipped.push({ id: j.opener?.id ?? '', reason: j.reason ?? '' }); continue }
    if (j.outcome === 'would_send') { s.would_send += 1; continue }
    if (j.outcome !== 'send' || !live || !opts.twilio || !j.opener) { s.stopped = `unexpected: ${j.outcome}`; break }

    let res: SendResult | SendFailure
    try {
      // the number their thread is already on, when it is still in the pool; a new phone is spread across the pool
      const pool = opts.env.twilio?.openerFrom ?? []
      const prev = await opts.rpc('sender_for_phone', { p_phone: j.opener.phone })
      const known = typeof prev.data === 'string' && pool.includes(prev.data) ? prev.data : null
      const from = known ?? openerFromFor(pool, j.opener.phone)
      res = from
        ? await opts.twilio.send(j.opener.phone, j.opener.body, from, { statusCallback: true })
        : await opts.twilio.send(j.opener.phone, j.opener.body)
    } catch (e) {
      res = { ok: false, httpStatus: null, code: null, message: String(e).slice(0, 300) }
    }
    const args = res.ok
      ? { p_id: j.opener.id, p_status: 'sent', p_sid: res.sid, p_error_code: null, p_reason: null, p_now: now().toISOString() }
      : { p_id: j.opener.id, p_status: classifyFailure(res), p_sid: null, p_error_code: res.code,
          p_reason: `${res.httpStatus ?? 'no answer'} ${res.code ?? ''} ${res.message}`.trim().slice(0, 300), p_now: now().toISOString() }
    // The text is out: writing its result must not be lost to one bad moment.
    let rec = await opts.rpc('record_send_result', args)
    for (let i = 0; rec.error && i < 3; i++) {
      await sleep(400 * (i + 1))
      rec = await opts.rpc('record_send_result', args)
    }
    if (res.ok && res.from) await opts.rpc('record_from', { p_sid: res.sid, p_from: res.from })
    if (res.ok) s.sent += 1
    else if (args.p_status === 'failed') s.failed += 1
    else s.uncertain += 1
    if (rec.error) { s.stopped = `record_error: ${rec.error.message}`; break }   // the entry stays 'sending': never retried
  }
  if (!s.stopped) s.stopped = 'max_claims'
  return s
}

/** The pool number a first text goes out from: the same one for the same phone, spread across the list. */
export function openerFromFor(list: string[], phone: string): string | null {
  if (!list.length) return null
  let h = 0
  for (const ch of phone.replace(/\D/g, '')) h = (h * 31 + ch.charCodeAt(0)) >>> 0
  return list[h % list.length]
}

// -------------------------------------------------------- Twilio callback signature
// https://www.twilio.com/docs/usage/security#validating-requests
export async function twilioSignature(authToken: string, url: string, params: Record<string, string>): Promise<string> {
  const data = url + Object.keys(params).sort().map((k) => k + params[k]).join('')
  const enc = new TextEncoder()
  const key = await crypto.subtle.importKey('raw', enc.encode(authToken), { name: 'HMAC', hash: 'SHA-1' }, false, ['sign'])
  const sig = new Uint8Array(await crypto.subtle.sign('HMAC', key, enc.encode(data)))
  let bin = ''
  for (const b of sig) bin += String.fromCharCode(b)
  return btoa(bin)
}

export async function validTwilioSignature(authToken: string, url: string, params: Record<string, string>, header: string | null) {
  if (!authToken || !header) return false
  const expected = await twilioSignature(authToken, url, params)
  if (expected.length !== header.length) return false
  let diff = 0
  for (let i = 0; i < expected.length; i++) diff |= expected.charCodeAt(i) ^ header.charCodeAt(i)
  return diff === 0
}
