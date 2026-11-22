// 0240: a Sunday is opened one day at a time. Colin 2026-11-15, a Sunday: "Yes start sending". The rule is off on the
// Sunday that was opened and back on by Monday's first tick; a number in a state that bars Sunday texts waits for
// Monday; a caller who is off on Sundays still gets no texts on their cards.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')
const SUNDAY = '2099-11-15'                  // a Sunday far ahead: sunday_open refuses a day that is past
const SUN_10AM = '2099-11-15T16:00:00Z'      // 10:00 AM Central
const MON_1204AM = '2099-11-16T06:04:00Z'    // Monday 12:04 AM Central
const NEXT_SUN = '2099-11-22T16:00:00Z'

let db: PGlite
const rows = async <T>(sql: string, params: unknown[] = []) => (await db.query<T>(sql, params)).rows
const one = async <T>(sql: string, params: unknown[] = []) => (await rows<{ r: T }>(`select ${sql} as r`, params))[0].r
const card = async (ownerId: number, owner: string, lockedTo: 'thalia' | 'adil', phone: string) => {
  const id = (await rows<{ id: string }>(
    `insert into public.leads (wpie_owner_id, owner_name, lane, stage, property_address, locked_to, reasons_to_sell, mailing_state)
     values ($1, $2, 'flip', 'opener_queued', $3, $4::public.team_person, '{foreclosure}', 'WI') returning id`,
    [ownerId, owner, `${ownerId} Sunday St`, lockedTo]))[0].id
  await db.query(`insert into public.contacts (lead_id, kind, value, value_normalized, line_type, person_name) values ($1, 'phone', $2, $2, 'mobile', $3)`, [id, phone, owner])
  await db.query(`insert into public.text_fitness (wpie_owner_id, verdict, need, need_why, tier, equity, as_of) values ($1, 'ok', true, 'test', 'B', 'likely', $2)`, [ownerId, SUNDAY])
  return id
}
const block = async (lead: string, at: string) => (await rows<{ block: string | null }>(`select block from public.text_pool($1) where lead_id = $2`, [at, lead]))[0].block
const listed = async (day: string) => (await rows<{ lead_id: string }>(`select lead_id from public.text_day where day = $1`, [day])).map((r) => r.lead_id)
const noSundays = async () => (await rows<{ no_sundays: boolean }>(`select no_sundays from public.campaign_control where id = 1`))[0].no_sundays

let tylers: string, tylersPa: string, tylersTx: string, thalias: string

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
  await db.exec(`insert into public.team_members (email, role, person, display_name) values
    ('thalia@example.com', 'caller', 'thalia', 'Thalia'), ('adil@example.com', 'caller', 'adil', 'Tyler') on conflict do nothing`)
  await db.exec(`update public.campaign_control set daily_cap = 10, day_first_floor = 1, window_start = '09:00', window_end = '19:00', day_backstop = false where id = 1`)
  await db.exec(`select public.caller_off_weekly_set('thalia', '{6,7}', 'weekends')`)
  tylers = await card(301, 'WANDA WISCONSIN', 'adil', '4145560301')
  tylersPa = await card(302, 'PENN PITTSBURGH', 'adil', '4125560302')       // 412: Pennsylvania, no Sunday texts
  tylersTx = await card(303, 'TEX DALLAS', 'adil', '2145560303')            // 214: Texas, Sunday from noon only
  thalias = await card(304, 'TINA THALIACARD', 'thalia', '4145560304')
}, 120_000)

describe('0277: Sunday is a texting day (Colin 2026-11-22)', () => {
  it('builds a list like any other day; the state law and the caller off still hold', async () => {
    expect(await noSundays()).toBe(false)
    await one('public.text_day_tick($1)', [SUN_10AM])
    expect(await noSundays()).toBe(false)
    expect(await listed(SUNDAY)).toEqual([tylers])
    expect(await block(tylersPa, SUN_10AM)).toBe('state_bars_sunday')
    expect(await block(tylersTx, SUN_10AM)).toBe('state_bars_sunday')
    expect(await block(thalias, SUN_10AM)).toBe('caller_off_today')
    // nothing special is said to the agent: a Sunday is a weekday (the rules text says so)
    expect((await one<Record<string, unknown> | null>(`public.agent_attention('Muse', $1)`, [SUN_10AM]))?.sunday).toBeUndefined()
    // an older setting that says Sunday is shut is put right by the tick
    await db.exec(`update public.campaign_control set no_sundays = true where id = 1`)
    await one('public.text_day_tick($1)', [SUN_10AM])
    expect(await noSundays()).toBe(false)
    // a belt text no longer slides to Monday; a belt call still does
    expect(await one<string>(`(public.belt_slide('2099-11-15T16:00:00Z'::timestamptz, 'America/Chicago', 'text') at time zone 'America/Chicago')::date::text`)).toBe('2099-11-15')
    expect(await one<string>(`(public.belt_slide('2099-11-15T16:00:00Z'::timestamptz, 'America/Chicago', 'call') at time zone 'America/Chicago')::date::text`)).toBe('2099-11-16')
    // the standing rule's switch, for the old tests below
    await db.exec(`delete from public.text_day where day = '${SUNDAY}'`)
    await db.exec(`update public.campaign_control set sundays_closed = true, no_sundays = true, day_last_build_at = null where id = 1`)
  })
})

