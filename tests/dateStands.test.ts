// 0229: a card waiting on a date the seller gave keeps the date, and the caller's call on it, when the seller texts
// again without interest. Interest still moves the card; a no still closes it.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')
const NOW = '2026-11-13T18:00:00Z'
const DATE = '2027-02-13T00:00:00Z'

let db: PGlite
const rows = async <T>(sql: string, params: unknown[] = []) => (await db.query<T>(sql, params)).rows
const one = async <T>(sql: string, params: unknown[] = []) => (await rows<{ r: T }>(`select ${sql} as r`, params))[0].r
const ev = (lead: string, event: string, payload: object, at = NOW) =>
  one<{ ok: boolean; belt: string }>(`public.belt_event($1, $2, $3::jsonb, 'test', $4::timestamptz)`, [lead, event, JSON.stringify(payload), at])
const card = async (n: number) => (await rows<{ id: string }>(
  `insert into public.leads (wpie_owner_id, owner_name, lane, stage, property_address, locked_to, mailing_state)
   values ($1, $2, 'flip', 'reply_received', $3, 'adil', 'WI') returning id`, [-n, `OWNER ${n}`, `${n} Wait St`]))[0].id
const state = async (lead: string) => (await rows<{ belt: string; next_stop_at: string | null; next_stop_who: string | null }>(
  `select belt, next_stop_at, next_stop_who from public.leads where id = $1`, [lead]))[0]
const openCalls = (lead: string) => rows<{ kind: string; owner: string; due_at: string }>(
  `select kind::text, owner::text, due_at from public.tasks where lead_id = $1 and done_at is null order by due_at`, [lead])
const waitOn = async (lead: string) => {
  await ev(lead, 'named_date', { named_date: DATE, named_event: 'the estate closes' })
}

const C: Record<string, string> = {}
beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
  await db.exec(`insert into public.team_members (email, role, person, display_name) values
    ('colin@example.com', 'owner', 'colin', 'Colin'), ('adil@example.com', 'caller', 'adil', 'Tyler') on conflict do nothing`)
  for (const k of ['polite', 'who', 'again', 'keen', 'no']) { C[k] = await card(700 + Object.keys(C).length); await waitOn(C[k]) }
}, 120_000)

describe('a date they gave stands', () => {
  it('the wait starts with a stop on the date', async () => {
    const s = await state(C.polite)
    expect(s.belt).toBe('not_now_dated')
    expect(new Date(s.next_stop_at!).getTime()).toBeGreaterThan(new Date('2027-01-15T00:00:00Z').getTime())
  })
  it('"I will", a question about us and another "not yet" all leave the card waiting on the same date', async () => {
    const before = await state(C.polite)
    for (const [k, payload] of [['polite', { intent: '', said: 'I will' }], ['who', { intent: 'who_is_this', said: 'How did you get my number?' }],
      ['again', { intent: 'not_now', said: 'It may be 3 or more months' }]] as const) {
      const r = await ev(C[k], 'inbound_text', { ...payload, key: `t:${k}`, at: '2026-11-13T18:05:00Z' }, '2026-11-13T18:05:00Z')
      expect(r).toMatchObject({ ok: true, belt: 'not_now_dated' })
      const s = await state(C[k])
      expect(s.belt).toBe('not_now_dated')
      expect(s.next_stop_at).toEqual(before.next_stop_at)
    }
    const note = await one<string>(`(select payload->>'note' from public.belt_events where lead_id = $1 and event = 'inbound_text' order by at desc limit 1)`, [C.polite])
    expect(note).toContain('the date they gave stands')
  })
  it('interest still moves the card off the wait', async () => {
    const r = await ev(C.keen, 'inbound_text', { intent: 'price_first', said: 'Actually, what would you pay?', key: 't:keen', at: '2026-11-13T18:06:00Z' }, '2026-11-13T18:06:00Z')
    expect(r.belt).toBe('yes_unbooked')
  })
  it('a no still closes it', async () => {
    const r = await ev(C.no, 'inbound_text', { intent: 'not_interested', outcome: 'not_interested', said: 'Never selling', key: 't:no', at: '2026-11-13T18:07:00Z' }, '2026-11-13T18:07:00Z')
    expect(r.belt).toBe('dead')
  })
})
