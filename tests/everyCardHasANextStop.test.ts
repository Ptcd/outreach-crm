// 0230: every live card has a next stop. The 90-day rest keeps its check-in as the next stop; a dial ahead of the stop
// does not use the stop up; a dormant card whose stops are done is resting, not broken; a release puts the card back
// on the follow-ups it was on before the hold and closes the hold's task.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')
const NOW = '2026-11-16T18:00:00Z'

let db: PGlite
const rows = async <T>(sql: string, params: unknown[] = []) => (await db.query<T>(sql, params)).rows
const one = async <T>(sql: string, params: unknown[] = []) => (await rows<{ r: T }>(`select ${sql} as r`, params))[0].r
type Res = { ok: boolean; belt: string | null; step?: number; kept?: boolean }
const ev = (lead: string, event: string, payload: object, at = NOW) =>
  one<Res>(`public.belt_event($1, $2, $3::jsonb, 'test', $4::timestamptz)`, [lead, event, JSON.stringify(payload), at])
let n = 800
const card = async (stage = 'reply_received') => (await rows<{ id: string }>(
  `insert into public.leads (wpie_owner_id, owner_name, lane, stage, property_address, locked_to, mailing_state)
   values ($1, $2, 'flip', $4::public.lead_stage, $3, 'adil', 'WI') returning id`, [-(++n), `OWNER ${n}`, `${n} Stop St`, stage]))[0].id
const state = async (lead: string) => (await rows<{ belt: string | null; belt_step: number; stage: string; next_stop_at: string | null; next_stop_who: string | null }>(
  `select belt, belt_step, stage::text, next_stop_at, next_stop_who from public.leads where id = $1`, [lead]))[0]
const onAlarm = (lead: string) => one<boolean>(`exists (select 1 from public.cards_no_stop where lead_id = $1)`, [lead])
const openBelt = (lead: string) => rows<{ title: string }>(`select title from public.tasks where lead_id = $1 and source = 'belt' and done_at is null`, [lead])
const noAnswer = (lead: string, k: string, at = NOW) => ev(lead, 'call_logged', { outcome: 'no_answer', key: `call:${k}`, note: 'No answer (Power hour).' }, at)

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
  await db.exec(`insert into public.team_members (email, role, person, display_name) values
    ('colin@example.com', 'owner', 'colin', 'Colin'), ('adil@example.com', 'caller', 'adil', 'Tyler') on conflict do nothing`)
}, 120_000)

describe('every live card has a next stop', () => {
  it('a card put to rest for 90 days has its check-in call as the next stop', async () => {
    const c = await card('follow_up')
    const r = await one<{ ok: boolean; checkin_at: string }>(`public.cold_rest($1, '9 dials, never reached', $2::timestamptz)`, [c, NOW])
    const s = await state(c)
    expect(s.belt).toBeNull()
    expect(s.next_stop_who).toBe('thalia_call')
    expect(new Date(s.next_stop_at!).getTime()).toBe(new Date(r.checkin_at).getTime())
    expect(await onAlarm(c)).toBe(false)
  })

  it('three no-answers in one sitting leave a dormant card on its first stop, 90 days out', async () => {
    const c = await card()
    await ev(c, 'move', { belt: 'dormant' })
    const before = await state(c)
    expect(before).toMatchObject({ belt: 'dormant', belt_step: 1 })
    for (const k of ['a', 'b', 'c']) expect(await noAnswer(c, `d${k}`, '2026-11-16T18:02:00Z')).toMatchObject({ ok: true, belt: 'dormant', kept: true })
    const s = await state(c)
    expect(s).toMatchObject({ belt: 'dormant', belt_step: 1 })
    expect(s.next_stop_at).toEqual(before.next_stop_at)
    expect((await openBelt(c)).map((t) => t.title)).toEqual(['Dormant: stop 1 of 3'])
    const note = await one<string>(`(select payload->>'note' from public.belt_events where lead_id = $1 and event = 'call_logged' order by at desc limit 1)`, [c])
    expect(note).toContain('before the stop was due')
  })

  it('the stop itself, logged as a no-answer, still moves the card on', async () => {
    const c = await card()
    await ev(c, 'move', { belt: 'dormant' })
    const r = await ev(c, 'stop_done', { outcome: 'no_answer', key: 'stop:1' })
    expect(r).toMatchObject({ ok: true, belt: 'dormant', step: 2 })
  })

  it('a no-answer on a call that was due still counts', async () => {
    const c = await card()
    await ev(c, 'move', { belt: 'dormant', step: 3 })
    expect((await state(c)).next_stop_who).toBe('thalia_call')
    await db.query(`update public.leads set next_stop_at = $2::timestamptz where id = $1`, [c, NOW])
    const r = await noAnswer(c, 'due')
    expect(r.kept).toBeUndefined()
    const s = await state(c)
    expect(s.next_stop_at).toBeNull()                    // the dormant stops are done: the card rests
    expect(await onAlarm(c)).toBe(false)                 // and that is not a broken belt
  })

  it('a card on a belt with stops ahead and no next stop is still on the alarm', async () => {
    const c = await card()
    await ev(c, 'move', { belt: 'dormant' })
    await db.query(`update public.leads set next_stop_at = null where id = $1`, [c])
    expect(await onAlarm(c)).toBe(true)
  })

  it('a release puts the card back on the follow-ups it was on before the hold, and closes the hold task', async () => {
    const c = await card()
    await ev(c, 'move', { belt: 'replied_quiet', step: 2 })
    await ev(c, 'move', { belt: 'hold_not_now', reason: 'held in error' }, '2026-11-16T18:05:00Z')
    expect((await openBelt(c)).map((t) => t.title)).toEqual(['Hold lane, not now: stop 1 of 2'])
    const r = await one<{ ok: boolean; released: boolean; back_on: Res }>(
      `public.agent_mark_card($1, 'release', 'the hold was applied in error', null, null, 'muse')`, [c])
    expect(r).toMatchObject({ ok: true, released: true })
    expect(r.back_on).toMatchObject({ ok: true, belt: 'replied_quiet' })
    const s = await state(c)
    expect(s.belt).toBe('replied_quiet')
    expect(s.next_stop_at).not.toBeNull()
    expect((await openBelt(c)).every((t) => !t.title.startsWith('Hold lane'))).toBe(true)
    expect(await onAlarm(c)).toBe(false)
  })

  it('a card that went straight onto a hold is released with no hold task left open', async () => {
    const c = await card('opener_sent')
    await ev(c, 'move', { belt: 'hold_not_now', reason: 'no phone yet' })
    const r = await one<{ ok: boolean; back_on?: Res }>(`public.agent_mark_card($1, 'release', 'numbers found', null, null, 'muse')`, [c])
    expect(r.ok).toBe(true)
    expect(r.back_on).toBeUndefined()
    expect((await state(c)).belt).toBeNull()
    expect(await openBelt(c)).toEqual([])
    expect(await onAlarm(c)).toBe(false)
  })
})
