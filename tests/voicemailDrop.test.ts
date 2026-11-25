// 0319: the voicemail drop. voicemail_drop_check says who may get the recorded message and writes its words from the
// card; as shipped only a number that called us or wrote back interested gets one (a cold number gets the caller's
// own voice), one message per number in three days, and another caller's card is refused.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATIONS = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')
const SID = (n: number) => `CA${String(n).padStart(32, '0')}`
const THALIA = { sub: '00000000-0000-0000-0000-00000000000c', email: 'thalia@example.com' }
const TYLER = { sub: '00000000-0000-0000-0000-00000000000d', email: 'adil@example.com' }

let db: PGlite
let card = ''
let estate = ''
const one = async <T>(sql: string, params: unknown[] = []) => (await db.query<{ r: T }>(`select ${sql} as r`, params)).rows[0].r
const as = (who: object | null) => db.query(`select set_config('request.jwt.claims', $1, false)`, [who ? JSON.stringify(who) : ''])
type Check = { ok: boolean; code?: string; reason?: string; say?: string; voice?: string; person?: string }
const check = (lead: string, phone: string) => one<Check>(`public.voicemail_drop_check($1, $2)`, [lead, phone])

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATIONS)
  await db.exec(`insert into public.team_members (email, role, person, display_name) values ('thalia@example.com', 'caller', 'thalia', 'Thalia'),
    ('adil@example.com', 'caller', 'adil', 'Tyler') on conflict do nothing`)
  const mk = async (id: number, name: string, addr: string, reasons: string) => (await db.query<{ id: string }>(
    `insert into public.leads (wpie_owner_id, owner_name, lane, stage, property_address, municipality, locked_to, assigned_to, reasons_to_sell)
     values ($1, $2, 'flip', 'follow_up', $3, 'Franklin', 'thalia', 'thalia', $4::text[]) returning id`, [id, name, addr, reasons])).rows[0].id
  card = await mk(9801, 'OLIVIA WYNE', '8408 S Tuckaway Shores Drv', '{}')
  estate = await mk(9802, 'RUSSEL GONE', '74 Pioneer Ct', '{probate filing}')
  await db.query(`insert into public.contacts (lead_id, kind, value, value_normalized) values
    ($1, 'phone', '4145559801', '4145559801'), ($1, 'phone', '4145559802', '4145559802'), ($1, 'phone', '4145559803', '4145559803'),
    ($2, 'phone', '4145559804', '4145559804')`, [card, estate])
  // 9801 wrote back interested; 9802 called us; 9803 never did either; the estate's number called us
  await db.query(`insert into public.reply_drafts (phone10, lead_id, inbound_body, inbound_at, intent, kind, status)
    values ('4145559801', $1, 'Yes I would sell, call me', now(), 'interested', 'candidate', 'no_reply')`, [card])
  await db.query(`insert into public.inbound_calls (call_sid, lead_id, from10, to_number, status) values ($1, $2, '4145559802', '+12623812196', 'missed'),
    ($3, $4, '4145559804', '+12623812196', 'missed')`, [SID(1), card, SID(2), estate])
})

describe('a street said aloud', () => {
  it('spells out directions and street types, and reads a leading St as Saint', async () => {
    expect(await one(`public.speech_street('8408 S Tuckaway Shores Drv')`)).toBe('South Tuckaway Shores Drive')
    expect(await one(`public.speech_street('3524 BUCKINGHAM RD')`)).toBe('Buckingham Road')
    expect(await one(`public.speech_street('226 60th Ave')`)).toBe('60th Avenue')
    expect(await one(`public.speech_street('1321 S Wilson Ave')`)).toBe('South Wilson Avenue')
    expect(await one(`public.speech_street('500 St Paul Ave')`)).toBe('Saint Paul Avenue')
    expect(await one(`public.speech_street('8408 S TUCKAWAY SHORE DR S')`)).toBe('South Tuckaway Shore Drive South')
    expect(await one(`public.speech_street('12 Main St Unit 4')`)).toBeNull()
  })
})

