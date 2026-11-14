// 0233: a sale ahead goes first, by itself. A sheriff sale 14+ days out puts the card at the top of its caller's Power hour
// list with no task and first in the day's first texts; a sale inside 14 days is never dialed from a list or texted; a
// follow-up that is due comes before the caller's list cards; an agent cannot park a sale card on a hold.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATIONS = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')
const NOON = '2026-11-17T18:00:00Z'      // Tuesday noon CT
const ADIL = { sub: '00000000-0000-0000-0000-00000000000b', email: 'adil@example.com' }
let db: PGlite
let n = 700

const one = async <T = Record<string, unknown>>(sql: string, params: unknown[] = []) => (await db.query<T>(sql, params)).rows[0]
async function as<T>(claims: object, fn: () => Promise<T>): Promise<T> {
  await db.query(`select set_config('request.jwt.claims', $1, false)`, [JSON.stringify(claims)])
  await db.exec('set role authenticated')
  try { return await fn() } finally { await db.exec('reset role'); await db.query(`select set_config('request.jwt.claims', '', false)`) }
}
/** A never-texted card of Tyler's (adil), agent-made (negative owner id), with one mobile. */
async function card(reasons: string[], stage = 'opener_queued') {
  const k = ++n
  const id = (await one<{ id: string }>(
    `insert into public.leads (wpie_owner_id, owner_name, lane, stage, property_address, municipality, mailing_state, locked_to, reasons_to_sell)
     values ($1, $2, 'flip', $3::public.lead_stage, $4, 'Green Bay', 'WI', 'adil', $5::text[]) returning id`,
    [-k, `OWNER ${k}`, stage, `${k} Sale St`, reasons])).id
  await db.query(`insert into public.contacts (lead_id, kind, value, value_normalized, line_type) values ($1, 'phone', $2, $2, 'mobile')`, [id, `414555${String(k).padStart(4, '0')}`])
  return id
}
const task = (lead: string, source: string, due: string, title: string) =>
  db.query(`insert into public.tasks (lead_id, due_at, kind, owner, source, title, note) values ($1, $2::timestamptz, 'call', 'adil', $3, $4, 'x')`, [lead, due, source, title])
type Row = { lead_id: string; source: string; why: string | null; sale_date: string | null }
const queue = () => as(ADIL, async () => (await one<{ r: Row[] }>(`select public.power_dial_queue(100, $1::timestamptz) r`, [NOON])).r)

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATIONS)
  await db.exec(`insert into public.team_members (email, role, person, display_name) values ('adil@example.com', 'caller', 'adil', 'Tyler')`)
}, 120_000)

