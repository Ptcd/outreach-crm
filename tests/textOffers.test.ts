// The offer by text (0223): Muse's rule (65% of the value minus repairs, the most at 70%), one next step per card,
// Colin's OK before any figure is texted, and the door refusing every other dollar figure. On the real migrations.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')
const COLIN = { email: 'colin@example.com', role: 'authenticated' }
const MUSE_LOGIN = { email: 'muse@example.com', role: 'authenticated' }

let db: PGlite
const rows = async <T>(sql: string, params: unknown[] = []) => (await db.query<T>(sql, params)).rows
const one = async <T>(sql: string, params: unknown[] = []) => (await rows<{ r: T }>(`select ${sql} as r`, params))[0].r
const as = (who: object | null) => db.query(`select set_config('request.jwt.claims', $1, false)`, [who ? JSON.stringify(who) : ''])

type Row = { offer_id: string; next: { step: string; who: string; late: boolean; say: string; gate: string | null }; numbers: Record<string, unknown>; seller: Record<string, unknown> }
type Res = { ok: boolean; reason?: string; offer?: Row; already?: boolean }
const open = (lead: string, words: string) => one<Res>(`public.agent_offer_open($1, 'asked_number', $2, '4145550001', 'Muse')`, [lead, words])
const update = (p: object) => one<Res>(`public.agent_offer_update($1::jsonb, 'Muse')`, [JSON.stringify(p)])
const problem = (lead: string, body: string) => one<string | null>(`public.text_rule_problem($1, $2, 0, now())`, [lead, body])
const decide = (id: string, say: string, n: number | null = null, note: string | null = null) =>
  one<{ ok: boolean; reason?: string }>(`public.text_offer_decide($1, $2, $3, $4)`, [id, say, n, note])
const comps = (n: number) => Array.from({ length: n }, (_, i) => ({ address: `${i + 1} Comp St`, sold_price: 225000 + i * 5000, sold_date: '2026-09-01', sqft: 1250 }))
const said = (lead: string, body: string) => db.query(
  `insert into public.messages (lead_id, direction, channel, body, status, sent_at) values ($1, 'out', 'sms', $2, 'delivered', now())`, [lead, body])
const heard = (lead: string, body: string, sid: string) => db.query(
  `insert into public.twilio_inbound (sid, from10, body, lead_id, received_at) values ($1, '4145550001', $2, $3, now() + interval '1 second')`, [sid, body, lead])

const C: Record<string, string> = {}
let n = 500
const card = async (owner: string) => {
  n += 1
  return (await rows<{ id: string }>(
    `insert into public.leads (wpie_owner_id, owner_name, lane, stage, property_address, locked_to, mailing_state)
     values ($1, $2, 'flip', 'ai_qualifying', $3, 'thalia', 'WI') returning id`, [-n, owner, `${n} Offer St`]))[0].id
}

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
  await db.exec(`insert into public.team_members (email, role, person, display_name) values
    ('colin@example.com', 'owner', 'colin', 'Colin'), ('muse@example.com', 'owner', 'muse', 'Muse'), ('thalia@example.com', 'caller', 'thalia', 'Thalia')
    on conflict do nothing`)
  await db.exec(`update public.campaign_control set day_rules_on = false where id = 1`)
  C.kuster = await card('KUSTER, PAT')
  C.retail = await card('RITA RETAIL')
  C.items = await card('IVAN ITEMS')
  C.asker = await card('ANNA ASKER')
  C.cheap = await card('CHAD CHEAP')
}, 120_000)

