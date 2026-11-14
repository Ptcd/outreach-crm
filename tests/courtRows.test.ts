// Court rows (0227): an agent deposits filings it has banked; the laptop answers each row. On the real migrations.
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
type Dep = { ok: boolean; reason?: string; added: number; updated: number; already_answered: number; waiting: number; refused: { case_number: string; reason: string }[] }
const deposit = (kind: string, list: object[]) => one<Dep>(`public.agent_court_rows_deposit($1::jsonb, 'Muse 2')`, [JSON.stringify({ kind, rows: list })])
const status = (p: object = {}) => one<{ by_kind: Record<string, Record<string, number>>; why_not_matched: Record<string, number>; rows: { case_number: string; state: string }[] | null }>(
  `public.agent_court_rows_status($1::jsonb, 'Muse 2')`, [JSON.stringify(p)])

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
}, 120_000)

describe('court rows', () => {
  it('takes eviction rows, refuses the ones with something missing, and the same case is the same row', async () => {
    const a = await deposit('eviction', [
      { county: 'Milwaukee County', case_number: '2026-SC-007476', filed: '2026-03-20', plaintiff: 'Bustos, Juana', defendant: 'A Tenant', address: '2319 S 10th St', city: 'Milwaukee', zip: '53215', class_code: '31004' },
      { county: 'Dane', case_number: '2026SC001', address: '1 Main St' },
      { county: 'Dane', case_number: 'nonsense', address: '1 Main St', city: 'Madison' },
    ])
    expect(a).toMatchObject({ ok: true, added: 1, waiting: 1 })
    expect(a.refused.map((r) => r.reason)).toEqual([expect.stringContaining('needs the city'), expect.stringContaining('case_number is the year')])
    const stored = await rows<{ county: string; case_number: string; deposited_by: string }>(`select county, case_number, deposited_by from public.court_rows`)
    expect(stored).toEqual([{ county: 'Milwaukee', case_number: '2026SC007476', deposited_by: 'Muse 2' }])
    const b = await deposit('eviction', [{ county: 'milwaukee', case_number: '2026SC007476', address: '2319 S 10th Street', city: 'Milwaukee' }])
    expect(b).toMatchObject({ added: 0, updated: 1, waiting: 1 })
  })
  it('a money judgment needs the debtor; a bad kind or a bad date saves nothing', async () => {
    const a = await deposit('money_judgment', [{ county: 'Dane', case_number: '2026CV000975', defendant: 'John Q Debtor', plaintiff: 'A Bank', amount: 4321.5, filed: '2026-10-01' },
      { county: 'Dane', case_number: '2026CV000976' }])
    expect(a).toMatchObject({ ok: true, added: 1 })
    expect(a.refused[0].reason).toContain('defendant')
    expect((await deposit('probate', [])).reason).toContain('kind is')
    expect((await deposit('money_judgment', [{ county: 'Dane', case_number: '2026CV000977', defendant: 'X Y', filed: 'last week' }])).ok).toBe(false)
    expect(await one<number>(`(select count(*)::int from public.court_rows where case_number = '2026CV000977')`)).toBe(0)
  })
  it('once the laptop has answered a row, a second deposit leaves it alone, and the status shows the result', async () => {
    await db.query(`update public.court_rows set state = 'matched', parcel_id = '4971256000', matched_owner = 'RAMIRO BUSTOS', result_note = 'the address is one parcel', result_at = now()
                     where case_number = '2026SC007476'`)
    await db.query(`update public.court_rows set state = 'unmatched', result_note = 'no residential parcel owned by that name in the county', result_at = now() where case_number = '2026CV000975'`)
    expect(await deposit('eviction', [{ county: 'Milwaukee', case_number: '2026SC007476', address: 'changed', city: 'Milwaukee' }])).toMatchObject({ added: 0, updated: 0, already_answered: 1 })
    const s = await status()
    expect(s.by_kind.eviction).toMatchObject({ rows: 1, matched: 1, waiting: 0, properties_matched: 1 })
    expect(s.by_kind.money_judgment).toMatchObject({ rows: 1, unmatched: 1 })
    expect(s.why_not_matched).toEqual({ 'no residential parcel owned by that name in the county': 1 })
    expect(s.rows).toBeNull()
    expect((await status({ rows: true, state: 'matched' })).rows).toEqual([expect.objectContaining({ case_number: '2026SC007476', state: 'matched' })])
  })
  it('a row the laptop could not tie can be corrected and waits again; Fond du Lac keeps its small du', async () => {
    const a = await deposit('money_judgment', [{ county: 'Dane', case_number: '2026CV000975', defendant: 'Jonathan Q Debtor' },
      { county: 'fond du lac county', case_number: '2026CV000001', defendant: 'Pat Smith' }])
    expect(a).toMatchObject({ added: 1, updated: 1, already_answered: 0 })
    const r = await rows<{ county: string; state: string; defendant: string; result_note: string | null }>(
      `select county, state, defendant, result_note from public.court_rows where kind = 'money_judgment' order by case_number`)
    expect(r).toEqual([{ county: 'Fond du Lac', state: 'waiting', defendant: 'Pat Smith', result_note: null },
      { county: 'Dane', state: 'waiting', defendant: 'Jonathan Q Debtor', result_note: null }])
  })
})