describe('a sale ahead goes first, by itself', () => {
  it('reads the sale date the way the cards write it', async () => {
    const d = async (s: string) => (await one<{ d: string | null }>(`select public.sale_date_in($1)::text d`, [s])).d
    expect(await d('Sheriff sale 2026-12-01')).toBe('2026-12-01')
    expect(await d('Foreclosure — sheriff sale Wed Dec 2, 2026')).toBe('2026-12-02')
    expect(await d('Foreclosure — sheriff sale Dec 9, 2026, case 2026CV000123')).toBe('2026-12-09')
    expect(await d('Sheriff sale Jan 13, 2027')).toBe('2027-01-13')
    expect(await d('pre-foreclosure')).toBeNull()
    expect(await d('Sheriff sale soon')).toBeNull()
  })

  it('orders the list: a sale ahead, then a follow-up that is due, then the list; a sale inside 14 days is not on it', async () => {
    const listCard = await card(['deep tax delinquency'])
    await task(listCard, 'power_hour', '2026-11-04T18:00:00Z', 'Tyler today: real need')
    const followUp = await card(['code / nuisance'], 'follow_up')
    await task(followUp, 'belt', '2026-11-17T16:00:00Z', 'Replied, went quiet: stop 2 of 3')
    const later = await card(['Sheriff sale Jan 13, 2027'])                     // no task at all
    const sooner = await card(['Foreclosure — sheriff sale Wed Dec 9, 2026'])
    const tooClose = await card(['Sheriff sale 2026-11-24'])                    // 7 days out
    await task(tooClose, 'power_hour', '2026-11-04T17:00:00Z', 'Sheriff sale Nov 24: last call day Nov 10')
    const past = await card(['Sheriff sale 2026-11-03'])
    await task(past, 'call_list', '2026-11-17T13:00:00Z', 'Call list')
    const q = await queue()
    const mine = [listCard, followUp, later, sooner, tooClose, past]
    expect(q.filter((x) => mine.includes(x.lead_id)).map((x) => x.lead_id)).toEqual([sooner, later, followUp, listCard])
    expect(q.find((x) => x.lead_id === sooner)).toMatchObject({ source: 'call_list', why: 'Sheriff sale Dec 9: last call day Nov 25', sale_date: '2026-12-09' })
  })

  it('a sale card leaves the list once someone is reached, and a thin or underwater one is not put first', async () => {
    const reached = await card(['Sheriff sale 2026-12-15'])
    await db.query(`insert into public.messages (lead_id, direction, channel, body, status, sent_at) values ($1, 'in', 'call', 'Call (Tyler): talked', 'reached_no_decision', $2::timestamptz - interval '1 day')`, [reached, NOON])
    const under = await card(['Sheriff sale 2026-12-15'])
    await db.query(`update public.leads set wpie_owner_id = 880001 where id = $1`, [under])
    await db.query(`insert into public.text_fitness (wpie_owner_id, verdict, as_of, sale_date, equity) values (880001, 'ok', '2026-11-17', '2026-12-15', 'underwater')`)
    const q = await queue()
    expect(q.some((x) => x.lead_id === reached)).toBe(false)
    expect(q.some((x) => x.lead_id === under)).toBe(false)
  })

  it('texts: a sale ahead is the first of the day\'s first texts, and a sale inside 14 days is blocked on any card', async () => {
    const ahead = await card(['Sheriff sale 2026-12-20'])
    const close = await card(['Sheriff sale 2026-11-24'])
    await card(['estate / inherited'])                                         // a real need with no sale date
    const pool = (await db.query<{ lead_id: string; block: string | null; ord: string }>(
      `select lead_id, block, ord from public.text_pool($1::timestamptz) where kind = 'first' order by ord`, [NOON])).rows
    const open = pool.filter((p) => p.block === null)
    const withSale = new Set((await db.query<{ lead_id: string }>(`select lead_id from public.card_sale_dates where sale_date >= '2026-12-01'`)).rows.map((r) => r.lead_id))
    const firstPlain = open.findIndex((p) => !withSale.has(p.lead_id))
    expect(firstPlain).toBeGreaterThan(0)                                     // there are plain cards, and none is first
    expect(open.slice(0, firstPlain).some((p) => p.lead_id === ahead)).toBe(true)
    expect(open.slice(firstPlain).some((p) => withSale.has(p.lead_id))).toBe(false)
    expect(pool.find((p) => p.lead_id === ahead)!.block).toBeNull()
    expect(pool.find((p) => p.lead_id === close)!.block).toBe('sheriff_sale_inside_14d')
    expect((await one<{ b: string }>(`select public.card_record_block($1, '2026-11-17') b`, [close])).b).toBe('sheriff_sale_inside_14d')
  })

  it('the sender is handed the sale text, filled in, for a card with a sale ahead (0234)', async () => {
    const c = await card(['Sheriff sale 2026-12-22'])
    await db.query(`update public.leads set owner_name = 'DOE, JANE Q', property_address = '12 OAK ST' where id = $1`, [c])
    const t = async (lead: string) => (await one<{ t: string | null }>(`select public.sale_first_text($1, 'Tyler', '2026-11-17') t`, [lead])).t
    expect(await t(c)).toBe("Hi Jane, Tyler here about 12 Oak St. I know a sale date may be coming up. If selling before then and walking away with something would help, I'd like to talk. Would you be open to that? Reply STOP to opt out.")
    expect(await t(await card(['estate / inherited']))).toBeNull()
    expect(await t(await card(['Sheriff sale 2026-11-24']))).toBeNull()        // inside 14 days: no text at all
    const ready = (await one<{ r: { new_cards: { lead_id: string; sale_text: string | null }[]; the_day: { how: string } } }>(
      `select public.agent_ready_to_text(200, true, true, $1::timestamptz) r`, [NOON])).r
    expect(ready.new_cards.find((x) => x.lead_id === c)!.sale_text).toContain('I know a sale date may be coming up')
    expect(ready.the_day.how).toContain('sale_text')
  })

  it('an agent cannot park a card with a sale ahead on a hold', async () => {
    const soon = (await one<{ d: string }>(`select to_char((now() at time zone 'America/Chicago')::date + 30, 'YYYY-MM-DD') d`)).d
    const c = await card([`Sheriff sale ${soon}`])
    const r = (await one<{ r: { ok: boolean; reason: string } }>(`select public.agent_mark_card($1, 'held', 'weak phones', null, null, 'muse') r`, [c])).r
    expect(r.ok).toBe(false)
    expect(r.reason).toContain('a sheriff sale is ahead')
    const plain = await card(['deep tax delinquency'])
    expect((await one<{ r: { ok: boolean } }>(`select public.agent_mark_card($1, 'held', 'weak phones', null, null, 'muse') r`, [plain])).r.ok).toBe(true)
  })
})