describe('the rule', () => {
  it('65% of the value minus repairs by the square foot, to the nearest $100; the most at 70%', async () => {
    const x = await one<{ ok: boolean; lao: number; mao: number; repairs: number; wholesale: number }>(`public.text_offer_numbers(230000, 1271, '{}', 'medium')`)
    expect(x).toMatchObject({ ok: true, repairs: 38130, lao: 111400, mao: 122900 })
    expect(x.wholesale).toBe(98300)
  })
  it('repairs are the items the seller named when they named any', async () => {
    const x = await one<{ ok: boolean; lao: number; repairs: number; repairs_basis: string }>(`public.text_offer_numbers(150000, null, '{roof,furnace}', null)`)
    expect(x).toMatchObject({ ok: true, repairs: 19500, lao: 78000 })
    expect(x.repairs_basis).toContain('roof $10,000')
  })
  it('no figure without a repair basis, and none when the rule leaves nothing', async () => {
    expect((await one<{ ok: boolean }>(`public.text_offer_numbers(150000, 1200, '{}', null)`)).ok).toBe(false)
    expect((await one<{ ok: boolean; reason: string }>(`public.text_offer_numbers(40000, 1200, '{}', 'heavy')`)).reason).toContain('nothing to offer')
  })
  it('reads dollar figures however they are written, and leaves addresses and sizes alone', async () => {
    const amts = async (b: string) => (await one<(number | string)[]>(`public.text_amounts($1)`, [b])).map(Number).sort((x, y) => x - y)
    expect(await amts('I could do $85,000 for it')).toEqual([85000])
    expect(await amts('around 85k, maybe $90.5k')).toEqual([85000, 90500])
    expect(await amts('how about 111,400')).toEqual([111400])
    expect(await amts('Still the owner of 2500 Iris Ct? It is 1,271 sq ft, zip 53212, call 414-233-0336')).toEqual([])
  })
})

