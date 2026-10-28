// The data pipes (migration 0103, Muse's spec 2026-10-28) on the real migrations: staged MPROP rows and their
// ownership-change delta, the six gates, the Milwaukee map (out / held_buffer for Colin / ok), dedupe against every card
// (parcel first, address second), conflicts kept with both sides and never written to the card, and the door's
// claim / close with outcome codes.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { callTool, TOOLS, type Agent, type DoorDb } from '../supabase/functions/_shared/agentDoor'
import { SUPABASE_STUB } from './supabaseStub'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')
type J = Record<string, any>
let db: PGlite
const r = async (sql: string, params: unknown[] = []) => (await db.query<{ r: J }>(`select ${sql} as r`, params)).rows[0].r
const rows = async (sql: string, params: unknown[] = []) => (await db.query<J>(sql, params)).rows

// an MPROP-shaped staged row (the laptop publisher builds these)
const parcel = (id: string, o: J = {}) => ({ county: 'Milwaukee', parcel_id: id, situs_address: `${Number(id.slice(-4))} S Test St`, municipality: 'Milwaukee',
  zip: '53207', owner_names: ['SAMPLE, PAT'], mail_street: '1 Mail St', mail_city: 'Milwaukee', mail_state: 'WI', mail_zip: '53207',
  use_class: 'single_family', land_use: '8810', land_use_group: '1', units: 1, condo: false, assessed_land: 20000, assessed_impr: 100000,
  assessed_total: 120000, assessment_year: 2026, year_built: 1925, zoning: 'RT4', lat: 42.99, lon: -87.90, point_source: 'test', row_hash: 'h-' + id, ...o })
const load = (rowsIn: J[], day = '2026-10-27', initial = false) =>
  r(`public.pipe_upsert_parcels('mke.mprop', $1::date, $2::jsonb, $3)`, [day, JSON.stringify(rowsIn), initial])
const signal = (rec: string, parcelId: string | null, o: J = {}) =>
  db.query(`insert into public.pipe_signals (source, source_record_id, kind, county, parcel_id, address, addr_key, signal_date, tax_years, pairs_only, active)
            values ($1, $2, $3, 'Milwaukee', $4, $5, public.addr_key(public.addr_main($5)), '2026-10-01', $6, $7, $8)`,
    ['test', rec, o.kind ?? 'vacant_building', parcelId, o.address ?? null, o.tax_years ?? null, o.pairs_only ?? false, o.active ?? true])
const screen = (id: string) => r(`public.pipe_screen('Milwaukee', $1)`, [id])
const card = async (o: J) => (await rows(`insert into public.leads (owner_name, county, municipality, property_address, property_zip, parcel_id, wpie_owner_id, stage, reasons_to_sell)
  values ($1, 'Milwaukee', $2, $3, '53207', $4, $5, coalesce($6, 'postcard_mailed')::public.lead_stage, $7) returning id, updated_at`,
  [o.owner, o.municipality ?? 'Milwaukee', o.address, o.parcel ?? null, o.wpie ?? null, o.stage ?? null, o.reasons ?? []]))[0]
const SQUARE = { type: 'Polygon', coordinates: [[[-87.95, 43.05], [-87.93, 43.05], [-87.93, 43.07], [-87.95, 43.07], [-87.95, 43.05]]] }

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
})

describe('pipes: staging and the ownership delta', () => {
  it('a first load logs nothing new; a changed owner is logged, stamped and re-screened; unchanged rows are not written', async () => {
    expect(await load([parcel('4000000001'), parcel('4000000002')], '2026-10-26', true)).toMatchObject({ written: 2, changes: 0, owner_changes: 0 })
    expect(await load([parcel('4000000001'), parcel('4000000002')], '2026-10-27')).toMatchObject({ written: 0, changes: 0 })
    const moved = await load([parcel('4000000001', { owner_names: ['NEWBUYER LLC'], row_hash: 'h2' }), parcel('4000000003')], '2026-10-27')
    expect(moved).toMatchObject({ written: 2, changes: 2, owner_changes: 1 })
    const ch = await rows(`select parcel_id, kinds, before->'owner_names' b, after->'owner_names' a from public.pipe_parcel_changes order by id`)
    expect(ch).toEqual([{ parcel_id: '4000000001', kinds: ['owner'], b: ['SAMPLE, PAT'], a: ['NEWBUYER LLC'] },
      { parcel_id: '4000000003', kinds: ['new'], b: null, a: ['SAMPLE, PAT'] }])
    expect(await rows(`select owner_changed_on::text d, owner_key, addr_key from public.pipe_parcels where parcel_id = '4000000001'`))
      .toEqual([{ d: '2026-10-27', owner_key: 'NEWBUYER LLC', addr_key: '1 S TEST ST' }])
    // a care-of line is not an owner
    expect(await load([parcel('4000000002', { owner_names: ['SAMPLE, PAT', 'C/O PMC RENTALS'], row_hash: 'h-co' })], '2026-10-27'))
      .toMatchObject({ written: 1, changes: 1, owner_changes: 0 })
    expect(await r(`public.pipe_parcels_gone('mke.mprop', '2026-10-28', array['4000000003'])`)).toBe(1)
    expect(await rows(`select gone_on::text g from public.pipe_parcels where parcel_id = '4000000003'`)).toEqual([{ g: '2026-10-28' }])
  })
})

