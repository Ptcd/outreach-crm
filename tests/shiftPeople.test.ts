// Migration 0040 on the real migrations (PGlite): on the shared app login (one team row, Colin's), Thalia and
// Adil each keep their own hot-ping email and phone, the alert lists read them, and Colin's row is untouched.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, beforeEach, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')
const APP = { sub: '00000000-0000-0000-0000-00000000000c', email: 'app@example.com' }       // the one shared login
const STRANGER = { sub: '00000000-0000-0000-0000-00000000000f', email: 'nobody@example.com' }

let db: PGlite
async function as<T>(who: { sub: string; email: string }, fn: () => Promise<T>): Promise<T> {
  await db.query(`select set_config('request.jwt.claims', $1, false)`, [JSON.stringify(who)])
  await db.exec('set role authenticated')
  try { return await fn() } finally { await db.exec('reset role') }
}
const rpc = async (fn: string, args: Record<string, unknown>) => {
  const names = Object.keys(args)
  const r = await db.query<{ r: unknown }>(`select public.${fn}(${names.map((n, i) => `${n} => $${i + 1}`).join(', ')}) as r`,
    names.map((n) => args[n]))
  return r.rows[0]?.r
}

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
  await db.exec(`insert into public.team_members (email, role, person, display_name) values ('app@example.com', 'owner', 'colin', 'Colin')`)
})

beforeEach(async () => {
  await db.exec(`update public.team_members set alert_phone = null, alert_email = null;
                 update public.shift_people set alert_phone = null, alert_email = null`)
})

describe('who is on shift, on the shared login', () => {
  it('Thalia and Adil are on the shift list from the start, not on the login list', async () => {
    const rows = (await db.query<{ person: string }>(`select person::text from public.shift_people order by person`)).rows
    expect(rows.map((r) => r.person)).toEqual(['thalia', 'adil'].sort())
    expect((await db.query(`select 1 from public.team_members`)).rows).toHaveLength(1)
  })

  it("Thalia's email and phone go on her shift row; Colin's stay as they were", async () => {
    await as(APP, () => rpc('set_person_alerts', { p_person: 'colin', p_phone: '2625550100', p_email: 'colin@example.com' }))
    const r = await as(APP, () => rpc('set_person_alerts', { p_person: 'thalia', p_phone: '(414) 555-0199', p_email: 'Thalia@Example.com ' }))
    expect(r).toEqual({ ok: true, person: 'thalia', phone: '4145550199', email: 'thalia@example.com' })
    expect((await db.query(`select alert_phone, alert_email from public.team_members`)).rows)
      .toEqual([{ alert_phone: '2625550100', alert_email: 'colin@example.com' }])
    expect(await as(APP, () => rpc('person_alerts', { p_person: 'thalia' })))
      .toEqual({ ok: true, person: 'thalia', name: 'Thalia', alert_phone: '4145550199', alert_email: 'thalia@example.com' })
    expect(await as(APP, () => rpc('person_alerts', { p_person: 'colin' })))
      .toMatchObject({ ok: true, name: 'Colin', alert_phone: '2625550100', alert_email: 'colin@example.com' })
  })

  it('the alert lists read both: texts to the callers (never the owner), emails to everyone, one per address', async () => {
    await as(APP, () => rpc('set_person_alerts', { p_person: 'colin', p_phone: '2625550100', p_email: 'colin@example.com' }))
    await as(APP, () => rpc('set_person_alerts', { p_person: 'thalia', p_phone: '4145550199', p_email: 'thalia@example.com' }))
    await as(APP, () => rpc('set_person_alerts', { p_person: 'adil', p_phone: '', p_email: 'THALIA@example.com' }))
    expect(await rpc('alert_recipients', {})).toEqual([{ person: 'thalia', phone: '+14145550199' }])
    expect(await rpc('alert_email_recipients', {})).toEqual([
      { person: 'colin', email: 'colin@example.com' }, { person: 'adil', email: 'thalia@example.com' },
    ].sort((a, b) => a.person.localeCompare(b.person)))
  })

  it('refuses a bad number, a bad address and anyone not on the team', async () => {
    expect(await as(APP, () => rpc('set_person_alerts', { p_person: 'adil', p_phone: '555', p_email: '' }))).toMatchObject({ ok: false, reason: /10 digits/ })
    expect(await as(APP, () => rpc('set_person_alerts', { p_person: 'adil', p_phone: '', p_email: 'nope' }))).toMatchObject({ ok: false, reason: /not an email/ })
    await expect(as(STRANGER, () => rpc('set_person_alerts', { p_person: 'adil', p_phone: '4145550100', p_email: '' }))).rejects.toThrow(/team only/)
    await expect(as(STRANGER, () => rpc('person_alerts', { p_person: 'adil' }))).rejects.toThrow(/team only/)
  })
})