describe('the path, one next step at a time', () => {
  let id: string
  it('a text that asks for a number opens the offer by itself', async () => {
    await heard(C.asker, 'Well what would you pay for it?', 'SM-ask-1')
    const w = await rows<{ opened_by: string; trigger_text: string }>(`select opened_by, trigger_text from public.text_offers where lead_id = $1`, [C.asker])
    expect(w).toEqual([{ opened_by: 'system', trigger_text: 'Well what would you pay for it?' }])
    await heard(C.items, 'Yes', 'SM-yes-1')            // a bare yes opens nothing
    expect(await rows(`select 1 from public.text_offers where lead_id = $1`, [C.items])).toEqual([])
  })
  it('opens, and the first step is the one condition question', async () => {
    const r = await open(C.kuster, 'Make me an offer')
    expect(r.ok).toBe(true)
    id = r.offer!.offer_id
    expect(r.offer!.next).toMatchObject({ step: 'ask_condition', who: 'muse' })
    expect((await open(C.kuster, 'again')).already).toBe(true)
  })
  it('no dollar figure may be texted before Colin has OK\'d one', async () => {
    expect(await problem(C.kuster, 'We could do $111,400 for it')).toContain('Colin has not OK')
    expect(await problem(C.items, 'I can pay 90k')).toContain('no open offer')
    expect(await problem(C.kuster, 'What are the big things it needs?')).toBeNull()
  })
  it('then the comp, and a thin comp set is not a set', async () => {
    let r = await update({ offer_id: id, condition_asked: true })
    expect(r.offer!.next.step).toBe('comp')
    r = await update({ offer_id: id, arv: 230000, arv_basis: 'two sold nearby', comps: comps(2), sqft: 1271 })
    expect(r.offer!.next).toMatchObject({ step: 'comp' })
    expect(r.offer!.next.say).toContain('Only 2 sold comp')
    r = await update({ offer_id: id, arv: 230000, arv_basis: 'three sold within half a mile, 90 days', comps: comps(3) })
    expect(r.offer!.next).toMatchObject({ step: 'wait_condition', who: 'seller' })
  })
  it('a repair figure needs the seller\'s own words', async () => {
    const other = await open(C.cheap, 'What is your offer')
    const r = await update({ offer_id: other.offer!.offer_id, repair_level: 'medium' })
    expect(r).toMatchObject({ ok: false })
    expect(r.reason).toContain('own words')
    expect((await update({ offer_id: id, condition_words: 'needs work', repair_items: ['pool'] })).reason).toContain('not a repair item')
  })
  it('with the comp and the condition in, the figure goes to Colin', async () => {
    const r = await update({ offer_id: id, condition_words: 'Roof is 20 years old, kitchen is original, furnace works', repair_level: 'medium' })
    expect(r.offer!.next).toMatchObject({ step: 'colin', who: 'colin' })
    expect(r.offer!.numbers).toMatchObject({ offer: 111400, most: 122900, asked_of_colin: 111400 })
    const ping = await one<{ kind: string; number: number }[]>(`public.text_offer_ping_claim(now())`)
    expect(ping.filter((p) => p.kind === 'ask').map((p) => p.number)).toContain(111400)
    expect((await one<{ kind: string }[]>(`public.text_offer_ping_claim(now())`)).filter((p) => p.kind === 'ask')).toEqual([])
  })
  it('only Colin says yes: not the agent\'s own login, not a caller', async () => {
    await as(MUSE_LOGIN)
    await expect(decide(id, 'ok')).rejects.toThrow(/only Colin/)
    await as(null)
    await expect(decide(id, 'ok')).rejects.toThrow(/only Colin/)
  })
  it('Colin can ask first; the answer brings it back to him', async () => {
    await as(COLIN)
    expect((await decide(id, 'ask', null, 'Is the furnace original?')).ok).toBe(true)
    await as(null)
    const w = await one<{ yours: Row[] }>(`public.agent_offer_worklist(now())`)
    expect(w.yours.find((x) => x.offer_id === id)!.next).toMatchObject({ step: 'answer_colin', who: 'muse' })
    const r = await update({ offer_id: id, answer: 'They said it was replaced in 2019' })
    expect(r.offer!.next.step).toBe('colin')
  })
  it('Colin OKs a figure; that figure and no other may be texted', async () => {
    await as(COLIN)
    expect((await decide(id, 'ok', 110000, 'round it')).ok).toBe(true)
    await as(null)
    const w = await one<{ yours: Row[] }>(`public.agent_offer_worklist(now())`)
    expect(w.yours.find((x) => x.offer_id === id)!.next).toMatchObject({ step: 'send_number', who: 'muse' })
    expect(await problem(C.kuster, 'I can do $110,000 for it, closing whenever suits you')).toBeNull()
    expect(await problem(C.kuster, 'I can do 110k')).toBeNull()
    expect(await problem(C.kuster, 'I can do $111,400')).toContain('not a figure Colin OK')
    expect(await problem(C.asker, 'I can do $110,000')).toContain('Colin has not OK')
  })
  it('once it is texted the step is the seller\'s, and their answer is read', async () => {
    await said(C.kuster, 'I can do $110,000 for it, closing whenever suits you')
    let r = await update({ offer_id: id })
    expect(r.offer!.next).toMatchObject({ step: 'wait_reply', who: 'seller' })
    await heard(C.kuster, 'Could you do 120?', 'SM-counter-1')
    r = await update({ offer_id: id })
    expect(r.offer!.next).toMatchObject({ step: 'read_reply', who: 'muse' })
  })
  it('a counter goes to Colin before it is answered, and never above the most', async () => {
    let r = await update({ offer_id: id, response: 'counter', response_words: 'Could you do 120?', counter_number: 120000 })
    expect(r.offer!.next).toMatchObject({ step: 'colin', who: 'colin' })
    expect(r.offer!.numbers.asked_of_colin).toBe(120000)
    expect(await problem(C.kuster, 'OK, $120,000 works')).toContain('not a figure Colin OK')
    r = await update({ offer_id: id, response: 'counter', response_words: 'No, 150', counter_number: 150000 })
    expect(r.offer!.numbers.asked_of_colin).toBe(122900)
    await as(COLIN)
    expect((await decide(id, 'ok', 118000)).ok).toBe(true)
    await as(null)
    expect(await problem(C.kuster, 'I can stretch to $118,000')).toBeNull()
    expect(await problem(C.kuster, 'as I said, $110,000')).toBeNull()
  })
  it('a yes: who signs and the email, then the written offer is Colin\'s', async () => {
    await said(C.kuster, 'I can stretch to $118,000')
    let r = await update({ offer_id: id, response: 'accepted', response_words: 'OK deal' })
    expect(r.offer!.next).toMatchObject({ step: 'signing_details', who: 'muse' })
    expect((await update({ offer_id: id, seller_email: 'not an email' })).ok).toBe(false)
    r = await update({ offer_id: id, signers: 'Pat Kuster and Lee Kuster', seller_email: 'pat@example.com' })
    expect(r.offer!.next).toMatchObject({ step: 'written_offer', who: 'colin' })
    const ping = await one<{ kind: string; number: number }[]>(`public.text_offer_ping_claim(now())`)
    expect(ping.find((p) => p.kind === 'written')!.number).toBe(118000)
  })
})