describe('pipes: the gates', () => {
  it('no signal, no item: a parcel alone is never a lead', async () => {
    await load([parcel('4100000001')])
    expect(await screen('4100000001')).toMatchObject({ pass: false, fails: ['no_distress'], item: null })
  })

  it('county, type, value and the tax / DOR rules', async () => {
    await load([parcel('4100000002', { use_class: 'apartment_3plus', land_use: '8830', units: 6 }), parcel('4100000003', { assessed_total: 500000 }),
      parcel('4100000004'), parcel('4100000005'), parcel('4100000006'), parcel('4100000007', { use_class: 'condo', land_use: '8811', condo: true })])
    await signal('a', '4100000002'); await signal('b', '4100000003')
    await signal('c', '4100000004', { kind: 'tax_delinquent', tax_years: 1 })
    await signal('d', '4100000005', { kind: 'dor_delinquent', pairs_only: true })
    await signal('e', '4100000006', { kind: 'tax_delinquent', tax_years: 2 }); await signal('f', '4100000007')
    expect((await screen('4100000002')).fails).toEqual(['type_3plus_units'])
    expect((await screen('4100000003')).fails).toEqual(['value_over_cap'])
    expect((await screen('4100000004')).fails).toEqual(['tax_under_2_years'])
    expect((await screen('4100000005')).fails).toEqual(['dor_needs_a_pair'])
    // passes everything but the map: City of Milwaukee waits for Muse's polygon, never guessed
    expect(await screen('4100000006')).toMatchObject({ pass: false, fails: ['map_not_loaded'], item: null })
    expect(await screen('4100000007')).toMatchObject({ fails: ['map_not_loaded'] })
  })

  it('the map: inside = excluded, inside the band = held for Colin, a clear area or far away = queued', async () => {
    const agentDb = doorDb()
    const bad = await callTool('pipe_set_map', { name: 'x', kind: 'exclusion', geojson: { type: 'Polygon', coordinates: [[[43.05, -87.95], [43.05, -87.93], [43.07, -87.93]]] } }, MUSE, agentDb)
    expect(bad).toMatchObject({ isError: true })
    expect((await callTool('pipe_set_map', { name: 'north side', kind: 'exclusion', geojson: SQUARE, note: 'Muse' }, MUSE, agentDb)).value).toMatchObject({ ok: true, polygons: 1, buffer_m: 275 })
    await load([parcel('4200000001', { lat: 43.06, lon: -87.94 }), parcel('4200000002', { lat: 43.06, lon: -87.927 }),
      parcel('4200000003', { lat: 42.99, lon: -87.90 }), parcel('4200000004', { lat: 43.06, lon: -87.928 }), parcel('4200000005', { municipality: 'West Allis', lat: 43.06, lon: -87.94 })])
    for (const [i, id] of ['4200000001', '4200000002', '4200000003', '4200000004', '4200000005'].entries()) await signal('m' + i, id)
    expect(await screen('4200000001')).toMatchObject({ fails: ['map_excluded'], item: null })
    expect(await screen('4200000002')).toMatchObject({ pass: false, fails: [], item_state: 'held_buffer', item_kind: 'new' })
    expect(await screen('4200000003')).toMatchObject({ pass: true, item_state: 'open', item_kind: 'new' })
    expect(await screen('4200000005')).toMatchObject({ pass: true, item_state: 'open' })   // the map is the City of Milwaukee's only
    await callTool('pipe_set_map', { name: 'east of Holton', kind: 'clear', geojson: { type: 'Polygon', coordinates: [[[-87.929, 43.0], [-87.9275, 43.0], [-87.9275, 43.1], [-87.929, 43.1], [-87.929, 43.0]]] } }, MUSE, agentDb)
    expect(await screen('4200000004')).toMatchObject({ pass: true, item_state: 'open' })
    expect((await screen('4200000006').catch(() => ({ error: 'x' })))).toHaveProperty('error')
  })

  it('freeze and corpse: an active bankruptcy, a dead card, a deceased sole owner with nobody live', async () => {
    await load([parcel('4300000001'), parcel('4300000002'), parcel('4300000003')])
    await signal('n1', '4300000001'); await signal('n1b', '4300000001', { kind: 'bankruptcy' })
    await signal('n2', '4300000002'); await signal('n3', '4300000003')
    await card({ owner: 'Pat Sample', address: '2 S Test St', parcel: '4300000002', stage: 'dnc', wpie: 4302 })
    const c3 = await card({ owner: 'Pat Sample', address: '3 S Test St', parcel: '4300000003', wpie: 4303 })
    await db.query(`update public.interests set status = 'deceased' where lead_id = $1`, [c3.id])
    expect((await screen('4300000001')).fails).toContain('bankruptcy_active')
    expect((await screen('4300000002')).fails).toContain('card_dead_or_dnc')
    expect((await screen('4300000003')).fails).toContain('deceased_no_representative')
  })
})

