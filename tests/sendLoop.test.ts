// The send-openers loop (supabase/functions/_shared/sending.ts) end to end against the
// real migrations on PGlite, with a fake Twilio. Proves: a dry env never calls Twilio's
// send, the never-retry classification, a STOP pulled from Twilio stops the next send,
// a failed inbound check stops a live run, and a pause code stops the loop.
import { createHmac } from 'node:crypto'
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, beforeEach, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'
import parity from './replyParity.generated.json'
import {
  classifyFailure, isOptOut, runSendOpeners, senderEnv, twilioSignature, validTwilioSignature,
  type InboundText, type OutboundText, type Rpc, type SendFailure, type SendResult, type TwilioPort,
} from '../supabase/functions/_shared/sending'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')
const NOW = new Date('2026-10-22T15:30:00Z')         // Thursday 10:30 Central
const BODY = 'Hi Ann, Colin Merrill here. Any interest in selling the place on Oak St? No worries if not, just reply STOP.'

let db: PGlite
const rpc: Rpc = async (fn, args) => {
  const names = Object.keys(args)
  const sql = `select public.${fn}(${names.map((n, i) => `${n} => $${i + 1}`).join(', ')}) as r`
  try {
    const r = await db.query<{ r: unknown }>(sql, names.map((n) => args[n]))
    return { data: r.rows[0].r, error: null }
  } catch (e) {
    return { data: null, error: { message: String(e) } }
  }
}

const LIVE = senderEnv((n) => ({
  TWILIO_LIVE_SENDING: '1', TWILIO_ACCOUNT_SID: 'ACtest', TWILIO_AUTH_TOKEN: 'tok', CAMPAIGN_MESSAGING_SERVICE_SID: 'MGtest',
  CAMPAIGN_FROM_NUMBER: '+12629996513',
} as Record<string, string>)[n], 'https://x.supabase.co/functions/v1')

class FakeTwilio implements TwilioPort {
  sends: { to: string; body: string }[] = []
  inbound: InboundText[] = []
  answers: (SendResult | SendFailure | Error)[] = []
  inboundFails = false
  async send(to: string, body: string) {
    this.sends.push({ to, body })
    const a = this.answers.shift() ?? { ok: true as const, sid: `SM${this.sends.length}`, status: 'accepted' }
    if (a instanceof Error) throw a
    return a
  }
  inboundAsked: (string | undefined)[] = []
  async inboundSince(_since: Date, to?: string) {
    if (this.inboundFails) throw new Error('Twilio inbound list answered 503')
    this.inboundAsked.push(to)
    return to ? this.inbound.filter((m) => m.to === to) : this.inbound
  }
  outbound: OutboundText[] = []
  outboundFails = false
  async outboundTo(to: string) {
    if (this.outboundFails) throw new Error('Twilio message list answered 500')
    return this.outbound.filter((m) => m.to === to)
  }
}

// A row the claim left in 'sending' (the result never came back), claimed `ago` seconds before NOW.
async function stuck(phone: string, ago = 300) {
  await db.query(`update public.planned_openers set send_status = 'sending', claim_mode = 'live', claimed_at = $2
                   where phone = $1`, [`+1${phone}`, new Date(NOW.getTime() - ago * 1000).toISOString()])
}

let n = 0
async function approvedOpener() {
  n += 1
  const phone = `414555${String(1000 + n)}`
  const l = await db.query<{ id: string }>(`insert into public.leads (wpie_owner_id, owner_name, stage) values ($1, $2, 'opener_queued') returning id`, [5000 + n, `OWNER ${n}`])
  await db.query(`insert into public.contacts (lead_id, kind, value, value_normalized) values ($1, 'phone', $2, $2)`, [l.rows[0].id, phone])
  await db.query(
    `insert into public.planned_openers (plan_date, wpie_owner_id, attempt, lead_id, phone, body, body_sha256, scheduled_at,
       window_start_utc, window_end_utc, dnc_state, per_hour, decision)
     values ('2026-10-22', $1, 1, $2, $3, $4, encode(sha256(convert_to($4, 'UTF8')), 'hex'), '2026-10-22T15:00:00Z',
       '2026-10-22T15:00:00Z', '2026-10-22T23:15:00Z', 'unknown', 50, 'approved')`,
    [5000 + n, l.rows[0].id, `+1${phone}`, BODY])
  return phone
}

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
})

