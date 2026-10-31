// The exit anchor (migration 0149; Colin 2026-10-30): one low, non-firm figure a caller may say to a seller who will
// not name a number or is leaving, so the seller says their own. Rick's arithmetic on the county's value and the
// condition answers; off until Colin turns it on; the only number a caller logs is the one the database handed them.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')
const COLIN = { sub: '00000000-0000-0000-0000-00000000000c', email: 'colin@example.com' }
const THALIA = { sub: '00000000-0000-0000-0000-0000000000a1', email: 'thalia@example.com' }
let db: PGlite
const r = async (sql: string, params: unknown[] = []) => (await db.query<{ r: Record<string, unknown> }>(`select ${sql} as r`, params)).rows[0].r
const as = async <T>(who: { sub: string; email: string }, fn: () => Promise<T>) => {
  await db.query(`select set_config('request.jwt.claims', $1, false)`, [JSON.stringify(who)])
  await db.exec('set role authenticated')
  try { return await fn() } finally { await db.exec('reset role'); await db.query(`select set_config('request.jwt.claims', '', false)`) }
}
const answer = (lead: string, key: string, value: unknown) => as(THALIA, () => r(`public.call_answer($1, $2, $3::jsonb)`, [lead, key, JSON.stringify(value)]))

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
  await db.exec(`insert into public.team_members (email, role, person, display_name) values
    ('colin@example.com', 'owner', 'colin', 'Colin'), ('thalia@example.com', 'caller', 'thalia', 'Thalia')`)
})

async function card(name: string, street: string, propertyId: number | null) {
  const lead = (await r(`public.agent_add_prospect($1::jsonb, 'Muse intake')`, [JSON.stringify({ owner_name: name, owner_type: 'individual',
    address: street, city: 'Waukesha', phones: [{ number: '414556' + String(Math.floor(1000 + Math.random() * 8999)), name }] })])).lead_id as string
  if (propertyId != null) await db.query(`update public.leads set wpie_property_id = $2 where id = $1`, [lead, propertyId])
  return lead
}

