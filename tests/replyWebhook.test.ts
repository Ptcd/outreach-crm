// The instant-reply path (reply-inbound) end to end on the real migrations (PGlite), with
// Twilio-signed fake webhooks, a fake Twilio and a fake drafter. No real text anywhere.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, beforeEach, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'
import redteam from '../supabase/functions/_shared/replyRedteam.generated.json'
import { EMPTY_TWIML, afterWebhook, recordWebhook } from '../supabase/functions/_shared/inbound'
import { runReplyAgent, type Drafter } from '../supabase/functions/_shared/replyAgent'
import type { RedteamRow } from '../supabase/functions/_shared/replyBrain'
import {
  senderEnv, twilioSignature, validTwilioSignature, type Rpc, type SendFailure, type SendResult, type TwilioPort,
} from '../supabase/functions/_shared/sending'

const MIGRATION = readdirSync(path.resolve(__dirname, '../supabase/migrations')).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.resolve(__dirname, '../supabase/migrations', f), 'utf8')).join('\n')
const COLIN = { sub: '00000000-0000-0000-0000-00000000000c', email: 'colin@example.com' }
const URL = 'https://jyfetargyaaxcqmxdgft.supabase.co/functions/v1/reply-inbound'
const TOKEN = 'test-subaccount-token'
const ROWS = redteam.rows as unknown as RedteamRow[]
const DRY = senderEnv(() => undefined, 'https://x')
const LIVE = senderEnv((n) => ({ TWILIO_LIVE_SENDING: '1', TWILIO_ACCOUNT_SID: 'AC', TWILIO_AUTH_TOKEN: TOKEN,
  CAMPAIGN_MESSAGING_SERVICE_SID: 'MG', CAMPAIGN_FROM_NUMBER: '+12629996513' } as Record<string, string>)[n], 'https://x')

let db: PGlite
const rpc: Rpc = async (fn, args) => {
  const names = Object.keys(args)
  try {
    const r = await db.query<{ r: unknown }>(`select public.${fn}(${names.map((n, i) => `${n} => $${i + 1}`).join(', ')}) as r`,
      names.map((n) => { const v = args[n]; return v !== null && typeof v === 'object' ? JSON.stringify(v) : v }))
    const rows = r.rows.map((x) => x.r)
    return { data: fn === 'reply_due' ? rows : rows[0], error: null }
  } catch (e) {
    return { data: null, error: { message: String(e) } }
  }
}

class FakeTwilio implements TwilioPort {
  sends: { to: string; body: string; from?: string | null }[] = []
  async send(to: string, body: string, from?: string | null): Promise<SendResult | SendFailure> {
    this.sends.push({ to, body, from })
    return { ok: true, sid: `SMout${this.sends.length}`, status: 'accepted' }
  }
  async inboundSince() { return [] }
}
const drafter: Drafter = async () => 'Thanks for writing back. Is the place on Burleigh still yours?'

/** A clock the fake sleep moves forward. */
function clock(start: string) {
  let t = new Date(start).getTime()
  return { now: () => new Date(t), sleep: async (ms: number) => { t += ms }, at: () => t }
}

async function webhook(params: Record<string, string>, sign = true, now?: () => Date) {
  const sig = await twilioSignature(TOKEN, URL, params)
  const ok = await validTwilioSignature(TOKEN, URL, params, sign ? sig : 'forged')
  return recordWebhook({ rpc, params, signatureOk: ok, now })
}
const msg = (sid: string, body: string, from = '+14145550177') =>
  ({ MessageSid: sid, SmsSid: sid, From: from, To: '+12629996513', Body: body, AccountSid: 'AC', MessagingServiceSid: 'MG' })
async function control() {
  return (await db.query<{ reply_numbers: string[]; redteam_version: string | null; agent_last_run_at: string | null }>(
    `select reply_numbers, redteam_version, agent_last_run_at from public.campaign_control`)).rows[0]
}
async function drafts() {
  return (await db.query<{ kind: string; status: string; body: string | null; send_after: string | null }>(
    `select kind, status, body, send_after from public.reply_drafts order by inbound_at`)).rows
}
async function routineOn() {
  await runReplyAgent({ rpc, env: DRY, twilio: null, drafter, control: await control(), redteamRows: ROWS })   // scores the red team
  await db.query(`select set_config('request.jwt.claims', $1, false)`, [JSON.stringify(COLIN)])
  await db.exec('set role authenticated')
  try { await db.query('select public.set_routine_replies(true)') } finally { await db.exec('reset role') }
}

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
  await db.exec(`insert into public.team_members (email, role, person, display_name) values ('colin@example.com', 'owner', 'colin', 'Colin')`)
})

