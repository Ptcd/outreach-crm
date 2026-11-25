// 0326: a retired number is released once 30 days pass with no seller calling or texting it, counted from the day it
// was retired or the last contact, whichever is later; never a number we still dial from.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATIONS = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')
let db: PGlite
type Due = { lines: { number: string; due_on: string; last_inbound_at: string | null }[]; due: string[] }
const due = async (at: string) => (await db.query<{ r: Due }>(`select public.line_release_due($1::timestamptz) as r`, [at])).rows[0].r

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATIONS)
}, 120_000)

describe('releasing the two flagged numbers', () => {
  it('neither is due before Dec 25, both are on Dec 25 when nobody has called or texted them', async () => {
    expect((await due('2026-12-15T15:00:00Z')).due).toEqual([])
    const r = await due('2026-12-25T15:00:00Z')
    expect(r.due.sort()).toEqual(['+12624180202', '+12624299057'])
    expect(r.lines.find((l) => l.number === '+12624180202')?.due_on).toBe('2026-12-25')
  })
  it('a seller text or call to it starts the 30 days again', async () => {
    await db.query(`insert into public.twilio_inbound (sid, from10, to_number, body, received_at) values ('SMx1', '4145550001', '+12624180202', 'Still interested', '2026-12-10T18:00:00Z')`)
    await db.query(`insert into public.inbound_calls (call_sid, from10, to_number, status, created_at) values ('CA' || repeat('7', 32), '4145550002', '+12624299057', 'missed', '2026-12-20T18:00:00Z')`)
    const r = await due('2026-12-25T15:00:00Z')
    expect(r.due).toEqual([])
    expect(r.lines.find((l) => l.number === '+12624180202')?.due_on).toBe('2027-01-09')
    expect(r.lines.find((l) => l.number === '+12624299057')?.due_on).toBe('2027-01-19')
    expect((await due('2027-01-15T15:00:00Z')).due).toEqual(['+12624180202'])
  })
  it('a team phone calling it does not count, and a number we dial from again is never due', async () => {
    await db.exec(`insert into public.team_members (email, role, person, display_name, alert_phone) values ('colin@example.com', 'owner', 'colin', 'Colin', '+14145559999') on conflict do nothing`)
    await db.query(`insert into public.inbound_calls (call_sid, from10, to_number, status, created_at) values ('CA' || repeat('8', 32), '4145559999', '+12624180202', 'missed', '2027-01-10T18:00:00Z')`)
    expect((await due('2027-01-15T15:00:00Z')).due).toEqual(['+12624180202'])
    await db.exec(`update public.call_lines set dial = true where number = '+12624180202'`)
    expect((await due('2027-01-15T15:00:00Z')).due).toEqual([])
    await db.exec(`update public.call_lines set dial = false where number = '+12624180202'`)
  })
  it('once released it is out of the dialing list, the reply pool and the callers\' lines, and is never due again', async () => {
    expect((await db.query<{ r: { ok: boolean } }>(`select public.line_released('+12624299057', 'test') as r`)).rows[0].r).toEqual({ ok: true })
    expect((await db.query<{ r: { ok: boolean } }>(`select public.line_released('+12624299057', 'again') as r`)).rows[0].r.ok).toBe(false)
    expect((await db.query(`select 1 from public.caller_numbers where number = '+12624299057'`)).rows).toHaveLength(0)
    expect((await db.query(`select 1 from public.campaign_control where '+12624299057' = any (reply_numbers)`)).rows).toHaveLength(0)
    expect((await due('2027-06-01T15:00:00Z')).lines.map((l) => l.number)).toEqual(['+12624180202'])
  })
  it('the two new numbers dial; a caller\'s login cannot run any of it', async () => {
    expect((await db.query<{ n: number }>(`select count(*)::int n from public.call_lines where number in ('+12624409051', '+12622289462') and dial`)).rows[0].n).toBe(2)
    await db.exec('set role authenticated')
    await expect(due('2027-01-15T15:00:00Z')).rejects.toThrow()
    await db.exec('reset role')
  })
})

describe('the day it is counted from', () => {
  it('a contact on the evening before it was retired (Central) still counts from the retiring day', async () => {
    const d2 = new PGlite()
    await d2.exec(SUPABASE_STUB)
    await d2.exec(MIGRATIONS)
    await d2.query(`insert into public.twilio_inbound (sid, from10, to_number, body, received_at) values ('SMx2', '4145550003', '+12624180202', 'ok', '2026-11-25T01:14:00Z')`)
    const r = (await d2.query<{ r: Due }>(`select public.line_release_due('2026-11-26T15:00:00Z'::timestamptz) as r`)).rows[0].r
    expect(r.lines.find((l) => l.number === '+12624180202')?.due_on).toBe('2026-12-25')
  })
})
