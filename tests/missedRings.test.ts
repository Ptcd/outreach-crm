// 0317: a seller who hangs up while it is still ringing is a missed call like any other (Juan, 3524 Buckingham Rd,
// 2026-11-24: three calls, one logged). inbound_rings_missed takes Twilio's finished calls and logs the ones nothing did.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATIONS = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')
const LEAD = '00000000-0000-0000-0000-0000000000d1'
const LINE = '+12623812196'
const SID = (n: number) => `CA${String(n).padStart(32, '0')}`
const NOW = '2026-11-24T18:20:00Z'

let db: PGlite
const one = async <T>(sql: string, params: unknown[] = []) => (await db.query<{ r: T }>(`select ${sql} as r`, params)).rows[0].r
const call = (n: number, from: string, to = LINE, start = '2026-11-24T18:15:43Z') => ({ sid: SID(n), from, to, start_time: start, duration: 10 })

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATIONS)
  await db.exec(`
    insert into public.leads (id, wpie_owner_id, owner_name, property_address, municipality, mailing_state, lane, stage, locked_to)
      values ('${LEAD}', 9701, 'Ellen Kupper', '3524 Buckingham Rd', 'Sturtevant', 'WI', 'flip', 'follow_up', 'thalia');
    insert into public.contacts (lead_id, kind, value, value_normalized, line_type) values ('${LEAD}', 'phone', '2626641903', '2626641903', 'mobile');
    insert into public.messages (lead_id, channel, direction, status, body, from_number, to_number, sent_at)
      values ('${LEAD}', 'sms', 'out', 'sent', 'hola', '${LINE}', '+12626641903', now());`)
  // the 11:10 call was logged by the phone server: it must not be logged twice
  await db.query(`select public.inbound_call_log($1, '+12626641903', $2, 'missed', 77, null, '2026-11-24T17:12:12Z'::timestamptz)`, [SID(1), LINE])
})

describe('calls nobody logged', () => {
  it('logs a seller who hung up while it rang, once, with a call-back task on the card', async () => {
    const r = await one<{ seller_calls: number; logged_now: number }>(`public.inbound_rings_missed($1::jsonb, false, $2::timestamptz)`,
      [JSON.stringify([call(1, '+12626641903'), call(2, '+12626641903')]), NOW])
    expect(r).toMatchObject({ seller_calls: 2, logged_now: 1 })
    const t = (await db.query<{ title: string; owner: string }>(`select title, owner::text from public.tasks where lead_id = $1 and source_key like '%' || $2`, [LEAD, SID(2)])).rows
    expect(t.length + (await db.query(`select 1 from public.tasks where lead_id = $1 and title = 'They called us: call back'`, [LEAD])).rows.length).toBeGreaterThan(0)
    expect((await db.query(`select 1 from public.messages where source_key = $1`, [`icall:${SID(2)}`])).rows).toHaveLength(1)
    const again = await one<{ logged_now: number }>(`public.inbound_rings_missed($1::jsonb, false, $2::timestamptz)`, [JSON.stringify([call(2, '+12626641903')]), NOW])
    expect(again.logged_now).toBe(0)
  })
  it('leaves alone a call to a line that is not a seller line, a call the assistant took, and an app leg', async () => {
    await db.query(`insert into public.voice_calls (call_sid, from10, to_number, started_at, outcome) values ($1, '2626641903', $2, now(), 'hung_up')`, [SID(3), LINE])
    const r = await one<{ seller_calls: number; logged_now: number }>(`public.inbound_rings_missed($1::jsonb, false, $2::timestamptz)`,
      [JSON.stringify([call(4, '+12626641903', '+14145550000'), call(3, '+12626641903'), { ...call(5, 'client:thalia') }]), NOW])
    expect(r).toMatchObject({ seller_calls: 1, logged_now: 0 })
  })
  it('a look back writes each call at the time it was made', async () => {
    await one(`public.inbound_rings_missed($1::jsonb, true, $2::timestamptz)`, [JSON.stringify([call(6, '+14145557777', LINE, '2026-11-21T16:03:00Z')]), NOW])
    const row = (await db.query<{ t: string }>(`select created_at::text t from public.inbound_calls where call_sid = $1`, [SID(6)])).rows[0]
    expect(row.t.startsWith('2026-11-21')).toBe(true)
  })
})
