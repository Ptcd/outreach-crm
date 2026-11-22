// 0289: an estate card is never greeted by name (74 Pioneer Ct, 2026-11-22: "Hi Russel" to the family of the Russel
// the card's own probate note named).
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')
let db: PGlite
const lead = async (owner: string, reasons: string[]) => (await db.query<{ id: string }>(
  `insert into public.leads (wpie_owner_id, owner_name, lane, stage, property_address, mailing_state, reasons_to_sell)
   values ((random() * 1e8)::bigint, $1, 'flip', 'opener_queued', '74 Pioneer Ct', 'WI', $2) returning id`, [owner, reasons])).rows[0].id

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
}, 180_000)

describe('0289: an estate card is never greeted by name', () => {
  it('a probate or estate reason, or anyone marked deceased, makes it an estate card', async () => {
    const estate = await lead('THOMPSON, RUSSEL J', ['Probate / estate - Fond du Lac County case 2026PR000012'])
    const plain = await lead('ROE, JANE', ['behind on taxes'])
    const is = async (id: string) => (await db.query<{ r: boolean }>(`select public.card_is_estate($1) as r`, [id])).rows[0].r
    expect(await is(estate)).toBe(true)
    expect(await is(plain)).toBe(false)
    const person = (await db.query<{ id: string }>(`insert into public.people (kind, name, name_key) values ('person', 'Jane Roe', 'jane roe') returning id`)).rows[0].id
    await db.query(`insert into public.interests (lead_id, person_id, role, status) values ($1, $2, 'owner_of_record', 'deceased')`, [plain, person])
    expect(await is(plain)).toBe(true)
    // the sale text runs with the rule in it (it writes words only for a card with a sale ahead)
    await expect(db.query(`select public.sale_first_text($1, 'Tyler', current_date + 30)`, [estate])).resolves.toBeTruthy()
  })
})
