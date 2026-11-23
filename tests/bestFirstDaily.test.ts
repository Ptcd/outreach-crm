// Best first, every day (0311). Colin 2026-11-23: "Yes, every day" to the strongest-first order being the standing
// order of both call lists. On the real migrations: the morning run ranks each working caller's list once a day
// (tier A, B, C; never D), skips Sunday, a caller who is off and the hours before 5 AM Central, puts an agent's task
// behind the ranked cards, and closes an earlier day's ranked task whose card fell off the list.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')
const MON = '2026-11-23T11:35:00Z'        // Monday 5:35 AM Central
const MON_EARLY = '2026-11-23T10:35:00Z'  // Monday 4:35 AM Central
const TUE = '2026-11-24T11:35:00Z'
const SUN = '2026-11-29T11:35:00Z'

let db: PGlite
const rows = async <T>(sql: string, params: unknown[] = []) => (await db.query<T>(sql, params)).rows
const one = async <T>(sql: string, params: unknown[] = []) => (await rows<{ r: T }>(`select ${sql} as r`, params))[0].r
const morning = (at: string) => one<{ ran: boolean; why?: string; lists?: Record<string, unknown> }>(`public.power_lists_morning($1::timestamptz)`, [at])

const card = async (ownerId: number, name: string, who: 'thalia' | 'adil', tier: string | null) => {
  const id = (await rows<{ id: string }>(
    `insert into public.leads (wpie_owner_id, owner_name, lane, stage, property_address, locked_to, reasons_to_sell, mailing_state)
     values ($1, $2, 'flip', 'opener_sent', $3, $4::public.team_person, array['behind on taxes'], 'WI') returning id`,
    [ownerId, name, `${ownerId} Test St`, who]))[0].id
  const p = `414555${String(1000 + ownerId).slice(-4)}`
  await db.query(`insert into public.contacts (lead_id, kind, value, value_normalized, line_type, person_name) values ($1, 'phone', $2, $2, 'mobile', $3)`, [id, p, name])
  if (tier) {
    await db.query(`insert into public.text_fitness (wpie_owner_id, verdict, need, need_why, tier, equity, as_of) values ($1, 'ok', true, $2, $3, 'unknown', '2026-11-23')`,
      [ownerId, tier === 'B' ? 'foreclosure + tax' : 'tax', tier])
  }
  return id
}
const openTasks = (lead: string) => rows<{ source: string; source_key: string | null; due_at: string; done_at: string | null }>(
  `select source, source_key, due_at::text, done_at::text from public.tasks where lead_id = $1 order by due_at`, [lead])

const C: Record<string, string> = {}

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
  await db.exec(`insert into public.team_members (email, role, person, display_name) values
    ('colin@example.com', 'owner', 'colin', 'Colin'), ('thalia@example.com', 'caller', 'thalia', 'Thalia'), ('adil@example.com', 'caller', 'adil', 'Tyler')
    on conflict do nothing`)
  await db.exec(`delete from public.caller_off_weekly`)
  C.b = await card(201, 'BETTY B', 'thalia', 'B')
  C.c = await card(202, 'CARL C', 'thalia', 'C')
  C.d = await card(203, 'DAN D', 'thalia', 'D')
  C.agent = await card(204, 'ANNA AGENT', 'thalia', null)
  // an agent's call task, written for later in the day: it goes behind the ranked cards
  await db.query(`insert into public.tasks (lead_id, due_at, kind, owner, source, source_key, title)
                  values ($1, '2026-11-23T18:00:00Z', 'call', 'thalia', 'power_hour', 'agent:Grok:x1', 'Grok: call')`, [C.agent])
  C.t = await card(205, 'TOM TYLERCARD', 'adil', 'B')
  await db.query(`insert into public.caller_off (person, day) values ('adil', '2026-11-23')`)
})

describe('the morning ranking', () => {
  it('waits for 5 AM Central', async () => {
    const r = await morning(MON_EARLY)
    expect(r.ran).toBe(false)
    expect(await rows(`select 1 from public.power_list_runs`)).toHaveLength(0)
  })

  it('ranks a working caller strongest first, never tier D, and leaves a caller who is off alone', async () => {
    const r = await morning(MON)
    expect(r.ran).toBe(true)
    expect(r.lists?.adil).toBe('off today')
    const b = await openTasks(C.b), c = await openTasks(C.c)
    expect(b).toHaveLength(1); expect(c).toHaveLength(1)
    expect(b[0].source_key).toBe(`need:2026-11-23:${C.b}`)
    expect(new Date(b[0].due_at) < new Date(c[0].due_at)).toBe(true)     // B before C
    expect(await openTasks(C.d)).toHaveLength(0)                          // D is never put on the list
    expect(await openTasks(C.t)).toHaveLength(0)                          // Tyler is off
    const ag = await openTasks(C.agent)
    expect(new Date(ag[0].due_at) > new Date(c[0].due_at)).toBe(true)    // the agent's task is behind
    expect(ag[0].done_at).toBeNull()                                      // and not closed
  })

  it('runs once a day', async () => {
    const r = await morning('2026-11-23T12:35:00Z')
    expect(r.lists?.thalia).toBe('already ranked today')
    expect(await rows(`select 1 from public.tasks where source_key like 'need:%'`)).toHaveLength(2)
  })

  it('rests on Sunday', async () => {
    const r = await morning(SUN)
    expect(r.ran).toBe(false)
  })

  it('closes yesterday\'s ranked task whose card fell off the list, and keeps the one still on it', async () => {
    await db.query(`update public.leads set stage = 'dead' where id = $1`, [C.c])
    await morning(TUE)
    const b = await openTasks(C.b), c = await openTasks(C.c)
    expect(b).toHaveLength(1)
    expect(b[0].done_at).toBeNull()
    expect(b[0].due_at.startsWith('2026-11-24')).toBe(true)              // re-timed to today's list
    expect(c[0].source).toBe('power_hour_dropped')
    expect(c[0].done_at).not.toBeNull()
    const run = await one<{ dropped: number }>(`(select result from public.power_list_runs where day = '2026-11-24' and person = 'thalia')`)
    expect(run.dropped).toBe(1)
  })
})