describe('the gates', () => {
  it('a number above what it is worth fixed up is retail: no number', async () => {
    const r0 = await open(C.retail, 'what is your offer')
    const r = await update({ offer_id: r0.offer!.offer_id, their_number: 380000, their_words: 'firm at 380', flexible: 'firm',
      condition_words: 'all updated', repair_level: 'light', arv: 230000, arv_basis: 'three sold', comps: comps(3), sqft: 1300 })
    expect(r.offer!.next).toMatchObject({ step: 'retail', who: 'muse' })
    expect(r.offer!.numbers.asked_of_colin).toBeNull()
    const c = await one<{ ok: boolean }>(`public.agent_offer_close($1, 'retail', 'firm at 380', 'Muse')`, [r0.offer!.offer_id])
    expect(c.ok).toBe(true)
    expect(await one<string>(`(select notes from public.leads where id = $1)`, [C.retail])).toContain('offer by text closed: retail')
  })
  it('their own number under the rule\'s offer is the figure asked of Colin', async () => {
    const o = (await rows<{ id: string }>(`select id from public.text_offers where lead_id = $1 and status = 'open'`, [C.cheap]))[0].id
    const r = await update({ offer_id: o, their_number: 60000, their_words: 'I just want 60 out of it', condition_words: 'roof leaks', repair_items: ['roof'],
      arv: 150000, arv_basis: 'three sold', comps: comps(3) })
    expect(r.offer!.numbers).toMatchObject({ offer: 87500, asked_of_colin: 60000 })
  })
  it('Colin passes with a reason, and the step is to close politely', async () => {
    const o = (await rows<{ id: string }>(`select id from public.text_offers where lead_id = $1 and status = 'open'`, [C.cheap]))[0].id
    await as(COLIN)
    expect((await decide(o, 'pass')).ok).toBe(false)
    expect((await decide(o, 'pass', null, 'too far out')).ok).toBe(true)
    await as(null)
    const w = await one<{ yours: Row[] }>(`public.agent_offer_worklist(now())`)
    expect(w.yours.find((x) => x.offer_id === o)!.next).toMatchObject({ step: 'passed' })
  })
})

describe('the clock', () => {
  it('closes an offer whose card went do-not-contact, and tells Muse once when her step is late', async () => {
    await db.query(`update public.leads set stage = 'dnc' where id = $1`, [C.cheap])
    await db.query(`update public.text_offers set opened_at = now() - interval '3 days', comp_due_at = now() - interval '2 days' where lead_id = $1`, [C.asker])
    const noon = await one<string>(`(((now() at time zone 'America/Chicago')::date + 2 - extract(isodow from (now() at time zone 'America/Chicago')::date + 2)::int % 7 * 0) + time '12:00') at time zone 'America/Chicago'`)
    const day = new Date(noon)
    // a weekday noon at least a day on (never a Sunday)
    while (new Intl.DateTimeFormat('en-US', { timeZone: 'America/Chicago', weekday: 'short' }).format(day) === 'Sun') day.setUTCDate(day.getUTCDate() + 1)
    const t1 = await one<{ closed: number; told_muse: number }>(`public.text_offer_tick($1)`, [day.toISOString()])
    expect(t1.closed).toBe(1)
    expect(t1.told_muse).toBeGreaterThanOrEqual(1)
    expect(await one<string>(`(select closed_why from public.text_offers where lead_id = $1)`, [C.cheap])).toBe('dnc')
    const t2 = await one<{ told_muse: number }>(`public.text_offer_tick($1)`, [day.toISOString()])
    expect(t2.told_muse).toBe(0)
    const posts = await rows<{ topic: string }>(`select topic from public.desk_messages where topic like 'OFFER STEP LATE%'`)
    expect(posts.some((p) => p.topic.includes('ask_condition'))).toBe(true)
  })
  it('posts the evening report once', async () => {
    const eve = new Date(); eve.setUTCDate(eve.getUTCDate() + 3)
    while (new Intl.DateTimeFormat('en-US', { timeZone: 'America/Chicago', weekday: 'short' }).format(eve) === 'Sun') eve.setUTCDate(eve.getUTCDate() + 1)
    const local = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Chicago' }).format(eve)
    const at = await one<string>(`(($1::date + time '19:10') at time zone 'America/Chicago')`, [local])
    expect((await one<{ reported: boolean }>(`public.text_offer_tick($1)`, [at])).reported).toBe(true)
    expect((await one<{ reported: boolean }>(`public.text_offer_tick($1)`, [at])).reported).toBe(false)
    expect((await rows(`select 1 from public.desk_messages where topic like 'Offers by text:%'`)).length).toBe(1)
  })
})