describe('the exit anchor', () => {
  it('ships off: no number to say, and nothing can be logged as said', async () => {
    expect((await db.query(`select mode from public.offer_settings`)).rows).toEqual([{ mode: 'off' }])
    const lead = await card('ANN ANCHOR', '41 Anchor Test St', 9001)
    await db.query(`insert into public.property_values (wpie_property_id, est_market_value, building_sqft) values (9001, 105000, 1000)`)
    const shot = await as(THALIA, () => r(`public.offer_shoot($1)`, [lead]))
    expect(shot).toMatchObject({ ok: true, mode: 'off' })
    expect(await as(THALIA, () => r(`public.offer_said($1, $2, 'open')`, [lead, shot.number]))).toMatchObject({ ok: false, reason: expect.stringContaining('off') })
  })

  it("Colin turns it on; only Colin: a caller cannot", async () => {
    await expect(as(THALIA, () => r(`public.offer_settings_set('{"mode":"exit_only"}'::jsonb)`))).rejects.toThrow(/only Colin/)
    expect(await as(COLIN, () => r(`public.offer_settings_set('{"mode":"sideways"}'::jsonb)`))).toMatchObject({ ok: false })
    expect(await as(COLIN, () => r(`public.offer_settings_set('{"mode":"exit_only"}'::jsonb)`))).toMatchObject({ ok: true, mode: 'exit_only' })
  })

  it("Rick's repairs by the square foot: something old means medium, $30 a sq ft (0156)", async () => {
    const lead = await card('BO ANCHOR', '42 Anchor Test St', 9002)
    // Hayes-shaped: $105K value, 1,000 sq ft, roof and furnace gone
    await db.query(`insert into public.property_values (wpie_property_id, est_market_value, building_sqft) values (9002, 105000, 1000)`)
    await answer(lead, 'condition', { choices: ['roof', 'furnace'] })
    const s = await as(THALIA, () => r(`public.offer_shoot($1)`, [lead]))
    // roof and furnace old: medium, 1,000 sq ft x $30 = 30,000; (105,000 - 30,000) x 0.70 = 52,500; x 0.85 = 44,625 -> 44,000
    expect(s).toMatchObject({ ok: true, tier: 'medium', repairs: 30000, number: 44000, value_basis: expect.stringContaining('county') })
    // the buyer's price is Colin's alone (0157): a caller's answer has none of it
    expect(s.mao).toBeUndefined(); expect(s.lao).toBeUndefined(); expect(s.pct).toBeUndefined()
    // (105,000 - 30,000) x 0.70 = 52,500 for Colin
    expect(await as(COLIN, () => r(`public.offer_shoot($1)`, [lead]))).toMatchObject({ pct: 0.7, mao: 52500, lao: 44625, number: 44000 })
    expect((s.lines as { item: string }[]).map((x) => x.item)).toEqual(["Rick's rate: medium"])
    expect(String(s.say)).toContain('$44,000')
    expect(String(s.say)).toContain("can't give you a firm number")
  })

  it('no county size: the bedrooms they named set it; cosmetic only leaves just the base refresh; the 75% band above $120K', async () => {
    const lead = await card('CY ANCHOR', '43 Anchor Test St', 9003)
    await db.query(`insert into public.property_values (wpie_property_id, est_market_value) values (9003, 200000)`)
    await answer(lead, 'layout', { text: '3 bed 1 bath ranch, two car garage' })
    await answer(lead, 'condition', { choices: ['cosmetic'] })
    const s = await as(THALIA, () => r(`public.offer_shoot($1)`, [lead]))
    // 3 beds = 1,250 sq ft x $10 light = 12,500; (200,000 - 12,500) x 0.75 = 140,625; x 0.85 = 119,531.25 -> 119,000
    expect(s).toMatchObject({ ok: true, sqft: 1250, sqft_basis: expect.stringContaining('3 bedrooms'), tier: 'light', repairs: 12500, number: 119000 })
  })

  it("a band may carry its own discount: Rick's 2026 bands, 35% under $120K, 30% above (0153)", async () => {
    const rick = [{ upto: 120000, pct: 0.70, off: 0.35 }, { upto: 200000, pct: 0.75, off: 0.30 }, { upto: 250000, pct: 0.78, off: 0.30 },
      { upto: 350000, pct: 0.80, off: 0.30 }, { upto: null, pct: 0.83, off: 0.30 }]
    expect(await as(COLIN, () => r(`public.offer_settings_set($1::jsonb)`, [JSON.stringify({ bands: rick, lao_discount: 0.30 })]))).toMatchObject({ ok: true })
    const cheap = await card('HAL BAND', '48 Anchor Test St', 9008)
    await db.query(`insert into public.property_values (wpie_property_id, est_market_value, building_sqft) values (9008, 105000, 1000)`)
    await answer(cheap, 'condition', { choices: ['roof'] })
    // medium 30,000; (105,000 - 30,000) x 0.70 = 52,500; x 0.65 = 34,125 -> 34,000
    expect(await as(THALIA, () => r(`public.offer_shoot($1)`, [cheap]))).toMatchObject({ ok: true, off: 0.35, number: 34000 })
    const mid = await card('IDA BAND', '49 Anchor Test St', 9009)
    await db.query(`insert into public.property_values (wpie_property_id, est_market_value, building_sqft) values (9009, 150000, 1000)`)
    await answer(mid, 'condition', { choices: ['furnace'] })
    // medium 30,000; (150,000 - 30,000) x 0.75 = 90,000; x 0.70 = 63,000
    expect(await as(THALIA, () => r(`public.offer_shoot($1)`, [mid]))).toMatchObject({ ok: true, off: 0.3, number: 63000 })
    // back to the defaults so the other tests keep their numbers
    await as(COLIN, () => r(`public.offer_settings_set($1::jsonb)`, [JSON.stringify({ bands: [{ upto: 120000, pct: 0.70 }, { upto: 250000, pct: 0.75 }, { upto: null, pct: 0.80 }], lao_discount: 0.15 })]))
  })

  it('nothing on file: no number, ask for theirs; water or foundation: walk first; too thin: book Colin', async () => {
    const none = await card('DI ANCHOR', '44 Anchor Test St', null)
    expect(await as(THALIA, () => r(`public.offer_shoot($1)`, [none]))).toMatchObject({ ok: false, reason: expect.stringContaining('no value on file') })
    const thin = await card('ED ANCHOR', '45 Anchor Test St', 9005)
    await db.query(`insert into public.property_values (wpie_property_id, est_market_value, building_sqft) values (9005, 60000, 1400)`)
    await answer(thin, 'condition', { choices: ['foundation'] })
    expect(await as(THALIA, () => r(`public.offer_shoot($1)`, [thin]))).toMatchObject({ ok: false, walk_first: true, reason: expect.stringContaining('walks it first') })
    await answer(thin, 'condition', { choices: [] })
    // 1,400 sq ft at $60,000, nothing asked: heavy 1,400 x $60 = 84,000 is more than the value
    expect(await as(THALIA, () => r(`public.offer_shoot($1)`, [thin]))).toMatchObject({ ok: false, reason: expect.stringContaining('too thin') })
  })

  it("the package's own value wins over the county's; Colin's number on the package is back on", async () => {
    const lead = await card('FAY ANCHOR', '46 Anchor Test St', 9006)
    await db.query(`insert into public.property_values (wpie_property_id, est_market_value, building_sqft) values (9006, 100000, 1000)`)
    const sent = await as(THALIA, () => r(`public.package_submit($1::jsonb)`, [JSON.stringify({ lead_id: lead, need: 'moving', callback_at: '2026-11-02T22:00:00Z' })]))
    expect(sent).toMatchObject({ ok: true })
    expect(await r(`public.package_set_value($1, 150000, 'three sales nearby', null, 'Muse')`, [sent.package_id])).toMatchObject({ ok: true })
    expect(await as(THALIA, () => r(`public.offer_shoot($1)`, [lead]))).toMatchObject({ ok: true, value: 150000, value_basis: expect.stringContaining('package') })
    expect(await as(COLIN, () => r(`public.package_price($1, 95000, 'non-firm, pending the walk', 'B')`, [sent.package_id]))).toMatchObject({ ok: true })
    expect((await db.query(`select status, our_number from public.deal_packages where id = $1`, [sent.package_id])).rows).toEqual([{ status: 'number_ready', our_number: '95000' }])
  })

  it("said it: only the card's own number logs; their counter becomes Their number; the package sent after carries it", async () => {
    const lead = await card('GUS ANCHOR', '47 Anchor Test St', 9007)
    await db.query(`insert into public.property_values (wpie_property_id, est_market_value, building_sqft) values (9007, 105000, 1000)`)
    await answer(lead, 'condition', { choices: ['roof'] })
    await answer(lead, 'price', { choices: ['refused'] })
    const s = await as(THALIA, () => r(`public.offer_shoot($1)`, [lead]))
    expect(s.number).toBe(44000)
    expect(await as(THALIA, () => r(`public.offer_said($1, 40000, 'open')`, [lead]))).toMatchObject({ ok: false, reason: expect.stringContaining('44000') })
    expect(await as(THALIA, () => r(`public.offer_said($1, 44000, 'gave_number', null)`, [lead]))).toMatchObject({ ok: false, reason: expect.stringContaining('number they said') })
    expect(await as(THALIA, () => r(`public.offer_said($1, 44000, 'gave_number', 60000, 'said he needs sixty')`, [lead]))).toMatchObject({ ok: true })
    const l = (await db.query<{ facts: Record<string, { value: Record<string, unknown>; by: string }>; notes: string }>(
      `select call_facts as facts, notes from public.leads where id = $1`, [lead])).rows[0]
    expect(l.facts.our_number.value).toMatchObject({ number: 44000, choices: ['gave_number'], counter: 60000 })
    expect(l.facts.our_number.by).toBe('Thalia')
    expect(l.facts.price.value).toMatchObject({ number: '60000' })
    expect(l.notes).toContain('anchor said by Thalia: around 44000, they said 60000')
    const sent = await as(THALIA, () => r(`public.package_submit($1::jsonb)`, [JSON.stringify({ lead_id: lead, need: 'moving', callback_at: '2026-11-02T22:00:00Z' })]))
    expect((await db.query(`select said_number, number_note from public.deal_packages where id = $1`, [sent.package_id])).rows)
      .toEqual([{ said_number: '44000', number_note: 'non-firm anchor said on the first call, they gave_number 60000' }])
  })
  it('the four quick answers on a Power hour call: all good leaves the base refresh; anything big means walk first', async () => {
    const lead = await card('JO QUICK', '50 Anchor Test St', 9010)
    await db.query(`insert into public.property_values (wpie_property_id, est_market_value, building_sqft) values (9010, 150000, 1000)`)
    for (const [k, v] of [['quick_roof', 'new'], ['quick_hvac', 'new'], ['quick_kb', 'updated'], ['quick_big', 'no']]) await answer(lead, k, { choices: [v] })
    // light 1,000 x $10 = 10,000; (150,000 - 10,000) x 0.75 = 105,000; x 0.85 = 89,250 -> 89,000
    expect(await as(THALIA, () => r(`public.offer_shoot($1)`, [lead]))).toMatchObject({ ok: true, asked: 4, tier: 'light', repairs: 10000, number: 89000 })
    await answer(lead, 'quick_roof', { choices: ['old'] })
    // an old roof: medium, 1,000 x $30 = 30,000 (the rate carries the roof); (150,000 - 30,000) x 0.75 = 90,000; x 0.85 = 76,500
    expect(await as(THALIA, () => r(`public.offer_shoot($1)`, [lead]))).toMatchObject({ ok: true, tier: 'medium', repairs: 30000, number: 76000 })
    await answer(lead, 'quick_big', { choices: ['yes'] })
    expect(await as(THALIA, () => r(`public.offer_shoot($1)`, [lead]))).toMatchObject({ ok: false, walk_first: true })
    // Colin edits one rehab figure: only that figure changes
    await answer(lead, 'quick_big', { choices: ['no'] })
    expect(await as(COLIN, () => r(`public.offer_settings_set('{"rehab":{"medium_per_ft":40}}'::jsonb)`))).toMatchObject({ ok: true })
    expect((await db.query<{ h: number }>(`select (rehab->>'light_per_ft')::int h from public.offer_settings`)).rows[0].h).toBe(10)
    // medium 1,000 x $40 = 40,000; (150,000 - 40,000) x 0.75 = 82,500; x 0.85 = 70,125 -> 70,000
    expect(await as(THALIA, () => r(`public.offer_shoot($1)`, [lead]))).toMatchObject({ ok: true, repairs: 40000, number: 70000 })
    await as(COLIN, () => r(`public.offer_settings_set('{"rehab":{"medium_per_ft":30}}'::jsonb)`))
  })

  it('nothing asked yet: heavy, $60 a sq ft (0156)', async () => {
    const lead = await card('KAY HEAVY', '51 Anchor Test St', 9011)
    await db.query(`insert into public.property_values (wpie_property_id, est_market_value, building_sqft) values (9011, 150000, 1000)`)
    // heavy 1,000 x $60 = 60,000; (150,000 - 60,000) x 0.75 = 67,500; x 0.85 = 57,375 -> 57,000
    expect(await as(THALIA, () => r(`public.offer_shoot($1)`, [lead]))).toMatchObject({ ok: true, asked: 0, tier: 'heavy', repairs: 60000, number: 57000 })
  })

  it("Adil's walkthrough (0157): the package carries the Quick number's answers, and the next call goes to the locked caller", async () => {
    await db.exec(`insert into public.team_members (email, role, person, display_name) values ('adil@example.com', 'caller', 'adil', 'Adil') on conflict do nothing`)
    const ADIL = { sub: '00000000-0000-0000-0000-0000000000a2', email: 'adil@example.com' }
    const lead = await card('LEE LOCKED', '52 Anchor Test St', 9012)
    await db.query(`insert into public.property_values (wpie_property_id, est_market_value, building_sqft) values (9012, 150000, 1000)`)
    for (const [k, v] of [['quick_roof', 'old'], ['quick_hvac', 'new'], ['quick_kb', 'original'], ['quick_big', 'no']])
      await as(ADIL, () => r(`public.call_answer($1, $2, $3::jsonb)`, [lead, k, JSON.stringify({ choices: [v] })]))
    const sent = await as(ADIL, () => r(`public.package_submit($1::jsonb)`, [JSON.stringify({ lead_id: lead, need: 'moving', condition: { roof: 'leaks over the kitchen' }, callback_at: '2026-11-02T22:00:00Z' })]))
    expect(sent).toMatchObject({ ok: true })
    const cond = (await db.query<{ c: Record<string, string> }>(`select condition c from public.deal_packages where id = $1`, [sent.package_id])).rows[0].c
    expect(cond).toEqual({ roof: 'leaks over the kitchen', hvac: 'newer (quick number)', kitchen_baths: 'original (quick number)' })
    // locked to Adil: a weekday caller step is his, and says so
    await db.query(`update public.leads set locked_to = 'adil', locked_at = now() where id = $1`, [lead])
    await db.query(`select public.belt_enter($1, 'yes_unbooked', 1, 'test', '{}'::jsonb, 'test', '2026-11-03T15:00:00Z'::timestamptz)`, [lead])
    const row = (await db.query<{ next_action: string; next_stop_who: string }>(`select next_action, next_stop_who from public.leads where id = $1`, [lead])).rows[0]
    if (row.next_stop_who === 'thalia_call') {
      expect(row.next_action).toBe('Adil calls')
      expect((await db.query<{ owner: string }>(`select owner::text from public.tasks where lead_id = $1 and source = 'belt' and done_at is null order by created_at desc limit 1`, [lead])).rows[0]?.owner).toBe('adil')
    }
  })

})