describe('pipes: dedupe and conflicts', () => {
  it('a signal on a carded parcel is a stack; Muse\'s card with no parcel id matches by address', async () => {
    await load([parcel('4400000001', { lat: 42.99 }), parcel('4400000002', { situs_address: '2825 2827 S LOGAN AV' })])
    const laptop = await card({ owner: 'Pat Sample', address: '1 S Test Street', parcel: '4400000001', wpie: 4401, reasons: ['vacant'] })
    const muse = await card({ owner: 'Pat Sample', address: '2825 S Logan Ave', wpie: -4402 })
    await signal('s1', '4400000001'); await signal('s2', null, { address: '2825 S Logan Ave' })
    expect(await screen('4400000001')).toMatchObject({ pass: true, item_kind: 'stack', cards: [laptop.id] })
    expect(await screen('4400000002')).toMatchObject({ item_kind: 'stack', cards: [muse.id], signals: 1 })
    // the same signal again: no second item
    const again = await screen('4400000001')
    expect(await rows(`select count(*)::int n from public.pipe_queue where parcel_id = '4400000001'`)).toEqual([{ n: 1 }])
    expect(again.item_state).toBe('open')
  })

  it('an owner change on a card: a re-screen and a conflict with both sides stamped; the card is never written', async () => {
    await load([parcel('4500000001')], '2026-10-26')
    const c = await card({ owner: 'Pat Sample', address: '1 S Test St', parcel: '4500000001', wpie: 4501, reasons: ['tax'] })
    expect(await screen('4500000001')).toMatchObject({ item: null })          // same owner, no signal: nothing to do
    await load([parcel('4500000001', { owner_names: ['ZED, ROBIN'], row_hash: 'h3' })], '2026-10-27')
    const v = await screen('4500000001')
    expect(v).toMatchObject({ item_kind: 're_screen', item_state: 'open' })
    const item = await r(`public.pipe_door_item($1)`, [v.item])
    expect(item.why).toEqual(['owner_changed', 'owner_conflict'])
    expect(item.conflicts[0]).toMatchObject({ field: 'owner', card: 'Pat Sample', card_basis: 'the card', pipe: 'ZED, ROBIN', pipe_source: 'mke.mprop', pipe_date: '2026-10-27' })
    expect(item.missing).toContain('current_ownership_confirmation')
    expect(item.facts.assessed_value).toMatchObject({ total: 120000, assessment_year: 2026, source: 'City of Milwaukee MPROP master property file' })
    expect(item.changes[0]).toMatchObject({ kinds: ['owner'] })
    expect(await rows(`select owner_name, updated_at = $2 same from public.leads where id = $1`, [c.id, c.updated_at])).toEqual([{ owner_name: 'Pat Sample', same: true }])
    // a re-run the same day does not open a second one
    await screen('4500000001')
    expect(await rows(`select count(*)::int n from public.pipe_queue where parcel_id = '4500000001'`)).toEqual([{ n: 1 }])
  })

  it('a card matched only by a shared address (a condo building): a stack, no conflict, the lane picks the unit', async () => {
    await load([parcel('4600000001', { situs_address: '1500 N Shared Ave', use_class: 'condo', land_use: '8811', condo: true, owner_names: ['ONE, OWNER'], lat: 42.99 }),
      parcel('4600000002', { situs_address: '1500 N Shared Ave', use_class: 'condo', land_use: '8811', condo: true, owner_names: ['TWO, OWNER'], lat: 42.99 })])
    const m = await card({ owner: 'Somebody Else', address: '1500 N Shared Avenue', wpie: -4601 })
    await signal('sh1', '4600000001')
    const v = await screen('4600000001')
    expect(v).toMatchObject({ item_kind: 'stack', cards: [m.id], cards_by_shared_address: [m.id] })
    expect(await rows(`select count(*)::int n from public.pipe_conflicts where lead_id = $1`, [m.id])).toEqual([{ n: 0 }])
    expect((await r(`public.pipe_door_item($1)`, [v.item])).missing).toContain("which_parcel: the card's address is 2 staged parcels")
  })

  it('pipe_screen_source screens what can matter and pipe_gate_counts gives the whole picture', async () => {
    const s = await r(`public.pipe_screen_source('mke.mprop')`)
    expect(s.screened).toBeGreaterThan(10)
    const g = await r(`public.pipe_gate_counts('mke.mprop')`)
    expect(g).toMatchObject({ first_static_fail: { type_3plus_units: 1, value_over_cap: 1 } })
    expect(g.staged).toBe(22)  // (before the 1b parcels load)
    expect(g.with_card_any).toBeGreaterThanOrEqual(5)
  })
})

