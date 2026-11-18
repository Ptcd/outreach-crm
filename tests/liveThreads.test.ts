// 0246 (Colin 2026-11-16): a caller is told when a seller on their card is texting back and forth right now. Live is
// them, us, them inside the hour; one alert per card per hour; the card's caller, or the other one when that caller is
// off today; nothing in quiet hours, for a taken-over thread, or for a do-not-contact card. On the real migrations.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'
import { liveThreadMessage, runLiveThreadAlerts, type LiveThread } from '../supabase/functions/_shared/liveThreads'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')

let db: PGlite
let NOON: string                                  // today, 12:00 Central: never in quiet hours
const rows = async <T>(sql: string, params: unknown[] = []) => (await db.query<T>(sql, params)).rows
const one = async <T>(sql: string, params: unknown[] = []) => (await rows<{ r: T }>(`select ${sql} as r`, params))[0].r
const at = (min: number) => new Date(new Date(NOON).getTime() + min * 60_000).toISOString()
let sid = 0
const them = (lead: string, min: number, body: string, stop = false) => db.query(
  `insert into public.twilio_inbound (sid, from10, body, lead_id, received_at, is_opt_out) values ($1, '4145550001', $2, $3, $4, $5)`,
  [`SM-live-${++sid}`, body, lead, at(min), stop])
const us = (lead: string, min: number, body: string) => db.query(
  `insert into public.messages (lead_id, direction, channel, body, status, sent_at, created_at) values ($1, 'out', 'sms', $2, 'delivered', $3, $3)`, [lead, body, at(min)])
const claim = (min = 0) => one<LiveThread[]>(`public.live_threads_claim($1)`, [at(min)])

const C: Record<string, string> = {}
let n = 900
const card = async (owner: string, caller: string | null, extra = '') => {
  n += 1
  return (await rows<{ id: string }>(
    `insert into public.leads (wpie_owner_id, owner_name, lane, stage, property_address, municipality, locked_to, mailing_state ${extra ? ', ' + extra.split('=')[0] : ''})
     values ($1, $2, 'flip', 'reply_received', $3, 'CITY OF TEST', $4, 'WI' ${extra ? ', ' + extra.split('=')[1] : ''}) returning id`, [-n, owner, `${n} Live St`, caller]))[0].id
}
const exchange = async (lead: string, last = -2) => { await them(lead, last - 20, 'who is this'); await us(lead, last - 10, 'This is Thalia, a local buyer'); await them(lead, last, 'oh ok, I might sell') }

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
  await db.exec(`insert into public.team_members (email, role, person, display_name, alert_email) values
    ('colin@example.com', 'owner', 'colin', 'Colin', null), ('thalia@example.com', 'caller', 'thalia', 'Thalia', 'thalia-alerts@example.com'),
    ('adil@example.com', 'caller', 'adil', 'Tyler', null)
    on conflict (email) do update set alert_email = excluded.alert_email, display_name = excluded.display_name`)
  NOON = await one<string>(`(((now() at time zone 'America/Chicago')::date + time '12:00') at time zone 'America/Chicago')`)
  await db.exec(`delete from public.caller_off; delete from public.caller_off_weekly`)
  C.live = await card('LIVELY, LOU', 'thalia')
  C.first = await card('FIRST, FRAN', 'thalia')
  C.stale = await card('STALE, STAN', 'thalia')
  C.tyler = await card('TYLERS, TOM', 'adil')
  C.taken = await card('TAKEN, TESS', 'thalia')
  C.dnc = await card('DONOT, DAN', 'thalia')
  C.nobody = await card('NOBODY, NED', null)
  C.stop = await card('STOPPER, SUE', 'thalia')
}, 120_000)

