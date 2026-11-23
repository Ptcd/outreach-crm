// 0314: house facts are not needed to make a card; an agent puts them on later with card_facts_set, the county
// assessor's record is never written over, and cards_missing_facts counts both.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')

let db: PGlite
const rows = async <T>(sql: string, params: unknown[] = []) => (await db.query<T>(sql, params)).rows
const one = async <T>(sql: string, params: unknown[] = []) => (await rows<{ r: T }>(`select ${sql} as r`, params))[0].r
const set = (p: Record<string, unknown>) => one<Record<string, unknown>>(`public.agent_card_facts_set($1::jsonb, 'Grok')`, [JSON.stringify(p)])
const missing = (p: Record<string, unknown> = {}) =>
  one<{ counts: Record<string, number>; cards: { lead_id: string; missing: string[] }[] }>(`public.agent_cards_missing_facts($1::jsonb, 'Grok')`, [JSON.stringify(p)])

const C: Record<string, string> = {}

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
  const mk = async (addr: string, wpid: number | null) => (await rows<{ id: string }>(
    `insert into public.leads (owner_name, lane, stage, property_address, wpie_property_id, county) values ('OWNER', 'flip', 'opener_queued', $1, $2, 'Racine') returning id`,
    [addr, wpid]))[0].id
  C.agentMade = await mk('1 Agent Made St', null)                 // no parcel from the laptop: made without any house facts
  C.assessor = await mk('2 Assessor St', 9002)
  await db.query(`insert into public.property_values (wpie_property_id, building_sqft, bedrooms, as_of) values (9002, 1450, 3, current_date)`)
})

describe('card_facts_set', () => {
  it('a card exists with no house facts at all, and is on the list to fill', async () => {
    const m = await missing()
    expect(m.cards.find((c) => c.lead_id === C.agentMade)?.missing).toEqual(['sqft', 'beds', 'baths', 'basement'])
  })

  it('writes what an agent read, with where, and the list shrinks', async () => {
    const r = await set({ lead_id: C.agentMade, sqft: 1180, beds: 3, baths_full: 1, basement: 'full, unfinished', source: 'Racine County assessor record card', date: '2026-11-23' })
    expect(r).toMatchObject({ ok: true, written: ['sqft', 'beds', 'baths_full', 'basement'] })
    const f = (await rows<{ building_sqft: number; sources: Record<string, { source: string; by: string }> }>(`select building_sqft, sources from public.card_facts where lead_id = $1`, [C.agentMade]))[0]
    expect(f.building_sqft).toBe(1180)
    expect(f.sources.sqft).toMatchObject({ source: 'Racine County assessor record card', by: 'Grok' })
    expect((await missing()).cards.find((c) => c.lead_id === C.agentMade)).toBeUndefined()
  })

  it('never writes over the county assessor record', async () => {
    const r = await set({ lead_id: C.assessor, sqft: 2000, baths_full: 2, source: 'Zillow listing' })
    expect(r).toMatchObject({ ok: true, written: ['baths_full'], kept_assessor: ['sqft'] })
    expect(await one<number | null>(`(select building_sqft from public.card_facts where lead_id = $1)`, [C.assessor])).toBeNull()
  })

  it('refuses a guess or a write with no source', async () => {
    expect(await set({ lead_id: C.agentMade, sqft: 1200 })).toMatchObject({ ok: false })
    expect(await set({ lead_id: C.agentMade, sqft: 90000, source: 'Zillow listing' })).toMatchObject({ ok: false })
    expect(await set({ lead_id: C.agentMade, beds: 2.5, source: 'Zillow listing' })).toMatchObject({ ok: false })
    expect(await set({ lead_id: C.agentMade, source: 'Zillow listing' })).toMatchObject({ ok: false })
  })
})