describe('pipes 1b: vacant buildings and permits as signals', () => {
  it('signals load and refresh; one off the list stays as history but no longer qualifies; a permit never opens an item', async () => {
    await load([parcel('4700000001', { lat: 42.99 }), parcel('4700000002', { situs_address: '9 N Permit St', lat: 42.99 }), parcel('4700000003', { lat: 42.99 })])
    const c = await card({ owner: 'Pat Sample', address: '9 N Permit St', parcel: '4700000002', wpie: 4702, reasons: ['tax'] })
    const vac = (id: string, active = true) => ({ source_record_id: id + ':2026-01-05', kind: 'vacant_building', county: 'Milwaukee', parcel_id: id,
      address: '1 S Test St', municipality: 'Milwaukee', signal_date: '2026-01-05', active, detail: { status: 'open' } })
    expect(await r(`public.pipe_upsert_signals('mke.vacant', $1::jsonb)`, [JSON.stringify([vac('4700000001'), vac('4700000003')])])).toEqual({ rows: 2, new: 2 })
    expect(await r(`public.pipe_upsert_signals('mke.vacant', $1::jsonb)`, [JSON.stringify([vac('4700000001')])])).toEqual({ rows: 1, new: 0 })
    expect(await r(`public.pipe_signals_listed('mke.vacant', array['4700000001:2026-01-05'])`)).toBe(1)
    expect(await screen('4700000001')).toMatchObject({ pass: true, item_kind: 'new' })
    expect(await screen('4700000003')).toMatchObject({ pass: false, fails: ['no_distress'], signals: 1, item: null })   // off the list: history only
    expect(await rows(`select count(*)::int n from public.pipe_signals where source = 'mke.vacant'`)).toEqual([{ n: 2 }])
    const permit = { source_record_id: 'RES-ALT-26-00001', kind: 'permit', county: 'Milwaukee', address: '9 N PERMIT ST', municipality: 'Milwaukee',
      signal_date: '2026-09-01', detail: { type: 'Residential Alteration Permit', cost: 12000 } }
    await r(`public.pipe_upsert_signals('mke.permits', $1::jsonb)`, [JSON.stringify([permit])])
    expect(await screen('4700000002')).toMatchObject({ pass: true, signals: 1, cards: [c.id], item: null })            // context, not distress
    expect(await r(`public.pipe_signal_counts('mke.permits')`)).toMatchObject({ signals: 1, on_a_staged_parcel: 1, active_on_a_card: 1 })
    await expect(r(`public.pipe_upsert_signals('nope', '[]'::jsonb)`)).rejects.toThrow(/unknown pipe source/)
  })
})

