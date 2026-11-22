// 0278: Saturdays and Sundays text only Tyler's cards (Colin 2026-11-22), whoever is marked off.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')
const SAT = '2099-11-14', SUN = '2099-11-15', MON = '2099-11-16'

let db: PGlite
const rows = async <T>(sql: string, params: unknown[] = []) => (await db.query<T>(sql, params)).rows
const block = async (lead: string, day: string) =>
  (await rows<{ b: string | null }>(`select public.card_record_block($1, $2::date) as b`, [lead, day]))[0].b
const card = async (ownerId: number, lockedTo: string | null) => {
  const id = (await rows<{ id: string }>(
    `insert into public.leads (wpie_owner_id, owner_name, lane, stage, property_address, locked_to, reasons_to_sell, mailing_state)
     values ($1::bigint, 'OWNER ' || $1::text, 'flip', 'opener_queued', $1::text || ' Weekend St', $2::public.team_person, '{foreclosure}', 'WI') returning id`,
    [ownerId, lockedTo]))[0].id
  await db.query(`insert into public.text_fitness (wpie_owner_id, verdict, need, need_why, tier, equity, as_of) values ($1, 'ok', true, 'test', 'B', 'likely', $2)`, [ownerId, SAT])
  return id
}
let tylers: string, thalias: string, colins: string, nobodys: string

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
  await db.exec(`insert into public.team_members (email, role, person, display_name) values
    ('thalia@example.com', 'caller', 'thalia', 'Thalia'), ('adil@example.com', 'caller', 'adil', 'Tyler'),
    ('colin@example.com', 'owner', 'colin', 'Colin') on conflict do nothing`)
  tylers = await card(401, 'adil')
  thalias = await card(402, 'thalia')     // Thalia is NOT marked off here: the weekend rule stands on its own
  colins = await card(403, 'colin')
  nobodys = await card(404, null)
}, 120_000)

describe('0278: weekends text only Tyler\'s cards', () => {
  it('Saturday and Sunday: Tyler\'s card goes, every other card waits; Monday everyone goes', async () => {
    for (const day of [SAT, SUN]) {
      expect(await block(tylers, day)).toBeNull()
      expect(await block(thalias, day)).toBe('weekend_other_caller')
      expect(await block(colins, day)).toBe('weekend_other_caller')
      expect(await block(nobodys, day)).toBe('weekend_other_caller')
    }
    expect(await block(thalias, MON)).toBeNull()
  })

  it('the weekend caller is a setting; null turns the rule off', async () => {
    await db.exec(`update public.campaign_control set weekend_text_caller = 'thalia' where id = 1`)
    expect(await block(thalias, SAT)).toBeNull()
    expect(await block(tylers, SAT)).toBe('weekend_other_caller')
    await db.exec(`update public.campaign_control set weekend_text_caller = null where id = 1`)
    expect(await block(colins, SAT)).toBeNull()
    await db.exec(`update public.campaign_control set weekend_text_caller = 'adil' where id = 1`)
  })
})
