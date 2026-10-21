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
import * as R from './replyRules.generated.ts'

export type Rpc = (fn: string, args: Record<string, unknown>) => Promise<{ data: unknown; error: { message: string } | null }>

export interface TwilioConfig {
  accountSid: string
  // Basic-auth user/password: an API key (SK...) and its secret, or the account SID and auth token.
  user: string
  password: string
  messagingServiceSid: string
  campaignNumber: string        // E.164; inbound texts TO this number are pulled before each run
  statusCallbackUrl?: string    // set only when the auth token is available to verify callbacks
}

export interface SendResult { ok: true; sid: string; status: string }
export interface SendFailure { ok: false; httpStatus: number | null; code: string | null; message: string }

export interface InboundText { sid: string; from: string; to: string; body: string; dateSent: string }

export interface TwilioPort {
  send(to: string, body: string): Promise<SendResult | SendFailure>
  inboundSince(since: Date): Promise<InboundText[]>
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
        accountSid, user, password, messagingServiceSid, campaignNumber,
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
    async send(to, body) {
      const form = new URLSearchParams({ To: to, Body: body, MessagingServiceSid: cfg.messagingServiceSid })
      if (cfg.statusCallbackUrl) form.set('StatusCallback', cfg.statusCallbackUrl)
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
        return { ok: true, sid: json.sid, status: String(json.status ?? 'accepted') }
      }
      return {
        ok: false, httpStatus: res.status,
        code: json.code != null ? String(json.code) : null,
        message: String(json.message ?? res.statusText ?? '').slice(0, 300),
      }
    },
    async inboundSince(since) {
      const day = since.toISOString().slice(0, 10)
      const url = `${base}/Messages.json?To=${encodeURIComponent(cfg.campaignNumber)}&DateSent%3E=${day}&PageSize=200`
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
}

export async function runSendOpeners(opts: {
  rpc: Rpc
  env: SenderEnv
  twilio: TwilioPort | null
  now?: () => Date
  maxSends?: number            // campaign_control.max_per_run
  maxClaims?: number           // a hard bound on loop turns (skips included)
  lastInboundPollAt?: string | null
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
      for (const m of await opts.twilio.inboundSince(since)) {
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

  // 2. Claim, send, record - one text at a time.
  const maxSends = opts.maxSends ?? 10
  const maxClaims = opts.maxClaims ?? 300
  for (let turn = 0; turn < maxClaims; turn++) {
    if (s.sent + s.failed + s.uncertain + s.would_send >= maxSends) { s.stopped = 'max_per_run'; break }
    const c = await opts.rpc('claim_next_opener', { p_dry_run: !live, p_now: now().toISOString() })
    if (c.error) { s.stopped = `claim_error: ${c.error.message}`; break }
    const j = c.data as { outcome: string; reason?: string; opener?: { id: string; phone: string; body: string } }
    if (j.outcome === 'idle') { s.stopped = j.reason ?? 'idle'; break }
    if (j.outcome === 'skipped') { s.skipped.push({ id: j.opener?.id ?? '', reason: j.reason ?? '' }); continue }
    if (j.outcome === 'would_send') { s.would_send += 1; continue }
    if (j.outcome !== 'send' || !live || !opts.twilio || !j.opener) { s.stopped = `unexpected: ${j.outcome}`; break }

    let res: SendResult | SendFailure
    try {
      res = await opts.twilio.send(j.opener.phone, j.opener.body)
    } catch (e) {
      res = { ok: false, httpStatus: null, code: null, message: String(e).slice(0, 300) }
    }
    const args = res.ok
      ? { p_id: j.opener.id, p_status: 'sent', p_sid: res.sid, p_error_code: null, p_reason: null, p_now: now().toISOString() }
      : { p_id: j.opener.id, p_status: classifyFailure(res), p_sid: null, p_error_code: res.code,
          p_reason: `${res.httpStatus ?? 'no answer'} ${res.code ?? ''} ${res.message}`.trim().slice(0, 300), p_now: now().toISOString() }
    const rec = await opts.rpc('record_send_result', args)
    if (res.ok) s.sent += 1
    else if (args.p_status === 'failed') s.failed += 1
    else s.uncertain += 1
    if (rec.error) { s.stopped = `record_error: ${rec.error.message}`; break }   // the entry stays 'sending': never retried
  }
  if (!s.stopped) s.stopped = 'max_claims'
  return s
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

// ------------------------------------------------- opt-out (wpie/sms/webhooks.py)
// The word lists and regexes are generated from WPIE (replyRules.generated.ts, copied
// from pm-phone, written by WPIE tools/export_reply_prompt.py); this is the same small
// algorithm pm-phone ports, and tests/optout.parity.test.ts checks it against
// Python's answer for every red-team text.
const re = (spec: R.RegexSpec, extra = '') => new RegExp(spec.source, spec.flags + extra)
const OPTOUT_WORDS = new Set(R.OPTOUT_WORDS)
const OPTOUT_PHRASE = re(R.OPTOUT_PHRASE)
const LEGAL_THREAT = re(R.LEGAL_THREAT)
const SOFT_OPTOUT = re(R.SOFT_OPTOUT)
const CHANNEL_PREF = re(R.CHANNEL_PREF)
const NEGATED = re(R.NEGATED, 'g')
const POLITE_TAIL = re(R.POLITE_TAIL, 'g')
const POLITE_HEAD = re(R.POLITE_HEAD, 'g')
const SHORT_STOP = re(R.SHORT_STOP)
const COMBINING_MARK = re(R.COMBINING_MARK, 'g')

function fold(text: string): string {
  const t = (text ?? '').toLowerCase().replace(/’/g, "'").normalize('NFKD').replace(COMBINING_MARK, '')
  return t.replace(/[^a-z0-9' ]/g, ' ').replace(/\s+/g, ' ').trim()
}
const squash = (s: string) => s.replace(/[ ']/g, '')

export function isOptOut(text: string): boolean {
  const normalized = fold(text)
  if (OPTOUT_WORDS.has(squash(normalized))) return true
  let core = normalized.replace(POLITE_TAIL, '').replace(POLITE_HEAD, '').trim()
  if (OPTOUT_WORDS.has(squash(core))) return true
  core = core.replace(NEGATED, ' ').replace(/\s+/g, ' ').trim()
  if (OPTOUT_PHRASE.test(core) || LEGAL_THREAT.test(core)) return true
  if (SOFT_OPTOUT.test(core) && !CHANNEL_PREF.test(core)) return true
  return SHORT_STOP.test(core)
}
