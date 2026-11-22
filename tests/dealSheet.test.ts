// 0270, the deal sheet (Colin 2026-11-21: "how can this be designed so thalia and Tyler, people from overseas with no
// knowledge of our local market, can capture insane value on properties without becoming specialists"). One sheet a
// card, worked by the server: the seller's own arithmetic, the kind of seller that makes them, the number to say, the
// steps a caller may go up, and a gate that sends anything the formula does not fit to Colin.
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
const HOWARD = '00000000-0000-0000-0000-00000000d001'   // Tyler's: an estate that owes more than the house brings
const EQUITY = '00000000-0000-0000-0000-00000000d002'   // Tyler's: owes a little, keeps the difference
const TRAILER = '00000000-0000-0000-0000-00000000d003'  // Tyler's: a manufactured home
const THALIAS = '00000000-0000-0000-0000-00000000d004'  // Thalia's card
const COLIN = 'colin@example.com', TYLER = 'adil@example.com', THALIA = 'thalia@example.com'

const asUser = async <T = Json>(email: string, sql: string, params: unknown[] = []) => {
  await db.query(`select set_config('request.jwt.claims', $1, false)`, [JSON.stringify({ email })])
  await db.exec('set role authenticated')
  try { return (await db.query<T>(sql, params)).rows } finally { await db.exec('reset role'); await db.query(`select set_config('request.jwt.claims', '', false)`) }
}
const sheet = async (email: string, lead: string) => (await asUser<{ r: Json | null }>(email, `select public.deal_sheet_get($1) as r`, [lead]))[0].r
const call = async (email: string, sql: string, params: unknown[] = []) => (await asUser<{ r: Json }>(email, `select ${sql} as r`, params))[0].r
const comps = (prices: number[]) => prices.map((p, i) => ({ address: `${10 + i} Near St`, sold_price: p, sold_date: `2026-0${i + 4}-15`, sqft: 1300 }))
const ROWS = (light: number, heavy: number) => [
  { inside: 'Inside light', repairs: light, repairs_basis: 'paint and floors', open: 1, top: 2 },
  { inside: 'Inside heavy', repairs: heavy, repairs_basis: 'kitchen, baths, furnace', open: 1, top: 2 }]
