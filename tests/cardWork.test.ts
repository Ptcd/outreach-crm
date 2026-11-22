// 0281: comps, angles and a number on any card, by whichever agent claims it first (Colin 2026-11-22: "My goal is for
// grok to be able to set those numbers and then also fully realize the situation ... Estate owes more than house is
// worth but mortgage is much lower then price just has to clear mortgage and fees. Mortgage high then no go deal").
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')

let db: PGlite
type Json = Record<string, any>
const ESTATE = '00000000-0000-0000-0000-00000000e281'   // Tyler's: estate claims far over the house, a small mortgage
const UNDER = '00000000-0000-0000-0000-00000000e282'    // Tyler's: a mortgage more than we can pay
const FRESH = '00000000-0000-0000-0000-00000000e283'    // Tyler's: nothing on it yet; the button
const TYLER = 'adil@example.com', COLIN = 'colin@example.com'

const asUser = async <T = Json>(email: string, sql: string, params: unknown[] = []) => {
  await db.query(`select set_config('request.jwt.claims', $1, false)`, [JSON.stringify({ email })])
  await db.exec('set role authenticated')
  try { return (await db.query<T>(sql, params)).rows } finally { await db.exec('reset role'); await db.query(`select set_config('request.jwt.claims', '', false)`) }
}
const one = async (sql: string, params: unknown[] = []) => (await db.query<{ r: Json }>(`select ${sql} as r`, params)).rows[0].r
const comps = (prices: number[]) => prices.map((p, i) => ({ address: `${10 + i} Near St`, sold_price: p, sold_date: `2026-0${i + 4}-15`, sqft: 1300 }))
const ROWS = [{ inside: 'Inside light', repairs: 12000, repairs_basis: 'paint and floors', open: 1, top: 2 },
  { inside: 'Inside heavy', repairs: 20000, repairs_basis: 'kitchen, baths', open: 1, top: 2 }]
const valued = async (lead: string) => {
  await db.query(`insert into public.text_offers (lead_id, opened_by, trigger, trigger_text) values ($1, 'system', 'caller_asked', 'asked from the card')`, [lead])
  await db.query(`update public.text_offers set arv = 200000, sqft = 1300, arv_basis = 'three sold nearby', comps = $2::jsonb,
    street = '{"image_date": "June 2025", "seen": []}'::jsonb, call_prices = $3::jsonb, valued_at = now(), valued_by = 'Grok' where lead_id = $1`,
    [lead, JSON.stringify(comps([195000, 200000, 210000])), JSON.stringify(ROWS)])
}
const brief = (lead: string, owed: Json[], angles: Json[] = []) => one(`public.agent_call_brief_set($1::jsonb, 'Grok')`, [JSON.stringify({
  lead_id: lead, story: 'The owner died last year; the son is the personal representative and lives out of state. The house is empty.',
  owed, angles, situation: 'Estate, nothing left for them: the price clears the mortgage and fees.',
  script: '**Open**\n' + 'Hi, this is Tyler. '.repeat(30) + '\n**Close**\nIf the mortgage is under 40, we can close on your date.' })])

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
  await db.exec(`
    insert into public.team_members (email, role, person, display_name) values
      ('${COLIN}', 'owner', 'colin', 'Colin'), ('${TYLER}', 'caller', 'adil', 'Tyler'), ('thalia@example.com', 'caller', 'thalia', 'Thalia')
    on conflict (email) do update set role = excluded.role, person = excluded.person, display_name = excluded.display_name;
    insert into public.leads (id, wpie_owner_id, owner_name, lane, stage, property_address, municipality, county, mailing_state, locked_to, assigned_to) values
      ('${ESTATE}', 9811, 'ESTATE OF TEST', 'flip', 'colin_call', '991 TEST ST', 'CITY OF TEST', 'Brown', 'WI', 'adil', 'adil'),
      ('${UNDER}', 9812, 'UNDER OWNER', 'flip', 'colin_call', '2 OWE ST', 'CITY OF TEST', 'Brown', 'WI', 'adil', 'adil'),
      ('${FRESH}', 9813, 'FRESH OWNER', 'flip', 'opener_sent', '3 NEW ST', 'CITY OF TEST', 'Brown', 'WI', 'adil', 'adil');`)
}, 180_000)

