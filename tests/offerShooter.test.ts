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

  it("Rick's arithmetic on the county's value and what the seller said: heavy repairs, under $120K, 70%, anchor 15% under", async () => {
    const lead = await card('BO ANCHOR', '42 Anchor Test St', 9002)
    // Hayes-shaped: $105K value, 1,000 sq ft, roof and furnace gone
    await db.query(`insert into public.property_values (wpie_property_id, est_market_value, building_sqft) values (9002, 105000, 1000)`)
    await answer(lead, 'condition', { choices: ['roof', 'furnace'] })
    const s = await as(THALIA, () => r(`public.offer_shoot($1)`, [lead]))
    // repairs 50 x 1000 = 50,000; (105,000 - 50,000) x 0.70 = 38,500; x 0.85 = 32,725; rounded down to 32,000
    expect(s).toMatchObject({ ok: true, tier: 'heavy', repairs: 50000, pct: 0.7, mao: 38500, lao: 32725, number: 32000, value_basis: expect.stringContaining('county') })
    expect(String(s.say)).toContain('$32,000')
    expect(String(s.say)).toContain("can't give you a firm number")
  })

  it('no county size: the bedrooms they named set it; cosmetic only is the light tier; the 75% band above $120K', async () => {
    const lead = await card('CY ANCHOR', '43 Anchor Test St', 9003)
    await db.query(`insert into public.property_values (wpie_property_id, est_market_value) values (9003, 200000)`)
    await answer(lead, 'layout', { text: '3 bed 1 bath ranch, two car garage' })
    await answer(lead, 'condition', { choices: ['cosmetic'] })
    const s = await as(THALIA, () => r(`public.offer_shoot($1)`, [lead]))
    // 3 beds = 1,250 sq ft x $15 = 18,750; (200,000 - 18,750) x 0.75 = 135,937.5; x 0.85 = 115,546.875 -> 115,000
    expect(s).toMatchObject({ ok: true, sqft: 1250, sqft_basis: expect.stringContaining('3 bedrooms'), tier: 'light', repairs: 18750, pct: 0.75, number: 115000 })
  })

  it('nothing on file for the parcel: no number, ask for theirs; too thin: no number, book Colin', async () => {
    const none = await card('DI ANCHOR', '44 Anchor Test St', null)
    expect(await as(THALIA, () => r(`public.offer_shoot($1)`, [none]))).toMatchObject({ ok: false, reason: expect.stringContaining('no value on file') })
    const thin = await card('ED ANCHOR', '45 Anchor Test St', 9005)
    await db.query(`insert into public.property_values (wpie_property_id, est_market_value, building_sqft) values (9005, 60000, 1400)`)
    await answer(thin, 'condition', { choices: ['foundation'] })
    // (60,000 - 70,000) is negative: too thin
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
    expect(s.number).toBe(32000)
    expect(await as(THALIA, () => r(`public.offer_said($1, 40000, 'open')`, [lead]))).toMatchObject({ ok: false, reason: expect.stringContaining('32000') })
    expect(await as(THALIA, () => r(`public.offer_said($1, 32000, 'gave_number', null)`, [lead]))).toMatchObject({ ok: false, reason: expect.stringContaining('number they said') })
    expect(await as(THALIA, () => r(`public.offer_said($1, 32000, 'gave_number', 60000, 'said he needs sixty')`, [lead]))).toMatchObject({ ok: true })
    const l = (await db.query<{ facts: Record<string, { value: Record<string, unknown>; by: string }>; notes: string }>(
      `select call_facts as facts, notes from public.leads where id = $1`, [lead])).rows[0]
    expect(l.facts.our_number.value).toMatchObject({ number: 32000, choices: ['gave_number'], counter: 60000 })
    expect(l.facts.our_number.by).toBe('Thalia')
    expect(l.facts.price.value).toMatchObject({ number: '60000' })
    expect(l.notes).toContain('anchor said by Thalia: around 32000, they said 60000')
    const sent = await as(THALIA, () => r(`public.package_submit($1::jsonb)`, [JSON.stringify({ lead_id: lead, need: 'moving', callback_at: '2026-11-02T22:00:00Z' })]))
    expect((await db.query(`select said_number, number_note from public.deal_packages where id = $1`, [sent.package_id])).rows)
      .toEqual([{ said_number: '32000', number_note: 'non-firm anchor said on the first call, they gave_number 60000' }])
  })
})