describe('pipes: Milwaukee delinquent tax and sheriff sales (the 14-day rule)', () => {
  const day = (n: number) => new Date(Date.now() + n * 86400000).toISOString().slice(0, 10)
  const sale = (pid: string, date: string, o: J = {}) => ({ source_record_id: o.case ?? '2026CV00' + pid.slice(-4), kind: 'sheriff_sale', county: 'Milwaukee',
    parcel_id: pid, address: '1 S Test St', municipality: 'Milwaukee', signal_date: date, active: o.active ?? true, detail: { status: o.status ?? 'scheduled' } })
  const tax = (pid: string, years: number[]) => ({ source_record_id: pid, kind: 'tax_delinquent', county: 'Milwaukee', parcel_id: pid,
    address: '1 S Test St', municipality: 'Milwaukee', signal_date: `${years[0]}-12-31`, tax_years: years.length, active: true, detail: { levy_years: years } })

  it("tax: the file's own depth decides; one unpaid year does not qualify, two do", async () => {
    await load([parcel('4800000001'), parcel('4800000002')])
    await r(`public.pipe_upsert_signals('mke.delqtax', $1::jsonb)`, [JSON.stringify([tax('4800000001', [2025]), tax('4800000002', [2024, 2025])])])
    expect(await screen('4800000001')).toMatchObject({ fails: ['tax_under_2_years'], item: null })
    expect(await screen('4800000002')).toMatchObject({ pass: true, item_kind: 'new' })
  })

  it('a sale 14+ days out qualifies; inside 14 days or past blocks the parcel even with other distress; an adjournment brings it back', async () => {
    await load([parcel('4900000001'), parcel('4900000002'), parcel('4900000003'), parcel('4900000004')])
    await signal('v49', '4900000002')                                                     // vacant too: still blocked
    await r(`public.pipe_upsert_signals('mkco.sheriff_sales', $1::jsonb)`, [JSON.stringify([sale('4900000001', day(30)), sale('4900000002', day(5), { active: false }),
      sale('4900000003', day(-20), { active: false }), sale('4900000004', day(-100), { status: 'sold', active: false })])])
    expect(await screen('4900000001')).toMatchObject({ pass: true, item_kind: 'new', item_state: 'open' })
    expect(await screen('4900000002')).toMatchObject({ fails: ['sheriff_sale_inside_14_days_or_past'], item: null })
    expect(await screen('4900000003')).toMatchObject({ fails: ['no_distress', 'sheriff_sale_inside_14_days_or_past'], item: null })
    expect(await screen('4900000004')).toMatchObject({ fails: ['no_distress', 'sheriff_sale_sold'] })
    // the date drifts inside the window: the unclaimed item closes itself
    await r(`public.pipe_upsert_signals('mkco.sheriff_sales', $1::jsonb)`, [JSON.stringify([sale('4900000001', day(10), { active: false })])])
    expect(await screen('4900000001')).toMatchObject({ item_state: 'killed', fails: ['no_distress', 'sheriff_sale_inside_14_days_or_past'] })
    // adjourned: same case, a new date 40 days out -> a new item (dedupe on the case, re-test the new date)
    await r(`public.pipe_upsert_signals('mkco.sheriff_sales', $1::jsonb)`, [JSON.stringify([sale('4900000001', day(40))])])
    expect(await rows(`select count(*)::int n from public.pipe_signals where source = 'mkco.sheriff_sales' and parcel_id = '4900000001'`)).toEqual([{ n: 1 }])
    expect(await screen('4900000001')).toMatchObject({ pass: true, item_kind: 'new', item_state: 'open' })
    expect(await screen('4900000001')).toMatchObject({ item_state: 'open' })               // and only once
    expect(await rows(`select state from public.pipe_queue where parcel_id = '4900000001' order by created_at`)).toEqual([{ state: 'killed' }, { state: 'open' }])
  })
})

const MUSE: Agent = { id: 'k1', name: 'Muse', role: 'agent' }
const LANE2: Agent = { id: 'k2', name: 'Muse lane 2', role: 'agent' }
function doorDb(): DoorDb {
  const rpc = async (fn: string, args: Record<string, unknown>) => {
    const names = Object.keys(args)
    const sql = `select public.${fn}(${names.map((n, i) => `${n} => $${i + 1}`).join(', ')}) as r`
    return (await db.query<{ r: unknown }>(sql, names.map((n) => { const v = args[n]; return v !== null && typeof v === 'object' ? JSON.stringify(v) : v }))).rows[0].r
  }
  return { records: rpc } as unknown as DoorDb
}

