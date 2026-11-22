// 0284: a card a person can read (Colin 2026-11-22). Agent bookkeeping leaves the notes, an entry is on a card once,
// a reason is listed once.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')
let db: PGlite
const ID = '00000000-0000-0000-0000-00000000f284'
const card = async () => (await db.query<{ notes: string | null; notes_log: string | null; reasons_to_sell: string[] }>(
  `select notes, notes_log, reasons_to_sell from public.leads where id = $1`, [ID])).rows[0]

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
}, 180_000)

describe('0284: a card a person can read', () => {
  it('a new card: the pack is kept once, the bookkeeping goes to the log, a reason is listed once', async () => {
    const pack = 'STEP 6 PACK - imported 2026-11-02.\nCase: Fond du Lac County 2026PR000012 (probate).\nParcel: 039FDL1517093356400.'
    await db.query(`insert into public.leads (id, wpie_owner_id, owner_name, lane, stage, property_address, mailing_state, reasons_to_sell, notes)
      values ($1, 98284, 'THOMPSON, RUSSEL J', 'flip', 'opener_sent', '74 PIONEER COURT', 'WI', $2, $3)`,
      [ID, ['behind on taxes', 'Behind on taxes', 'Foreclosure'], [pack, 'Muse: ' + pack, '2026-11-03 card locked to Thalia',
        'Muse: Phones loaded from banked FPS results (phones_wanted nightly 2026-11-06, wpie_owner_id 461206): EXACT tie',
        'Muse (held): no-phone list 2 wave 1'].join(' | ')])
    const c = await card()
    expect(c.reasons_to_sell).toEqual(['behind on taxes', 'Foreclosure'])
    expect(c.notes).toBe([pack, '2026-11-03 card locked to Thalia'].join(' | '))
    expect(c.notes_log).toContain('Phones loaded from banked FPS')
    expect(c.notes_log).toContain('Muse (held)')
    // the parcel line a card is tied by (0161) is still in the notes
    expect((await db.query<{ p: string[] }>(`select public.notes_parcels(notes) as p from public.leads where id = $1`, [ID])).rows[0].p).toEqual(['039FDL1517093356400'])
  })

  it('the same line written again every night stays one line, the newest; a real note is added once', async () => {
    for (const day of ['2026-11-07', '2026-11-08', '2026-11-09']) {
      await db.query(`update public.leads set notes = coalesce(notes || ' | ', '') || $2 where id = $1`,
        [ID, `Muse: Phones loaded from banked FPS results (phones_wanted nightly ${day}, wpie_owner_id 461206): EXACT`])
    }
    await db.query(`update public.leads set notes = notes || ' | ' || 'Seller said the roof leaks over the kitchen' where id = $1`, [ID])
    await db.query(`update public.leads set notes = notes || ' | ' || 'Muse: Seller said the roof leaks over the kitchen' where id = $1`, [ID])
    const c = await card()
    expect(c.notes!.split(' | ')).toHaveLength(3)
    expect(c.notes).toContain('roof leaks')
    expect(c.notes_log!.match(/Phones loaded from banked/g)).toHaveLength(1)
    expect(c.notes_log).toContain('2026-11-09')
    await db.query(`update public.leads set reasons_to_sell = reasons_to_sell || '{FORECLOSURE,Estate}' where id = $1`, [ID])
    expect((await card()).reasons_to_sell).toEqual(['behind on taxes', 'Foreclosure', 'Estate'])
  })
})
