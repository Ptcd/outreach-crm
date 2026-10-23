// Hot-lead alerts on the real migrations (PGlite, as service_role): which replies are hot, the
// text Colin gets, the first alert within the minute, one repeat at 15 minutes unless the lead was
// called (a logged call or "I called them" stops it and records speed to lead), the 7 PM list once
// a day, and nothing in quiet hours. Since 0022 each alert also texts every team member with a
// phone on file and pushes every registered phone, at the same moments.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, beforeEach, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'
import { alertPush, alertText, digestPush, digestText, firstNameOf, isHotReply, runHotAlerts, type HotAlert, type HotPush } from '../supabase/functions/_shared/hotLeads'
import type { Rpc } from '../supabase/functions/_shared/sending'

const MIGRATION = readdirSync(path.resolve(__dirname, '../supabase/migrations')).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.resolve(__dirname, '../supabase/migrations', f), 'utf8')).join('\n')
const LEAD = '00000000-0000-0000-0000-0000000000a1'
const T = (hhmm: string) => new Date(`2026-10-22T${hhmm}:00Z`)       // UTC; 15:00Z = 10:00 Central

let db: PGlite
const rpc: Rpc = async (fn, args) => {
  const names = Object.keys(args)
  try {
    await db.exec('set role service_role')
    const r = await db.query<{ r: unknown }>(`select public.${fn}(${names.map((n, i) => `${n} => $${i + 1}`).join(', ')}) as r`,
      names.map((n) => args[n]))
    return { data: r.rows[0]?.r ?? null, error: null }
  } catch (e) {
    return { data: null, error: { message: String(e) } }
  } finally { await db.exec('reset role') }
}
let texts: string[] = []                                           // to Colin (no `to`)
let memberTexts: { to: string; text: string }[] = []
let pushes: { endpoint: string; title: string; url: string; tag: string }[] = []
let pushStatus = 201
const send = async (t: string, to?: string) => {
  if (to) { memberTexts.push({ to, text: t }); return { ok: true, sid: `SMm${memberTexts.length}` } }
  texts.push(t)
  return { ok: true, sid: `SMa${texts.length}` }
}
const SUB = { endpoint: 'https://fcm.googleapis.com/fcm/send/thalia', p256dh: 'k', auth: 'a' }
const push: HotPush = {
  subscriptions: async () => (await db.query<{ endpoint: string; p256dh: string; auth: string }>('select endpoint, p256dh, auth from public.push_subscriptions')).rows,
  push: async (sub, m) => {
    const x = m as { title: string; url: string; tag: string }
    pushes.push({ endpoint: sub.endpoint, title: x.title, url: x.url, tag: x.tag })
    return { ok: pushStatus < 300, gone: pushStatus === 410, status: pushStatus }
  },
}
const run = (at: Date, o: { send?: typeof send | null; push?: HotPush | null } = {}) =>
  runHotAlerts({ rpc, send: o.send === undefined ? send : o.send, push: o.push === undefined ? push : o.push,
    appUrl: 'https://deals.example.com', now: () => at })
const record = (sid: string, at: Date, body = 'yes still mine', lead: string | null = LEAD, test = false) =>
  rpc('hot_record', { p_sid: sid, p_lead_id: lead, p_phone10: '4144776435', p_first_name: 'John', p_address: '2825 S LOGAN AV',
    p_body: body, p_is_test: test, p_now: at.toISOString() })

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
  await db.exec(`insert into public.team_members (email, role, person, display_name, alert_phone) values
    ('colin@example.com', 'owner', 'colin', 'Colin', '(262) 555-0100'),
    ('thalia@example.com', 'caller', 'thalia', 'Thalia', '414-555-0123')`)
})
beforeEach(async () => {
  texts = []
  memberTexts = []
  pushes = []
  pushStatus = 201
  await db.exec(`truncate public.hot_alerts, public.messages, public.leads, public.push_subscriptions cascade;
    insert into public.push_subscriptions (endpoint, p256dh, auth) values ('${SUB.endpoint}', 'k', 'a');
    update public.campaign_control set hot_digest_date = null;
    insert into public.leads (id, wpie_owner_id, owner_name, property_address, stage) values ('${LEAD}', 1, 'JOHN W PANKIEWICZ JR', '2825 S LOGAN AV', 'opener_sent');`)
})