const offer = async (lead: string, f: Json) => {
  await db.query(`insert into public.text_offers (lead_id, opened_by, trigger, trigger_text) values ($1, 'system', 'yes_to_selling', 'yes')`, [lead])
  await db.query(`update public.text_offers set arv = $2, sqft = 1300, arv_basis = $3, comps = $4::jsonb, street = $5::jsonb, call_prices = $6::jsonb, property_kind = $7,
    valued_at = now(), valued_by = 'Muse' where lead_id = $1`,
    [lead, f.arv, f.basis ?? 'three sold on the next streets', JSON.stringify(f.comps), JSON.stringify(f.street ?? { image_date: 'June 2025', seen: [] }),
      JSON.stringify(f.rows), f.kind ?? null])
}
const brief = async (lead: string, owed: Json[], toClear: number, total: number) =>
  db.query(`insert into public.call_briefs (lead_id, status, story, owed, script, to_clear, owed_total, written_by, written_at)
            values ($1, 'ready', 'story', $2::jsonb, 'script', $3, $4, 'Muse', now())`, [lead, JSON.stringify(owed), toClear, total])

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
  await db.exec(`
    insert into public.team_members (email, role, person, display_name) values
      ('${COLIN}', 'owner', 'colin', 'Colin'), ('${TYLER}', 'caller', 'adil', 'Tyler'), ('${THALIA}', 'caller', 'thalia', 'Thalia')
    on conflict (email) do update set role = excluded.role, person = excluded.person, display_name = excluded.display_name;
    insert into public.leads (id, wpie_owner_id, owner_name, lane, stage, property_address, municipality, county, mailing_state, locked_to, assigned_to) values
      ('${HOWARD}', 9701, 'ESTATE OF TEST', 'flip', 'colin_call', '991 TEST ST', 'CITY OF TEST', 'Brown', 'WI', 'adil', 'adil'),
      ('${EQUITY}', 9702, 'EQUITY OWNER', 'flip', 'colin_call', '24 KEEP ST', 'CITY OF TEST', 'Brown', 'WI', 'adil', 'adil'),
      ('${TRAILER}', 9703, 'TRAILER OWNER', 'flip', 'colin_call', 'N1 LOVE LN', 'TOWN OF TEST', 'Marinette', 'WI', 'adil', 'adil'),
      ('${THALIAS}', 9704, 'OTHER SELLER', 'flip', 'colin_call', '5 OTHER ST', 'CITY OF TEST', 'Brown', 'WI', 'thalia', 'thalia');`)
  // Howard St's shape: about 200 finished, 20 of work, a 34 mortgage that follows the house, 194 of estate claims that do not
  await offer(HOWARD, { arv: 200000, comps: comps([195000, 200000, 210000]), rows: ROWS(12000, 20000) })
  await brief(HOWARD, [{ kind: 'mortgage', creditor: 'the lender', amount: 34000, basis: 'the seller said', follows_house: 'yes' },
    { kind: 'estate_claim', creditor: 'a hospital', amount: 194000, basis: 'court record', follows_house: 'no' }], 34000, 228000)
  await offer(EQUITY, { arv: 200000, comps: comps([190000, 200000, 215000]), rows: ROWS(25000, 40000) })
  await brief(EQUITY, [{ kind: 'tax', creditor: 'the city', amount: 20000, basis: 'tax roll', follows_house: 'yes' },
    { kind: 'mortgage', creditor: null, amount: null, basis: 'none on record, never confirmed', follows_house: 'unknown' }], 20000, 20000)
  await offer(TRAILER, { arv: 213000, comps: comps([147000, 213000, 249000]), rows: ROWS(25000, 100000), kind: 'manufactured', street: { no_view: true, why: 'no coverage' } })
  await brief(TRAILER, [{ kind: 'tax', creditor: 'the county', amount: 6000, basis: 'tax roll', follows_house: 'yes' }], 6000, 6000)
}, 180_000)

