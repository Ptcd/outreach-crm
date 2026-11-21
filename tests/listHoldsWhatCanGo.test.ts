// 0257 (desk 324/326, 2026-11-20): about 110 of the day's 400 places went every day to the same cards, each written
// and then refused at the moment of sending: a phone two owners share, a third text whose text 2 "was not delivered"
// when it was (the card had been re-keyed to its real owner id and its sent texts had not), a follow-up whose first
// text has no delivery receipt. The pool now says what the send check will say, and a card's texts follow its owner id.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')

let db: PGlite
const A = '00000000-0000-0000-0000-00000000d001'   // Ann's card
const B = '00000000-0000-0000-0000-00000000d002'   // Bob's card: carries Ann's number too
const C = '00000000-0000-0000-0000-00000000d003'   // Ann's second house: same owner name, same number
const M = '00000000-0000-0000-0000-00000000d004'   // a card an agent made on a negative owner id
const one = async <T>(sql: string, params: unknown[] = []) => (await db.query<{ v: T }>(`select ${sql} as v`, params)).rows[0].v

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
  await db.exec(`
    insert into public.leads (id, wpie_owner_id, owner_name, lane, stage, property_address, municipality, mailing_state) values
      ('${A}', 9301, 'ANN ALPHA', 'flip', 'opener_queued', '1 A ST', 'CITY OF TEST', 'WI'),
      ('${B}', 9302, 'BOB BRAVO', 'flip', 'opener_queued', '2 B ST', 'CITY OF TEST', 'WI'),
      ('${C}', 9303, 'Ann Alpha', 'flip', 'opener_queued', '3 C ST', 'CITY OF TEST', 'WI'),
      ('${M}', -77, 'MUSE MADE', 'flip', 'opener_sent', '4 M ST', 'CITY OF TEST', 'WI');
    insert into public.contacts (lead_id, kind, value, value_normalized) values
      ('${A}', 'phone', '4145550101', '4145550101'), ('${B}', 'phone', '4145550101', '4145550101'),
      ('${A}', 'phone', '4145550102', '4145550102'), ('${C}', 'phone', '4145550102', '4145550102'),
      ('${M}', 'phone', '4145550104', '4145550104');`)
}, 180_000)

describe('the list holds only what can go', () => {
  it('a number two different owners share is shared; one owner with two houses is not', async () => {
    expect(await one<boolean>(`public.phone_is_shared('4145550101')`)).toBe(true)    // Ann and Bob
    expect(await one<boolean>(`public.phone_is_shared('4145550102')`)).toBe(false)   // Ann, twice
    expect(await one<boolean>(`public.phone_is_shared('4145550104')`)).toBe(false)
  })

  it('an owner who opted out on one number is opted out on every card of theirs', async () => {
    expect(await one<boolean>(`public.owner_opted_out(9301)`)).toBe(false)
    await db.exec(`update public.contacts set suppressed = true where lead_id = '${A}' and value_normalized = '4145550102'`)
    expect(await one<boolean>(`public.owner_opted_out(9301)`)).toBe(true)
    expect(await one<boolean>(`public.owner_opted_out(9302)`)).toBe(false)
    expect(await one<boolean>(`public.owner_opted_out(null)`)).toBe(false)
  })

  it('a follow-up is blocked for the send check\'s own reasons, and passes once the earlier texts are delivered', async () => {
    const plan = (lead: string, owner: number, attempt: number, status: string, day: string) => db.query(
      `insert into public.planned_openers (plan_date, wpie_owner_id, attempt, lead_id, phone, body, lane, send_status)
       values ($1, $2, $3, $4, '+14145550104', 'x', 'agent', $5)`, [day, owner, attempt, lead, status])
    expect(await one<string | null>(`public.followup_send_block($1, '4145550104', 2)`, [M])).toBe('opener_not_delivered')
    await plan(M, -77, 1, 'delivered', '2026-10-26')
    expect(await one<string | null>(`public.followup_send_block($1, '4145550104', 2)`, [M])).toBeNull()
    expect(await one<string | null>(`public.followup_send_block($1, '4145550104', 3)`, [M])).toBe('text_2_not_delivered')
    await plan(M, -77, 12, 'delivered', '2026-10-29')
    expect(await one<string | null>(`public.followup_send_block($1, '4145550104', 3)`, [M])).toBeNull()
    expect(await one<string | null>(`public.followup_send_block($1, '4145550101', 2)`, [A])).toBe('phone_shared')
  })

  it('when a card is re-keyed to its real owner, the texts already sent on it go with it', async () => {
    expect(await one<number>(`(select count(*)::int from public.planned_openers where lead_id = '${M}' and wpie_owner_id = -77)`)).toBe(2)
    await db.exec(`update public.leads set wpie_owner_id = 462382 where id = '${M}'`)
    expect(await one<number>(`(select count(*)::int from public.planned_openers where lead_id = '${M}' and wpie_owner_id = 462382)`)).toBe(2)
    // the send check's own test for text 2 (by owner id, attempt 12, delivered) now finds it
    expect(await one<boolean>(`exists (select 1 from public.planned_openers p where p.wpie_owner_id = 462382 and p.attempt = 12 and p.send_status = 'delivered')`)).toBe(true)
  })
})
