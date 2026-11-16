// 0244: an owner who said yes keeps the caller's call until a person reaches them. Before, the owner's next text closed
// the "call now" task and set the next call four days out. A no, a STOP and a date they gave still do what they did.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')
const YES = '2026-11-12T20:00:00Z'           // Thursday 2:00 PM Central
const AGAIN = '2026-11-12T20:12:00Z'
const LATER = '2026-11-12T21:30:00Z'

let db: PGlite
const rows = async <T>(sql: string, params: unknown[] = []) => (await db.query<T>(sql, params)).rows
const one = async <T>(sql: string, params: unknown[] = []) => (await rows<{ r: T }>(`select ${sql} as r`, params))[0].r
const ev = (lead: string, payload: object, at: string) =>
  one<{ ok: boolean; belt: string; step: number }>(`public.belt_event($1, 'inbound_text', $2::jsonb, 'test', $3::timestamptz)`, [lead, JSON.stringify({ ...payload, at }), at])
const card = async (n: number) => (await rows<{ id: string }>(
  `insert into public.leads (wpie_owner_id, owner_name, lane, stage, property_address, locked_to, mailing_state)
   values ($1, $2, 'flip', 'opener_sent', $3, 'adil', 'WI') returning id`, [n, `OWNER ${n}`, `${n} Yes St`]))[0].id
const openCalls = (lead: string) => rows<{ owner: string; title: string; due_at: string; alerted: boolean }>(
  `select owner::text, title, due_at, notified_at is not null as alerted from public.tasks where lead_id = $1 and kind = 'call' and done_at is null`, [lead])

const C: Record<string, string> = {}
beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
  await db.exec(`insert into public.team_members (email, role, person, display_name) values
    ('colin@example.com', 'owner', 'colin', 'Colin'), ('adil@example.com', 'caller', 'adil', 'Tyler') on conflict do nothing`)
  for (const k of ['stays', 'no', 'dated', 'cold']) C[k] = await card(800 + Object.keys(C).length)
  for (const k of ['stays', 'no', 'dated']) await ev(C[k], { intent: 'interested', said: 'Yes', key: `y:${k}` }, YES)
}, 120_000)

describe('said yes, not booked', () => {
  it('a yes puts a call on the caller, now', async () => {
    const t = await openCalls(C.stays)
    expect(t).toHaveLength(1)
    expect(t[0]).toMatchObject({ owner: 'adil', title: 'Said yes, not booked: stop 1 of 4' })
  })
  it('the next text, an answer that is not a no, leaves that call on (it used to move four days out)', async () => {
    const r = await ev(C.stays, { intent: 'statement', said: 'It needs a roof', key: 'a:stays' }, AGAIN)
    expect(r).toMatchObject({ ok: true, belt: 'yes_unbooked', step: 1 })
    const t = await openCalls(C.stays)
    expect(t).toHaveLength(1)
    expect(t[0].title).toBe('Said yes, not booked: stop 1 of 4')
    expect(new Date(t[0].due_at).getTime()).toBeLessThanOrEqual(new Date(AGAIN).getTime() + 60 * 60 * 1000)
    const note = await one<string>(`(select payload->>'note' from public.belt_events where lead_id = $1 and event = 'inbound_text' order by at desc limit 1)`, [C.stays])
    expect(note).toContain('the call stays on')
  })
  it('an alert that is over half an hour old goes again; a fresh one does not', async () => {
    await db.query(`update public.tasks set notified_at = $2 where lead_id = $1 and done_at is null`, [C.stays, AGAIN])
    await ev(C.stays, { intent: 'statement', said: 'Three bedrooms', key: 'b:stays' }, '2026-11-12T20:20:00Z')
    expect((await openCalls(C.stays))[0].alerted).toBe(true)
    await ev(C.stays, { intent: 'statement', said: 'Are you there?', key: 'c:stays' }, LATER)
    expect((await openCalls(C.stays))[0].alerted).toBe(false)
  })
  it('a no still closes the card and the call', async () => {
    const r = await ev(C.no, { intent: 'not_interested', outcome: 'not_interested', said: 'Keeping it', key: 'a:no' }, AGAIN)
    expect(r.belt).toBe('dead')
    expect(await openCalls(C.no)).toEqual([])
  })
  it('"not now" still parks it', async () => {
    const r = await ev(C.dated, { intent: 'not_now', said: 'Maybe next year', key: 'a:dated' }, AGAIN)
    expect(r.belt).toBe('dormant')
  })
  it('a card that never said yes is unchanged: a plain reply goes to replied, went quiet', async () => {
    const r = await ev(C.cold, { intent: 'statement', said: 'Ok', key: 'a:cold' }, AGAIN)
    expect(r.belt).toBe('replied_quiet')
  })
})
