// 0322: the assistant's call result is saved. Until 2026-11-25 voice_agent_result failed ("column reference lane is
// ambiguous") on every conversation with a card that ended in a call back, and nothing was kept; and a call outside
// 9 AM to 7 PM had its call back set for 9:30 PM the evening before. Nothing tested the function at all.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATIONS = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')
const SID = (n: number) => `CA${String(n).padStart(32, '0')}`

let db: PGlite
let card = ''
type Out = { ok: boolean; outcome: string; owner: string; due_at: string; task_id: string; lead_id: string }
const result = async (p: object) => (await db.query<{ r: Out }>(`select public.voice_agent_result($1::jsonb) as r`, [JSON.stringify(p)])).rows[0].r
const talk = [{ role: 'agent', text: 'Hi, thanks for calling about the house on Oak Street. Who am I speaking with?' }, { role: 'caller', text: 'This is Pat. I would sell.' },
  { role: 'agent', text: 'Thanks Pat.' }, { role: 'caller', text: 'Call me back.' }]
const call = (n: number, extraction: object) => ({ call_sid: SID(n), from: '+14145559901', to: '+12629996513', lead_id: card, seconds: 90, transcript: talk, extraction })

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATIONS)
  await db.exec(`insert into public.team_members (email, role, person, display_name) values ('thalia@example.com', 'caller', 'thalia', 'Thalia'),
    ('adil@example.com', 'caller', 'adil', 'Tyler') on conflict do nothing`)
  card = (await db.query<{ id: string }>(`insert into public.leads (wpie_owner_id, owner_name, lane, stage, property_address, municipality, locked_to, assigned_to)
    values (9901, 'PAT SELLER', 'flip', 'opener_sent', '12 Oak St', 'Franklin', 'thalia', 'thalia') returning id`)).rows[0].id
  await db.query(`insert into public.contacts (lead_id, kind, value, value_normalized) values ($1, 'phone', '4145559901', '4145559901')`, [card])
})

describe('the assistant talked to a seller whose number is on a card', () => {
  it('a booked call back is saved: the card line, the task for the card\'s caller, the call with its transcript', async () => {
    const r = await result(call(1, { caller_name: 'Pat Seller', why: 'got a text, would sell', condition: 'needs a roof', lane: '1', stop: false, wrong_person: false,
      callback_window: 'this afternoon after two' }))
    expect(r).toMatchObject({ ok: true, outcome: 'callback_booked', owner: 'thalia', lead_id: card })
    const t = (await db.query<{ title: string; owner: string; source: string; note: string }>(`select title, owner::text, source, note from public.tasks where id = $1`, [r.task_id])).rows[0]
    expect(t).toMatchObject({ title: 'Call back: they talked to the assistant', owner: 'thalia', source: 'voice_agent' })
    expect(t.note).toContain('Who: Pat Seller')
    const m = (await db.query<{ body: string; status: string }>(`select body, status from public.messages where source_key = $1`, [`voice:${SID(1)}`])).rows[0]
    expect(m.status).toBe('ai_answered')
    expect(m.body).toContain('The assistant answered their call (90 s).')
    expect(m.body).toContain('Callback set for')
    const v = (await db.query<{ outcome: string; n: number }>(`select outcome, jsonb_array_length(transcript) as n from public.voice_calls where call_sid = $1`, [SID(1)])).rows[0]
    expect(v).toEqual({ outcome: 'callback_booked', n: 4 })
    const l = (await db.query<{ say_next: string; stage: string }>(`select say_next, stage::text from public.leads where id = $1`, [card])).rows[0]
    expect(l.say_next).toContain('They called and talked to the assistant about got a text, would sell.')
    expect(l.stage).toBe('reply_received')
  })
  it('a not-now and a "not a fit, but call me" are saved too', async () => {
    expect(await result(call(2, { caller_name: 'Pat', lane: '3', stop: false, wrong_person: false }))).toMatchObject({ ok: true, outcome: 'not_now' })
    expect(await result(call(3, { caller_name: 'Pat', lane: 'never', stop: false, wrong_person: false, callback_window: 'tomorrow' }))).toMatchObject({ ok: true, outcome: 'never_callback' })
    const l = (await db.query<{ say_next: string }>(`select say_next from public.leads where id = $1`, [card])).rows[0]
    expect(l.say_next).toContain('the read is not a fit')
  })
  it('with no time given the call back is in half an hour, or 9:30 the next working morning, never in the past', async () => {
    const r = await result(call(4, { caller_name: 'Pat', lane: '1', stop: false, wrong_person: false }))
    const row = (await db.query<{ ahead: boolean; local: string; soon: boolean }>(
      `select $1::timestamptz > now() as ahead, to_char($1::timestamptz at time zone 'America/Chicago', 'HH24:MI') as local,
              $1::timestamptz < now() + interval '31 minutes' as soon`, [r.due_at])).rows[0]
    expect(row.ahead).toBe(true)
    expect(row.soon || row.local === '09:30').toBe(true)
  })
})
