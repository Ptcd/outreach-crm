// 0290: who died and who to talk to, on the probate cards (Colin 2026-11-22: "You could look up obits").
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')
let db: PGlite
type Json = Record<string, any>
const one = async (sql: string, params: unknown[] = []) => (await db.query<{ r: Json }>(`select ${sql} as r`, params)).rows[0].r
let card: string, plain: string

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
  const add = async (owner: string, notes: string) => (await db.query<{ id: string }>(
    `insert into public.leads (wpie_owner_id, owner_name, lane, stage, property_address, municipality, county, mailing_state, reasons_to_sell, notes)
     values ((random() * 1e8)::bigint, $1, 'flip', 'opener_sent', '74 Pioneer Ct', 'Fond du Lac', 'Fond du Lac', 'WI', '{Probate}', $2) returning id`, [owner, notes])).rows[0].id
  card = await add('THOMPSON, RUSSEL J', 'STEP 6 PACK\nCase: Fond du Lac County 2026PR000012 (probate / estate).\nCourt subject (Step 2, verbatim): Russel J Thompson\nParcel: 039FDL1')
  plain = await add('ROE, JANE', 'Case: Brown County 2026CV000496 (foreclosure).\nCourt subject (verbatim): Jane Roe')
  const person = (await db.query<{ id: string }>(`insert into public.people (kind, name, name_key) values ('person', 'Russel J Thompson', 'russel j thompson') returning id`)).rows[0].id
  await db.query(`insert into public.interests (lead_id, person_id, role, status) values ($1, $2, 'owner_of_record', 'active')`, [card, person])
}, 180_000)

describe('0290: who died and who to talk to', () => {
  it('lists the probate cards, hands a batch with the method, and one agent holds a card at a time', async () => {
    const g = await one(`public.agent_estate_people('Grok', 15)`)
    expect(g.cards.map((c: Json) => c.lead_id)).toEqual([card])            // the foreclosure card is not on the list
    expect(g.cards[0]).toMatchObject({ probate_subject: 'Russel J Thompson', probate_case: '2026PR000012', owner_on_record: 'THOMPSON, RUSSEL J' })
    expect(g.cards[0].people_on_card.length).toBeGreaterThanOrEqual(1)   // the card makes its own owner record
    expect(g.how).toMatch(/A name alone is not a match/)
    expect((await one(`public.agent_estate_people('Muse 2', 15)`)).cards).toEqual([])
    expect(plain).toBeTruthy()
  })

  it('"found" is refused until the card shows it; unsure needs what was seen; done leaves the list', async () => {
    const done = (b: Json) => one(`public.agent_estate_people_done($1::jsonb, 'Grok')`, [JSON.stringify({ lead_id: card, ...b })])
    expect((await done({ outcome: 'found' })).reason).toMatch(/source/)
    expect((await done({ outcome: 'found', source: 'https://example.org/obit' })).reason).toMatch(/add_prospects first/)
    expect((await done({ outcome: 'unsure' })).reason).toMatch(/where you looked/)
    await db.query(`update public.interests set status = 'deceased', status_reason = 'died 2026-01-08, obituary link' where lead_id = $1`, [card])
    expect(await done({ outcome: 'found', source: 'https://example.org/obit' })).toMatchObject({ ok: true, left: 0 })
    expect((await one(`public.agent_estate_people('Grok', 15)`)).cards).toEqual([])
  })
})
