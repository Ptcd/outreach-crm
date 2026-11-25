// 0325: a card has a number, and calls to it go out from that number: the one that texted the phone, else a number
// picked from the pool by the card and kept. A number we no longer dial from (flagged as spam) is never given.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATIONS = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')
const POOL = ['+12623812196', '+12624767158', '+12626675223', '+12629996513', '+14144200081', '+14144200843', '+14146778472', '+12624409051', '+12622289462']
let db: PGlite
let n = 0
const line = async (lead: string, phone?: string) => (await db.query<{ r: string | null }>(`select public.card_call_line($1, $2) as r`, [lead, phone ?? null])).rows[0].r
async function card(phone: string) {
  const k = ++n
  const id = (await db.query<{ id: string }>(`insert into public.leads (wpie_owner_id, owner_name, lane, stage, property_address, municipality, locked_to)
    values ($1, $2, 'flip', 'opener_sent', $3, 'Franklin', 'thalia') returning id`, [9500 + k, `OWNER ${k}`, `${k} Line St`])).rows[0].id
  await db.query(`insert into public.contacts (lead_id, kind, value, value_normalized) values ($1, 'phone', $2, $2)`, [id, phone])
  return id
}
const texted = (lead: string, phone: string, from: string) => db.query(
  `insert into public.messages (lead_id, direction, channel, body, from_number, to_number, sent_at, provider_sid, status)
   values ($1, 'out', 'sms', 'Hi', $2, $3, now(), 'SM' || md5(random()::text), 'delivered')`, [lead, from, `+1${phone}`])

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATIONS)
  await db.exec(`insert into public.team_members (email, role, person, display_name) values ('thalia@example.com', 'caller', 'thalia', 'Thalia') on conflict do nothing`)
}, 120_000)

describe('the number a card is called from', () => {
  it('a never-texted card gets one pool number, keeps it, and different cards spread over the pool', async () => {
    const a = await card('4145551001')
    const first = await line(a, '4145551001')
    expect(POOL).toContain(first)
    expect(await line(a, '4145551001')).toBe(first)
    expect((await db.query<{ call_line: string }>(`select call_line from public.leads where id = $1`, [a])).rows[0].call_line).toBe(first)
    const seen = new Set<string>()
    for (let i = 0; i < 40; i++) seen.add((await line(await card(`41455520${String(i).padStart(2, '0')}`)))!)
    expect(seen.size).toBeGreaterThanOrEqual(5)
    for (const s of seen) expect(POOL).toContain(s)
  })
  it('a texted card is called from the number that texted it', async () => {
    const b = await card('4145551002')
    const before = await line(b, '4145551002')
    const other = POOL.find((p) => p !== before)!
    await texted(b, '4145551002', other)
    expect(await line(b, '4145551002')).toBe(other)
    expect(await line(b)).toBe(other)
  })
  it('never the flagged numbers or a caller\'s own line, even when one of them texted the card', async () => {
    for (const bad of ['+12624180202', '+12624299057', '+12623846865']) {
      const c = await card(`414555${bad.slice(-4)}`)
      await texted(c, `414555${bad.slice(-4)}`, bad)
      const got = await line(c, `414555${bad.slice(-4)}`)
      expect(got).not.toBe(bad)
      expect(POOL).toContain(got)
    }
  })
  it('a number we stop dialing from is passed over, and the card gets another and keeps it', async () => {
    const d = await card('4145551004')
    const first = (await line(d, '4145551004'))!
    await db.query(`update public.call_lines set dial = false where number = $1`, [first])
    const next = (await line(d, '4145551004'))!
    expect(next).not.toBe(first)
    expect(await line(d, '4145551004')).toBe(next)
    await db.query(`update public.call_lines set dial = true where number = $1`, [first])
    expect(await line(d, '4145551004')).toBe(next)
  })
  it('no such card, and a caller\'s login cannot ask', async () => {
    expect(await line('00000000-0000-0000-0000-000000000000')).toBeNull()
    await db.exec('set role authenticated')
    await expect(line('00000000-0000-0000-0000-000000000000')).rejects.toThrow()
    await db.exec('reset role')
  })
})
