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

  it("line-item repairs from what the seller said, unasked items counted, a base refresh always, 20% unseen buffer (0154)", async () => {
    const lead = await card('BO ANCHOR', '42 Anchor Test St', 9002)
    // Hayes-shaped: $105K value, 1,000 sq ft, roof and furnace gone
    await db.query(`insert into public.property_values (wpie_property_id, est_market_value, building_sqft) values (9002, 105000, 1000)`)
    await answer(lead, 'condition', { choices: ['roof', 'furnace'] })
    const s = await as(THALIA, () => r(`public.offer_shoot($1)`, [lead]))
    // base 12,000 + roof 12,000 + furnace 8,000 + kitchen 10,000 (unasked: counted) + bath 7,000 = 49,000; +20% = 58,800
    // (105,000 - 58,800) x 0.70 = 32,340; x 0.85 = 27,489; rounded down to 27,000
    expect(s).toMatchObject({ ok: true, tier: 'itemized', repairs: 58800, pct: 0.7, mao: 32340, lao: 27489, number: 27000, value_basis: expect.stringContaining('county') })
    expect((s.lines as { item: string }[]).map((x) => x.item)).toEqual(['Base refresh (paint, floors, fixtures)', 'Roof', 'Furnace / AC', 'Kitchen', 'Bath', 'Buffer, unseen'])
    expect(String(s.say)).toContain('$27,000')
    expect(String(s.say)).toContain("can't give you a firm number")
  })

  it('no county size: the bedrooms they named set it; cosmetic only leaves just the base refresh; the 75% band above $120K', async () => {
    const lead = await card('CY ANCHOR', '43 Anchor Test St', 9003)
    await db.query(`insert into public.property_values (wpie_property_id, est_market_value) values (9003, 200000)`)
    await answer(lead, 'layout', { text: '3 bed 1 bath ranch, two car garage' })
    await answer(lead, 'condition', { choices: ['cosmetic'] })
    const s = await as(THALIA, () => r(`public.offer_shoot($1)`, [lead]))
    // 3 beds = 1,250 sq ft; base 15,000 + 20% = 18,000; (200,000 - 18,000) x 0.75 = 136,500; x 0.85 = 116,025 -> 116,000
    expect(s).toMatchObject({ ok: true, sqft: 1250, sqft_basis: expect.stringContaining('3 bedrooms'), repairs: 18000, pct: 0.75, number: 116000 })
  })

  it("a band may carry its own discount: Rick's 2026 bands, 35% under $120K, 30% above (0153)", async () => {
    const rick = [{ upto: 120000, pct: 0.70, off: 0.35 }, { upto: 200000, pct: 0.75, off: 0.30 }, { upto: 250000, pct: 0.78, off: 0.30 },
      { upto: 350000, pct: 0.80, off: 0.30 }, { upto: null, pct: 0.83, off: 0.30 }]
    expect(await as(COLIN, () => r(`public.offer_settings_set($1::jsonb)`, [JSON.stringify({ bands: rick, lao_discount: 0.30 })]))).toMatchObject({ ok: true })
    const cheap = await card('HAL BAND', '48 Anchor Test St', 9008)
    await db.query(`insert into public.property_values (wpie_property_id, est_market_value, building_sqft) values (9008, 105000, 1000)`)
    await answer(cheap, 'condition', { choices: ['roof'] })
    // repairs 58,800; (105,000 - 58,800) x 0.70 = 32,340; x 0.65 = 21,021 -> 21,000
    expect(await as(THALIA, () => r(`public.offer_shoot($1)`, [cheap]))).toMatchObject({ ok: true, pct: 0.7, off: 0.35, mao: 32340, number: 21000 })
    const mid = await card('IDA BAND', '49 Anchor Test St', 9009)
    await db.query(`insert into public.property_values (wpie_property_id, est_market_value, building_sqft) values (9009, 150000, 1000)`)
    await answer(mid, 'condition', { choices: ['furnace'] })
    // base 12,000 + roof 12,000 + furnace 8,000 + kitchen 12,000 (8% of value) + bath 7,000 = 51,000; +20% = 61,200
    // (150,000 - 61,200) x 0.75 = 66,600; x 0.70 = 46,620 -> 46,000
    expect(await as(THALIA, () => r(`public.offer_shoot($1)`, [mid]))).toMatchObject({ ok: true, pct: 0.75, off: 0.3, mao: 66600, number: 46000 })
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
    // 1,400 sq ft at $60,000: base 16,800 + roof 12,000 + furnace 8,000 + kitchen 10,000 + bath 7,000, +20% = 64,560 > value
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
    expect(s.number).toBe(27000)
    expect(await as(THALIA, () => r(`public.offer_said($1, 40000, 'open')`, [lead]))).toMatchObject({ ok: false, reason: expect.stringContaining('27000') })
    expect(await as(THALIA, () => r(`public.offer_said($1, 27000, 'gave_number', null)`, [lead]))).toMatchObject({ ok: false, reason: expect.stringContaining('number they said') })
    expect(await as(THALIA, () => r(`public.offer_said($1, 27000, 'gave_number', 60000, 'said he needs sixty')`, [lead]))).toMatchObject({ ok: true })
    const l = (await db.query<{ facts: Record<string, { value: Record<string, unknown>; by: string }>; notes: string }>(
      `select call_facts as facts, notes from public.leads where id = $1`, [lead])).rows[0]
    expect(l.facts.our_number.value).toMatchObject({ number: 27000, choices: ['gave_number'], counter: 60000 })
    expect(l.facts.our_number.by).toBe('Thalia')
    expect(l.facts.price.value).toMatchObject({ number: '60000' })
    expect(l.notes).toContain('anchor said by Thalia: around 27000, they said 60000')
    const sent = await as(THALIA, () => r(`public.package_submit($1::jsonb)`, [JSON.stringify({ lead_id: lead, need: 'moving', callback_at: '2026-11-02T22:00:00Z' })]))
    expect((await db.query(`select said_number, number_note from public.deal_packages where id = $1`, [sent.package_id])).rows)
      .toEqual([{ said_number: '27000', number_note: 'non-firm anchor said on the first call, they gave_number 60000' }])
  })
  it('the four quick answers on a Power hour call: all good leaves the base refresh; anything big means walk first', async () => {
    const lead = await card('JO QUICK', '50 Anchor Test St', 9010)
    await db.query(`insert into public.property_values (wpie_property_id, est_market_value, building_sqft) values (9010, 150000, 1000)`)
    for (const [k, v] of [['quick_roof', 'new'], ['quick_hvac', 'new'], ['quick_kb', 'updated'], ['quick_big', 'no']]) await answer(lead, k, { choices: [v] })
    // base 12,000 + 20% = 14,400; (150,000 - 14,400) x 0.75 = 101,700; x 0.85 = 86,445 -> 86,000
    expect(await as(THALIA, () => r(`public.offer_shoot($1)`, [lead]))).toMatchObject({ ok: true, asked: 4, repairs: 14400, mao: 101700, number: 86000 })
    await answer(lead, 'quick_roof', { choices: ['old'] })
    // + roof 12,000: 24,000 + 20% = 28,800; (150,000 - 28,800) x 0.75 = 90,900; x 0.85 = 77,265 -> 77,000
    expect(await as(THALIA, () => r(`public.offer_shoot($1)`, [lead]))).toMatchObject({ ok: true, repairs: 28800, number: 77000 })
    await answer(lead, 'quick_big', { choices: ['yes'] })
    expect(await as(THALIA, () => r(`public.offer_shoot($1)`, [lead]))).toMatchObject({ ok: false, walk_first: true })
    // Colin edits one rehab figure: only that figure changes
    await answer(lead, 'quick_big', { choices: ['no'] })
    expect(await as(COLIN, () => r(`public.offer_settings_set('{"rehab":{"roof_small":20000}}'::jsonb)`))).toMatchObject({ ok: true })
    expect((await db.query<{ h: number }>(`select (rehab->>'hvac')::int h from public.offer_settings`)).rows[0].h).toBe(8000)
    // roof 20,000: 32,000 + 20% = 38,400; (150,000 - 38,400) x 0.75 = 83,700; x 0.85 = 71,145 -> 71,000
    expect(await as(THALIA, () => r(`public.offer_shoot($1)`, [lead]))).toMatchObject({ ok: true, repairs: 38400, number: 71000 })
    await as(COLIN, () => r(`public.offer_settings_set('{"rehab":{"roof_small":12000}}'::jsonb)`))
  })

})