describe('which replies are hot', () => {
  it('selling talk, price asks and a yes to the pitch are hot; a bare yes to the question-only opener is not', () => {
    for (const [intent, text, afterPitch] of [['price_first', "what's your offer", false], ['statement', 'maybe, depends on timing', false],
      ['worth', 'what do you think it is worth', false], ['statement', "I'd sell if the timing works", false],
      ['interested', 'yes', true], ['statement', 'sure', true]] as const) {
      expect(isHotReply({ intent, text, removal: false, afterPitch }), text).toBe(true)
    }
    for (const [intent, text, removal, afterPitch] of [['interested', 'Yes', false, false], ['statement', 'still mine', false, false],
      ['who_is_this', 'who is this and why', false, false], ['opt_out', 'STOP', true, true], ['wrong_number', 'wrong number', false, false],
      ['not_interested', 'not for sale', false, true], ['sold', 'sold it last year', false, false], ['statement', 'ok thanks', false, false],
      ['statement', "If you're looking to overpay then yes it's for sale but otherwise I'm not looking to sell", false, true]] as const) {
      expect(isHotReply({ intent, text, removal, afterPitch }), text).toBe(false)
    }
  })

  it("a yes then a soft later is not hot, and Claude's later or no outranks a one-line yes (3325 Linden, 2026-10-23)", () => {
    const linden = "Yes, the house is still mine and at this point, I'm not ready to think about selling, but I'll keep you in mind. Have a great day."
    expect(isHotReply({ intent: 'interested', text: linden, removal: false, afterPitch: true })).toBe(false)
    expect(isHotReply({ intent: 'interested', text: 'yes', removal: false, afterPitch: true, aiInterest: 'later' })).toBe(false)
    expect(isHotReply({ intent: 'statement', text: "I'd sell if the timing works", removal: false, aiInterest: 'no' })).toBe(false)
    expect(isHotReply({ intent: 'interested', text: 'yes', removal: false, afterPitch: true, aiInterest: 'yes' })).toBe(true)
    expect(isHotReply({ intent: 'price_first', text: 'not for a year, but what would you pay?', removal: false, aiInterest: 'later' })).toBe(true)
  })

  it('writes the alert for Colin: who, what they said, the number, the lead link', () => {
    const a: HotAlert = { id: 'x', n: 1, lead_id: LEAD, phone10: '4144776435', first_name: 'John', address: '2825 S LOGAN AV, Milwaukee',
      body: 'Yes still mine', is_test: false }
    expect(alertText(a, 'https://deals.example.com')).toBe(
      `HOT: John, 2825 S Logan Av said: "Yes still mine". Call: (414) 477-6435 https://deals.example.com/lead/${LEAD}?call=1&phone=4144776435`)
    expect(alertText({ ...a, n: 2, is_test: true }, 'https://deals.example.com')).toMatch(/^TEST STILL NOT CALLED \(15 min\) - HOT: John/)
    expect(digestText([{ first_name: 'John', address: '2825 S LOGAN AV', phone10: '4144776435' }]))
      .toBe('7 PM: 1 hot lead not called yet: John (2825 S Logan Av) (414) 477-6435')
    expect(firstNameOf('ACME HOLDINGS LLC')).toBeNull()
    expect(firstNameOf('JOHN W PANKIEWICZ JR')).toBe('John')
  })

  it('writes the phone notification: "Hot lead: John, 2825 S Logan Av", tap opens the lead card with the number', () => {
    const a: HotAlert = { id: 'x', n: 1, lead_id: LEAD, phone10: '4144776435', first_name: 'John', address: '2825 S LOGAN AV, Milwaukee',
      body: 'Yes still mine', is_test: false }
    expect(alertPush(a, 'https://deals.example.com/')).toEqual({
      title: 'Hot lead: John, 2825 S Logan Av', body: '"Yes still mine" Call (414) 477-6435',
      url: `https://deals.example.com/lead/${LEAD}?call=1&phone=4144776435`, tag: 'hot-x' })
    expect(alertPush({ ...a, n: 2, is_test: true }, 'x').title).toBe('TEST Still not called (15 min): John, 2825 S Logan Av')
    expect(alertPush({ ...a, lead_id: null, first_name: null, address: null }, 'https://deals.example.com'))
      .toMatchObject({ title: 'Hot lead: Seller', url: 'https://deals.example.com/inbox' })
    expect(digestPush([{ first_name: 'John', address: null, phone10: '4144776435' }], 'https://deals.example.com'))
      .toEqual({ title: '7 PM: 1 hot lead not called', body: 'John. Open the Inbox.', url: 'https://deals.example.com/inbox', tag: 'hot-digest' })
  })
})