beforeEach(async () => {
  await db.exec(`
    truncate public.opener_send_events, public.twilio_inbound, public.suppressed_phones, public.planned_openers,
             public.messages, public.contacts, public.leads cascade;
    update public.campaign_control set sending_enabled = true, paused = false, pause_reason = null, dnc_policy = 'allow_unknown';
  `)
})

describe('runSendOpeners', () => {
  it('sender pool: reads STOPs on every pool number, sends without From, and records the number Twilio used', async () => {
    const POOL = senderEnv((n) => ({ TWILIO_LIVE_SENDING: '1', TWILIO_ACCOUNT_SID: 'ACtest', TWILIO_AUTH_TOKEN: 'tok',
      CAMPAIGN_MESSAGING_SERVICE_SID: 'MGtest', CAMPAIGN_FROM_NUMBER: 'pool' } as Record<string, string>)[n], 'https://x')
    expect(POOL.live).toBe(true)
    const stopper = await approvedOpener()
    const fine = await approvedOpener()
    const tw = new FakeTwilio()
    tw.inbound = [{ sid: 'SMstop', from: `+1${stopper}`, to: '+12624180202', body: 'STOP', dateSent: NOW.toISOString() }]
    tw.answers = [{ ok: true, sid: 'SMpool1', status: 'accepted', from: '+12624180202' }]
    const s = await runSendOpeners({ rpc, env: POOL, twilio: tw, now: () => NOW, inboundNumbers: ['+12629996513', '+12624180202'] })
    expect(tw.inboundAsked).toEqual(['+12629996513', '+12624180202'])
    expect(s).toMatchObject({ inbound_new: 1, sent: 1 })
    expect(tw.sends.map((x) => x.to)).toEqual([`+1${fine}`])
    const r = (await db.query<{ from_number: string }>(`select from_number from public.planned_openers where provider_sid = 'SMpool1'`)).rows
    expect(r).toEqual([{ from_number: '+12624180202' }])
    // No pool numbers known: STOPs cannot be read, so a live run sends nothing.
    const none = await runSendOpeners({ rpc, env: POOL, twilio: new FakeTwilio(), now: () => NOW, inboundNumbers: [] })
    expect(none).toMatchObject({ stopped: 'inbound_check_failed', sent: 0 })
  })

  it('reconciles a lost result: Twilio has the text -> recorded sent with its delivery, never re-sent', async () => {
    const phone = await approvedOpener()
    await stuck(phone)
    const tw = new FakeTwilio()
    tw.outbound = [{ sid: 'SMlost', to: `+1${phone}`, body: BODY, status: 'delivered', errorCode: null,
      dateCreated: new Date(NOW.getTime() - 290_000).toISOString() }]
    const s = await runSendOpeners({ rpc, env: LIVE, twilio: tw, now: () => NOW })
    expect(s.reconciled).toEqual([{ id: expect.any(String), outcome: 'found', detail: 'SMlost delivered' }])
    expect(tw.sends).toEqual([])
    const r = (await db.query<{ send_status: string; provider_sid: string }>(`select send_status, provider_sid from public.planned_openers`)).rows
    expect(r).toEqual([{ send_status: 'delivered', provider_sid: 'SMlost' }])
    const ev = (await db.query<{ event: string }>(`select event from public.opener_send_events order by at, id`)).rows.map((x) => x.event)
    expect(ev).toEqual(['sent', 'delivered'])
  })

  it('reconciles a claim that never went out: released to planned, then sent once in the same run', async () => {
    const phone = await approvedOpener()
    await stuck(phone)
    const tw = new FakeTwilio()
    tw.outbound = [{ sid: 'SMother', to: `+1${phone}`, body: 'a different text', status: 'delivered', errorCode: null,
      dateCreated: NOW.toISOString() }]
    const s = await runSendOpeners({ rpc, env: LIVE, twilio: tw, now: () => NOW })
    expect(s.reconciled?.[0]).toMatchObject({ outcome: 'released' })
    expect(tw.sends).toHaveLength(1)
    expect(s.sent).toBe(1)
    const ev = (await db.query<{ event: string }>(`select event from public.opener_send_events order by at, id`)).rows.map((x) => x.event)
    expect(ev).toEqual(['released', 'sending', 'sent'])
  })

  it('leaves a stuck row alone when Twilio cannot be asked, and ignores fresh claims', async () => {
    const a = await approvedOpener(); const b = await approvedOpener()
    await stuck(a); await stuck(b, 30)
    const tw = new FakeTwilio()
    tw.outboundFails = true
    const s = await runSendOpeners({ rpc, env: LIVE, twilio: tw, now: () => NOW })
    expect(s.reconciled).toEqual([{ id: expect.any(String), outcome: 'error', detail: 'Twilio message list answered 500' }])
    expect((await db.query<{ n: number }>(`select count(*)::int n from public.planned_openers where send_status = 'sending'`)).rows[0].n).toBe(2)
    expect(tw.sends).toEqual([])
  })

  it('never starts a claim with under 10 s left, and retries writing a result', async () => {
    await approvedOpener(); await approvedOpener()
    const tw = new FakeTwilio()
    let t = 0
    const clock = () => t
    const s1 = await runSendOpeners({ rpc, env: LIVE, twilio: tw, now: () => NOW, deadline: 9_000, clock })
    expect(s1).toMatchObject({ sent: 0, stopped: 'time_budget' })
    let fails = 1
    const flaky: Rpc = async (fn, args) => {
      if (fn === 'record_send_result' && fails > 0) { fails -= 1; return { data: null, error: { message: 'connection reset' } } }
      return rpc(fn, args)
    }
    t = 0
    const s2 = await runSendOpeners({ rpc: flaky, env: LIVE, twilio: tw, now: () => NOW, deadline: 60_000, clock, sleep: async () => {} })
    expect(s2).toMatchObject({ sent: 2, stopped: 'nothing_due' })
    expect((await db.query<{ n: number }>(`select count(*)::int n from public.planned_openers where send_status = 'sent'`)).rows[0].n).toBe(2)
  })

  it('in a dry env checks everything and never calls Twilio send', async () => {
    await approvedOpener(); await approvedOpener()
    const tw = new FakeTwilio()
    const dry = senderEnv(() => undefined, 'https://x')
    const s = await runSendOpeners({ rpc, env: dry, twilio: tw, now: () => NOW })
    expect(s).toMatchObject({ mode: 'dry', why_dry: 'TWILIO_LIVE_SENDING is not 1', would_send: 2, sent: 0, stopped: 'nothing_due' })
    expect(tw.sends).toEqual([])
  })

  it('sends live, classifies refusals as failed and everything else as uncertain, never retrying', async () => {
    for (let i = 0; i < 4; i++) await approvedOpener()
    const tw = new FakeTwilio()
    tw.answers = [
      { ok: true, sid: 'SMgood', status: 'accepted' },
      { ok: false, httpStatus: 400, code: '21610', message: 'Attempt to send to unsubscribed recipient' },
      { ok: false, httpStatus: 503, code: null, message: 'Service Unavailable' },
      new Error('socket hang up'),
    ]
    const s = await runSendOpeners({ rpc, env: LIVE, twilio: tw, now: () => NOW })
    expect(s).toMatchObject({ mode: 'live', sent: 1, failed: 1, uncertain: 2, stopped: 'nothing_due' })
    const rows = await db.query<{ send_status: string }>(`select send_status from public.planned_openers order by claimed_at, send_status`)
    expect(rows.rows.map((r) => r.send_status).sort()).toEqual(['failed', 'sent', 'uncertain', 'uncertain'])
    const again = await runSendOpeners({ rpc, env: LIVE, twilio: tw, now: () => NOW })
    expect(again.sent + again.failed + again.uncertain).toBe(0)
    expect(tw.sends.length).toBe(4)
  })

  it('a STOP pulled from Twilio stops the text to that phone in the same run', async () => {
    const phone = await approvedOpener()
    const tw = new FakeTwilio()
    tw.inbound = [{ sid: 'SMin', from: `+1${phone}`, to: '+12629996513', body: 'Stop texting me', dateSent: NOW.toISOString() }]
    const s = await runSendOpeners({ rpc, env: LIVE, twilio: tw, now: () => NOW })
    expect(s).toMatchObject({ inbound_new: 1, sent: 0 })
    expect(s.skipped.map((x) => x.reason)).toEqual(['phone_suppressed'])
    expect(tw.sends).toEqual([])
  })

  it('a live run that cannot read new replies sends nothing', async () => {
    await approvedOpener()
    const tw = new FakeTwilio()
    tw.inboundFails = true
    const s = await runSendOpeners({ rpc, env: LIVE, twilio: tw, now: () => NOW })
    expect(s).toMatchObject({ stopped: 'inbound_check_failed', sent: 0 })
    expect(tw.sends).toEqual([])
  })

  it('stops the loop on an account error code (the database pauses)', async () => {
    await approvedOpener(); await approvedOpener()
    const tw = new FakeTwilio()
    tw.answers = [{ ok: false, httpStatus: 400, code: '21606', message: 'From is not a valid number for this account' }]
    const s = await runSendOpeners({ rpc, env: LIVE, twilio: tw, now: () => NOW })
    expect(s).toMatchObject({ failed: 1, sent: 0, stopped: 'paused' })
    expect(tw.sends.length).toBe(1)
  })

  it('stops at max_per_run', async () => {
    for (let i = 0; i < 3; i++) await approvedOpener()
    const tw = new FakeTwilio()
    const s = await runSendOpeners({ rpc, env: LIVE, twilio: tw, now: () => NOW, maxSends: 2 })
    expect(s).toMatchObject({ sent: 2, stopped: 'max_per_run' })
  })
})

