import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const files = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
const BEFORE = files.filter((f) => f < '0039_').map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')
const HARDEN = readFileSync(path.join(MIGRATIONS_DIR, '0039_seller_shift_review_hardening.sql'), 'utf8')
const LEAD = '00000000-0000-0000-0000-0000000000e1'
const THALIA = { sub: '00000000-0000-0000-0000-00000000000a', email: 'thalia@example.com' }

async function database() {
  const db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(BEFORE)
  await db.exec(`
    insert into public.team_members (email, role, person, display_name) values
      ('thalia@example.com', 'caller', 'thalia', 'Thalia'),
      ('adil@example.com', 'caller', 'adil', 'Adil');
    insert into public.leads (id, wpie_owner_id, owner_name, property_address, municipality, mailing_state, lane, stage)
      values ('${LEAD}', 904, 'JANE ROE', '100 N MAIN ST, Milwaukee', 'Milwaukee', 'WI', 'flip', 'opener_sent');
    insert into public.contacts (lead_id, kind, value, value_normalized, line_type)
      values ('${LEAD}', 'phone', '4145550177', '4145550177', 'mobile');
  `)
  return db
}

async function as<T>(db: PGlite, claims: object, fn: () => Promise<T>): Promise<T> {
  await db.query(`select set_config('request.jwt.claims', $1, false)`, [JSON.stringify(claims)])
  await db.exec('set role authenticated')
  try { return await fn() } finally { await db.exec('reset role'); await db.query(`select set_config('request.jwt.claims', '', false)`) }
}

describe('0039 legacy takeover preflight', () => {
  it('fails before mutation rather than blessing a reassigned legacy authorization', async () => {
    const db = await database()
    await as(db, THALIA, () => db.query(`select public.begin_human_call($1, '4145550177', 'personal',
      'legacy_upgrade_001', '2026-10-23T16:00:00Z')`, [LEAD]))
    await db.query(`update public.leads set assigned_to = 'adil' where id = $1`, [LEAD])

    await expect(db.exec(HARDEN)).rejects.toThrow(/every legacy human call pause to be resolved first/)
    expect((await db.query(`select 1 from information_schema.columns where table_schema = 'public'
      and table_name = 'leads' and column_name = 'human_takeover_assigned_to'`)).rows).toHaveLength(0)
    expect((await db.query<{ active: boolean; owner: string; key: string }>(`
      select human_takeover_at is not null active, assigned_to::text owner, human_takeover_key key
        from public.leads where id = $1`, [LEAD])).rows[0]).toEqual({
      active: true, owner: 'adil', key: 'legacy_upgrade_001',
    })
  })

  it('applies with zero active pauses and snapshots only new authorizations', async () => {
    const db = await database()
    await db.exec(HARDEN)
    expect((await db.query(`select 1 from information_schema.columns where table_schema = 'public'
      and table_name = 'leads' and column_name = 'human_takeover_assigned_to'`)).rows).toHaveLength(1)

    const first = await as(db, THALIA, async () => (await db.query<{ r: Record<string, unknown> }>(`
      select public.begin_human_call($1, '4145550177', 'personal', 'post_upgrade_001', '2026-10-23T16:00:00Z') r`, [LEAD])).rows[0].r)
    const retry = await as(db, THALIA, async () => (await db.query<{ r: Record<string, unknown> }>(`
      select public.begin_human_call($1, '4145550177', 'personal', 'post_upgrade_001', '2026-10-23T16:00:00Z') r`, [LEAD])).rows[0].r)
    expect(first).toMatchObject({ ok: true, duplicate: false, paused: true })
    expect(retry).toMatchObject({ ok: true, duplicate: true, paused: true })
    expect((await db.query<{ owner: string }>(`select human_takeover_assigned_to::text owner from public.leads where id = $1`, [LEAD])).rows[0])
      .toEqual({ owner: 'thalia' })
  })
})