describe('a Sunday, with the standing rule switched back on (sundays_closed)', () => {
  it('is shut unless it was opened: no list, whatever the cards', async () => {
    expect(await noSundays()).toBe(true)
    expect(await one<Record<string, unknown>>('public.text_day_tick($1)', [SUN_10AM])).toMatchObject({ why: 'Sunday' })
    expect(await listed(SUNDAY)).toEqual([])
  })

  it('opened for the day: Wisconsin numbers on the cards of a caller who is working, and nobody else', async () => {
    await expect(db.query(`select public.sunday_open('2099-11-16', 'desk')`)).rejects.toThrow(/not a Sunday/)
    expect(await one<Record<string, unknown>>(`public.sunday_open($1, 'desk', 'Colin: yes start sending')`, [SUNDAY])).toMatchObject({ opened: SUNDAY, texts_today: false })
    expect(await noSundays()).toBe(true)                       // not yet: the day has not come
    await one('public.text_day_tick($1)', [SUN_10AM])
    expect(await noSundays()).toBe(false)
    expect(await listed(SUNDAY)).toEqual([tylers])
    expect(await block(tylersPa, SUN_10AM)).toBe('state_bars_sunday')
    expect(await block(tylersTx, SUN_10AM)).toBe('state_bars_sunday')
    expect(await block(thalias, SUN_10AM)).toBe('caller_off_today')
    // the queue door refuses the held number too
    const q = await one<{ status: string }>(`public.agent_queue_text($1, '4125560302', $2, 1, null, 'Muse', $3)`,
      [tylersPa, 'Hi Penn, this is Tyler. Are you the current owner of 302 Sunday St? Reply STOP to opt out.', SUN_10AM])
    expect(q.status).toBe('refused')
  })

  it('0242: the opened Sunday says so where the agent looks, with the replies nobody answered; a shut Sunday says nothing', async () => {
    await db.query(`insert into public.twilio_inbound (sid, from10, to_number, body, lead_id, received_at) values ('SM0242', '4145560301', '+12625550000', 'yes', $1, '2099-11-15T15:00:00Z')`, [tylers])
    const open = await one<{ sunday: string; replies: string }>(`public.agent_attention('Muse', $1)`, [SUN_10AM])
    expect(open.sunday).toContain('Today is a Sunday that was opened for texting by desk')
    expect(open.sunday).toContain('answer replies')
    expect(open.replies).toContain('1 person texted back in the last day and has had no answer')
    // under 20 minutes old: not yet
    expect((await one<{ replies?: string }>(`public.agent_attention('Muse', '2099-11-15T15:10:00Z')`)).replies).toBeUndefined()
    // the agent that does not text is told nothing
    expect(await one<unknown>(`public.agent_attention('Muse 2', $1)`, [SUN_10AM])).toBeNull()
    // the list the agent reads is the same people
    const list = await one<{ reply_to: { text: string } }[]>('public.agent_replies_waiting(30)')
    expect(list.map((r) => r.reply_to.text)).toEqual(['yes'])
    // a Sunday that is shut: no line, and no nagging about replies that cannot be answered until Monday
    await db.query(`update public.twilio_inbound set received_at = '2099-11-22T15:00:00Z' where sid = 'SM0242'`)
    // (this clock is in 2099, so the Research Board's behind line, 0248, is there; it is not what this test is about)
    const shut = await one<Record<string, unknown> | null>(`public.agent_attention('Muse', $1)`, [NEXT_SUN])
    expect(Object.keys(shut ?? {}).filter((k) => k !== 'research')).toEqual([])
    // Monday: the reply is owed again
    expect((await one<{ replies: string }>(`public.agent_attention('Muse', '2099-11-23T16:00:00Z')`)).replies).toContain('1 person')
    await db.query(`delete from public.twilio_inbound where sid = 'SM0242'`)
  })

  it('closes itself: Monday the rule is back, the held numbers are ready, and the next Sunday is shut', async () => {
    await one('public.text_day_tick($1)', [MON_1204AM])
    expect(await noSundays()).toBe(true)
    expect(await block(tylersPa, '2099-11-16T16:00:00Z')).toBeNull()
    expect(await block(tylersTx, '2099-11-16T16:00:00Z')).toBeNull()
    await db.exec(`update public.text_fitness set as_of = '2099-11-22'`)
    expect(await one<Record<string, unknown>>('public.text_day_tick($1)', [NEXT_SUN])).toMatchObject({ why: 'Sunday' })
    expect(await listed('2099-11-22')).toEqual([])
  })
})