describe('sender env', () => {
  it('is live only with the flag AND every Twilio setting', () => {
    expect(LIVE.live).toBe(true)
    expect(senderEnv((k) => (k === 'TWILIO_LIVE_SENDING' ? '1' : undefined), 'x')).toMatchObject({ live: false })
    expect(senderEnv((k) => (k === 'TWILIO_LIVE_SENDING' ? 'true' : 'set'), 'x').live).toBe(false)
  })
  it('asks Twilio for status callbacks only when it can verify them', () => {
    expect(LIVE.twilio?.statusCallbackUrl).toBe('https://x.supabase.co/functions/v1/opener-status')
    const keyOnly = senderEnv((k) => ({ TWILIO_ACCOUNT_SID: 'AC', TWILIO_API_KEY_SID: 'SK', TWILIO_API_KEY_SECRET: 's',
      CAMPAIGN_MESSAGING_SERVICE_SID: 'MG', CAMPAIGN_FROM_NUMBER: '+1' } as Record<string, string>)[k], 'https://x')
    expect(keyOnly.twilio).toMatchObject({ user: 'SK', statusCallbackUrl: undefined })
  })
  it('treats only a 4xx as a definite refusal', () => {
    expect(classifyFailure({ ok: false, httpStatus: 429, code: '20429', message: '' })).toBe('failed')
    expect(classifyFailure({ ok: false, httpStatus: 500, code: null, message: '' })).toBe('uncertain')
    expect(classifyFailure({ ok: false, httpStatus: null, code: null, message: '' })).toBe('uncertain')
  })
})