describe('the deal sheet', () => {
  it('ships for Colin only: a caller gets nothing until it is switched on, and never another caller\'s card', async () => {
    expect(await sheet(TYLER, HOWARD)).toBeNull()
    const c = await sheet(COLIN, HOWARD)
    expect(c).toMatchObject({ mode: 'owner', owner: true, stage: 'ready' })
    await call(COLIN, `public.deal_sheet_mode('on')`)
    expect(await sheet(TYLER, HOWARD)).toMatchObject({ owner: false, stage: 'ready' })
    await expect(sheet(THALIA, HOWARD)).rejects.toThrow()
  })

  it('a seller the price cannot reach: the number is what clears the debts that follow the house, plus walking money', async () => {
    const c = (await sheet(COLIN, HOWARD))!
    // 200,000 - 20,000 of work (the heaviest row until they say) - 20,000 to sell it - 34,000 - 194,000 = nothing
    expect(c.math).toMatchObject({ finished: 200000, needs: 20000, needs_assumed: true, selling_costs: 20000, to_clear: 34000, other_owed: 194000, walk_away: -68000, owed_known: true })
    expect(c.math.cost_words).toBe('6% to an agent, 2% closing, 4 months of taxes and upkeep')
    expect(c).toMatchObject({ kind: 'nothing_left', source: 'math', number: 39000, ceiling: 120000, rule_opening: 110000, gap: 81000, limit: 79500 })
    expect(c.steps).toEqual([39000, 59000, 79500])                // Colin signed the real one at 60,000
    expect(c.comps.map((x: Json) => x.address)).toEqual(['11 Near St', '10 Near St', '12 Near St'])   // nearest the value first
    // the caller sees the number and the steps, never our ceiling or the room under it
    const t = (await sheet(TYLER, HOWARD))!
    expect(t).toMatchObject({ number: 39000, steps: [39000, 59000, 79500], kind: 'nothing_left' })
    for (const k of ['ceiling', 'rule_opening', 'gap', 'gate']) expect(t).not.toHaveProperty(k)
  })

  it('what is owed has to be known first: an open line on the brief waits for the caller to ask', async () => {
    const before = (await sheet(TYLER, EQUITY))!
    expect(before).toMatchObject({ stage: 'needs_owed', number: null })
    expect(before.missing).toEqual([{ what: 'what is owed: ask them on the call, then tap the answer', who: 'caller' }])
    expect(before.math.open_owed).toEqual([{ kind: 'mortgage', creditor: null, basis: 'none on record, never confirmed' }])
    // they say they owe 60,000: 200,000 - 40,000 - 20,000 - 60,000 = 80,000 left for them; we open at 80% of that
    const said = await call(TYLER, `public.deal_sheet_fact($1, 'owed_said', '60000'::jsonb)`, [EQUITY])
    expect(said.sheet).toMatchObject({ stage: 'ready', kind: 'some_left', number: 64000, steps: [64000, 73000, 82000] })
    expect(said.sheet.math).toMatchObject({ to_clear: 60000, walk_away: 80000 })
    // the inside is lighter than assumed: less work, more left for them, and a number the rule's opening now caps
    const lighter = await call(TYLER, `public.deal_sheet_inside($1, 0)`, [EQUITY])
    expect(lighter.sheet.math).toMatchObject({ needs: 25000, needs_assumed: false, walk_away: 95000 })
    expect(lighter.sheet).toMatchObject({ kind: 'some_left', number: 76000 })
    await call(TYLER, `public.deal_sheet_inside($1, 1)`, [EQUITY])
  })

  it('a seller who keeps the difference gets no number, unless their own floor is under the rule\'s opening', async () => {
    await call(TYLER, `public.deal_sheet_fact($1, 'owed_said', null)`, [EQUITY])
    await call(TYLER, `public.deal_sheet_fact($1, 'owed_nothing', 'true'::jsonb)`, [EQUITY])
    // owes only the 20,000 of taxes: 120,000 left for them, more than the 100,000 we could ever pay
    const a = (await sheet(COLIN, EQUITY))!
    expect(a).toMatchObject({ stage: 'no_number', kind: 'a_lot', number: null, ceiling: 100000 })
    expect(a.why).toMatch(/^Selling it the usual way leaves them more than we can pay/)
    // they say they would not go under 55,000: far under, so the card takes theirs
    const f = await call(TYLER, `public.deal_sheet_fact($1, 'floor', '55000'::jsonb)`, [EQUITY])
    expect(f.sheet).toMatchObject({ stage: 'ready', source: 'their_floor', number: 55000, steps: [55000, 66000, 77500] })
    // a floor that leaves too little room under the ceiling is Colin's, not a caller's
    const thin = await call(TYLER, `public.deal_sheet_fact($1, 'floor', '85000'::jsonb)`, [EQUITY])
    expect(thin.sheet).toMatchObject({ stage: 'colin_prices', number: null })
    expect(thin.sheet.why).toBe('Thin: the number would be only $15,000 under the most we can pay.')
    await call(TYLER, `public.deal_sheet_fact($1, 'floor', '55000'::jsonb)`, [EQUITY])
  })

  it('anything the formula does not fit goes to Colin: a manufactured home, no picture, comps far apart, a value far from the county\'s', async () => {
    const c = (await sheet(COLIN, TRAILER))!
    expect(c).toMatchObject({ stage: 'colin_prices', number: null, property_kind: 'manufactured' })
    expect(c.gate).toEqual(['it is a manufactured home', 'there is no street picture of it'])
    expect(c.missing).toEqual([{ what: 'a number for this one', who: 'colin' }])
    expect((await sheet(TYLER, TRAILER))!.why).toBe('No formula number: it is a manufactured home; there is no street picture of it.')
    // an ordinary house with comps from 90 to 230 and a value twice the county's
    await db.query(`update public.text_offers set comps = $2::jsonb where lead_id = $1`, [HOWARD, JSON.stringify(comps([90000, 200000, 230000]))])
    await db.query(`insert into public.equity_inputs (lead_id, est_market_value) values ($1, 95000)`, [HOWARD])
    await db.query(`update public.text_offers set street = '{"image_date": "Aug 2019", "seen": []}'::jsonb where lead_id = $1`, [HOWARD])
    expect((await sheet(COLIN, HOWARD))!.gate).toEqual(['the comps run from $90,000 to $230,000', 'Muse has it at $200,000 and the county at $95,000', 'the street picture is from 2019'])
    await db.query(`update public.text_offers set comps = $2::jsonb, street = '{"image_date": "June 2025", "seen": []}'::jsonb where lead_id = $1`, [HOWARD, JSON.stringify(comps([195000, 200000, 210000]))])
    await db.query(`delete from public.equity_inputs where lead_id = $1`, [HOWARD])
  })

  it('Colin\'s own number is the only one the card then shows, and the card\'s caller is told', async () => {
    await expect(call(TYLER, `public.deal_sheet_colin($1, 30000)`, [TRAILER])).rejects.toThrow(/only Colin/)
    const r = await call(COLIN, `public.deal_sheet_colin($1, 30000, 35000, 'a double-wide on piers, 2007 photos')`, [TRAILER])
    expect(r.sheet).toMatchObject({ stage: 'ready', source: 'colin', number: 30000, limit: 35000, steps: [30000, 32500, 35000], why: 'a double-wide on piers, 2007 photos' })
    const t = (await db.query<Json>(`select owner::text, title, note from public.tasks where lead_id = $1 and kind = 'nudge' order by created_at desc limit 1`, [TRAILER])).rows[0]
    expect(t).toEqual({ owner: 'adil', title: 'Heads-up from Colin', note: 'Colin\'s number is on the card for N1 LOVE LN. Open the Deal sheet before you call.' })
    const pass = await call(COLIN, `public.deal_sheet_colin($1, null, null, 'not our kind of house', true)`, [TRAILER])
    expect(pass.sheet).toMatchObject({ stage: 'passed', number: null, why: 'not our kind of house' })
    await call(COLIN, `public.deal_sheet_colin($1, 30000, 35000, 'a double-wide on piers, 2007 photos')`, [TRAILER])
  })

  it('a caller records only a number the card showed; a yes lets Send offer go out at it; past the limit is one tap to Colin', async () => {
    const no = await call(TYLER, `public.deal_sheet_said($1, 45000, 'yes')`, [HOWARD])
    expect(no).toEqual({ ok: false, reason: '$45,000 is not a number this card shows. Say only the number on the sheet; anything else is Colin\'s.' })
    const first = await call(TYLER, `public.deal_sheet_said($1, 39000, 'counter', 'we were told three hundred', 90000)`, [HOWARD])
    expect(first.sheet.said).toHaveLength(1)
    expect((await db.query<{ v: number | null }>(`select public.offer_colin_number($1) as v`, [HOWARD])).rows[0].v).toBeNull()
    const yes = await call(TYLER, `public.deal_sheet_said($1, 59000, 'yes', 'okay, let us be done with it')`, [HOWARD])
    expect(yes.sheet.said.map((e: Json) => [e.number, e.response, e.by])).toEqual([[39000, 'counter', 'adil'], [59000, 'yes', 'adil']])
    expect(Number((await db.query<{ v: string }>(`select public.offer_colin_number($1) as v`, [HOWARD])).rows[0].v)).toBe(59000)
    const note = (await db.query<{ body: string }>(`select body from public.messages where lead_id = $1 and channel = 'note' order by created_at desc limit 1`, [HOWARD])).rows[0].body
    expect(note).toBe('Deal sheet: Adil said $59,000. They said: yes. "okay, let us be done with it".')
    const ask = await call(TYLER, `public.deal_sheet_ask_colin($1, 'they will sign today at 85, the sister is on the line')`, [EQUITY])
    expect(ask.ok).toBe(true)
    const t = (await db.query<Json>(`select owner::text, title, note from public.tasks where id = $1`, [ask.task_id])).rows[0]
    expect(t).toEqual({ owner: 'colin', title: 'Number wanted by Adil', note: 'Deal sheet, 24 KEEP ST: they will sign today at 85, the sister is on the line' })
    expect((await sheet(COLIN, EQUITY))!.colin.asked_words).toBe('they will sign today at 85, the sister is on the line')
  })

  it('with the sheet on, the yes task points at it; switched back to Colin only, callers see nothing and Send offer falls back', async () => {
    expect((await db.query<{ v: string }>(`select public.yes_call_sheet($1) as v`, [HOWARD])).rows[0].v)
      .toBe('NUMBER: the number, the reason and the words are on the card under Deal sheet. Read it before you dial.')
    await expect(call(TYLER, `public.deal_sheet_mode('off')`)).rejects.toThrow(/only Colin/)
    await call(COLIN, `public.deal_sheet_mode('owner')`)
    expect(await sheet(TYLER, HOWARD)).toBeNull()
    expect((await db.query<{ v: number | null }>(`select public.offer_colin_number($1) as v`, [HOWARD])).rows[0].v).toBeNull()
    expect((await db.query<{ v: string }>(`select public.yes_call_sheet($1) as v`, [HOWARD])).rows[0].v).toMatch(/^NUMBER: Value fixed up \$200,000/)
    const set = await call(COLIN, `public.deal_sheet_rules_set('{"walk_money": 8000, "min_gap": 25000}'::jsonb)`)
    expect(set.rules).toMatchObject({ walk_money: 8000, min_gap: 25000 })
    expect((await sheet(COLIN, HOWARD))!.number).toBe(42000)
  })

  it('no login reads the sheets table itself', async () => {
    await expect(asUser(THALIA, `select count(*) from public.deal_sheets`)).rejects.toThrow(/permission denied/)
  })
})

