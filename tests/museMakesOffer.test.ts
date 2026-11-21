// 0245 (Colin 2026-11-16: "Let Muse make offers"): with the switch on, the rule's own figure is OK'd by the server and
// Muse's step is to text it. The door still refuses every other figure; nothing above the most; a card Colin passed on
// or asked about stays his; Colin is told of each figure. With the switch off, 0223 stands. On the real migrations.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'
import { offerPingMessage } from '../supabase/functions/_shared/textOffers'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')
const COLIN = { email: 'colin@example.com', role: 'authenticated' }

let db: PGlite
const rows = async <T>(sql: string, params: unknown[] = []) => (await db.query<T>(sql, params)).rows
const one = async <T>(sql: string, params: unknown[] = []) => (await rows<{ r: T }>(`select ${sql} as r`, params))[0].r
const as = (who: object | null) => db.query(`select set_config('request.jwt.claims', $1, false)`, [who ? JSON.stringify(who) : ''])

type Row = { offer_id: string; next: { step: string; who: string; say: string }; numbers: Record<string, unknown> }
type Res = { ok: boolean; reason?: string; offer?: Row }
const open = (lead: string, words: string) => one<Res>(`public.agent_offer_open($1, 'asked_number', $2, '4145550001', 'Muse')`, [lead, words])
const update = (p: object) => one<Res>(`public.agent_offer_update($1::jsonb, 'Muse')`, [JSON.stringify(p)])
const problem = (lead: string, body: string) => one<string | null>(`public.text_rule_problem($1, $2, 0, now())`, [lead, body])
const decide = (id: string, say: string, n: number | null = null, note: string | null = null) =>
  one<{ ok: boolean; reason?: string }>(`public.text_offer_decide($1, $2, $3, $4)`, [id, say, n, note])
const comps = (n: number) => Array.from({ length: n }, (_, i) => ({ address: `${i + 1} Comp St`, sold_price: 225000 + i * 5000, sold_date: '2026-09-01', sqft: 1250 }))
const said = (lead: string, body: string) => db.query(
  `insert into public.messages (lead_id, direction, channel, body, status, sent_at) values ($1, 'out', 'sms', $2, 'delivered', now())`, [lead, body])
const auto = (on: boolean) => one<{ ok: boolean; okd_now?: number; reason?: string }>(`public.text_offer_auto_set($1, 'desk', 'Colin 2026-11-16: let Muse make offers')`, [on])
const offer = async (lead: string) => (await rows<{ id: string; ok_by: string | null; ok_number: string | null; ok_numbers: string[]; auto_told_at: string | null }>(
  `select id, ok_by, ok_number, ok_numbers, auto_told_at from public.text_offers where lead_id = $1 and status = 'open'`, [lead]))[0]
// everything the rule needs: the condition in their words, three sold comps, the size. 230,000 x 65% - 38,130 = 111,400; the most 122,900
const FULL = { condition_words: 'needs a lot, kitchen is original', repair_level: 'medium', sqft: 1271, arv: 230000, arv_basis: 'three sold nearby', comps: comps(3) }

const C: Record<string, string> = {}
let n = 700
const card = async (owner: string) => {
  n += 1
  return (await rows<{ id: string }>(
    `insert into public.leads (wpie_owner_id, owner_name, lane, stage, property_address, locked_to, mailing_state)
     values ($1, $2, 'flip', 'ai_qualifying', $3, 'thalia', 'WI') returning id`, [-n, owner, `${n} Rule St`]))[0].id
}

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
  await db.exec(`insert into public.team_members (email, role, person, display_name) values
    ('colin@example.com', 'owner', 'colin', 'Colin'), ('thalia@example.com', 'caller', 'thalia', 'Thalia') on conflict do nothing`)
  await db.exec(`update public.campaign_control set day_rules_on = false where id = 1`)
  for (const k of ['waiting', 'fresh', 'counter', 'asked', 'passed', 'thin', 'retail', 'off', 'colins', 'trailer', 'under']) C[k] = await card(k.toUpperCase() + ' OWNER')
}, 120_000)

describe('the switch is off until someone says who and why', () => {
  it('starts off, and a figure waits for Colin as before', async () => {
    expect(await one<boolean>(`(select auto_ok from public.text_offer_rules where id = 1)`)).toBe(false)
    const o = (await open(C.waiting, 'what would you pay')).offer!
    const r = await update({ offer_id: o.offer_id, ...FULL })
    expect(r.offer!.next).toMatchObject({ step: 'colin', who: 'colin' })
    expect(await problem(C.waiting, 'I can do $111,400')).toContain('Colin has not OK')
  })
  it('refuses to turn on without a name and a reason', async () => {
    expect((await one<{ ok: boolean }>(`public.text_offer_auto_set(true, '', '')`)).ok).toBe(false)
    expect(await one<boolean>(`(select auto_ok from public.text_offer_rules where id = 1)`)).toBe(false)
  })
})