describe('Twilio callback signature', () => {
  it('matches an independent HMAC-SHA1 and rejects a tampered body', async () => {
    const url = 'https://x.supabase.co/functions/v1/opener-status'
    const params = { MessageSid: 'SM1', MessageStatus: 'delivered', ErrorCode: '' }
    const ours = await twilioSignature('secret-token', url, params)
    const node = createHmac('sha1', 'secret-token').update(url + 'ErrorCode' + 'MessageSid' + 'SM1' + 'MessageStatus' + 'delivered').digest('base64')
    expect(ours).toBe(node)
    expect(await validTwilioSignature('secret-token', url, params, ours)).toBe(true)
    expect(await validTwilioSignature('secret-token', url, { ...params, MessageStatus: 'failed' }, ours)).toBe(false)
    expect(await validTwilioSignature('', url, params, ours)).toBe(false)
  })
})

describe('opt-out parity with wpie/sms/webhooks.py is_opt_out', () => {
  it('agrees with Python on every red-team text', () => {
    const rows = parity.opt_out as { text: string; python_is_opt_out: boolean }[]
    expect(rows.length).toBeGreaterThanOrEqual(400)
    const mismatches = rows.filter((r) => isOptOut(r.text) !== r.python_is_opt_out).map((r) => r.text)
    expect(mismatches).toEqual([])
  })
})