describe('the team gets it too', () => {
  it('texts every member with a phone on file (never Colin twice) and pushes every registered phone, at the same moments', async () => {
    await record('SM10', T('15:10'))
    expect(await run(T('15:10'))).toMatchObject({ alerts: 1, member_texts: 1, pushes_ok: 1, pushes_failed: 0, errors: [] })
    expect(texts).toHaveLength(1)
    expect(memberTexts).toEqual([{ to: '+14145550123', text: texts[0] }])          // Thalia's, normalized; Colin's row is skipped
    expect(pushes).toEqual([{ endpoint: SUB.endpoint, title: 'Hot lead: John, 2825 S Logan Av',
      url: `https://deals.example.com/lead/${LEAD}?call=1&phone=4144776435`, tag: expect.stringMatching(/^hot-/) }])
    expect(await run(T('15:26'))).toMatchObject({ second_alerts: 1, member_texts: 1, pushes_ok: 1 })
    expect(memberTexts[1].text).toMatch(/^STILL NOT CALLED/)
    expect(pushes[1].title).toBe('Still not called (15 min): John, 2825 S Logan Av')
    const s = await run(new Date('2026-10-23T00:05:00Z'))                          // 7:05 PM Central
    expect(s).toMatchObject({ digest: 1, member_texts: 1, pushes_ok: 1 })
    expect(memberTexts[2].text).toMatch(/^7 PM: 1 hot lead not called yet/)
    expect(pushes[2]).toMatchObject({ title: '7 PM: 1 hot lead not called', url: 'https://deals.example.com/inbox', tag: 'hot-digest' })
    expect((await db.query<{ ok: string }>('select last_ok_at::text as ok from public.push_subscriptions')).rows[0].ok).toBeTruthy()
  })

  it('a member text that fails is an error on the run, never a reason to skip Colin or the push', async () => {
    await record('SM11', T('15:10'))
    const flaky = async (t: string, to?: string) => (to ? { ok: false, error: 'pm-phone 403: to is not an alert number' } : send(t))
    expect(await run(T('15:10'), { send: flaky })).toMatchObject({ alerts: 1, member_texts: 0, pushes_ok: 1,
      errors: ['thalia: pm-phone 403: to is not an alert number'] })
    expect(texts).toHaveLength(1)
  })

  it('with push set up but no pm-phone secret, the push still goes out and the alert is claimed', async () => {
    await record('SM12', T('15:10'))
    expect(await run(T('15:10'), { send: null })).toMatchObject({ alerts: 1, member_texts: 0, pushes_ok: 1 })
    expect(texts).toHaveLength(0)
    expect(await run(T('15:11'))).toMatchObject({ alerts: 0 })                       // not texted later: it was claimed
    expect((await db.query<{ e: string }>('select last_error as e from public.hot_alerts')).rows[0].e).toBe('push only (no ALERT_SECRET)')
  })

  it('a phone whose push service says gone is forgotten', async () => {
    await record('SM13', T('15:10'))
    pushStatus = 410
    expect(await run(T('15:10'))).toMatchObject({ alerts: 1, pushes_ok: 0, pushes_failed: 1 })
    expect((await db.query('select 1 from public.push_subscriptions')).rows).toHaveLength(0)
  })
})

