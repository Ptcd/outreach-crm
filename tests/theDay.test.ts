// The day (0219): one list a day, built by the server from the whole store by one set of rules. On the real
// migrations: which cards are ready and the one reason each of the others is not; the order of the list (a floor of
// new people, then the follow-ups that are due, then more new people); ready_to_text serving that list; the queue
// refusing what the records forbid, a second name in a thread and a STOP line on a follow-up; the evening report on
// the desk; the backstop writing the settled wording when it is switched on.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')
const NOW = '2026-11-12T16:00:00Z'          // Thursday 10:00 AM Central
const TODAY = '2026-11-12'

let db: PGlite
const rows = async <T>(sql: string, params: unknown[] = []) => (await db.query<T>(sql, params)).rows
const one = async <T>(sql: string, params: unknown[] = []) => (await rows<{ r: T }>(`select ${sql} as r`, params))[0].r

type CardOpts = { owner: string; address?: string; lockedTo?: 'thalia' | 'adil'; reasons?: string[]; phone?: string; lineType?: string; parked?: boolean; stage?: string }
const card = async (ownerId: number, o: CardOpts) => {
  const id = (await rows<{ id: string }>(
    `insert into public.leads (wpie_owner_id, owner_name, lane, stage, property_address, locked_to, reasons_to_sell, parked_at, mailing_state)
     values ($1, $2, 'flip', $3::public.lead_stage, $4, $5::public.team_person, $6, $7, 'WI') returning id`,
    [ownerId, o.owner, o.stage ?? 'opener_queued', o.address ?? `${Math.abs(ownerId)} Test St`, o.lockedTo ?? 'thalia', o.reasons ?? [],
      o.parked ? NOW : null]))[0].id
  if (o.phone !== '') {
    const p = o.phone ?? `414555${String(1000 + Math.abs(ownerId)).slice(-4)}`
    await db.query(`insert into public.contacts (lead_id, kind, value, value_normalized, line_type, person_name) values ($1, 'phone', $2, $2, $3, $4)`,
      [id, p, o.lineType ?? 'mobile', o.owner])
  }
  return id
}
const fit = (ownerId: number, verdict: string, x: { need?: boolean; tier?: string; equity?: string; sale?: string | null; asOf?: string } = {}) =>
  db.query(`insert into public.text_fitness (wpie_owner_id, verdict, need, need_why, tier, equity, sale_date, as_of)
            values ($1, $2, $3, 'test', $4, $5, $6, $7)`,
    [ownerId, verdict, x.need ?? true, x.tier ?? null, x.equity ?? 'unknown', x.sale ?? null, x.asOf ?? TODAY])
const pool = () => rows<{ lead_id: string; kind: string; step: number; block: string | null; ord: string; tier: string | null }>(
  `select lead_id, kind, step, block, ord, tier from public.text_pool($1) order by kind, ord`, [NOW])
const queue = (lead: string, phone: string, body: string, step = 1, now = NOW) =>
  one<{ status: string; reason?: string }>(`public.agent_queue_text($1, $2, $3, $4, null, 'Muse', $5)`, [lead, phone, body, step, now])
const phoneOf = async (lead: string) => (await rows<{ v: string }>(`select value_normalized v from public.contacts where lead_id = $1 limit 1`, [lead]))[0].v

const C: Record<string, string> = {}

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
  await db.exec(`insert into public.team_members (email, role, person, display_name) values
    ('colin@example.com', 'owner', 'colin', 'Colin'), ('thalia@example.com', 'caller', 'thalia', 'Thalia'), ('adil@example.com', 'caller', 'adil', 'Tyler')
    on conflict do nothing`)
  await db.exec(`update public.campaign_control set daily_cap = 3, day_first_floor = 1 where id = 1`)
  C.best = await card(109, { owner: 'PAT A BEST', lockedTo: 'adil', reasons: ['foreclosure', 'behind on taxes'] }); await fit(109, 'ok', { tier: 'A', equity: 'likely' })
  C.good = await card(101, { owner: 'GOOD, SAM J' }); await fit(101, 'ok', { tier: 'B' })
  C.weak = await card(102, { owner: 'WENDY WEAK' }); await fit(102, 'weak_distress', { need: false })
  C.sale = await card(103, { owner: 'SALLY SALE' }); await fit(103, 'ok', { tier: 'C', sale: '2026-11-22' })      // 10 days out
  C.unjudged = await card(104, { owner: 'ULA UNJUDGED', reasons: ['foreclosure'] })
  C.want = await card(-5, { owner: 'WALT WANT', reasons: ['tired landlord', 'long held'] })
  C.muse = await card(-6, { owner: 'ACME HOLDINGS LLC', reasons: ['probate'] })
  C.parked = await card(105, { owner: 'PAULA PARKED', parked: true }); await fit(105, 'ok', { tier: 'C' })
  C.landline = await card(106, { owner: 'LARRY LANDLINE', lineType: 'landline' }); await fit(106, 'ok', { tier: 'C' })
  C.thin = await card(107, { owner: 'THEO THIN' }); await fit(107, 'ok', { tier: 'C', equity: 'thin' })
  C.listed = await card(108, { owner: 'LISA LISTED' }); await fit(108, 'actively_listed')
  C.stale = await card(110, { owner: 'STAN STALE' }); await fit(110, 'ok', { tier: 'C', asOf: '2026-11-01' })
  C.farSale = await card(111, { owner: 'FARRAH FARSALE' }); await fit(111, 'ok', { tier: 'C', sale: '2026-12-15' })   // 33 days out
}, 120_000)

