// 0237: a caller who is off gets no texts on their cards that day. Marking a caller off withdraws that day's waiting
// texts on their cards, blocks new ones at every gate, and the day's room goes to cards whose caller is working.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')
const NOW = '2026-11-17T16:00:00Z'          // Tuesday 10:00 AM Central
const TODAY = '2026-11-17'

let db: PGlite
const rows = async <T>(sql: string, params: unknown[] = []) => (await db.query<T>(sql, params)).rows
const one = async <T>(sql: string, params: unknown[] = []) => (await rows<{ r: T }>(`select ${sql} as r`, params))[0].r
const card = async (ownerId: number, owner: string, lockedTo: 'thalia' | 'adil') => {
  const id = (await rows<{ id: string }>(
    `insert into public.leads (wpie_owner_id, owner_name, lane, stage, property_address, locked_to, reasons_to_sell, mailing_state)
     values ($1, $2, 'flip', 'opener_queued', $3, $4::public.team_person, '{foreclosure}', 'WI') returning id`,
    [ownerId, owner, `${ownerId} Off St`, lockedTo]))[0].id
  await db.query(`insert into public.contacts (lead_id, kind, value, value_normalized, line_type, person_name) values ($1, 'phone', $2, $2, 'mobile', $3)`,
    [id, `414556${String(1000 + ownerId).slice(-4)}`, owner])
  await db.query(`insert into public.text_fitness (wpie_owner_id, verdict, need, need_why, tier, equity, as_of) values ($1, 'ok', true, 'test', 'B', 'likely', $2)`, [ownerId, TODAY])
  return id
}
const phoneOf = async (lead: string) => (await rows<{ v: string }>(`select value_normalized v from public.contacts where lead_id = $1 limit 1`, [lead]))[0].v
const block = async (lead: string) => (await rows<{ block: string | null }>(`select block from public.text_pool($1) where lead_id = $2`, [NOW, lead]))[0].block
const status = async (lead: string) => (await rows<{ send_status: string; send_reason: string | null }>(
  `select send_status, send_reason from public.planned_openers where lead_id = $1 order by created_at desc limit 1`, [lead]))[0]
const listed = async () => (await rows<{ lead_id: string }>(`select lead_id from public.text_day where day = $1`, [TODAY])).map((r) => r.lead_id)

let tylers: string, thalias: string, thalias2: string

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
  await db.exec(`insert into public.team_members (email, role, person, display_name) values
    ('thalia@example.com', 'caller', 'thalia', 'Thalia'), ('adil@example.com', 'caller', 'adil', 'Tyler') on conflict do nothing`)
  await db.exec(`update public.campaign_control set daily_cap = 2, day_first_floor = 1, window_start = '09:00', window_end = '19:00' where id = 1`)
  thalias = await card(201, 'TINA THALIACARD', 'thalia')
  thalias2 = await card(202, 'TODD THALIACARD', 'thalia')
  tylers = await card(203, 'TERRY TYLERCARD', 'adil')
}, 120_000)

