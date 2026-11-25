// 0327: an interested seller gets a call, whoever is or is not at work. A said-yes card that only held its belt
// follow-up got no reply call and sat behind the cold list; and when a card's caller does not dial, the rescue (off as
// shipped) moves the seller to the caller who is working, once, with the call at the top of their list.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')
const NOW = '2026-11-24T22:30:00Z'       // Tuesday 4:30 PM Central
const TYLER = { sub: '00000000-0000-0000-0000-00000000000b', email: 'adil@example.com' }
const THALIA = { sub: '00000000-0000-0000-0000-00000000000c', email: 'thalia@example.com' }

let db: PGlite
const rows = async <T>(sql: string, params: unknown[] = []) => (await db.query<T>(sql, params)).rows
const one = async <T>(sql: string, params: unknown[] = []) => (await rows<{ r: T }>(`select ${sql} as r`, params))[0].r
async function as<T>(claims: object, fn: () => Promise<T>): Promise<T> {
  await db.query(`select set_config('request.jwt.claims', $1, false)`, [JSON.stringify(claims)])
  await db.exec('set role authenticated')
  try { return await fn() } finally { await db.exec('reset role'); await db.query(`select set_config('request.jwt.claims', '', false)`) }
}
let n = 700
const card = async (name: string, who: 'thalia' | 'adil') => {
  n += 1
  const id = (await rows<{ id: string }>(
    `insert into public.leads (wpie_owner_id, owner_name, lane, stage, belt, property_address, municipality, locked_to, assigned_to, mailing_state)
     values ($1, $2, 'flip', 'colin_call', 'yes_unbooked', $3, 'Franklin', $4::public.team_person, $4::public.team_person, 'WI') returning id`, [n, name, `${n} Yes St`, who]))[0].id
  await db.query(`insert into public.contacts (lead_id, kind, value, value_normalized, line_type) values ($1, 'phone', $2, $2, 'mobile')`, [id, `414555${n}0`])
  return id
}
const reply = (lead: string, hoursAgo: number, body = 'Yes') =>
  db.query(`insert into public.reply_drafts (phone10, lead_id, inbound_body, inbound_at, intent, kind, status)
            values ('4145550000', $1, $2, $3::timestamptz - make_interval(hours => $4), 'interested', 'candidate', 'no_reply')`, [lead, body, NOW, hoursAgo])
const dialedBy = (who: string, hoursAgo: number, lead: string) =>
  db.query(`insert into public.belt_events (lead_id, event, payload, at, by) values ($1, 'human_call_started', '{}'::jsonb, $2::timestamptz - make_interval(hours => $3), $4)`, [lead, NOW, hoursAgo, who])
type Row = { lead_id: string; source: string }
const queue = (who: object) => as(who, async () => (await rows<{ r: Row[] }>(`select public.power_dial_queue(100, $1::timestamptz) r`, [NOW]))[0].r)
const C: Record<string, string> = {}

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
  await db.exec(`insert into public.team_members (email, role, person, display_name) values
    ('colin@example.com', 'owner', 'colin', 'Colin'), ('thalia@example.com', 'caller', 'thalia', 'Thalia'), ('adil@example.com', 'caller', 'adil', 'Tyler') on conflict do nothing`)
  await db.exec(`delete from public.caller_off_weekly`)
  C.yes = await card('SAID YES SHANE', 'adil'); await reply(C.yes, 30)
  C.fresh = await card('FRESH YES FRAN', 'adil'); await reply(C.fresh, 3)
  C.cold = await card('COLD LIST CARL', 'adil')
  await db.query(`update public.leads set stage = 'opener_queued', belt = null where id = $1`, [C.cold])
  await db.query(`delete from public.tasks`)
  // what the cards really hold: the belt's follow-up, and a morning-list task on the cold card
  await db.query(`insert into public.tasks (lead_id, due_at, kind, owner, source, title, note) values
    ($1, $4::timestamptz - interval '1 hour', 'call', 'adil', 'belt', 'Said yes, not booked: stop 1 of 4', 'x'),
    ($2, $4::timestamptz - interval '1 hour', 'call', 'adil', 'belt', 'Said yes, not booked: stop 1 of 4', 'x'),
    ($3, $4::timestamptz - interval '9 hours', 'call', 'adil', 'power_hour', 'Tyler today: real need', 'x')`, [C.yes, C.fresh, C.cold, NOW])
}, 120_000)

describe('a seller who said yes', () => {
  it('gets a reply call even though the card already holds its belt follow-up, and comes up before the list', async () => {
    const before = await queue(TYLER)
    expect(before.find((x) => x.lead_id === C.yes)?.source).toBe('call_list')
    const r = await one<{ tasks_made: number }>(`public.warm_sellers_tick($1::timestamptz)`, [NOW])
    expect(r.tasks_made).toBe(2)
    const q = await queue(TYLER)
    expect(q.find((x) => x.lead_id === C.yes)?.source).toBe('replied')
    expect(q.find((x) => x.lead_id === C.fresh)?.source).toBe('replied')
    const at = (id: string) => q.findIndex((x) => x.lead_id === id)
    expect(at(C.yes)).toBeLessThan(at(C.cold))
    expect(at(C.fresh)).toBeLessThan(at(C.cold))
    expect((await one<{ tasks_made: number }>(`public.warm_sellers_tick($1::timestamptz)`, [NOW])).tasks_made).toBe(0)
  })
})