describe('which threads are live', () => {
  it('them, us, them inside the hour is live, and the card\'s caller is told', async () => {
    await exchange(C.live)
    await them(C.first, -3, 'yes I own it')                                  // a first reply only: not a back and forth
    await us(C.first, -30, 'Hi Fran, this is Thalia. Are you the owner?')
    await them(C.stale, -200, 'maybe'); await us(C.stale, -190, 'what would you need?'); await them(C.stale, -100, 'not sure')   // long over
    const out = await claim()
    expect(out.map((x) => x.lead_id)).toEqual([C.live])
    expect(out[0]).toMatchObject({ person: 'thalia', card_caller: 'thalia', email: 'thalia-alerts@example.com', their_words: 'oh ok, I might sell', texts_this_hour: 2 })
  })
  it('is handed out once, and not again inside the hour however much they write', async () => {
    expect(await claim()).toEqual([])
    await us(C.live, 5, 'what is the place like?'); await them(C.live, 8, 'needs a roof')
    expect(await claim(10)).toEqual([])
  })
  it('tells them again when the thread is still going an hour later', async () => {
    await us(C.live, 58, 'and the furnace?'); await them(C.live, 62, 'furnace is new')
    const out = await claim(63)
    expect(out.map((x) => x.lead_id)).toEqual([C.live])
  })
  it('leaves alone a taken-over thread, a do-not-contact card, a STOP, and a card with no caller', async () => {
    for (const k of ['taken', 'dnc', 'nobody']) await exchange(C[k])
    await db.query(`update public.leads set human_takeover_at = now(), human_takeover_by = 'thalia' where id = $1`, [C.taken])
    await db.query(`update public.leads set stage = 'dnc' where id = $1`, [C.dnc])
    await db.query(`update public.leads set locked_to = null, assigned_to = 'colin' where id = $1`, [C.nobody])   // a new card gets a caller by default
    await them(C.stop, -22, 'who is this'); await us(C.stop, -12, 'This is Thalia'); await them(C.stop, -2, 'STOP', true)
    expect(await claim()).toEqual([])
  })
  it('says nothing in quiet hours, or when it is switched off', async () => {
    await exchange(C.tyler)
    const night = await one<string>(`(((now() at time zone 'America/Chicago')::date + time '23:30') at time zone 'America/Chicago')`)
    expect(await one<LiveThread[]>(`public.live_threads_claim($1)`, [night])).toEqual([])
    await db.exec(`update public.campaign_control set live_thread_alerts = false where id = 1`)
    expect(await claim()).toEqual([])
    await db.exec(`update public.campaign_control set live_thread_alerts = true where id = 1`)
  })
})

describe('who is told', () => {
  it('a caller who is off today: nobody else is told, the card has one owner (0250)', async () => {
    await db.query(`insert into public.caller_off (person, day, note, set_by) values ('adil', ($1::timestamptz at time zone 'America/Chicago')::date, 'test', 'desk')`, [NOON])
    expect((await claim()).filter((t) => t.lead_id === C.tyler)).toHaveLength(0)
  })
})

describe('the sender', () => {
  it('pushes the person\'s phones and emails their alert address, and records what got through', async () => {
    await db.exec(`delete from public.live_thread_alerts`)
    const pushes: { person: string; title: string }[] = []; const mails: { to: string; subject: string }[] = []
    const rpc = async (fn: string, args: Record<string, unknown>) => {
      const keys = Object.keys(args)
      const r = await db.query<{ r: unknown }>(`select public.${fn}(${keys.map((k, i) => `${k} => $${i + 1}`).join(', ')}) as r`, keys.map((k) => args[k]))
      return { data: r.rows[0].r, error: null }
    }
    const s = await runLiveThreadAlerts({ rpc, appUrl: 'https://app.example', now: () => new Date(NOON),
      push: async (person, m) => { pushes.push({ person, title: m.title }); return person === 'thalia' ? 1 : 0 },
      email: async (m) => { mails.push({ to: m.to, subject: m.subject }) } })
    expect(s).toMatchObject({ threads: 1, pushes: 1, emails: 1, nothing: 0 })      // Tyler is off: his card's thread waits for him
    expect(pushes.every((p) => p.person === 'thalia')).toBe(true)
    expect(mails.every((m) => m.to === 'thalia-alerts@example.com')).toBe(true)
    expect(await one<number>(`(select count(*)::int from public.live_thread_alerts where reached = 2)`)).toBe(1)
    const again = await runLiveThreadAlerts({ rpc, appUrl: 'https://app.example', now: () => new Date(NOON), push: async () => 1, email: null })
    expect(again.threads).toBe(0)
  })
  it('claims nothing when there is nowhere to send it', async () => {
    const s = await runLiveThreadAlerts({ rpc: async () => { throw new Error('must not be called') }, appUrl: 'x', push: null, email: null })
    expect(s.off).toBeTruthy()
  })
})
