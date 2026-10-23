import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const files = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
const BEFORE = files.filter((f) => f < '0038_').map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')
const ALIGN = readFileSync(path.join(MIGRATIONS_DIR, '0038_not_now_manual_alignment.sql'), 'utf8')
const HARDEN = readFileSync(path.join(MIGRATIONS_DIR, '0039_seller_shift_review_hardening.sql'), 'utf8')
const LEAD = '00000000-0000-0000-0000-0000000000e1'
let db: PGlite

const one = async <T,>(sql: string, params: unknown[] = []) => (await db.query<T>(sql, params)).rows[0]
const asThalia = async <T,>(fn: () => Promise<T>) => {
  await db.query(`select set_config('request.jwt.claims', $1, false)`, [JSON.stringify({
    sub: '00000000-0000-0000-0000-00000000000d', email: 'thalia@example.com',
  })])
  await db.exec('set role authenticated')
  try { return await fn() } finally { await db.exec('reset role') }
}

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(BEFORE)
  await db.exec(`
    insert into public.team_members (email, role, person, display_name)
      values ('thalia@example.com', 'caller', 'thalia', 'Thalia'),
             ('colin@example.com', 'owner', 'colin', 'Colin');
    insert into public.leads
      (id, wpie_owner_id, owner_name, property_address, municipality, mailing_state, lane, stage)
      values ('${LEAD}', 903, 'JANE ROE', '100 N MAIN ST, Milwaukee', 'Milwaukee', 'WI', 'flip', 'opener_sent');
    insert into public.contacts (lead_id, kind, value, value_normalized, line_type)
      values ('${LEAD}', 'phone', '4145550177', '4145550177', 'mobile');
  `)
})

describe('operator-manual exact-date reconciliation', () => {
  it('cancels the legacy early text and backfills one call no earlier than the Central seller date', async () => {
    await db.query(`update public.leads set named_date = '2026-11-02T18:00:00Z', named_event = 'the move' where id = $1`, [LEAD])
    await one(`select public.belt_event($1, 'move', '{"belt":"not_now_dated"}', 'legacy', '2026-10-22T17:00:00Z')`, [LEAD])
    const old = await one<{ stop: string; who: string }>(`
      select to_char(next_stop_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') stop, next_stop_who who
        from public.leads where id = $1`, [LEAD])
    expect(old).toEqual({ stop: '2026-10-29T18:00:00Z', who: 'auto_text' })
    await one(`select public.belt_claim_text($1, true, false, '2026-10-29T18:01:00Z')`, [LEAD])
    expect(await one<{ status: string }>(`select status from public.reply_drafts where lead_id = $1`, [LEAD]))
      .toEqual({ status: 'awaiting_approval' })

    await db.exec(ALIGN)

    expect(await one<{ status: string }>(`select status from public.reply_drafts where lead_id = $1`, [LEAD]))
      .toEqual({ status: 'superseded' })
    const lead = await one<{ stop: string; named: string; who: string; step: number }>(`
      select to_char(next_stop_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') stop,
        to_char(named_date at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') named,
        next_stop_who who, belt_step step from public.leads where id = $1`, [LEAD])
    expect(lead).toEqual({ stop: '2026-11-02T18:00:00Z', named: '2026-11-02T18:00:00Z', who: 'colin_call', step: 1 })
    const tasks = (await db.query<{ due: string; kind: string; owner: string; source_key: string; title: string }>(`
      select to_char(due_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') due, kind, owner::text, source_key, title
        from public.tasks where lead_id = $1 and source = 'belt' and done_at is null`, [LEAD])).rows
    expect(tasks).toEqual([{ due: '2026-11-02T18:00:00Z', kind: 'call', owner: 'colin',
      source_key: `belt:${LEAD}:not_now_dated:1:1`, title: 'Not now, with a date: stop 1 of 2' }])

    await db.exec(HARDEN)
  })

  it('reschedules the same stop, cancels the old due time, and keeps the exact CST date boundary', async () => {
    await asThalia(() => db.query(`select public.log_call($1, '4145550177', 'not_now', 'a week later',
      '2026-11-09T18:00:00Z'::timestamptz)`, [LEAD]))
    const tasks = (await db.query<{ due: string; source_key: string }>(`
      select to_char(due_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') due, source_key
        from public.tasks where lead_id = $1 and source = 'belt' and done_at is null`, [LEAD])).rows
    expect(tasks).toHaveLength(1)
    expect(tasks[0].due).toBe('2026-11-09T16:00:00Z')
    expect(await one<{ named: string; stop: string }>(`
      select to_char(named_date at time zone 'America/Chicago', 'YYYY-MM-DD HH24:MI') named,
        to_char(next_stop_at at time zone 'America/Chicago', 'YYYY-MM-DD HH24:MI') stop
        from public.leads where id = $1`, [LEAD]))
      .toEqual({ named: '2026-11-09 10:00', stop: '2026-11-09 10:00' })
  })
})