describe('the caller did not dial them for a day', () => {
  it('switched off (as shipped) nothing moves, but the dry run says what would', async () => {
    await dialedBy('Thalia', 2, C.cold)        // Thalia is at work today
    expect(await one<{ on: boolean }>(`public.warm_rescue_tick($1::timestamptz, false)`, [NOW])).toEqual({ on: false })
    const dry = await one<{ moved: number; cards: { owner: string; to: string }[] }>(`public.warm_rescue_tick($1::timestamptz, true)`, [NOW])
    expect(dry.moved).toBe(1)
    expect(dry.cards[0]).toMatchObject({ owner: 'SAID YES SHANE', from: 'adil', to: 'thalia' })
    expect((await rows<{ locked_to: string }>(`select locked_to::text from public.leads where id = $1`, [C.yes]))[0].locked_to).toBe('adil')
  })
  it('switched on: the one who waited a day goes to the caller who is working, with the call at the top of her list; the fresh one stays', async () => {
    await db.exec(`update public.campaign_control set warm_rescue = true where id = 1`)
    const r = await one<{ moved: number }>(`public.warm_rescue_tick($1::timestamptz, false)`, [NOW])
    expect(r.moved).toBe(1)
    const l = (await rows<{ locked_to: string; assigned_to: string }>(`select locked_to::text, assigned_to::text from public.leads where id = $1`, [C.yes]))[0]
    expect(l).toEqual({ locked_to: 'thalia', assigned_to: 'thalia' })
    expect((await rows<{ locked_to: string }>(`select locked_to::text from public.leads where id = $1`, [C.fresh]))[0].locked_to).toBe('adil')
    expect((await rows(`select 1 from public.tasks where lead_id = $1 and done_at is null and owner <> 'thalia'`, [C.yes]))).toHaveLength(0)
    const hers = await queue(THALIA)
    expect(hers[0]).toMatchObject({ lead_id: C.yes, source: 'replied' })
    expect((await queue(TYLER)).some((x) => x.lead_id === C.yes)).toBe(false)
    const note = (await rows<{ body: string }>(`select body from public.messages where lead_id = $1 and channel = 'note' order by sent_at desc limit 1`, [C.yes]))[0].body
    expect(note).toContain('Card moved to Thalia from Adil')
  })
  it('a card moves once: if the new caller does not dial it either it stays hers and is named to Colin, never passed back', async () => {
    const later = '2026-11-26T22:30:00Z'
    await db.query(`insert into public.belt_events (lead_id, event, payload, at, by) values ($1, 'human_call_started', '{}'::jsonb, $2::timestamptz - interval '2 hours', 'Tyler')`, [C.cold, later])
    const r = await one<{ moved: number; cards: { owner: string }[] }>(`public.warm_rescue_tick($1::timestamptz, false)`, [later])
    expect(r.cards.map((c) => c.owner)).not.toContain('SAID YES SHANE')
    expect((await rows<{ locked_to: string }>(`select locked_to::text from public.leads where id = $1`, [C.yes]))[0].locked_to).toBe('thalia')
  })
  it('nobody is moved to a caller who is off today or has not dialed since yesterday', async () => {
    const w = await card('WAITING WANDA', 'adil'); await reply(w, 40)
    await db.query(`insert into public.caller_off (person, day) values ('thalia', '2026-11-24')`)
    expect((await one<{ moved: number }>(`public.warm_rescue_tick($1::timestamptz, true)`, [NOW])).moved).toBe(0)
    await db.query(`delete from public.caller_off`)
    await db.query(`delete from public.belt_events where event = 'human_call_started' and by = 'Thalia'`)
    expect((await one<{ moved: number }>(`public.warm_rescue_tick($1::timestamptz, true)`, [NOW])).moved).toBe(0)
  })
  it('only Colin moves a card by hand, as before', async () => {
    await expect(as(TYLER, () => rows(`select public.card_reassign($1, 'adil', 'mine')`, [C.yes]))).rejects.toThrow(/only Colin/)
    await expect(as(TYLER, () => rows(`select public.card_move($1, 'adil', 'mine', 'me')`, [C.yes]))).rejects.toThrow()
  })
})

describe('a seller calling back the number they were just dialed from', () => {
  it('rings the caller who dialed, Tyler included, and a card assigned to a caller rings that caller', async () => {
    const t = await card('RETURN CALL RON', 'adil')
    await db.query(`update public.leads set locked_to = null where id = $1`, [t])
    const ph = (await rows<{ v: string }>(`select value_normalized v from public.contacts where lead_id = $1`, [t]))[0].v
    expect((await one<{ ring: string[] }>(`public.inbound_call_ring($1, $2::timestamptz)`, [ph, NOW])).ring).toEqual(['adil'])
    const u = await card('UNOWNED URSULA', 'adil')
    await db.query(`update public.leads set locked_to = null, assigned_to = null where id = $1`, [u])
    const ph2 = (await rows<{ v: string }>(`select value_normalized v from public.contacts where lead_id = $1`, [u]))[0].v
    await db.query(`insert into public.belt_events (lead_id, event, payload, at, by) values ($1, 'human_call_started', jsonb_build_object('phone', $2::text), $3::timestamptz - interval '10 minutes', 'Tyler')`, [u, ph2, NOW])
    const r = await one<{ ring: string[]; return_call: boolean }>(`public.inbound_call_ring($1, $2::timestamptz)`, [ph2, NOW])
    expect(r).toMatchObject({ ring: ['adil'], return_call: true })
  })
})