describe('the day', () => {
  it('every first-text card is ready or carries the one reason it is not', async () => {
    const p = await pool()
    const by = Object.fromEntries(p.filter((r) => r.kind === 'first').map((r) => [r.lead_id, r.block]))
    expect(by).toEqual({
      [C.best]: null, [C.good]: null, [C.muse]: null, [C.farSale]: null,
      [C.weak]: 'weak_distress', [C.sale]: 'sheriff_sale_inside_14d', [C.unjudged]: 'no_record_verdict', [C.want]: 'want_not_need',
      [C.parked]: 'parked', [C.landline]: 'no_textable_phone', [C.thin]: 'equity_thin', [C.listed]: 'actively_listed', [C.stale]: 'record_verdict_stale',
    })
    // a sale ahead is the first text of the day (0233); then need: tier A, then B, then the agent's own card with no tier
    expect(p.filter((r) => r.kind === 'first' && r.block === null).map((r) => r.lead_id)).toEqual([C.farSale, C.best, C.good, C.muse])
  })

  it('a name fit to greet with, or "there"', async () => {
    const f = (n: string) => one<string>('public.text_first_name($1)', [n])
    expect([await f('SMITH, JOHN A'), await f('JOHN A SMITH'), await f('ACME HOLDINGS LLC'), await f('ESTATE OF MARY JONES'), await f('J R EWING'), await f('')])
      .toEqual(['John', 'John', 'there', 'there', 'there', 'there'])
  })

  it('builds the list to the cap, need first, and ready_to_text serves it with the phone and the name', async () => {
    const b = await one<{ built: boolean; listed: number; added: Record<string, number> }>('public.text_day_build($1)', [NOW])
    expect(b).toMatchObject({ built: true, listed: 3, added: { first_floor: 1, more_first: 2 } })
    expect(await rows(`select lead_id, kind, step, voice, ord from public.text_day where day = $1 order by ord`, [TODAY])).toEqual([
      { lead_id: C.farSale, kind: 'first', step: 1, voice: 'Thalia', ord: 1 },
      { lead_id: C.best, kind: 'first', step: 1, voice: 'Tyler', ord: 2 },
      { lead_id: C.good, kind: 'first', step: 1, voice: 'Thalia', ord: 3 },
    ])
    // a second build the same morning changes nothing
    expect(await one<{ listed: number }>('public.text_day_build($1)', [NOW])).toMatchObject({ listed: 3 })
    const ready = await one<{ new_cards: { lead_id: string; voice: string; phone: string; tier: string }[]; the_day: { left_to_write: number; list_built: boolean } }>(
      'public.agent_ready_to_text(50, true, false, $1)', [NOW])
    expect(ready.new_cards.map((c) => [c.lead_id, c.voice, c.tier])).toEqual([[C.farSale, 'Thalia', 'C'], [C.best, 'Tyler', 'A'], [C.good, 'Thalia', 'B']])
    expect(ready.new_cards[1].phone).toBe(await phoneOf(C.best))
    expect(ready.the_day).toMatchObject({ list_built: true, left_to_write: 3 })
  })

  it('the queue refuses a second name, a first text with no name, and what the records forbid', async () => {
    const ph = await phoneOf(C.best)
    expect(await queue(C.best, ph, 'Hi Pat, this is Thalia. Are you the current owner of 109 Test St? Reply STOP to opt out.'))
      .toMatchObject({ status: 'refused', reason: expect.stringContaining('hears from Tyler, not Thalia') })
    expect(await queue(C.best, ph, 'Hi Pat, are you the current owner of 109 Test St? Reply STOP to opt out.'))
      .toMatchObject({ status: 'refused', reason: expect.stringContaining('says who is writing') })
    expect(await queue(C.weak, await phoneOf(C.weak), 'Hi Wendy, this is Thalia. Are you the current owner of 102 Test St? Reply STOP to opt out.'))
      .toMatchObject({ status: 'refused', reason: expect.stringContaining('weak_distress') })
    expect(await queue(C.want, await phoneOf(C.want), 'Hi Walt, this is Thalia. Are you the current owner of 5 Test St? Reply STOP to opt out.'))
      .toMatchObject({ status: 'refused', reason: expect.stringContaining('a want is not a need') })
    expect(await queue(C.listed, await phoneOf(C.listed), 'Hi Lisa, this is Thalia. Are you the current owner of 108 Test St? Reply STOP to opt out.'))
      .toMatchObject({ status: 'refused', reason: expect.stringContaining('a listed property is not a lead') })
    expect(await queue(C.best, ph, 'Hi Pat, this is Tyler. Are you the current owner of 109 Test St? Reply STOP to opt out.')).toMatchObject({ status: 'queued' })
    // written: it stays on the list and leaves what is left to write
    const ready = await one<{ new_cards: { lead_id: string }[]; the_day: { left_to_write: number } }>('public.agent_ready_to_text(50, true, false, $1)', [NOW])
    expect(ready.new_cards.map((c) => c.lead_id)).toEqual([C.farSale, C.good])
    expect(await one<{ listed: number; not_written: number }>('public.text_day_report($1)', [NOW])).toMatchObject({ listed: 3, not_written: 2 })
  })

  it('a follow-up keeps the name the seller saw, carries no STOP line, and gets its place on the next list', async () => {
    const ph = await phoneOf(C.best)
    // the first text went out and was delivered; three days pass
    await db.query(`update public.planned_openers set send_status = 'delivered', sent_at = $2, provider_sid = 'SM1' where lead_id = $1 and step = 1`, [C.best, NOW])
    await db.query(`insert into public.messages (lead_id, direction, channel, body, provider_sid, is_opener, sent_at, status, to_number)
                    values ($1, 'out', 'sms', 'Hi Pat, this is Tyler. Are you the current owner of 109 Test St? Reply STOP to opt out.', 'SM1', true, $2, 'delivered', $3)`,
      [C.best, NOW, '+1' + ph])
    await db.query(`update public.leads set stage = 'opener_sent', locked_to = 'thalia' where id = $1`, [C.best])
    const later = '2026-11-16T16:00:00Z'      // Monday: day 3 was Saturday, so it is due
    expect(await one<string>('public.card_voice($1)', [C.best])).toBe('Tyler')       // the card changed hands; the thread did not change its name
    const p = await rows<{ lead_id: string; step: number; block: string | null }>(
      `select lead_id, step, block from public.text_pool($1) where kind = 'followup'`, [later])
    expect(p).toEqual([{ lead_id: C.best, step: 2, block: null }])
    const b = await one<{ added: Record<string, number> }>('public.text_day_build($1)', [later])
    expect(b.added).toMatchObject({ first_floor: 1, followups_2_3: 1 })
    expect(await queue(C.best, ph, 'Hi Pat, Tyler again about 109 Test St. Still the owner there? Reply STOP to opt out.', 2, later))
      .toMatchObject({ status: 'refused', reason: expect.stringContaining('carries no STOP line') })
    expect(await queue(C.best, ph, 'Hi Pat, Thalia again about 109 Test St. Still the owner there?', 2, later))
      .toMatchObject({ status: 'refused', reason: expect.stringContaining('hears from Tyler') })
    expect(await queue(C.best, ph, 'Hi Pat, Tyler again about 109 Test St. Still the owner there? Just checking I have the right place.', 2, later))
      .toMatchObject({ status: 'queued' })
  })

  it('the name follows the person to another card, and the intro is only for the first text to a person (0221, Colin 2026-11-10)', async () => {
    const ph = await phoneOf(C.best)
    // Pat's second property, a new card on Thalia's pile, with the same phone: Pat hears from Tyler there too
    const second = await card(112, { owner: 'PAT A BEST', address: '112 Other St', lockedTo: 'thalia', phone: ph })
    await fit(112, 'ok', { tier: 'C' })
    expect(await one<string>('public.card_voice($1)', [second])).toBe('Tyler')
    expect(await one<boolean>('public.card_texted_before($1)', [second])).toBe(true)
    // a first text on that card needs no intro (Pat has met Tyler), and may not introduce Thalia
    expect(await one<string | null>(`public.text_rule_problem($1, 'Hi Pat, also wanted to ask about 112 Other St. Is that one yours too? Reply STOP to opt out.', 1, $2)`,
      [second, NOW])).toBeNull()
    expect(await one<string | null>(`public.text_rule_problem($1, 'Hi Pat, this is Thalia. Is 112 Other St yours too? Reply STOP to opt out.', 1, $2)`, [second, NOW]))
      .toContain('hears from Tyler, not Thalia')
    // someone nobody has texted still gets the intro on their first text
    expect(await one<boolean>('public.card_texted_before($1)', [C.good])).toBe(false)
    expect(await one<string | null>(`public.text_rule_problem($1, 'Hi Sam, are you the current owner of 101 Test St? Reply STOP to opt out.', 1, $2)`, [C.good, NOW]))
      .toContain('says who is writing')
  })

  it('the clock: the evening report goes on the desk once, flagged when the new people are about to run out', async () => {
    const evening = '2026-11-17T01:20:00Z'    // Monday 7:20 PM Central
    const t = await one<{ report?: string; low_supply?: boolean }>('public.text_day_tick($1)', [evening])
    expect(t).toMatchObject({ report: 'posted', low_supply: true })
    const posts = await rows<{ topic: string; body: string; kind: string }>(`select topic, body, kind from public.desk_messages where topic like 'The day %' order by id`)
    expect(posts).toHaveLength(1)
    expect(posts[0].topic).toContain('NEW PEOPLE RUN OUT')
    expect(posts[0].body).toContain('weak_distress')
    expect(await one<Record<string, unknown>>('public.text_day_tick($1)', [evening])).toEqual({})     // once a day
    expect(await one<Record<string, unknown>>('public.text_day_tick($1)', ['2026-11-15T16:00:00Z'])).toMatchObject({ why: 'Sunday' })
  })

  it('the backstop, when it is switched on, writes the settled wording for what nobody wrote', async () => {
    const tue = '2026-11-17T17:10:00Z'        // Tuesday 11:10 AM Central
    expect(await one<{ ran: boolean }>('public.text_day_backstop($1)', [tue])).toMatchObject({ ran: false })
    await db.exec(`update public.campaign_control set day_backstop = true, daily_cap = 10 where id = 1`)
    await db.exec(`update public.text_fitness set as_of = '2026-11-17'`)
    const t = await one<{ build: { listed: number }; backstop: { ran: boolean; queued: number } }>('public.text_day_tick($1)', [tue])
    expect(t.build.listed).toBeGreaterThanOrEqual(3)
    expect(t.backstop).toMatchObject({ ran: true })
    const sent = await rows<{ body: string; variant: string; decided_by_name: string }>(
      `select body, variant, decided_by_name from public.planned_openers where template_lane = 'day_backstop' order by body`)
    expect(sent.map((s) => s.body)).toEqual([
      'Hi Farrah, this is Thalia. Are you the current owner of 111 Test St? Reply STOP to opt out.',
      'Hi Sam, this is Thalia. Are you the current owner of 101 Test St? Reply STOP to opt out.',
      'Hi Stan, this is Thalia. Are you the current owner of 110 Test St? Reply STOP to opt out.',   // judged again, no longer stale
      'Hi there, this is Thalia. Are you the right person to ask about 6 Test St? Reply STOP to opt out.',
    ])
    expect(sent[0]).toMatchObject({ variant: 'V4', decided_by_name: 'Muse (the day)' })
  })

  it('the kill switch turns the rule gate off', async () => {
    await db.exec(`update public.campaign_control set day_rules_on = false where id = 1`)
    expect(await one<string | null>('public.card_record_block($1, $2)', [C.weak, TODAY])).toBeNull()
    expect(await one<string | null>(`public.text_rule_problem($1, 'Hi, Colin here about the house', 2, $2)`, [C.good, NOW])).toBeNull()
    await db.exec(`update public.campaign_control set day_rules_on = true where id = 1`)
    expect(await one<string | null>('public.card_record_block($1, $2)', [C.weak, TODAY])).toBe('weak_distress')
  })
})