describe('pipes: the door', () => {
  it('the queue tools sit under the prospects scope', () => {
    const names = TOOLS.filter((t) => t.name.startsWith('pipe_')).map((t) => t.name)
    expect(names).toEqual(['pipe_counts', 'pipe_queue', 'pipe_claim', 'pipe_item', 'pipe_close', 'pipe_set_map'])
    expect(TOOLS.filter((t) => t.name.startsWith('pipe_')).every((t) => t.role === 'intake')).toBe(true)
  })

  it('claim, then close: verified needs stamped fields, killed a code, held a blocker; a buffer item takes only Colin\'s ruling', async () => {
    const d = doorDb()
    const counts = (await callTool('pipe_counts', {}, MUSE, d)).value as J
    expect(counts).toMatchObject({ map_loaded: true })
    const claimed = (await callTool('pipe_claim', { limit: 2, kind: 'new' }, MUSE, d)).value as J
    expect(claimed.claimed).toBe(2)
    const [a, b] = claimed.items
    expect(a.facts.owner).toMatchObject({ source: 'City of Milwaukee MPROP master property file', grade: 'current' })
    expect(a.signals[0]).toMatchObject({ kind: 'vacant_building', source: 'test' })
    expect((await callTool('pipe_close', { item_id: a.id, outcome: 'verified', verified: { owner: { value: 'Pat Sample' } } }, MUSE, d))).toMatchObject({ isError: true })
    expect((await callTool('pipe_close', { item_id: a.id, outcome: 'verified', verified: { owner: { value: 'Pat Sample', source: 'MPROP', date: '2026-10-28' } } }, LANE2, d)).value)
      .toMatchObject({ ok: false, error: 'claimed by Muse' })
    expect((await callTool('pipe_close', { item_id: a.id, outcome: 'verified',
      verified: { owner: { value: 'Pat Sample', source: 'MPROP', date: '2026-10-28' }, assessed_value: { value: 120000, source: 'MPROP', date: '2026-10-28' } } }, MUSE, d)).value)
      .toMatchObject({ ok: false })                                                  // a value field needs its assessed basis
    expect((await callTool('pipe_close', { item_id: a.id, outcome: 'verified',
      verified: { owner: { value: 'Pat Sample', source: 'MPROP', date: '2026-10-28' }, assessed_value: { value: 120000, basis: 'assessed value 2026', source: 'MPROP', date: '2026-10-28' } } }, MUSE, d)).value)
      .toMatchObject({ ok: true, state: 'verified', next: expect.stringMatching(/add_prospects/) })
    expect((await callTool('pipe_close', { item_id: b.id, outcome: 'killed', code: 'because' }, MUSE, d)).isError).toBe(true)
    expect((await callTool('pipe_close', { item_id: b.id, outcome: 'held' }, MUSE, d)).isError).toBe(true)
    expect((await callTool('pipe_close', { item_id: b.id, outcome: 'held', note: 'waiting on the case detail read' }, MUSE, d)).value).toMatchObject({ ok: true, state: 'held' })
    expect((await callTool('pipe_close', { item_id: b.id, outcome: 'killed', code: 'sold_or_transferred', note: 'deed 2026-10-20' }, MUSE, d)).value).toMatchObject({ state: 'killed' })
    // a verified item is not reopened by the same signal
    expect(await screen(a.parcel_id)).toMatchObject({ item: null })

    const held = ((await callTool('pipe_queue', { state: 'held_buffer' }, MUSE, d)).value as J[])[0]
    expect(held).toMatchObject({ parcel_id: '4200000002' })
    expect((await callTool('pipe_claim', { item_id: held.item_id }, MUSE, d)).value).toMatchObject({ claimed: 0 })
    expect((await callTool('pipe_close', { item_id: held.item_id, outcome: 'verified', verified: {} }, MUSE, d)).isError).toBe(true)
    expect((await callTool('pipe_close', { item_id: held.item_id, outcome: 'ruled_in', note: 'that block is fine' }, MUSE, d)).value).toMatchObject({ ok: true, state: 'open' })
  })

  it('a killed re-screen settles the card\'s conflict; a later owner change opens a new one', async () => {
    const d = doorDb()
    const it = ((await callTool('pipe_claim', { kind: 're_screen' }, MUSE, d)).value as J).items[0]
    expect((await callTool('pipe_close', { item_id: it.id, outcome: 'killed', code: 'sold_or_transferred' }, MUSE, d)).value).toMatchObject({ ok: true })
    expect(await screen('4500000001')).toMatchObject({ item: null })
    await load([parcel('4500000001', { owner_names: ['THIRD, OWNER'], row_hash: 'h4' })], '2026-10-29')
    expect(await screen('4500000001')).toMatchObject({ item_kind: 're_screen', item_state: 'open' })
  })
})