describe('0281: comps, angles and a number on any card', () => {
  it('the card button opens a comp that is never texted to the seller and asks for the brief; Muse and Grok both see it; the first claim wins', async () => {
    const r = (await asUser<{ r: Json }>(TYLER, `select public.card_work_ask($1) as r`, [FRESH]))[0].r
    expect(r.ok).toBe(true)
    const o = (await db.query<Json>(`select trigger, status from public.text_offers where lead_id = $1`, [FRESH])).rows[0]
    expect(o).toMatchObject({ trigger: 'caller_asked', status: 'open' })
    const live = await one(`public.agent_live_work()`)
    expect(live.cards.map((c: Json) => c.lead_id)).toContain(FRESH)
    expect((await one(`public.agent_attention('Grok')`))?.live).toBeTruthy()
    expect((await one(`public.agent_work_claim($1, 'Grok')`, [FRESH])).ok).toBe(true)
    expect(await one(`public.agent_work_claim($1, 'Muse')`, [FRESH])).toMatchObject({ ok: false })
    // once valued and priced, the offer is the caller's: Muse is never asked to text a condition question on it
    await db.query(`update public.text_offers set arv = 200000, comps = $2::jsonb, call_prices = $3::jsonb, valued_at = now() where lead_id = $1`,
      [FRESH, JSON.stringify(comps([195000, 200000, 210000])), JSON.stringify(ROWS)])
    const v = (await db.query<{ r: Json }>(`select public.text_offer_view(o, now()) as r from public.text_offers o where o.lead_id = $1`, [FRESH])).rows[0].r
    expect(v).toMatchObject({ step: 'caller_has_it', who: 'caller' })
    // the seller's own yes later takes it over, keeping the comps
    const up = await one(`public.agent_offer_open($1, 'yes_to_selling', 'yes I would sell', '4145550100', 'Muse')`, [FRESH])
    expect(up).toMatchObject({ ok: true, upgraded: true })
  })

  it('the brief carries the angles, ranked, and the situation; an angle with no reason is refused', async () => {
    await valued(ESTATE)
    const owed = [{ kind: 'mortgage', creditor: 'the lender', amount: 34000, basis: 'register of deeds', follows_house: 'yes' },
      { kind: 'estate_claim', creditor: 'a hospital', amount: 194000, basis: 'court record', follows_house: 'no' }]
    expect(await brief(ESTATE, owed, [{ angle: 'close on their date' }])).toMatchObject({ ok: false })
    expect((await brief(ESTATE, owed, [{ angle: 'haul what is left in it', why: 'the son lives out of state and cannot empty it' },
      { angle: 'handle the estate papers', why: 'he has never sold a house through probate' }])).ok).toBe(true)
    const b = await one(`public.agent_call_brief_get($1)`, [ESTATE])
    expect(b.angles).toHaveLength(2)
    expect(b.situation).toMatch(/clears the mortgage/)
  })

  it('an agent prices it: the number must clear what follows the house, stay under the most we pay, and carry the situation', async () => {
    const note = 'Estate: claims of 194k on a 200k house do not follow it; only the 34k mortgage does. The son wants it gone.'
    expect(await one(`public.agent_deal_price($1, 40000, 45000, 'too short', 'Grok')`, [ESTATE])).toMatchObject({ ok: false })
    expect((await one(`public.agent_deal_price($1, 30000, 33000, $2, 'Grok')`, [ESTATE, note])).reason).toMatch(/cannot close/)
    expect((await one(`public.agent_deal_price($1, 150000, 190000, $2, 'Grok')`, [ESTATE, note])).reason).toMatch(/over the most we pay/)
    expect((await one(`public.agent_deal_price($1, 40000, 45000, $2, 'Grok')`, [ESTATE, note])).ok).toBe(true)
    const w = await one(`public.deal_sheet_work($1)`, [ESTATE])
    expect(w).toMatchObject({ stage: 'ready', source: 'agent', number: 40000, limit: 45000 })
    expect(w.agent.by).toBe('Grok')
    // no value on the card yet: comp it first
    expect((await one(`public.agent_deal_price($1, 40000, 45000, $2, 'Grok')`, [UNDER, note])).reason).toMatch(/comp it first/)
    // a mortgage more than we can pay: not a deal, whatever number is tried
    await valued(UNDER)
    await brief(UNDER, [{ kind: 'mortgage', creditor: 'the lender', amount: 170000, basis: 'register of deeds', follows_house: 'yes' }])
    expect((await one(`public.agent_deal_price($1, 100000, 115000, $2, 'Grok')`, [UNDER, note])).reason).toMatch(/cannot close/)
  })

  it("Colin's own number is still above the agent's", async () => {
    await asUser(COLIN, `select public.deal_sheet_colin($1, 38000, 42000, 'mine', false)`, [ESTATE])
    expect(await one(`public.deal_sheet_work($1)`, [ESTATE])).toMatchObject({ source: 'colin', number: 38000 })
  })
})

describe('0283: the button goes to Grok only, and the caller is told when it is ready (Colin 2026-11-22)', () => {
  it('Muse does not see or claim a card asked for from the button; Grok does; a prices alert says it was asked for', async () => {
    const id = '00000000-0000-0000-0000-00000000e284'
    await db.query(`insert into public.leads (id, wpie_owner_id, owner_name, lane, stage, property_address, municipality, county, mailing_state, locked_to, assigned_to)
      values ($1, 9814, 'BUTTON OWNER', 'flip', 'opener_sent', '4 ASK ST', 'CITY OF TEST', 'Brown', 'WI', 'adil', 'adil')`, [id])
    expect((await asUser<{ r: Json }>(TYLER, `select public.card_work_ask($1) as r`, [id]))[0].r.ok).toBe(true)
    const ids = async (who: string) => ((await one(`public.agent_live_work(now(), $1)`, [who])).cards ?? []).map((c: Json) => c.lead_id)
    expect(await ids('Muse')).not.toContain(id)
    expect(await ids('Grok')).toContain(id)
    expect((await one(`public.agent_work_claim($1, 'Muse')`, [id])).reason).toMatch(/Grok/)
    expect((await one(`public.agent_work_claim($1, 'Grok')`, [id])).ok).toBe(true)
    await db.query(`update public.text_offers set arv = 200000, comps = $2::jsonb, call_prices = $3::jsonb, valued_at = now() where lead_id = $1`,
      [id, JSON.stringify(comps([195000, 200000, 210000])), JSON.stringify(ROWS)])
    expect((await db.query(`select 1 from public.yes_ready_alerts where lead_id = $1 and kind = 'prices'`, [id])).rows).toHaveLength(1)
    // the seller says yes: the card is the yes path again, which Muse works too
    await one(`public.agent_offer_open($1, 'yes_to_selling', 'yes', '4145550101', 'Muse')`, [id])
    expect(await one(`public.card_asked_for_grok($1)`, [id])).toBe(false)
  })
})
