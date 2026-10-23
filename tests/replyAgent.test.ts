// The reply agent end to end on the real migrations (PGlite), with a fake Twilio and a fake drafter:
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
  return (await db.query<{ reply_numbers: string[]; redteam_version: string | null; agent_last_run_at: string | null; test_opener: string | null }>(
    `select reply_numbers, redteam_version, agent_last_run_at, test_opener from public.campaign_control`)).rows[0]
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
    truncate public.hot_alerts, public.tasks, public.reply_drafts, public.reply_threads, public.opener_send_events, public.twilio_inbound, public.suppressed_phones,
             public.planned_openers, public.messages, public.contacts, public.leads cascade;
    update public.campaign_control set routine_enabled = false, redteam_version = null, redteam_ok = false, agent_rules_version = null,
      agent_last_run_at = null;
    insert into public.leads (id, wpie_owner_id, owner_name, property_address, stage) values
      ('00000000-0000-0000-0000-0000000000a1', 77, 'TEST OWNER', '2847 N Burleigh St', 'opener_sent');
    insert into public.contacts (lead_id, kind, value, value_normalized) values
      ('00000000-0000-0000-0000-0000000000a1', 'phone', '4145550177', '4145550177'),
      ('00000000-0000-0000-0000-0000000000a1', 'phone', '4145550178', '4145550178');
    insert into public.messages (lead_id, direction, channel, body, provider_sid, is_opener, sent_at, source_key) values
      ('00000000-0000-0000-0000-0000000000a1', 'out', 'sms', 'Hi, Colin Merrill here from Mequon. Is the place on N Burleigh St still yours? No worries if not, just reply STOP.',
       'SMopener', true, '2026-10-22T15:00:00Z', 'ledger:77:1:opener');
  `)
})

describe('the reply agent, end to end with no real text', () => {

  it("Colin's test phone plays a real planned owner: the draft knows the owner, the property and the opening text", async () => {
    const seen: Parameters<Drafter>[0][] = []
    const capture: Drafter = async (x) => { seen.push(x); return 'Thanks for getting back to me, John. Is the place on Logan still yours?' }
    const tw = new FakeTwilio()
    tw.inbound = [text('SMt', '+12627770909', 'Test - what is this about?')]
    await runReplyAgent({ rpc, env: DRY, twilio: tw, drafter: capture, control: await control(), redteamRows: ROWS, now: () => NOON })
    expect(seen).toHaveLength(1)
    expect(seen[0]).toMatchObject({ ownerName: 'JOHN W PANKIEWICZ JR', propertyAddress: '2825 S LOGAN AV, Milwaukee' })
    expect(seen[0].history[0]).toEqual({ who: 'us', body: expect.stringMatching(/^Hi John, Colin Merrill here\..*2825 S Logan Ave/) })
    const d = (await db.query<{ is_test: boolean; status: string; body: string }>(`select is_test, status, body from public.reply_drafts`)).rows
    expect(d).toEqual([{ is_test: true, status: 'awaiting_approval', body: 'Thanks for getting back to me, John. Is the place on Logan still yours?' }])
    expect(tw.sends).toHaveLength(0)
  })

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
    const m = await db.query(`select source_key, provider_sid from public.messages where source_key like 'reply:%'`)
    expect(m.rows).toEqual([{ source_key: `reply:${cand.id}`, provider_sid: 'SMr1' }])
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

describe('work no text can do', () => {
  it('opens a task for Adil with their exact words and the address they gave, counted in the badge, pushed once', async () => {
    const tw = new FakeTwilio()
    tw.inbound = [text('SMe', '+14145550177', 'Maybe. Can you email me the details? dale@example.com')]
    const s = await run(tw)
    expect(s.tasks).toBe(1)
    const t = await db.query<{ owner: string; kind: string; quote: string; email_to: string; source: string; title: string }>(
      `select owner::text, kind, quote, email_to, source, title from public.tasks where source = 'reply'`)   // the belt opens its own call stop (0031)
    expect(t.rows).toEqual([{ owner: 'adil', kind: 'email', quote: 'Maybe. Can you email me the details? dale@example.com',
      email_to: 'dale@example.com', source: 'reply', title: 'Email them at dale@example.com' }])
    expect((await db.query(`select tasks_open from public.reply_waiting`)).rows).toEqual([{ tasks_open: 1 }])
    expect((await drafts())[0]).toMatchObject({ kind: 'candidate', status: 'awaiting_approval' })   // the text reply still waits for Colin
    await run(tw)                                                                                    // the same text again: no second task
    expect((await db.query(`select count(*)::int as n from public.tasks where source = 'reply'`)).rows).toEqual([{ n: 1 }])   // the belt's own stop aside (0031)
    // Keep this deterministic: whether the developer runs the suite during Central quiet hours is irrelevant.
    const first = await db.query<{ r: unknown[] }>(`select public.notify_claim_tasks('2026-10-22T17:00:00Z') as r`)
    const second = await db.query<{ r: unknown[] }>(`select public.notify_claim_tasks('2026-10-22T17:00:00Z') as r`)
    expect([first.rows[0].r.length, second.rows[0].r.length]).toEqual([1, 0])
  })

  it('a removal never opens a task', async () => {
    const tw = new FakeTwilio()
    tw.inbound = [text('SMr', '+14145550177', 'Stop texting me, talk to my attorney')]
    await run(tw)
    expect((await db.query(`select count(*)::int as n from public.tasks`)).rows).toEqual([{ n: 0 }])
  })

  it('keeps the facts the drafting model read', async () => {
    const tw = new FakeTwilio()
    tw.inbound = [text('SMf', '+14145550177', 'Moving to Arizona in March, roof is old, my wife is on the title too')]
    await runReplyAgent({ rpc, env: DRY, twilio: tw, control: await control(), redteamRows: ROWS, now: () => NOON,
      drafter: async () => ({ message: 'Thanks - what were you hoping to get for it?', facts: { motivation: 'moving to Arizona', timeline: 'March', decision_makers: 'wife on title', condition: 'old roof' } }) })
    const f = await db.query<{ facts: Record<string, string> }>(`select facts from public.reply_drafts`)
    expect(f.rows[0].facts).toEqual({ motivation: 'moving to Arizona', timeline: 'March', decision_makers: 'wife on title', condition: 'old roof' })
  })
})

describe('held phones', () => {
  it('get nothing on their own: a would-be routine reply is a draft for Colin with a hot alert; a STOP is still final', async () => {
    await db.exec(`insert into public.reply_holds (phone10, reason) values ('4145550177', 'false opt-out corrected'), ('4145550178', 'test')`)
    const tw = new FakeTwilio()
    tw.inbound = [text('SMk1', '+14145550177', 'Yes'), text('SMk2', '+14145550178', 'STOP')]
    await run(tw)
    const d = (await db.query<{ inbound_sid: string; kind: string; status: string; outcome: string }>(
      `select inbound_sid, kind, status, outcome from public.reply_drafts order by inbound_sid`)).rows
    expect(d.find((x) => x.inbound_sid === 'SMk1')).toMatchObject({ kind: 'candidate', status: 'awaiting_approval' })
    expect(d.find((x) => x.inbound_sid === 'SMk2')).toMatchObject({ kind: 'removal', outcome: 'dnc' })
    expect((await db.query<{ inbound_sid: string }>(`select inbound_sid from public.hot_alerts`)).rows).toEqual([{ inbound_sid: 'SMk1' }])
    expect((await db.query(`select 1 from public.suppressed_phones where phone10 = '4145550178'`)).rows).toHaveLength(1)
    await db.exec(`truncate public.reply_holds`)
  })
})

describe('hot replies', () => {
  it('a thumbs-up reaction (quoting our STOP line) is a yes: no suppression, no DNC, the pitch (not hot yet: it only confirms the place is theirs)', async () => {
    const tw = new FakeTwilio()
    const quote = 'Hi, Colin Merrill here. Any interest in selling? No worries if not, just reply STOP.'
    tw.inbound = [text('SMr1', '+14145550177', '\u{1F44D}​ to “​' + quote + '​”')]
    await run(tw)
    expect((await db.query(`select * from public.suppressed_phones`)).rows).toEqual([])
    expect((await db.query<{ is_opt_out: boolean }>(`select is_opt_out from public.twilio_inbound where sid = 'SMr1'`)).rows[0].is_opt_out).toBe(false)
    expect((await db.query<{ stage: string }>(`select stage::text from public.leads where wpie_owner_id = 77`)).rows[0].stage).not.toBe('dnc')
    const d = (await db.query<{ kind: string; body: string }>(`select kind, body from public.reply_drafts where inbound_sid = 'SMr1'`)).rows[0]
    expect(d.kind).toBe('routine')
    expect(d.body).toMatch(/Would you ever consider selling that one\?/)
    expect((await db.query(`select 1 from public.hot_alerts where inbound_sid = 'SMr1'`)).rows).toHaveLength(0)
  })

  it('Martin: a bare yes is not hot; a yes to the pitch is; a later no resolves the open alert', async () => {
    const tw = new FakeTwilio()
    tw.inbound = [text('SMm1', '+14145550177', 'Yes')]
    await run(tw)
    expect((await db.query(`select 1 from public.hot_alerts`)).rows).toHaveLength(0)
    // pretend the pitch went out (the routine reply), then they say yes to it: hot
    await db.query(`update public.reply_drafts set status = 'sent', sent_body = body, sent_at = $1 where inbound_sid = 'SMm1'`,
      [new Date(NOON.getTime() + 60_000).toISOString()])
    tw.inbound = [...tw.inbound, text('SMm2', '+14145550177', 'Yes I would', new Date(NOON.getTime() + 180_000))]
    await run(tw, DRY, new Date(NOON.getTime() + 180_000))
    expect((await db.query<{ inbound_sid: string }>(`select inbound_sid from public.hot_alerts`)).rows).toEqual([{ inbound_sid: 'SMm2' }])
    // then a no: the open alert is resolved (no repeat, not on the 7 PM list)
    tw.inbound = [...tw.inbound, text('SMm3', '+14145550177', "If you're looking to overpay. Then yes it's for sale but otherwise I'm not looking to sell",
      new Date(NOON.getTime() + 300_000))]
    await run(tw, DRY, new Date(NOON.getTime() + 300_000))
    const h = (await db.query<{ inbound_sid: string; resolved: boolean }>(`select inbound_sid, resolved_at is not null as resolved from public.hot_alerts`)).rows
    expect(h).toEqual([{ inbound_sid: 'SMm2', resolved: true }])
    // "if you're looking to overpay" is a plain no: closed politely, no draft for Colin
    const m3 = (await db.query<{ kind: string; outcome: string; body: string }>(`select kind, outcome, body from public.reply_drafts where inbound_sid = 'SMm3'`)).rows[0]
    expect(m3).toMatchObject({ kind: 'routine', outcome: 'not_interested', body: expect.stringMatching(/^Got it - thanks for your time/) })
  })

  it("a no with a real condition gets one question and a quiet 30-day check-back; a no that names a number stays Colin's", async () => {
    const tw = new FakeTwilio()
    tw.inbound = [text('SMc1', '+14145550177', 'Not interested unless I find a new place first'),
      text('SMc2', '+14145550178', 'Not interested unless you pay 300k')]
    await run(tw)
    const d = (await db.query<{ inbound_sid: string; kind: string; status: string; body: string | null }>(
      `select inbound_sid, kind, status, body from public.reply_drafts order by inbound_sid`)).rows
    expect(d.find((x) => x.inbound_sid === 'SMc1')).toMatchObject({ kind: 'routine', body: expect.stringMatching(/What would need to happen for selling to make sense/) })
    expect(d.find((x) => x.inbound_sid === 'SMc2')).toMatchObject({ kind: 'candidate', status: 'awaiting_approval' })
    const t = (await db.query<{ source: string; owner: string; days: number; notified: boolean }>(
      `select source, owner::text, round(extract(epoch from due_at - $1::timestamptz) / 86400)::int days, notified_at is not null notified from public.tasks where reply_inbound_sid = 'SMc1'`,
      [NOON.toISOString()])).rows
    expect(t).toEqual([{ source: 'nurture', owner: 'colin', days: 30, notified: true }])
    expect((await db.query<{ stage: string }>(`select stage::text from public.leads where wpie_owner_id = 77`)).rows[0].stage).toBe('follow_up')
    expect((await db.query(`select 1 from public.hot_alerts`)).rows).toHaveLength(0)
  })

  it('puts back a text a run claimed but never decided, so it is not lost', async () => {
    const tw = new FakeTwilio()
    tw.inbound = [text('SMl1', '+14145550177', 'Who is this?')]
    await run(tw)
    await db.query(`delete from public.reply_drafts where inbound_sid = 'SMl1'`)       // the run died after claiming it
    await db.query(`update public.twilio_inbound set processed_at = $1 where sid = 'SMl1'`, [new Date(NOON.getTime() - 300_000).toISOString()])
    await run(tw)
    expect((await db.query(`select 1 from public.reply_drafts where inbound_sid = 'SMl1'`)).rows).toHaveLength(1)
  })

  it('queue a text to Colin for interest and price talk, never for STOP or a wrong number', async () => {
    const tw = new FakeTwilio()
    tw.inbound = [text('SMh1', '+14145550177', 'Yes, what would you pay?'), text('SMh2', '+14145550178', 'STOP'),
      text('SMh3', '+14145550199', 'wrong number')]
    const s = await run(tw)
    expect(s.hot).toBe(1)
    const h = (await db.query<{ inbound_sid: string; first_name: string; address: string; body: string }>(
      `select inbound_sid, first_name, address, body from public.hot_alerts`)).rows
    expect(h).toEqual([{ inbound_sid: 'SMh1', first_name: null, address: '2847 N Burleigh St', body: 'Yes, what would you pay?' }])
  })
})

describe('the routine switch', () => {
  it('cannot be turned on until the red team passed for the rules the reply agent runs', async () => {
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
  it('a plain yes to the question-only opener gets the pitch line on its own; their answer to it is a draft for Colin', async () => {
    const seen: string[] = []
    const capture: Drafter = async (x) => { seen.push(x.inbound); return 'Glad to hear it - what has you thinking about it?' }
    const go = (tw: FakeTwilio, env = DRY, at = NOON) =>
      control().then((c) => runReplyAgent({ rpc, env, twilio: tw, drafter: capture, control: c, redteamRows: ROWS, now: () => at }))
    const tw = new FakeTwilio()
    await go(tw)                                              // scores the red team
    await as(() => db.query('select public.set_routine_replies(true)'))
    tw.inbound = [text('SMy', '+14145550177', 'Yes'), text('SMh', '+14145550178', 'Yes, how much?')]
    await go(tw, LIVE)
    const d = (await db.query<{ phone10: string; kind: string; status: string; body: string; draft_source: string; facts: Record<string, unknown> | null }>(
      `select phone10, kind, status, body, draft_source, facts from public.reply_drafts order by inbound_at, phone10`)).rows
    const yes = d.find((x) => x.phone10 === '4145550177')!
    expect(yes).toMatchObject({ kind: 'routine', draft_source: 'fixed_line',
      body: "Thanks for getting back to me. I buy a few houses a year around here myself, as-is and on your timeline. Would you ever consider selling that one? No pressure either way." })
    expect(yes.facts).toMatchObject({ pitched: true, last_asked: 'interest' })
    expect(d.find((x) => x.phone10 === '4145550178')).toMatchObject({ kind: 'candidate', status: 'awaiting_approval' })
    expect(seen).toEqual(['Yes, how much?'])
    expect(tw.sends).toHaveLength(0)                          // the natural 45-90 s pause first
    await go(tw, LIVE, new Date(NOON.getTime() + 91_000))
    expect(tw.sends).toEqual([{ to: '+14145550177', from: CAMPAIGN, body: yes.body }])
    const sent = (await db.query<{ status: string; decided_by: string }>(`select status, decided_by from public.reply_drafts where phone10 = '4145550177'`)).rows[0]
    expect(sent).toEqual({ status: 'sent', decided_by: 'auto-reply' })
    // Their answer to "would you ever consider selling" is Colin's to approve.
    tw.inbound = [...tw.inbound, text('SMy2', '+14145550177', 'Maybe, depends on the price', new Date(NOON.getTime() + 300_000))]
    await go(tw, LIVE, new Date(NOON.getTime() + 300_000))
    const ans = (await db.query<{ kind: string; status: string }>(`select kind, status from public.reply_drafts where inbound_sid = 'SMy2'`)).rows[0]
    expect(ans).toEqual({ kind: 'candidate', status: 'awaiting_approval' })
    expect(tw.sends).toHaveLength(1)
  })
})

// A text after the thread was closed is not a conversation (migration 0026; Colin 2026-10-22, on a
// "Reply needs you" email for "No problem, have a good day" after "Wrong number, STOP": "Why did I get this").
describe('after the thread is closed', () => {
  const count = async (table: string) => (await db.query<{ n: number }>(`select count(*)::int as n from public.${table}`)).rows[0].n

  it('a thanks after a STOP is recorded silently: no draft, no task, no alert, the Inbox copy seen', async () => {
    const tw = new FakeTwilio()
    tw.inbound = [text('SMa', '+14145550177', 'Wrong number, STOP', new Date(NOON.getTime() - 600_000))]
    await run(tw)
    tw.inbound.push(text('SMb', '+14145550177', 'No problem, have a good day 😊', NOON))
    const s = await run(tw)
    expect(s.decided.after_close).toBe(1)
    // The wrong-number STOP got our one goodbye line; the thanks after it gets nothing.
    expect((await drafts()).map((d) => [d.kind, d.status])).toEqual([['removal', 'would_send'], ['after_close', 'no_reply']])
    expect(await count('tasks')).toBe(0)
    expect(await count('hot_alerts')).toBe(0)
    expect(tw.sends).toEqual([])
    // The Inbox copy syncs later from the ledger with no provider sid: it is born seen.
    await db.query(`insert into public.messages (lead_id, direction, channel, body, sent_at) values ('00000000-0000-0000-0000-0000000000a1', 'in', 'sms', $1, $2)`,
      ['No problem, have a good day 😊', new Date(NOON.getTime() - 60_000).toISOString()])
    const seen = (await db.query<{ seen: boolean }>(`select seen_at is not null as seen from public.messages where direction = 'in'`)).rows[0]
    expect(seen.seen).toBe(true)
  })

  it('interest after a STOP is never texted: one quiet call task for Colin, no draft, no alert', async () => {
    const tw = new FakeTwilio()
    tw.inbound = [text('SMa', '+14145550177', 'STOP', new Date(NOON.getTime() - 600_000))]
    await run(tw)
    tw.inbound.push(text('SMb', '+14145550177', 'Actually I would sell it, what would you pay?', NOON))
    const s = await run(tw, LIVE)
    expect(s.decided.after_close).toBe(1)
    expect(s.tasks).toBe(1)
    const task = (await db.query<{ owner: string; kind: string; source: string; title: string; quote: string }>(
      `select owner::text, kind, source, title, quote from public.tasks`)).rows[0]
    expect(task).toMatchObject({ owner: 'colin', kind: 'call', source: 'after_stop', title: 'Wrote back after STOP: call, never text',
      quote: 'Actually I would sell it, what would you pay?' })
    expect((await drafts()).map((d) => d.status)).toEqual(['no_reply', 'no_reply'])
    expect(await count('hot_alerts')).toBe(0)
    expect(tw.sends).toEqual([])
  })

  it('a thread the laptop brain closed before the server agent ran counts as closed (no draft row needed)', async () => {
    await db.query(`insert into public.reply_threads (phone10, lead_id, outcome, agent_stage, last_inbound_at) values
      ('4145550178', '00000000-0000-0000-0000-0000000000a1', 'close_not_interested', 'closed', $1)`, [new Date(NOON.getTime() - 300_000).toISOString()])
    const tw = new FakeTwilio()
    tw.inbound = [text('SMe', '+14145550178', 'Thanks anyway ', NOON)]
    const s = await run(tw)
    expect(s.decided.after_close).toBe(1)
    expect((await drafts()).map((d) => [d.kind, d.status])).toEqual([['after_close', 'no_reply']])
    // the ledger copy may differ by a trailing space: still born seen
    await db.query(`insert into public.messages (lead_id, direction, channel, body, sent_at) values ('00000000-0000-0000-0000-0000000000a1', 'in', 'sms', 'Thanks anyway', $1)`,
      [new Date(NOON.getTime() - 60_000).toISOString()])
    expect((await db.query<{ seen: boolean }>(`select seen_at is not null as seen from public.messages where direction = 'in'`)).rows[0].seen).toBe(true)
  })

  it('a second STOP, or a thanks after a no, gets nothing more', async () => {
    const tw = new FakeTwilio()
    tw.inbound = [text('SMa', '+14145550177', 'STOP', new Date(NOON.getTime() - 600_000))]
    await run(tw)
    tw.inbound.push(text('SMb', '+14145550177', 'STOP', NOON))
    await run(tw)
    expect((await drafts()).map((d) => d.kind)).toEqual(['removal', 'after_close'])
    expect(await count('tasks')).toBe(0)

    // A wrong number (closed with our one line) followed by a pleasantry: the same silence.
    const tw2 = new FakeTwilio()
    tw2.inbound = [text('SMc', '+14145550178', 'Wrong number', new Date(NOON.getTime() - 300_000))]
    await run(tw2)
    tw2.inbound.push(text('SMd', '+14145550178', 'Thanks, you too', NOON))
    await run(tw2)
    const last = (await db.query<{ kind: string; status: string; outcome: string }>(`select kind, status, outcome from public.reply_drafts where inbound_sid = 'SMd'`)).rows[0]
    expect(last).toEqual({ kind: 'after_close', status: 'no_reply', outcome: 'wrong_number' })
    expect((await db.query<{ n: number }>(`select count(*)::int as n from public.reply_drafts where status = 'awaiting_approval'`)).rows[0].n).toBe(0)
  })
})