describe('who may get the recorded message', () => {
  it('a number that wrote back interested or called us gets it, with their name, the street and the caller', async () => {
    await as(THALIA)
    const a = await check(card, '(414) 555-9801')
    expect(a).toMatchObject({ ok: true, person: 'thalia', voice: 'Polly.Joanna-Neural' })
    // 0320, Colin's wording: no "recorded message", no team, just Thalia asking whether they would sell that address
    expect(a.say).toBe("Hi Olivia, this is Thalia. I'm calling to see if you'd be interested in selling the place on South Tuckaway Shores Drive. "
      + 'You can call or text me back at {number}. Thanks.')
    expect(await check(card, '4145559802')).toMatchObject({ ok: true })
  })
  it('a cold number is left in the caller\'s own voice until Colin opens it to everyone', async () => {
    expect(await check(card, '4145559803')).toMatchObject({ ok: false, code: 'cold' })
    await as(null)
    await db.exec(`update public.voicemail_drop_rules set mode = 'all'`)
    await as(THALIA)
    expect(await check(card, '4145559803')).toMatchObject({ ok: true })
    await as(null)
    await db.exec(`update public.voicemail_drop_rules set mode = 'off'`)
    await as(THALIA)
    expect(await check(card, '4145559801')).toMatchObject({ ok: false, code: 'off' })
    await as(null)
    await db.exec(`update public.voicemail_drop_rules set mode = 'engaged'`)
    await as(THALIA)
  })
  it('an estate card is not greeted by name', async () => {
    const e = await check(estate, '4145559804')
    expect(e.ok).toBe(true)
    expect(e.say!.startsWith('Hi, this is Thalia.')).toBe(true)
    expect(e.say).toContain('the place on Pioneer Court')
  })
  it('refuses a blocked number, a number not on the card, and the other caller\'s card', async () => {
    expect(await check(card, '4145550000')).toMatchObject({ ok: false, code: 'number' })
    await as(null)
    await db.exec(`update public.contacts set suppressed = true where value_normalized = '4145559802'`)
    await as(THALIA)
    expect(await check(card, '4145559802')).toMatchObject({ ok: false, code: 'blocked' })
    await as(TYLER)
    await expect(check(card, '4145559801')).rejects.toThrow()
    await as(THALIA)
  })
  it('one recorded message per number in three days', async () => {
    expect(await one(`public.voicemail_drop_done($1, '4145559801', $2, 'Hi Olivia')`, [card, SID(9)])).toMatchObject({ ok: true })
    expect(await one(`public.voicemail_drop_done($1, '4145559801', $2, 'Hi Olivia')`, [card, SID(9)])).toMatchObject({ ok: true })
    expect((await db.query(`select 1 from public.voicemail_drops`)).rows).toHaveLength(1)
    expect(await check(card, '4145559801')).toMatchObject({ ok: false, code: 'recent' })
    await as(null)
    await db.exec(`update public.voicemail_drops set at = now() - interval '4 days'`)
    await as(THALIA)
    expect(await check(card, '4145559801')).toMatchObject({ ok: true })
  })
})

// 0321: on a three-line round nobody hears the beep, so the phone server asks for the caller whose line it is
describe('the phone server, for a voicemail that answered a three-line line', () => {
  const auto = (lead: string, phone: string, who: string) => one<Check>(`public.voicemail_drop_auto($1, $2, $3)`, [lead, phone, who])
  it('reads the same rule as the button, in the name of the caller whose line it is', async () => {
    await as(null)
    await db.exec(`delete from public.voicemail_drops`)
    const a = await auto(card, '4145559801', 'thalia')
    expect(a).toMatchObject({ ok: true, person: 'thalia', voice: 'Polly.Joanna-Neural' })
    expect(a.say).toContain('Hi Olivia, this is Thalia.')
    expect(await auto(card, '4145559803', 'thalia')).toMatchObject({ ok: false, code: 'cold' })
    expect(await auto(card, '4145559802', 'thalia')).toMatchObject({ ok: false, code: 'blocked' })
  })
  it('refuses the other caller\'s card and someone not on the team', async () => {
    expect(await auto(card, '4145559801', 'adil')).toMatchObject({ ok: false, code: 'card' })
    expect(await auto(card, '4145559801', 'nobody')).toMatchObject({ ok: false, code: 'who' })
  })
  it('keeps the row and corrects the note the app wrote when the line ended', async () => {
    await as(THALIA)
    await one(`public.log_call($1, '4145559801', 'no_answer', 'No answer: voicemail picked up, no message left (three lines, Power hour).')`, [card])
    await as(null)
    expect(await one(`public.voicemail_drop_auto_done($1, '4145559801', 'thalia', $2, 'Hi Olivia')`, [card, SID(21)])).toMatchObject({ ok: true, note_fixed: true })
    const body = (await db.query<{ body: string }>(`select body from public.messages where lead_id = $1 and channel = 'call' order by sent_at desc limit 1`, [card])).rows[0].body
    expect(body).toContain('voicemail picked up, the recorded message was left (three lines, Power hour).')
    expect(await auto(card, '4145559801', 'thalia')).toMatchObject({ ok: false, code: 'recent' })
    // a caller's login cannot run the phone server's functions
    await db.exec(`set role authenticated`)
    await expect(auto(card, '4145559801', 'thalia')).rejects.toThrow()
    await db.exec(`reset role`)
  })
})