describe('alert timing', () => {
  it('texts once right away, once more at 15 minutes if not called, never a third time', async () => {
    await record('SM1', T('15:10'))
    await record('SM1', T('15:10'))                                  // the same inbound twice: one alert
    expect(await run(T('15:10'))).toMatchObject({ alerts: 1, second_alerts: 0 })
    expect(texts[0]).toMatch(/^HOT: John, 2825 S Logan Av said: "yes still mine"/)
    expect(await run(T('15:20'))).toMatchObject({ alerts: 0, second_alerts: 0 })
    expect(await run(T('15:26'))).toMatchObject({ second_alerts: 1 })
    expect(texts[1]).toMatch(/^STILL NOT CALLED/)
    await run(T('16:30'))
    expect(texts).toHaveLength(2)
    expect((await db.query<{ hot_at: string }>(`select hot_at::text from public.leads`)).rows[0].hot_at).toBeTruthy()
  })

  it('a logged call stops the repeat and records speed to lead', async () => {
    await record('SM2', T('15:10'))
    await run(T('15:10'))
    await db.query(`insert into public.messages (lead_id, direction, channel, body, sent_at) values ($1, 'in', 'call', 'Call: Interested', $2)`,
      [LEAD, T('15:16').toISOString()])
    expect(await run(T('15:30'))).toMatchObject({ second_alerts: 0 })
    const h = (await db.query<{ mins: number }>(`select extract(epoch from called_at - created_at)::int / 60 as mins from public.hot_alerts`)).rows[0]
    expect(h.mins).toBe(6)
    expect(texts).toHaveLength(1)
  })

  it('"I called them" counts as a call', async () => {
    await record('SM3', T('15:10'))
    await run(T('15:10'))
    await db.query(`select set_config('request.jwt.claims', $1, false)`, [JSON.stringify({ sub: '00000000-0000-0000-0000-00000000000c', email: 'colin@example.com' })])
    await db.exec('set role authenticated')
    try { await db.query(`select public.mark_called($1, $2)`, [LEAD, T('15:20').toISOString()]) } finally { await db.exec('reset role') }
    expect(await run(T('15:40'))).toMatchObject({ second_alerts: 0 })
  })

  it('holds alerts in quiet hours, then sends at 8 AM', async () => {
    await record('SM4', T('02:00'))                                  // 9 PM Central the night before
    expect(await run(T('02:01'))).toMatchObject({ alerts: 0 })
    expect(await run(T('13:01'))).toMatchObject({ alerts: 1 })       // 8:01 AM Central
  })

  it('at 7 PM lists today\'s hot leads not called, once, leaving out tests and called ones', async () => {
    await record('SM5', T('16:00'))
    await record('SM6', T('17:00'), 'how much', null, true)          // a TEST: not listed
    await run(T('17:00'))
    expect(await run(T('23:30'))).toMatchObject({ digest: 0 })       // 6:30 PM Central: not yet
    const s = await run(new Date('2026-10-23T00:05:00Z'))          // 7:05 PM Central
    expect(s.digest).toBe(1)
    expect(texts[texts.length - 1]).toBe('7 PM: 1 hot lead not called yet: John (2825 S Logan Av) (414) 477-6435')
    expect((await run(new Date('2026-10-23T00:35:00Z'))).digest).toBe(0)
  })

  it('without the pm-phone secret nothing is sent and nothing is claimed', async () => {
    await record('SM7', T('15:10'))
    expect(await runHotAlerts({ rpc, send: null, appUrl: 'x', now: () => T('15:10') })).toMatchObject({ off: 'ALERT_SECRET not set' })
    await db.exec('truncate public.push_subscriptions')
    expect(await run(T('15:10'), { send: null })).toMatchObject({ off: 'ALERT_SECRET not set and no phone registered' })
    expect(await run(T('15:11'))).toMatchObject({ alerts: 1 })
  })
})