// 0294, 0295 (Colin 2026-11-22, 226 60th Ave, Somers: "you'll see how Tyler can't figure out wtf is going on"). The
// sheet ended in a bold walk-away total with no number of ours; the caller texted it to the seller as an offer.
describe('the sheet says what to do about price', () => {
  const SOMERS = '00000000-0000-0000-0000-00000000d005'
  const work = async (lead = SOMERS) => (await db.query<{ r: Json }>(`select public.deal_sheet_work($1) as r`, [lead])).rows[0].r

  it('every stage carries one plain line; with no number it says not to say or text a price', async () => {
    await db.query(`insert into public.leads (id, wpie_owner_id, owner_name, lane, stage, property_address, municipality, county, mailing_state, locked_to, assigned_to)
                    values ($1, 9705, 'NOT AVAILABLE', 'flip', 'reply_received', '226 TEST AVE', 'Somers', 'Kenosha', 'WI', 'adil', 'adil')`, [SOMERS])
    await offer(SOMERS, { arv: 395000, comps: comps([373750, 383000, 432000]), rows: ROWS(20000, 85000) })
    await brief(SOMERS, [{ kind: 'mortgage', creditor: 'unknown', amount: null, basis: 'deed index not searched', follows_house: 'yes' }], 0, 0)
    const w = await work()
    expect(w).toMatchObject({ stage: 'needs_owed', number: null })
    expect(w.verdict.say).toBe('You have no number for this house. Do not say or text any price.')
    expect(w.verdict.next).toMatch(/Ask what is owed \(step 3\)/)
    // a card with a number says the number
    const h = await work(HOWARD)
    expect(h.stage).toBe('ready')
    expect(h.verdict.say).toBe(`Your number is $${Number(h.number).toLocaleString('en-US')}. Say it once, on a call, after step 5.`)
  })

  it('what the seller texted counts: a number over the finished price means no number, whatever is owed', async () => {
    await db.query(`insert into public.reply_drafts (lead_id, phone10, inbound_at, kind, status, facts)
                    values ($1, '2625550100', now(), 'routine', 'sent', $2::jsonb)`,
      [SOMERS, JSON.stringify({ price_expectation: '$500,000', condition: '2 new bathrooms, new kitchen', decision_makers: 'Only her on title', occupancy: 'owner' })])
    const w = await work()
    expect(w).toMatchObject({ stage: 'apart', number: null, theirs: { number: 500000, number_from: 'text' } })
    expect(w.verdict.say).toBe('You have no number for this house. Do not say or text any price.')
    expect(w.verdict.next).toMatch(/They want \$500,000\. Finished, houses like it sell for about \$395,000/)
    expect(w.verdict.next).toMatch(/rest the card/)
    expect(w.texted).toMatchObject({ condition: '2 new bathrooms, new kitchen', who_signs: 'Only her on title' })
    // a floor under the finished price, said on a call, takes the card back to the sheet's own arithmetic
    await db.query(`insert into public.deal_sheets (lead_id, facts) values ($1, '{"floor": 150000}'::jsonb)
                    on conflict (lead_id) do update set facts = excluded.facts`, [SOMERS])
    expect((await work()).stage).toBe('needs_owed')
  })

  it('money as people write it: "$500,000", "140k", "1.2 million"; a bare small figure is not guessed at', async () => {
    const m = async (s: string) => (await db.query<{ v: string | null }>(`select public.money_said($1) as v`, [s])).rows[0].v
    expect(Number(await m('$500,000'))).toBe(500000)
    expect(Number(await m('about 140k'))).toBe(140000)
    expect(Number(await m('$1.2 million'))).toBe(1200000)
    expect(await m('3 bed, 2 bath')).toBeNull()
    expect(await m('make me an offer')).toBeNull()
  })

  it('a call script that gives the caller a price is refused: the number is the Deal sheet\'s alone', async () => {
    const owed = [{ kind: 'mortgage', creditor: 'unknown', amount: null, basis: 'deed index not searched', follows_house: 'yes' }]
    const body = (money: string) => ({ lead_id: SOMERS, owed, unknowns: ['the mortgage'], sources: 'tax roll',
      story: 'The person who answered says she owns the house and lives in it. Nothing on record presses a sale. The mortgage is not known.',
      script: `**Open**\n"Hi, this is the caller, I texted you about the house. Can I ask a few quick questions first?"\n${'Ask who is on the title and who decides. '.repeat(8)}\n**Money**\n${money}\n**Close**\nBook a time.` })
    const set = async (money: string) => (await db.query<{ r: Json }>(`select public.agent_call_brief_set($1::jsonb, 'Grok') as r`, [JSON.stringify(body(money))])).rows[0].r
    const bad = await set('Cosmetic only: open $236,800, no higher than $256,500.')
    expect(bad.ok).toBe(false)
    expect(bad.reason).toMatch(/gives the caller a price/)
    expect(bad.reason).toMatch(/Deal sheet/)
    // what is owed, the finished price and the seller's own number may stay
    const ok = await set('She has said she wants $500,000. Finished, it sells for about $395,000. Your number is the one on the Deal sheet; if it shows none, give none.')
    expect(ok.ok).toBe(true)
    const packet = (await db.query<{ body: string }>(`select body from public.live_work_packet limit 1`)).rows[0].body
    expect(packet).not.toMatch(/use the rows you stored in call_prices/)
    expect(packet).toMatch(/name NO price of ours/)
  })
})
