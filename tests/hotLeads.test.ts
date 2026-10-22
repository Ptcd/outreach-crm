// Hot-lead alerts on the real migrations (PGlite, as service_role): which replies are hot, the
// text Colin gets, the first alert within the minute, one repeat at 15 minutes unless the lead was
// called (a logged call or "I called them" stops it and records speed to lead), the 7 PM list once
// a day, and nothing in quiet hours.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, beforeEach, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'
import { alertText, digestText, firstNameOf, isHotReply, runHotAlerts, type HotAlert } from '../supabase/functions/_shared/hotLeads'
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
let texts: string[] = []
const send = async (t: string) => { texts.push(t); return { ok: true, sid: `SMa${texts.length}` } }
const run = (at: Date) => runHotAlerts({ rpc, send, appUrl: 'https://deals.example.com', now: () => at })
const record = (sid: string, at: Date, body = 'yes still mine', lead: string | null = LEAD, test = false) =>
  rpc('hot_record', { p_sid: sid, p_lead_id: lead, p_phone10: '4144776435', p_first_name: 'John', p_address: '2825 S LOGAN AV',
    p_body: body, p_is_test: test, p_now: at.toISOString() })

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
  await db.exec(`insert into public.team_members (email, role, person, display_name) values ('colin@example.com', 'owner', 'colin', 'Colin')`)
})
beforeEach(async () => {
  texts = []
  await db.exec(`truncate public.hot_alerts, public.messages, public.leads cascade;
    update public.campaign_control set hot_digest_date = null;
    insert into public.leads (id, wpie_owner_id, owner_name, property_address, stage) values ('${LEAD}', 1, 'JOHN W PANKIEWICZ JR', '2825 S LOGAN AV', 'opener_sent');`)
})

describe('which replies are hot', () => {
  it('interest, questions about selling and price talk are; removals, wrong numbers and "not for sale" are not', () => {
    for (const [intent, text] of [['interested', 'yes'], ['price_first', "what's your offer"], ['who_is_this', 'who is this and why'],
      ['statement', 'maybe, depends on timing'], ['statement', 'still mine'], ['worth', 'what do you think it is worth']]) {
      expect(isHotReply({ intent, text, removal: false })).toBe(true)
    }
    for (const [intent, text, removal] of [['opt_out', 'STOP', true], ['wrong_number', 'wrong number', false],
      ['not_interested', 'not for sale', false], ['sold', 'sold it last year', false], ['statement', 'ok thanks', false]] as const) {
      expect(isHotReply({ intent, text, removal })).toBe(false)
    }
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
    expect(await run(T('15:11'))).toMatchObject({ alerts: 1 })
  })
})
