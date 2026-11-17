// 0248 (Colin 2026-11-17): the Research Board is weekly, and a job with two whole weeks and no tick is flagged to
// Colin (a text), to everyone (a desk post) and to Muse (agent_attention). On the real migrations.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')

let db: PGlite
const one = async <T>(sql: string, params: unknown[] = []) => (await db.query<{ r: T }>(`select ${sql} as r`, params)).rows[0].r
type Json = Record<string, any>
// a fixed clock: Tuesday 2026-11-17, in the week of Monday 2026-11-16
const NOW = '2026-11-17T18:00:00Z'
const plus = (days: number) => new Date(Date.parse(NOW) + days * 86400_000).toISOString()
const set = (job: string, week: string | null, done: boolean | null, note: string | null, status: string | null = null) =>
  one<Json>(`public.agent_research_set($1, $2, $3, $4, $5, 'Muse')`, [job, week, done, note, status])
const standing = async (now: string) => Object.fromEntries((await db.query<{ job_id: number; last_done: string | null; weeks_missed: number }>(
  `select job_id, to_char(last_done, 'YYYY-MM-DD') as last_done, weeks_missed from public.research_standing($1)`, [now])).rows.map((r) => [r.job_id, r]))

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
  // the ticks as they stood live: eleven seeded in the week of Nov 9, nothing else
  await db.exec(`delete from public.research_week_ticks;
    insert into public.research_week_ticks (job_id, week, done, note, by, at)
    select id, date '2026-11-09', true, 'seeded', 'Muse', timestamptz '2026-11-10 18:00+00' from public.research_jobs where id in (1, 2, 3, 4, 5, 15, 16, 17, 18, 19, 20)`)
}, 120_000)

describe('a tick is a week', () => {
  it('the monthly ticks were carried into a week, and every job is weekly', async () => {
    expect(await one<number>(`(select count(*)::int from public.research_jobs where cadence ilike '%month%' or cadence = 'Rides rotation')`)).toBe(0)
    expect(await one<string>(`public.research_week($1)::text`, [NOW])).toBe('2026-11-16')
    expect(await one<string>(`public.research_week('2026-11-23T05:30:00Z')::text`)).toBe('2026-11-16')   // Sunday 11:30 PM Central
  })
  it('refuses a week that has not started and one before the board', async () => {
    expect((await set('1', '2031-01-06', true, 'ran')).ok).toBe(false)
    expect((await set('1', '2026-10-05', true, 'ran')).ok).toBe(false)
    expect((await set('1', null, null, null)).ok).toBe(false)
    expect((await set('no_such', null, true, 'x')).ok).toBe(false)
  })
  it('ticks the week any of its days names, and leaves a status alone', async () => {
    const r = await set('tax_delinquent', '2026-11-12', true, 'Waukesha and Dane lists read')   // a Thursday
    expect(r).toMatchObject({ ok: true, job: 'tax_delinquent', week: '2026-11-09', done: true })
    const s = await set('bankruptcy', null, null, null, 'free feed only')
    expect(s).toMatchObject({ ok: true, status: 'free feed only' })
    expect(await one<number>(`(select count(*)::int from public.research_week_ticks where job_id = 7)`)).toBe(0)
  })
  it('the board carries the weeks newest first, the ticks by week, and where each job stands', async () => {
    const b = await one<Json>(`public.research_board()`)
    expect(b.weeks[0]).toBe(b.week)
    expect(b.weeks[b.weeks.length - 1] >= '2026-11-09').toBe(true)
    expect(b.months).toEqual([])
    const j = b.jobs.find((x: Json) => x.id === 1)
    expect(j.ticks['2026-11-09'].done).toBe(true)
    expect(j.last_done).toBe('2026-11-09')
    expect(typeof j.weeks_missed).toBe('number')
  })
})

describe('behind is two whole weeks with no tick', () => {
  it('the week under way never counts', async () => {
    const s = await standing(NOW)
    expect(s[1]).toMatchObject({ last_done: '2026-11-09', weeks_missed: 0 })
    expect(s[7]).toMatchObject({ last_done: null, weeks_missed: 1 })        // never ticked: the week of Nov 9 went by
    expect(await one<Json[]>(`public.research_behind($1)`, [NOW])).toEqual([])
  })
  it('a job never ticked is behind a week before one that ran in the first week', async () => {
    const b = await one<Json[]>(`public.research_behind($1)`, [plus(7)])     // Tuesday Nov 24
    expect(b.map((x) => x.key)).toEqual(['evictions', 'bankruptcy', 'money_judgments', 'divorce_fa', 'guardianship_gn', 'water_shutoff', 'fire_damage', 'vacant_registry', 'code_raze'])
    expect(b[0]).toMatchObject({ last_ran_week_of: null, weeks_with_no_tick: 2 })
    const later = await one<Json[]>(`public.research_behind($1)`, [plus(14)])   // Tuesday Dec 1
    expect(later.length).toBe(20)
    expect(later.find((x) => x.key === 'foreclosure_cv')).toMatchObject({ last_ran_week_of: '2026-11-09', weeks_with_no_tick: 2 })
  })
  it('a tick takes the job off the list', async () => {
    await set('evictions', '2026-11-18', true, '412 filings banked, 38 tied')
    const b = await one<Json[]>(`public.research_behind($1)`, [plus(7)])
    expect(b.map((x) => x.key)).not.toContain('evictions')
  })
})

describe('the Monday flag', () => {
  it('says nothing while nothing is behind', async () => {
    expect(await one<Json>(`public.research_behind_flag($1)`, [NOW])).toMatchObject({ ok: true, behind: 0 })
    expect(await one<number>(`(select count(*)::int from public.research_flags)`)).toBe(0)
  })
  it('one text to Colin and one desk post a week, naming the jobs', async () => {
    const before = await one<number>(`(select count(*)::int from public.ops_alerts)`)
    const r = await one<Json>(`public.research_behind_flag($1)`, [plus(6)])     // Monday Nov 23
    expect(r).toMatchObject({ ok: true, week: '2026-11-23', behind: 8 })
    const text = await one<string>(`(select text from public.ops_alerts order by id desc limit 1)`)
    expect(text).toMatch(/^Research behind: 8 jobs have had no tick for more than two weeks: Bankruptcy \(job 7, never ticked\)/)
    expect(text).toMatch(/The Research page has the list\.$/)
    const post = (await db.query<Json>(`select * from public.desk_messages where id = $1`, [Number(r.desk_id)])).rows[0]
    expect(post).toMatchObject({ author: 'desk', for_whom: 'all', kind: 'note' })
    expect(post.body).toMatch(/P2 job 7, Bankruptcy: never ticked, 2 whole weeks with no tick/)
    const again = await one<Json>(`public.research_behind_flag($1)`, [plus(8)])  // the same week
    expect(again.already_flagged).toBe(true)
    expect(await one<number>(`(select count(*)::int from public.ops_alerts)`)).toBe(before + 1)
  })
  it('Muse is told on every tool call until the job is ticked; Muse 2 is not', async () => {
    const a = await one<Json | null>(`public.agent_attention('Muse', $1)`, [plus(7)])
    expect(a?.research.behind.length).toBe(8)
    expect(a?.research.say).toMatch(/8 research jobs have had no tick/)
    expect((await one<Json | null>(`public.agent_attention('Muse 2', $1)`, [plus(7)]))?.research).toBeUndefined()
    expect((await one<Json | null>(`public.agent_attention('Muse', $1)`, [NOW]))?.research).toBeUndefined()
  })
})
