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
    expect((await deposit('bankruptcy', [])).reason).toContain('kind is')
    expect((await deposit('money_judgment', [{ county: 'Dane', case_number: '2026CV000977', defendant: 'X Y', filed: 'last week' }])).ok).toBe(false)
    expect(await one<number>(`(select count(*)::int from public.court_rows where case_number = '2026CV000977')`)).toBe(0)
  })
  it('takes foreclosure, probate and tax-warrant rows, each with its own case type (0274)', async () => {
    const f = await deposit('foreclosure', [
      { county: 'Brown', case_number: '2026CV000991', class_code: '30404', plaintiff: 'Lakeside Bank', defendant: 'Denu, Christin J', filed: '2026-11-17', amount: 88210.4 },
      { county: 'Brown', case_number: '2026SC000991', defendant: 'A Person' },                                  // not a CV case
      { county: 'Brown', case_number: '2026CV000992', class_code: '30301 Money Judgment', defendant: 'A Person' },   // a CV case of another class
      { county: 'Brown', case_number: '2026CV000993' },                                                          // nobody named
    ])
    expect(f).toMatchObject({ ok: true, added: 1 })
    expect(f.refused.map((r) => r.reason)).toEqual([expect.stringContaining('has CV in it'), expect.stringContaining('class code 30404'), expect.stringContaining('needs the defendant')])
    const p = await deposit('probate', [
      { county: 'Rock', case_number: '2026PR000123', defendant: 'Denu, Christin J', plaintiff: 'Denu, Mark', filed: '2026-11-16' },
      { county: 'Rock', case_number: '2026IN000045', caption: 'In the Matter of the Estate of Mary Smith' },
      { county: 'Rock', case_number: '2026CV000123', defendant: 'Someone' },
      { county: 'Rock', case_number: '2026PR000124' },
    ])
    expect(p).toMatchObject({ ok: true, added: 2 })
    expect(p.refused.map((r) => r.reason)).toEqual([expect.stringContaining('has PR (or IN'), expect.stringContaining('the person who died')])
    const t = await deposit('tax_warrant', [{ county: 'Dane', case_number: '2026TW000045', defendant: 'Jane Roe', plaintiff: 'Department of Revenue', amount: 8123.5 },
      { county: 'Dane', case_number: '2026CV000046', defendant: 'Jane Roe' }])
    expect(t).toMatchObject({ ok: true, added: 1 })
    expect(t.refused[0].reason).toContain('has TW in it')
    const st = await status()
    expect(st.by_kind.foreclosure).toMatchObject({ waiting: 1 })
    expect(st.by_kind.probate).toMatchObject({ waiting: 2 })
    expect(st.by_kind.tax_warrant).toMatchObject({ waiting: 1 })
    await db.query(`delete from public.court_rows where kind in ('foreclosure', 'probate', 'tax_warrant')`)
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

  it('0241: a guardianship has a way in, and a joint divorce petition is told how to come in', async () => {
    const g = await deposit('guardianship', [
      { county: 'Waukesha', case_number: '2026GN000123', filed: '2026-10-30', defendant: 'Roe, Jane A', plaintiff: 'Roe, Mark (guardian)', status: 'Open' },
      { county: 'Waukesha', case_number: '2026GN000124', caption: 'In the Matter of the Guardianship of John Q. Doe' },
      { county: 'Waukesha', case_number: '2026GN000125', plaintiff: 'Somebody' },
      { county: 'Waukesha', case_number: '2026PR000126', defendant: 'Wrong Case Type' },
    ])
    expect(g).toMatchObject({ ok: true, added: 2 })
    expect(g.refused.map((r) => r.reason)).toEqual([expect.stringContaining('the person the guardianship is for'), expect.stringContaining('has GN in it')])
    expect((g as unknown as { next: string }).next).toMatch(/no text and no paid trace/)
    expect(await rows(`select case_number, plaintiff, defendant, state from public.court_rows where kind = 'guardianship' order by case_number`)).toEqual([
      { case_number: '2026GN000123', plaintiff: 'Roe, Mark (guardian)', defendant: 'Roe, Jane A', state: 'waiting' },
      { case_number: '2026GN000124', plaintiff: null, defendant: null, state: 'waiting' }])
    expect((await status({ kind: 'guardianship' })).by_kind.guardianship).toMatchObject({ rows: 2, waiting: 2 })

    // a joint petition has no respondent: refused with the way to send it, then taken that way
    const d = await deposit('divorce', [{ county: 'Dane', case_number: '2026FA000777', plaintiff: 'Smith, Ann' }])
    expect(d.refused[0].reason).toMatch(/co-petitioner in defendant/)
    const d2 = await deposit('divorce', [{ county: 'Dane', case_number: '2026FA000777', plaintiff: 'Smith, Ann', defendant: 'Smith, Bob', caption: 'Joint petition: Smith, Ann and Smith, Bob' }])
    expect(d2).toMatchObject({ ok: true, added: 1, refused: [] })
    expect((await deposit('bankruptcy', [])).reason).toMatch(/divorce, guardianship, foreclosure, probate, tax_warrant, partition, will, land_contract, lien, quiet_title or receivership/)
  })

  it('0303: the six new categories are banked and wait; each says what it needs', async () => {
    const p = await deposit('partition', [
      { county: 'Racine', case_number: '2026CV000901', caption: 'Ann Roe vs. Bob Roe et al', class_code: 'Partition (30703)', filed: '2026-11-18' },
      { county: 'Racine', case_number: '2026CV000902', caption: 'Ann Roe vs. Carl Roe' }])
    expect(p).toMatchObject({ ok: true, added: 1 })
    expect(p.refused[0].reason).toMatch(/needs class_code/)
    expect((p as unknown as { next: string }).next).toMatch(/no rule for this kind yet/)
    const w = await deposit('will', [{ county: 'Dane', case_number: '2026WL000055', defendant: 'Doe, John' }, { county: 'Dane', case_number: '2026WL000056' }])
    expect(w).toMatchObject({ ok: true, added: 1 })
    expect(w.refused[0].reason).toMatch(/whose will it is/)
    for (const k of ['land_contract', 'lien', 'quiet_title', 'receivership'])
      expect(await deposit(k, [{ county: 'Rock', case_number: '2026CV00099' + k.length, defendant: 'X', class_code: 'Other Real Property (30799)' }])).toMatchObject({ ok: true, added: 1 })
    expect((await rows(`select count(*)::int n from public.court_rows where kind in ('partition','will','land_contract','lien','quiet_title','receivership') and state = 'waiting'`))[0]).toEqual({ n: 6 })
  })
})