beforeEach(async () => {
  await db.exec(`
    truncate public.reply_drafts, public.opener_send_events, public.twilio_inbound, public.suppressed_phones,
             public.messages, public.contacts, public.leads cascade;
    update public.campaign_control set routine_enabled = false, redteam_version = null, redteam_ok = false;
    insert into public.leads (id, wpie_owner_id, owner_name, property_address, stage) values
      ('00000000-0000-0000-0000-0000000000b1', 88, 'TEST OWNER', '2847 N Burleigh St', 'opener_sent');
    insert into public.contacts (lead_id, kind, value, value_normalized) values ('00000000-0000-0000-0000-0000000000b1', 'phone', '4145550177', '4145550177');
  `)
})

describe('reply-inbound webhook', () => {
  it('refuses an unsigned or forged request and records nothing', async () => {
    expect(await webhook(msg('SMx', 'STOP'), false)).toMatchObject({ status: 403 })
    expect((await db.query('select * from public.twilio_inbound')).rows).toEqual([])
  })

  it('a STOP is on the never-text list before Twilio even gets its answer', async () => {
    const r = await webhook(msg('SMstop', 'STOP'))
    expect(r).toEqual({ status: 200, body: EMPTY_TWIML, sid: 'SMstop' })
    const s = await db.query(`select phone10 from public.suppressed_phones`)
    expect(s.rows).toEqual([{ phone10: '4145550177' }])
  })

  it('a real reply becomes a draft for Colin right after the answer; a repeated delivery adds nothing', async () => {
    await webhook(msg('SMa', 'Maybe. What would you pay?'))
    await webhook(msg('SMa', 'Maybe. What would you pay?'))           // Twilio retried
    const c = clock('2026-10-22T17:00:00Z')
    await afterWebhook({ rpc, env: DRY, twilio: new FakeTwilio(), drafter, control: await control(), redteamRows: ROWS, ...c })
    expect(await drafts()).toEqual([{ kind: 'candidate', status: 'awaiting_approval', body: expect.stringMatching(/Burleigh/), send_after: null }])
  })

  it('answers a routine text by itself after a natural 45-90 s pause, exactly once', async () => {
    await routineOn()
    const c = clock('2026-10-22T17:00:00Z')
    await webhook(msg('SMw', 'who is this?'), true, c.now)
    const tw = new FakeTwilio()
    const start = c.at()
    const runs = await afterWebhook({ rpc, env: LIVE, twilio: tw, drafter, control: await control(), redteamRows: ROWS, ...c })
    const waited = (c.at() - start) / 1000
    expect(waited).toBeGreaterThanOrEqual(45)
    expect(waited).toBeLessThanOrEqual(91)
    expect(runs.map((r) => r.sent)).toEqual([0, 1])
    expect(tw.sends).toEqual([{ to: '+14145550177', from: '+12629996513', body: expect.stringMatching(/Fair question. I'm Sam/) }])
    // the catch-up timer running at the same moment finds nothing left to send
    await runReplyAgent({ rpc, env: LIVE, twilio: tw, drafter, control: await control(), redteamRows: ROWS, now: c.now })
    expect(tw.sends.length).toBe(1)
  })

  it('never answers by itself in quiet hours: it waits for 8am plus the pause, and the timer sends it', async () => {
    await routineOn()
    const c = clock('2026-10-23T03:30:00Z')                              // 22:30 Central
    await webhook(msg('SMq', 'wrong number'), true, c.now)
    const tw = new FakeTwilio()
    await afterWebhook({ rpc, env: LIVE, twilio: tw, drafter, control: await control(), redteamRows: ROWS, ...c })
    expect(tw.sends).toEqual([])
    const d = (await drafts())[0]
    const after = new Date(d.send_after!).getTime()
    expect(after).toBeGreaterThanOrEqual(new Date('2026-10-23T13:00:45Z').getTime())   // 08:00:45 Central
    await runReplyAgent({ rpc, env: LIVE, twilio: tw, drafter, control: await control(), redteamRows: ROWS, now: () => new Date(after + 1000) })
    expect(tw.sends.length).toBe(1)
  })

  it('with routine replies off, a routine text is only "would send" and nothing goes', async () => {
    const c = clock('2026-10-22T17:00:00Z')
    await webhook(msg('SMb', 'is this a bot?'), true, c.now)
    const tw = new FakeTwilio()
    await afterWebhook({ rpc, env: LIVE, twilio: tw, drafter, control: await control(), redteamRows: ROWS, ...c })
    expect((await drafts())[0]).toMatchObject({ kind: 'routine', status: 'would_send' })
    expect(tw.sends).toEqual([])
  })
})
