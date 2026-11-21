// 0266 (Colin 2026-11-20: "Muse can comp and have it done I think in under 10 min. Without that I doubt we can trust
// anything else."). A seller says yes: an offer opens with the comp due in 10 minutes and Muse's first step is the
// comp; the caller's call task and card say when the number is promised, then carry it: an opening and a top for
// light, medium and heavy repairs, or the one pair once the seller has said what is wrong. No comp set, no number.
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
const YES = '00000000-0000-0000-0000-00000000e001'
const THIN = '00000000-0000-0000-0000-00000000e002'
const one = async <T>(sql: string, params: unknown[] = []) => (await db.query<{ v: T }>(`select ${sql} as v`, params)).rows[0].v
const svc = async <T>(sql: string, params: unknown[] = []) => {
  await db.exec('set role service_role')
  try { return (await db.query<{ v: T }>(`select ${sql} as v`, params)).rows[0].v } finally { await db.exec('reset role') }
}
const asUser = async <T>(email: string, sql: string, params: unknown[] = []) => {
  await db.query(`select set_config('request.jwt.claims', $1, false)`, [JSON.stringify({ email })])
  await db.exec('set role authenticated')
  try { return (await db.query<T>(sql, params)).rows } finally { await db.exec('reset role'); await db.query(`select set_config('request.jwt.claims', '', false)`) }
}
const taskNote = async (lead: string) => one<string>(`(select note from public.tasks where lead_id = $1 and source = 'belt' and done_at is null)`, [lead])
const comps = (n: number) => Array.from({ length: n }, (_, i) => ({ address: `${10 + i} Near St`, sold_price: 200000 + i * 5000, sold_date: '2026-09-01', sqft: 1400 }))

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
  await db.exec(`
    insert into public.team_members (email, role, person, display_name) values
      ('colin@example.com', 'owner', 'colin', 'Colin'), ('adil@example.com', 'caller', 'adil', 'Tyler')
    on conflict (email) do update set role = excluded.role, person = excluded.person, display_name = excluded.display_name;
    insert into public.leads (id, wpie_owner_id, owner_name, lane, stage, property_address, municipality, mailing_state, locked_to, assigned_to) values
      ('${YES}', 9401, 'PAT SELLER', 'flip', 'reply_received', '1208 RACINE ST', 'CITY OF TEST', 'WI', 'adil', 'adil'),
      ('${THIN}', 9402, 'THIN COMPS', 'flip', 'reply_received', '9 FAR RD', 'TOWN OF TEST', 'WI', 'adil', 'adil');`)
}, 180_000)