describe('on: the rule answers', () => {
  it('turning it on OKs the figure that was already waiting', async () => {
    const r = await auto(true)
    expect(r).toMatchObject({ ok: true, okd_now: 1 })
    const o = await offer(C.waiting)
    expect(o.ok_by).toBe('rule')
    expect(Number(o.ok_number)).toBe(111400)
    const w = await one<{ yours: Row[]; rule: { figures_without_a_tap: boolean; colin: string } }>(`public.agent_offer_worklist(now())`)
    expect(w.rule.figures_without_a_tap).toBe(true)
    expect(w.rule.colin).toContain('Let Muse make offers')
    expect(w.yours.find((x) => x.offer_id === o.id)!.next).toMatchObject({ step: 'send_number', who: 'muse' })
  })
  it('that figure may be texted, and no other', async () => {
    expect(await problem(C.waiting, 'I can do $111,400 for it')).toBeNull()
    expect(await problem(C.waiting, 'I can do $115,000 for it')).toContain('not a figure Colin OK')
    expect(await problem(C.fresh, 'how about $90,000')).toContain('no open offer')
  })
  it('a new offer goes straight to send_number when everything is in', async () => {
    const o = (await open(C.fresh, 'make me an offer')).offer!
    const r = await update({ offer_id: o.offer_id, ...FULL })
    expect(r.offer!.next).toMatchObject({ step: 'send_number', who: 'muse' })
    expect(r.offer!.next.say).toContain('$111,400')
    expect(r.offer!.numbers.figures_you_may_text).toEqual([111400])
    expect(await one<string>(`(select notes from public.leads where id = $1)`, [C.fresh])).toContain("the rule OK'd $111,400")
  })
  it('the deal sheet outranks the rule: Colin\'s own number, or a property the formula does not fit, waits for his tap (0271)', async () => {
    // Colin put 20,000 to 25,000 on this card himself; the rule's 111,400 is above it
    await db.query(`insert into public.deal_sheets (lead_id, colin_open, colin_top) values ($1, 20000, 25000)`, [C.colins])
    const a = await update({ offer_id: (await open(C.colins, 'what would you pay')).offer!.offer_id, ...FULL })
    expect(a.offer!.next).toMatchObject({ step: 'colin', who: 'colin' })
    expect(a.offer!.numbers.figures_you_may_text).toEqual([])
    expect(await problem(C.colins, 'We could do $111,400.')).toContain('Colin has not OK')
    // a manufactured home: the sheet's gate sends it to Colin, so the rule does not OK it either
    const b = await update({ offer_id: (await open(C.trailer, 'make me an offer')).offer!.offer_id, ...FULL, property_kind: 'manufactured' })
    expect(b.offer!.next).toMatchObject({ step: 'colin', who: 'colin' })
    expect((await offer(C.trailer)).ok_by).toBeNull()
    // his number is at or above the rule's figure: nothing to protect, and the rule goes on as before
    await db.query(`insert into public.deal_sheets (lead_id, colin_open, colin_top) values ($1, 115000, 125000)`, [C.under])
    const c = await update({ offer_id: (await open(C.under, 'what is your number')).offer!.offer_id, ...FULL })
    expect(c.offer!.next).toMatchObject({ step: 'send_number', who: 'muse' })
    await db.query(`delete from public.text_offers where lead_id = $1`, [C.under])   // keeps the later counts of what Colin is told as they were
  })
  it('the seller\'s own number under the rule\'s offer is the figure', async () => {
    const o = (await open(C.off, 'what is your offer')).offer!
    const r = await update({ offer_id: o.offer_id, ...FULL, their_number: 90000, their_words: 'I want 90' })
    expect(r.offer!.numbers.figures_you_may_text).toEqual([90000])
    await one(`public.text_offer_close($1, 'other', 'test tidy', 'desk')`, [o.offer_id])
  })
  it('a counter inside the most is taken; above it the figure is the most, never more', async () => {
    const o = (await open(C.counter, 'what would you give me')).offer!
    await update({ offer_id: o.offer_id, ...FULL })
    await said(C.counter, 'I can do $111,400')
    let r = await update({ offer_id: o.offer_id, response: 'counter', response_words: 'could you do 118', counter_number: 118000 })
    expect(r.offer!.next).toMatchObject({ step: 'send_number', who: 'muse' })
    expect(r.offer!.numbers.ok_number).toBe(118000)
    expect(await problem(C.counter, 'OK, $118,000 works')).toBeNull()
    await said(C.counter, 'OK, $118,000 works')
    r = await update({ offer_id: o.offer_id, response: 'counter', response_words: 'no, 150', counter_number: 150000 })
    expect(r.offer!.numbers.ok_number).toBe(122900)
    expect(await problem(C.counter, 'the most I can do is $122,900')).toBeNull()
    expect(await problem(C.counter, 'fine, $150,000')).toContain('not a figure Colin OK')
    expect((await offer(C.counter)).ok_by).toBe('rule')
  })
  it('a thin comp set, and a retail ask, still get no number', async () => {
    let o = (await open(C.thin, 'what would you pay')).offer!
    let r = await update({ offer_id: o.offer_id, ...FULL, comps: comps(2) })
    expect(r.offer!.next.step).toBe('comp')
    expect((await offer(C.thin)).ok_number).toBeNull()
    o = (await open(C.retail, 'what would you pay')).offer!
    r = await update({ offer_id: o.offer_id, ...FULL, their_number: 300000, their_words: '300 firm', flexible: 'firm' })
    expect(r.offer!.next.step).toBe('retail')
    expect((await offer(C.retail)).ok_number).toBeNull()
  })
})

