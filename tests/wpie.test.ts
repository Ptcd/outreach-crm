import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { describe, expect, it } from 'vitest'
import { GATE_ITEMS, HARD_STOPS, STAGES, gateSuggestion, type GateScores } from '@/lib/wpie'
import { isoToLocalInput, localInputToIso, todayLocal } from '@/lib/format'
import { SUPABASE_STUB } from './supabaseStub'

// Every migration, in order (0001 schema, 0002 gate round 2, ...).
const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')

function enumValues(name: string): string[] {
  const m = MIGRATION.match(new RegExp(`create type public\\.${name} as enum \\(([\\s\\S]*?)\\);`))
  if (!m) throw new Error(`enum ${name} not found`)
  return [...m[1].matchAll(/'([a-z_]+)'/g)].map((x) => x[1])
}

describe('WPIE vocab matches the schema', () => {
  it('has a plain label for every lead stage, and only those', () => {
    expect(STAGES.map((s) => s.id).sort()).toEqual(enumValues('lead_stage').sort())
    for (const s of STAGES) expect(s.label.length).toBeGreaterThan(2)
  })

  it('uses the six gate items and the five hard stops the table allows', () => {
    expect(GATE_ITEMS.map((g) => g.id)).toEqual([
      'reason_and_clock', 'decision_makers', 'number_and_anchor', 'flexibility', 'condition', 'numbers_close',
    ])
    for (const g of GATE_ITEMS) expect(g.scale).toHaveLength(3)
    for (const h of HARD_STOPS) expect(MIGRATION).toContain(`'${h.id}'`)
  })
})

describe('gate rule', () => {
  const s = (a: number[]): GateScores => ({
    reason_and_clock: a[0], decision_makers: a[1], number_and_anchor: a[2], flexibility: a[3], condition: a[4], numbers_close: a[5],
  })

  it('follows the written pass rule', () => {
    expect(gateSuggestion(s([2, 2, 2, 2, 1, 1]), [])).toBe('walk')
    expect(gateSuggestion(s([1, 2, 1, 0, 1, 2]), [])).toBe('walk')
    expect(gateSuggestion(s([2, 1, 2, 2, 2, 1]), [])).toBe('one_more_call')
    expect(gateSuggestion(s([2, 2, 2, 0, 2, 1]), [])).toBe('one_more_call') // flexibility 0 needs numbers_close 2
    expect(gateSuggestion(s([2, 2, 2, 2, 2, 0]), [])).toBe('no_walk')
    expect(gateSuggestion(s([1, 1, 1, 1, 1, 1]), [])).toBe('no_walk')
    expect(gateSuggestion(s([2, 2, 2, 2, 2, 2]), ['no_authority'])).toBe('no_walk')
  })

  it('agrees with the database function on every possible score', async () => {
    const db = new PGlite()
    await db.exec(SUPABASE_STUB)
    await db.exec(MIGRATION)
    const res = await db.query<{ a: number; b: number; c: number; d: number; e: number; f: number; stop: boolean; out: string }>(`
      select a, b, c, d, e, f, stop,
             public.gate_suggestion(a::smallint, b::smallint, c::smallint, d::smallint, e::smallint, f::smallint,
                                    case when stop then array['listed_active'] else '{}'::text[] end)::text as out
        from generate_series(0,2) a, generate_series(0,2) b, generate_series(0,2) c, generate_series(0,2) d,
             generate_series(0,2) e, generate_series(0,2) f, (values (true), (false)) v(stop)`)
    expect(res.rows).toHaveLength(729 * 2)
    for (const r of res.rows) {
      expect(gateSuggestion(s([r.a, r.b, r.c, r.d, r.e, r.f]), r.stop ? ['listed_active'] : [])).toBe(r.out)
    }
    await db.close()
  })
})

describe('Milwaukee time helpers', () => {
  it('round-trips a datetime-local value', () => {
    const iso = localInputToIso('2026-10-21T17:30')!
    expect(iso).toBe('2026-10-21T22:30:00.000Z') // CDT is UTC-5
    expect(isoToLocalInput(iso)).toBe('2026-10-21T17:30')
    expect(localInputToIso('2026-12-01T09:00')).toBe('2026-12-01T15:00:00.000Z') // CST is UTC-6
  })

  it("knows today's date in Milwaukee", () => {
    expect(todayLocal(new Date('2026-10-21T03:00:00Z'))).toBe('2026-10-20')
  })
})
