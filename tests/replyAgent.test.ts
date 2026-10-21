// Sam end to end on the real migrations (PGlite), with a fake Twilio and a fake drafter:
// inbound -> classified -> removal / routine "would send" / candidate draft -> Colin approves
// -> "would send" recorded. Plus never twice, stale drafts, quiet hours, opted-out phones,
// a price in Colin's edit, the red-team gate on the routine switch, and live routine sends.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, beforeEach, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'
import redteam from '../supabase/functions/_shared/replyRedteam.generated.json'
import { approveReply, runReplyAgent, type Drafter } from '../supabase/functions/_shared/replyAgent'
import { rulesVersion, type RedteamRow } from '../supabase/functions/_shared/replyBrain'
import { senderEnv, type InboundText, type Rpc, type SendFailure, type SendResult, type TwilioPort } from '../supabase/functions/_shared/sending'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')
const COLIN = { sub: '00000000-0000-0000-0000-00000000000c', email: 'colin@example.com' }
const CAMPAIGN = '+12629996513'
const NOON = new Date('2026-10-22T17:00:00Z')            // Thursday 12:00 Central
const ROWS = redteam.rows as unknown as RedteamRow[]

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

const DRY = senderEnv(() => undefined, 'https://x')
const LIVE = senderEnv((n) => ({ TWILIO_LIVE_SENDING: '1', TWILIO_ACCOUNT_SID: 'AC', TWILIO_AUTH_TOKEN: 't',
  CAMPAIGN_MESSAGING_SERVICE_SID: 'MG', CAMPAIGN_FROM_NUMBER: CAMPAIGN } as Record<string, string>)[n], 'https://x')

class FakeTwilio implements TwilioPort {
  inbound: InboundText[] = []
  sends: { to: string; body: string; from?: string | null }[] = []
  async send(to: string, body: string, from?: string | null): Promise<SendResult | SendFailure> {
    this.sends.push({ to, body, from })
    return { ok: true, sid: `SMr${this.sends.length}`, status: 'accepted' }
  }
  async inboundSince(_since: Date, to?: string) {
    return this.inbound.filter((m) => m.to === (to ?? CAMPAIGN))
  }
}

const drafter: Drafter = async (x) => `Thanks for getting back to me about ${x.propertyAddress ?? 'the place'}. Is it still yours?`

async function control() {
  return (await db.query<{ reply_numbers: string[]; redteam_version: string | null; agent_last_run_at: string | null }>(
    `select reply_numbers, redteam_version, agent_last_run_at from public.campaign_control`)).rows[0]
}
async function run(tw: FakeTwilio, env = DRY, at = NOON) {
  return runReplyAgent({ rpc, env, twilio: tw, drafter, control: await control(), redteamRows: ROWS, now: () => at })
}
async function drafts() {
  return (await db.query<{ id: string; phone10: string; kind: string; status: string; body: string | null; intent: string }>(
    `select id, phone10, kind, status, body, intent from public.reply_drafts order by inbound_at`)).rows
}
const text = (sid: string, from: string, body: string, at = NOON, to = CAMPAIGN): InboundText =>
  ({ sid, from, to, body, dateSent: new Date(at.getTime() - 60_000).toISOString() })