describe('what stays Colin\'s', () => {
  it('a card he asked a question about comes back to him, answer and all', async () => {
    await auto(false)
    const o = (await open(C.asked, 'what would you pay')).offer!
    await update({ offer_id: o.offer_id, ...FULL })
    await as(COLIN)
    expect((await decide(o.offer_id, 'ask', null, 'is the roof new?')).ok).toBe(true)
    await as(null)
    await auto(true)
    const r = await update({ offer_id: o.offer_id, answer: 'they say 2019' })
    expect(r.offer!.next).toMatchObject({ step: 'colin', who: 'colin' })
    expect((await offer(C.asked)).ok_number).toBeNull()
  })
  it('a card he passed on is not reopened by the rule', async () => {
    await auto(false)
    const o = (await open(C.passed, 'what would you pay')).offer!
    await update({ offer_id: o.offer_id, ...FULL })
    await as(COLIN)
    expect((await decide(o.offer_id, 'pass', null, 'too far out')).ok).toBe(true)
    await as(null)
    expect((await auto(true)).okd_now).toBe(0)
    expect((await offer(C.passed)).ok_number).toBeNull()
  })
  it('his own tap is marked as his, and he gets no notice for it', async () => {
    await as(COLIN)
    expect((await decide((await offer(C.asked)).id, 'ok', 105000)).ok).toBe(true)
    await as(null)
    expect((await offer(C.asked)).ok_by).toBe('colin')
  })
  it('only the service side can flip the switch or OK by the rule', async () => {
    const grants = await rows<{ grantee: string }>(
      `select grantee from information_schema.routine_privileges where routine_schema = 'public' and routine_name in ('text_offer_auto_set', 'text_offer_auto_ok')`)
    expect(grants.some((g) => ['authenticated', 'anon', 'PUBLIC'].includes(g.grantee))).toBe(false)
  })
})

describe('Colin is told', () => {
  it('once for each figure the rule OK\'d, with the card to open', async () => {
    const pings = await one<{ kind: string; number: number; address: string; lead_id: string; offer_id: string; ask_kind: string; arv: number; repairs: number; most: number }[]>(
      `public.text_offer_ping_claim(((now() at time zone 'America/Chicago')::date + time '12:00') at time zone 'America/Chicago')`)
    const autos = pings.filter((p) => p.kind === 'auto')
    expect(autos.map((p) => Number(p.number)).sort()).toEqual([111400, 111400, 122900])
    expect(pings.some((p) => p.kind === 'auto' && p.lead_id === C.asked)).toBe(false)
    const again = await one<{ kind: string }[]>(`public.text_offer_ping_claim(((now() at time zone 'America/Chicago')::date + time '12:00') at time zone 'America/Chicago')`)
    expect(again.filter((p) => p.kind === 'auto')).toHaveLength(0)
    const m = offerPingMessage({ ...autos.find((p) => Number(p.number) === 122900)!, kind: 'auto', owner_name: 'x' }, 'https://app.example')
    expect(m.title).toContain('Muse is texting $122,900')
    expect(m.body).toContain('their counter')
    expect(m.url).toContain('/lead/')
  })
})