describe('a caller who is off', () => {
  it('gets no texts on their cards that day: waiting ones are withdrawn, new ones refused, the room goes to the other caller', async () => {
    await one('public.text_day_build($1)', [NOW])
    expect((await listed()).length).toBe(2)                                  // the cap
    const onList = (await listed()).find((l) => l === thalias || l === thalias2)!
    const q = await one<{ status: string }>(`public.agent_queue_text($1, $2, $3, 1, null, 'Muse', $4)`,
      [onList, await phoneOf(onList), 'Hi there, this is Thalia. Are you the right person to ask about this place? Reply STOP to opt out.', NOW])
    expect(q.status).toBe('queued')

    expect(await one<Record<string, unknown>>(`public.caller_off_set('Thalia', $1, 'not working today')`, [TODAY])).toMatchObject({ ok: true, person: 'thalia', texts_withdrawn: 1 })
    expect(await status(onList)).toEqual({ send_status: 'withdrawn', send_reason: "the card's caller is off that day" })
    expect(await block(thalias)).toBe('caller_off_today')
    expect(await block(tylers)).toBeNull()
    const again = await one<{ status: string; reason: string }>(`public.agent_queue_text($1, $2, $3, 1, null, 'Muse', $4)`,
      [thalias2, await phoneOf(thalias2), 'Hi Todd, this is Thalia. Are you the current owner of 202 Off St? Reply STOP to opt out.', NOW])
    expect(again.status).toBe('refused')

    // the next build: her rows leave the list (the withdrawn one too) and Tyler's card has the room
    await one('public.text_day_build($1)', ['2026-11-17T17:05:00Z'])
    expect(await listed()).toEqual([tylers])
    // the next day she is back
    expect((await rows<{ block: string | null }>(`select block from public.text_pool($1) where lead_id = $2`, ['2026-11-18T16:00:00Z', thalias2]))[0].block).toBeNull()
    expect(await one<Record<string, unknown>>(`public.caller_off_clear('thalia', $1)`, [TODAY])).toMatchObject({ ok: true, cleared: 1 })
    expect(await block(thalias2)).toBeNull()
  })

  it('standing days off: every Saturday and Sunday, and a text carried over onto one is withdrawn by the day\u2019s first build (0238)', async () => {
    const sat = '2026-11-21T16:00:00Z'       // Saturday 10:00 AM Central
    const fri = '2026-11-20T16:00:00Z'
    const blockAt = async (lead: string, at: string) => (await rows<{ block: string | null }>(`select block from public.text_pool($1) where lead_id = $2`, [at, lead]))[0].block
    await db.exec(`update public.text_fitness set as_of = '2026-11-20'`)
    // this test is the days-off rule by itself: the weekend caller rule (0278) is switched off for it
    await db.exec(`update public.campaign_control set weekend_text_caller = null where id = 1`)
    // a text waiting for Saturday on her card, queued before anyone said she is off
    const q = await one<{ status: string }>(`public.agent_queue_text($1, $2, $3, 1, null, 'Muse', $4)`,
      [thalias2, await phoneOf(thalias2), 'Hi Todd, this is Thalia. Are you the current owner of 202 Off St? Reply STOP to opt out.', sat])
    expect(q.status).toBe('queued')
    expect(await one<Record<string, unknown>>(`public.caller_off_weekly_set('thalia', '{6,7}', 'weekends')`)).toMatchObject({ ok: true, person: 'thalia', days: [6, 7] })
    expect(await blockAt(thalias, sat)).toBe('caller_off_today')
    expect(await blockAt(thalias, fri)).toBeNull()
    expect(await blockAt(tylers, sat)).toBeNull()
    await one('public.text_day_build($1)', [sat])
    expect(await status(thalias2)).toEqual({ send_status: 'withdrawn', send_reason: "the card's caller is off that day" })
    expect((await rows<{ lead_id: string }>(`select lead_id from public.text_day where day = '2026-11-21'`)).map((r) => r.lead_id)).toEqual([tylers])
    expect(await one<Record<string, unknown>>(`public.caller_off_weekly_set('thalia', '{8}')`)).toMatchObject({ ok: false })
    expect(await one<Record<string, unknown>>(`public.caller_off_weekly_set('thalia', '{}')`)).toMatchObject({ ok: true, days: [] })
    expect(await blockAt(thalias, sat)).toBeNull()
    await db.exec(`update public.campaign_control set weekend_text_caller = 'adil' where id = 1`)
  })

  it('no text goes out in an off caller\'s name, whoever owns the card now (0272, Colin 2026-11-21)', async () => {
    // a card Tyler owns whose thread started as Thalia, before the card became his
    const moved = await card(211, 'NED MOVEDCARD', 'adil')
    const tylersOwn = await card(212, 'OWEN TYLERTHREAD', 'adil')
    const sent = (lead: string, body: string, when: string) => db.query(
      `insert into public.messages (lead_id, direction, channel, body, status, provider_sid, sent_at, to_number)
       values ($1, 'out', 'sms', $2, 'delivered', $3, $4, '+14145560000')`, [lead, body, `SM${lead.slice(-6)}${when.slice(8, 10)}`, when])
    await sent(moved, 'Hi Ned, this is Thalia. Are you the current owner of 211 Off St? Reply STOP to opt out.', '2026-11-03T16:00:00Z')
    await sent(tylersOwn, 'Hi Owen, this is Tyler. Are you the current owner of 212 Off St? Reply STOP to opt out.', '2026-11-03T16:00:00Z')
    await db.query(`delete from public.caller_off`); await db.query(`delete from public.caller_off_weekly`)
    expect((await rows<{ lead_id: string }>(`select lead_id from public.text_name_off($1)`, [TODAY]))).toEqual([])   // nobody is off: nothing is held
    await one(`public.caller_off_set('Thalia', $1, 'not working today')`, [TODAY])
    expect((await rows<{ lead_id: string; name: string }>(`select lead_id, name from public.text_name_off($1)`, [TODAY]))).toEqual([{ lead_id: moved, name: 'Thalia' }])
    const blocks = await rows<{ lead_id: string; block: string | null }>(`select lead_id, block from public.text_pool($1) where lead_id = any($2::uuid[])`, [NOW, [moved, tylersOwn]])
    expect(blocks.filter((b) => b.lead_id === moved).every((b) => b.block === 'name_off_today')).toBe(true)
    expect(blocks.filter((b) => b.lead_id === tylersOwn).every((b) => b.block === null)).toBe(true)
    // a later text in Tyler's name: the thread has moved on, and it is his to text again
    await sent(moved, 'Hi Ned, Tyler here about 211 Off St. Still thinking it over?', '2026-11-10T16:00:00Z')
    expect((await rows(`select lead_id from public.text_name_off($1)`, [TODAY]))).toEqual([])
    // a text already waiting in her name on his card is withdrawn by the sweep
    await db.query(`delete from public.messages where lead_id = $1 and body like '%Tyler here%'`, [moved])
    await db.query(`insert into public.planned_openers (plan_date, wpie_owner_id, attempt, lead_id, lane, phone, body, send_status, step)
                    values ($1, 211, 2, $2, 'agent', '4145560211', 'Hi Ned, this is Thalia. Still thinking about 211 Off St?', 'planned', 2)`, [TODAY, moved])
    expect(await one<number>(`public.caller_off_sweep($1)`, [TODAY])).toBeGreaterThanOrEqual(1)
    expect(await status(moved)).toEqual({ send_status: 'withdrawn', send_reason: 'it goes out in the name of a caller who is off that day' })
    await db.query(`delete from public.caller_off`)
  })

  it('takes Tyler by either name and nobody else', async () => {
    expect(await one<Record<string, unknown>>(`public.caller_off_set('Tyler', '2026-11-19')`)).toMatchObject({ ok: true, person: 'adil' })
    expect(await one<Record<string, unknown>>(`public.caller_off_set('colin', '2026-11-19')`)).toMatchObject({ ok: false })
  })
})