describe('a yes gets a comp, and the caller gets the number', () => {
  it('the yes opens the comp, due in 10 minutes, and it is Muse\'s first step; the caller is told when the number is promised', async () => {
    await db.exec(`update public.leads set belt = 'yes_unbooked', belt_step = 1 where id = '${YES}'`)
    const o = (await db.query<Json>(`select trigger, opened_by, status, round(extract(epoch from comp_due_at - opened_at) / 60) mins from public.text_offers where lead_id = $1`, [YES])).rows
    expect(o).toEqual([{ trigger: 'yes_to_selling', opened_by: 'system', status: 'open', mins: '10' }])
    const v = await one<Json>(`public.text_offer_view((select t from public.text_offers t where lead_id = $1), now())`, [YES])
    expect(v).toMatchObject({ step: 'comp', who: 'muse', late: false })                       // the comp, not the condition question
    expect(v.say).toMatch(/^They said YES and a caller is being told to phone them\. Comp it NOW, inside 10 minutes/)
    expect((await one<Json>(`public.text_offer_view((select t from public.text_offers t where lead_id = $1), now() + interval '11 minutes')`, [YES])).late).toBe(true)
    // the belt writes the caller's call task: it starts with the sheet
    await db.query(`insert into public.tasks (lead_id, due_at, kind, owner, source, title, note) values ($1, now(), 'call', 'adil', 'belt', 'Said yes, not booked: stop 1 of 4', 'Say: You asked for a call about 1208 RACINE ST. Call (262) 555-0101 (mobile)')`, [YES])
    const note = await taskNote(YES)
    expect(note).toMatch(/^NUMBER: Muse is working out the value now\. It will be on this card by \d{1,2}:\d\d [AP]M\. Calling before then: get the story and their number, and give none\.\nSTORY: Muse is writing the story and a script for this call, on the card by \d{1,2}:\d\d [AP]M\.\nSay: You asked for a call about 1208 RACINE ST/)   // 0267: the story is asked for too
    // ten minutes on with no comp: the card says so
    expect(await one<string>(`public.yes_call_sheet($1, now() + interval '12 minutes')`, [YES])).toMatch(/^NUMBER: no value yet \(it was due .*\)\. Call for the story and their number, and give none\.$/)
  })

  it('the value alone gives the caller no number: the prices are Muse\'s, from a look at the house (0268)', async () => {
    const r = await svc<Json>(`public.agent_offer_update($1::jsonb, 'Muse')`, [JSON.stringify({ lead_id: YES, arv: 210000, arv_basis: 'three sold within half a mile, 90 days', comps: comps(3), sqft: 1400 })])
    expect(r.ok).toBe(true)
    expect(r.offer.next).toMatchObject({ step: 'call_prices', who: 'muse', gate: 'the prices for the call' })
    expect(r.offer.next.say).toMatch(/Look at the house on Street View/)
    const waiting = 'NUMBER: Value fixed up $210,000 (Muse, 3 sold comps, 1,400 sq ft). Muse has not put its prices by condition on this card yet. Call for the story, the condition and their number, and give none.'
    expect((await taskNote(YES)).split('\n')[0]).toBe(waiting)
    const upd = async (body: Json) => svc<Json>(`public.agent_offer_update($1::jsonb, 'Muse')`, [JSON.stringify({ lead_id: YES, ...body })])
    const street = { image_date: 'June 2023', seen: [{ item: 'roof', cost: 12000, note: 'shingles curling, a tarp on the back slope' }], notes: 'lawn kept, cars in the drive' }
    const light = { inside: 'Inside light', repairs: 33000, repairs_basis: 'roof 12,000 + paint and floors at $15 a sq ft', open: 103500, top: 114000 }
    const heavy = { inside: 'Inside heavy', repairs: 96000, repairs_basis: 'roof 12,000 + a full gut at $60 a sq ft', open: 40500, top: 51000 }
    // prices with no look at the house, a look with no date, one row only: each is refused with the reason
    expect((await upd({ call_prices: [light, heavy] })).reason).toMatch(/^send street: what you saw of the house on Street View/)
    expect((await upd({ street: { seen: [] }, call_prices: [light, heavy] })).reason).toMatch(/^street\.image_date/)
    expect((await upd({ street, call_prices: [light] })).reason).toMatch(/^call_prices is two to five rows \(you sent 1\)/)
    // what shows from the street is in every row
    expect((await upd({ street, call_prices: [{ ...light, repairs: 8000 }, heavy] })).reason)
      .toBe('the row "Inside light" has repairs of $8,000, less than what you saw from the street ($12,000: roof). What shows from the street is in every row')
    // and no top above Colin's standing most for those repairs
    expect((await upd({ street, call_prices: [{ ...light, top: 120000 }, heavy] })).reason)
      .toBe('the row "Inside light": a top of $120,000 is above the most Colin\'s rule allows for those repairs (70% of $210,000 minus $33,000 = $114,000)')
    expect((await taskNote(YES)).split('\n')[0]).toBe(waiting)
    const ok = await upd({ street, call_prices: [light, heavy, { inside: 'Fire or foundation', repairs: 160000, repairs_basis: 'roof 12,000 + structural', no_offer: true }] })
    expect(ok.ok).toBe(true)
    expect(ok.offer.next.step).not.toBe('call_prices')
    expect(ok.offer.comp.call_prices).toHaveLength(3)
    const sheet = 'NUMBER: Value fixed up $210,000 (Muse, 3 sold comps, 1,400 sq ft). From the street (picture from June 2023): roof (shingles curling, a tarp on the back slope). That is already in every row. Ask what shape the inside is in, then use that row. Inside light: open $103,500, top $114,000 (repairs $33,000). Inside heavy: open $40,500, top $51,000 (repairs $96,000). Fire or foundation: no offer (repairs $160,000 eat it).'
    const lines = (await taskNote(YES)).split('\n')
    expect([lines[0], lines[2]]).toEqual([sheet, 'Say: You asked for a call about 1208 RACINE ST. Call (262) 555-0101 (mobile)'])
    expect(lines[1]).toMatch(/^STORY: Muse is writing the story/)
    const brief = (await asUser<{ r: Json }>('adil@example.com', `select public.card_brief($1) as r`, [YES]))[0].r
    expect(brief.call_sheet).toBe(sheet)
    // what the seller names by text still gives the rule's figure for a text; the caller's sheet stays Muse's rows, one line
    const named = await upd({ condition_words: 'roof leaks, furnace is dead', repair_items: ['roof', 'furnace'] })
    expect(named.offer.numbers).toMatchObject({ offer: 117000, most: 127500 })
    const after = await taskNote(YES)
    expect(after.split('\n')[0]).toBe(sheet)
    expect(after.match(/NUMBER:/g)).toHaveLength(1)
    // a new value: prices worked from the old one do not stand
    const revalued = await upd({ arv: 190000, arv_basis: 'a fourth sale closed lower', comps: comps(4) })
    expect(revalued.offer.comp.call_prices).toBeNull()
    expect((await taskNote(YES)).split('\n')[0]).toMatch(/^NUMBER: Value fixed up \$190,000 \(Muse, 4 sold comps, 1,400 sq ft\)\. Open at /)
    // no picture of the house: said so, and the caller is told nothing outside is priced in
    const blind = await upd({ street: { no_view: true, why: 'a private road, the nearest picture is 400 feet off' },
      call_prices: [{ inside: 'Inside light', repairs: 21000, repairs_basis: '$15 a sq ft', open: 102500, top: 112000 }, { inside: 'Inside heavy', repairs: 84000, repairs_basis: '$60 a sq ft', open: 39500, top: 49000 }] })
    expect(blind.ok).toBe(true)
    expect((await taskNote(YES)).split('\n')[0]).toMatch(/No street picture of this house \(a private road, the nearest picture is 400 feet off\), so nothing outside is priced in: ask about the roof and the outside too\. Ask what shape the inside is in/)
  })

  it('fewer sold comps than the rule needs is no number; a card with no yes waiting has no sheet; a closed offer clears the task', async () => {
    await db.exec(`update public.leads set belt = 'yes_unbooked', belt_step = 1 where id = '${THIN}'`)
    await db.query(`insert into public.tasks (lead_id, due_at, kind, owner, source, title, note) values ($1, now(), 'call', 'adil', 'belt', 'Said yes, not booked: stop 1 of 4', 'Say: You asked for a call about 9 FAR RD.')`, [THIN])
    await svc(`public.agent_offer_update($1::jsonb, 'Muse')`, [JSON.stringify({ lead_id: THIN, arv: 150000, arv_basis: 'two sales, both a mile off', comps: comps(2), sqft: 1100 })])
    const thin = (await taskNote(THIN)).split('\n')
    expect([thin[0], thin.at(-1)]).toEqual(['NUMBER: only 2 sold comps near this house, not enough to offer from. Call for the story and their number, and give none.', 'Say: You asked for a call about 9 FAR RD.'])
    expect((await one<Json>(`public.text_offer_view((select t from public.text_offers t where lead_id = $1), now())`, [THIN])).step).toBe('comp')   // still Muse's: add comps or close
    await svc(`public.agent_offer_close((select id from public.text_offers where lead_id = $1), 'no_comp_set', 'nothing sold nearby', 'Muse')`, [THIN])
    expect(await one<string | null>(`public.yes_call_sheet($1)`, [THIN])).toBeNull()
    expect(await taskNote(THIN)).not.toMatch(/NUMBER:/)                              // the number line goes; the story line stays while Muse writes it
    expect((await taskNote(THIN)).split('\n').at(-1)).toBe('Say: You asked for a call about 9 FAR RD.')
    // a second yes on a card whose offer is already open does not open another
    await db.exec(`update public.leads set belt = 'call_missed' where id = '${YES}'; update public.leads set belt = 'yes_unbooked' where id = '${YES}';`)
    expect(await one<number>(`(select count(*)::int from public.text_offers where lead_id = $1)`, [YES])).toBe(1)
  })
})