async function as<T>(fn: () => Promise<T>): Promise<T> {
  await db.query(`select set_config('request.jwt.claims', $1, false)`, [JSON.stringify(COLIN)])
  await db.exec('set role authenticated')
  try { return await fn() } finally { await db.exec('reset role') }
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
             public.planned_openers, public.messages, public.contacts, public.leads cascade;
    update public.campaign_control set routine_enabled = false, redteam_version = null, redteam_ok = false, agent_rules_version = null,
      agent_last_run_at = null;
    insert into public.leads (id, wpie_owner_id, owner_name, property_address, stage) values
      ('00000000-0000-0000-0000-0000000000a1', 77, 'TEST OWNER', '2847 N Burleigh St', 'opener_sent');
    insert into public.contacts (lead_id, kind, value, value_normalized) values
      ('00000000-0000-0000-0000-0000000000a1', 'phone', '4145550177', '4145550177'),
      ('00000000-0000-0000-0000-0000000000a1', 'phone', '4145550178', '4145550178');
    insert into public.messages (lead_id, direction, channel, body, provider_sid, is_opener, sent_at, source_key) values
      ('00000000-0000-0000-0000-0000000000a1', 'out', 'sms', 'Hi, Colin Merrill here. Any interest in selling? No worries if not, just reply STOP.',
       'SMopener', true, '2026-10-22T15:00:00Z', 'ledger:77:1:opener');
  `)
})

describe('Sam, end to end with no real text', () => {
  it('routine reply would send, a real reply becomes a draft, and Colin approving it records "would send"', async () => {
    const tw = new FakeTwilio()
    tw.inbound = [text('SMa', '+14145550177', 'Maybe. What would you pay?'), text('SMb', '+14145550199', 'who is this?')]
    const s = await run(tw)
    expect(s).toMatchObject({ mode: 'dry', inbound_new: 2, decided: { candidate: 1, routine: 1, removal: 0, drafted: 1 } })
    expect(s.redteam).toMatch(/^440\/440 passed$/)
    const [cand, who] = await drafts()
    expect(cand).toMatchObject({ kind: 'candidate', status: 'awaiting_approval', intent: 'price_first' })
    expect(cand.body).toMatch(/2847 N Burleigh St/)
    expect(who).toMatchObject({ kind: 'routine', status: 'would_send', intent: 'who_is_this' })
    const lead = await db.query<{ stage: string }>(`select stage::text from public.leads where wpie_owner_id = 77`)
    expect(lead.rows[0].stage).toBe('reply_received')

    const a = await approveReply({ rpc, env: DRY, twilio: tw, id: cand.id, text: cand.body!, actor: 'Colin', now: () => NOON })
    expect(a.outcome).toBe('dry_sent')
    expect(tw.sends).toEqual([])
    const again = await approveReply({ rpc, env: LIVE, twilio: tw, id: cand.id, text: cand.body!, actor: 'Colin', now: () => NOON })
    expect(again.outcome).toBe('sent')                         // the same draft once live
    const twice = await approveReply({ rpc, env: LIVE, twilio: tw, id: cand.id, text: cand.body!, actor: 'Colin', now: () => NOON })
    expect(twice).toMatchObject({ outcome: 'refused', reason: 'already sent' })
    expect(tw.sends).toEqual([{ to: '+14145550177', body: cand.body, from: CAMPAIGN }])
    const m = await db.query(`select source_key, provider_sid from public.messages where source_key like 'sam:%'`)
    expect(m.rows).toEqual([{ source_key: `sam:${cand.id}`, provider_sid: 'SMr1' }])
  })

  it('a removal suppresses every phone of the owner at once, whatever the switches say', async () => {
    const tw = new FakeTwilio()
    tw.inbound = [text('SMs', '+14145550177', 'STOP')]
    await run(tw)
    expect((await drafts())[0]).toMatchObject({ kind: 'removal', status: 'no_reply', body: null })
    const sup = await db.query<{ phone10: string }>(`select phone10 from public.suppressed_phones order by 1`)
    expect(sup.rows.map((r) => r.phone10)).toEqual(['4145550177', '4145550178'])
    expect((await db.query<{ stage: string }>(`select stage::text from public.leads`)).rows[0].stage).toBe('dnc')
  })

  it('a newer text makes the older draft stale; an opted-out phone is never sent a draft', async () => {
    const tw = new FakeTwilio()
    tw.inbound = [text('SM1', '+14145550177', 'yes interested', new Date(NOON.getTime() - 120_000))]
    await run(tw)
    const old = (await drafts())[0]
    tw.inbound.push(text('SM2', '+14145550177', 'actually call me tomorrow', NOON))
    await run(tw)
    const r = await approveReply({ rpc, env: LIVE, twilio: tw, id: old.id, text: 'ok', actor: 'Colin', now: () => NOON })
    expect(r).toMatchObject({ outcome: 'refused' })
    expect((await drafts()).map((d) => d.status)).toEqual(['superseded', 'awaiting_approval'])
    const newer = (await drafts())[1]
    await db.query(`insert into public.suppressed_phones (phone10, reason) values ('4145550177', 'stop')`)
    expect(await approveReply({ rpc, env: LIVE, twilio: tw, id: newer.id, text: 'Sure - what time works?', actor: 'Colin', now: () => NOON }))
      .toMatchObject({ outcome: 'refused', reason: 'this phone opted out' })
    expect(tw.sends).toEqual([])
  })

  it("refuses a price or the business name in Colin's edit instead of changing his words", async () => {
    const tw = new FakeTwilio()
    tw.inbound = [text('SMp', '+14145550177', 'interested, make me an offer')]
    await run(tw)
    const d = (await drafts())[0]
    expect(await approveReply({ rpc, env: LIVE, twilio: tw, id: d.id, text: 'We could pay $90,000 cash', actor: 'Colin', now: () => NOON }))
      .toMatchObject({ outcome: 'refused' })
    expect(await approveReply({ rpc, env: LIVE, twilio: tw, id: d.id, text: 'This is Merrill Holdings', actor: 'Colin', now: () => NOON }))
      .toMatchObject({ outcome: 'refused' })
    expect(tw.sends).toEqual([])
  })

  it('holds an approval made in quiet hours until 8am, then sends it', async () => {
    const tw = new FakeTwilio()
    const night = new Date('2026-10-23T03:30:00Z')          // 22:30 Central
    tw.inbound = [text('SMn', '+14145550177', 'yes call me', night)]
    await run(tw, DRY, night)
    const d = (await drafts())[0]
    expect(await approveReply({ rpc, env: LIVE, twilio: tw, id: d.id, text: 'Great - Colin will call you tomorrow.', actor: 'Colin', now: () => night }))
      .toMatchObject({ outcome: 'queued' })
    await run(tw, LIVE, new Date('2026-10-23T12:30:00Z'))   // 07:30 Central: still quiet
    expect(tw.sends).toEqual([])
    const s = await run(tw, LIVE, new Date('2026-10-23T13:01:00Z'))   // 08:01 Central
    expect(s.sent).toBe(1)
    expect(tw.sends[0]).toMatchObject({ to: '+14145550177', body: 'Great - Colin will call you tomorrow.' })
  })
})

describe('the routine switch', () => {
  it('cannot be turned on until the red team passed for the rules Sam runs', async () => {
    await expect(as(() => db.query('select public.set_routine_replies(true)'))).rejects.toThrow(/red-team test has not passed/)
    await run(new FakeTwilio())                               // scores and records the red team
    const c = await db.query<{ redteam_ok: boolean; redteam_version: string }>(`select redteam_ok, redteam_version from public.campaign_control`)
    expect(c.rows[0]).toEqual({ redteam_ok: true, redteam_version: rulesVersion() })
    await as(() => db.query('select public.set_routine_replies(true)'))
    // a different rule set reported by the agent closes the gate again
    await db.query(`select public.record_redteam('other-version', 400, 440, false, '{}')`)
    expect((await db.query<{ routine_enabled: boolean }>(`select routine_enabled from public.campaign_control`)).rows[0].routine_enabled).toBe(false)
    await expect(as(() => db.query('select public.set_routine_replies(true)'))).rejects.toThrow(/red-team/)
  })

  it('when on and live, sends routine replies from the number they texted, once', async () => {
    const tw = new FakeTwilio()
    await run(tw)
    await as(() => db.query('select public.set_routine_replies(true)'))
    tw.inbound = [text('SMw', '+14145550177', 'wrong number', NOON, '+12624180202')]
    const s = await run(tw, LIVE)
    expect(s.sent).toBe(0)                                   // a natural 45-90 s pause first
    const later = await run(tw, LIVE, new Date(NOON.getTime() + 91_000))
    expect(later.sent).toBe(1)
    expect(tw.sends).toEqual([{ to: '+14145550177', from: '+12624180202', body: expect.stringMatching(/wrong number/) }])
    await run(tw, LIVE, new Date(NOON.getTime() + 200_000))
    expect(tw.sends.length).toBe(1)
    const ct = await db.query<{ status: string }>(`select status::text from public.contacts where value_normalized = '4145550177'`)
    expect(ct.rows[0].status).toBe('bad')
  })
})
