// 0313: a number the phone company says is not in service is marked bad by itself, from the call's recording; a
// voicemail greeting is not that; and a recorded call's notes are not a reach.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')

let db: PGlite
const rows = async <T>(sql: string, params: unknown[] = []) => (await db.query<T>(sql, params)).rows
const one = async <T>(sql: string, params: unknown[] = []) => (await rows<{ r: T }>(`select ${sql} as r`, params))[0].r
const says = (words: string) => one<boolean>(`public.words_say_not_in_service($1)`, [words])

const card = async (ownerId: number, name: string, phones: string[], stage = 'opener_sent') => {
  const id = (await rows<{ id: string }>(
    `insert into public.leads (wpie_owner_id, owner_name, lane, stage, property_address, locked_to, mailing_state)
     values ($1, $2, 'flip', $3::public.lead_stage, $4, 'thalia', 'WI') returning id`, [ownerId, name, stage, `${ownerId} Test St`]))[0].id
  for (const p of phones) {
    await db.query(`insert into public.contacts (lead_id, kind, value, value_normalized, line_type, person_name) values ($1, 'phone', $2, $2, 'mobile', $3)`, [id, p, name])
  }
  return id
}
const recorded = async (sid: string, lead: string, phone: string, words: string, direction = 'out') => {
  await db.query(`insert into public.call_recordings (call_sid, recording_sid, lead_id, direction, phone10, caller, duration_s, started_at, status)
                  values ($1, $2, $3, $4, $5, 'thalia', 22, now(), 'transcribing')`, [sid, 'RE' + sid.slice(2), lead, direction, phone])
  await db.query(`insert into public.call_transcripts (call_sid, lead_id, words, created_at) values ($1, $2, $3, now())`, [sid, lead, words])
}
const phoneStatus = (lead: string, phone: string) =>
  one<string>(`(select status::text from public.contacts where lead_id = $1 and value_normalized = $2)`, [lead, phone])
const stage = (lead: string) => one<string>(`(select stage::text from public.leads where id = $1)`, [lead])

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
})

describe('what counts as the not-in-service message', () => {
  it('hears the carriers\' wordings on the seller\'s side', async () => {
    expect(await says('Seller: The number you have dialed is not in service. Please check the number and try again.')).toBe(true)
    expect(await says('Seller: We\'re sorry, your call cannot be completed as dialed.')).toBe(true)
    expect(await says('Seller: The number you have reached has been disconnected or is no longer in service.')).toBe(true)
    expect(await says('Seller: This is not a working number.')).toBe(true)
    expect(await says('Seller: The number you have called is not in service at this time.')).toBe(true)
  })
  it('does not hear it in a voicemail greeting or in our own words', async () => {
    expect(await says('Seller: The person you are trying to reach is not available. Please leave a message after the tone.')).toBe(false)
    expect(await says('Seller: The wireless customer you are calling is not available.')).toBe(false)
    expect(await says('Seller: Hi, you\'ve reached Mike, leave your name and number.')).toBe(false)
    expect(await says('Us: Hi, is this still a working number for Mike? The old one was not in service.\nSeller: Yeah this is Mike.')).toBe(false)
  })
})

describe('the recording marks the number', () => {
  it('marks a dead number bad on every card that has it, and parks a card with nothing left', async () => {
    const lone = await card(401, 'LONE OWNER', ['4145550401'])
    const also = await card(402, 'ALSO HAS IT', ['4145550401', '4145550402'])
    await recorded('CA' + '1'.repeat(32), lone, '4145550401', 'Seller: The number you have dialed is not in service. Please check the number and dial again.')
    expect(await phoneStatus(lone, '4145550401')).toBe('bad')
    expect(await phoneStatus(also, '4145550401')).toBe('bad')
    expect(await stage(lone)).toBe('data_fix')
    expect(await stage(also)).toBe('opener_sent')                     // it still has a number to try
    expect(await phoneStatus(also, '4145550402')).toBe('ok')
  })
  it('leaves the number alone on a voicemail, and on a call that came in', async () => {
    const vm = await card(403, 'VOICEMAIL VIC', ['4145550403'])
    await recorded('CA' + '2'.repeat(32), vm, '4145550403', 'Seller: You have reached Vic. Leave a message.')
    expect(await phoneStatus(vm, '4145550403')).toBe('ok')
    const inbound = await card(404, 'INBOUND IDA', ['4145550404'])
    await recorded('CA' + '3'.repeat(32), inbound, '4145550404', 'Seller: not in service', 'in')
    expect(await phoneStatus(inbound, '4145550404')).toBe('ok')
  })
})

describe('a recorded call is not a reach', () => {
  it('keeps a card whose only call entry is the notes in the text pool', async () => {
    await db.exec(`insert into public.team_members (email, role, person, display_name) values ('thalia@example.com', 'caller', 'thalia', 'Thalia') on conflict do nothing`)
    const c = await card(405, 'NOTES NED', ['4145550405'], 'opener_queued')
    await db.query(`insert into public.text_fitness (wpie_owner_id, verdict, need, need_why, tier, equity, as_of) values (405, 'ok', true, 'tax', 'C', 'unknown', current_date)`)
    const before = await rows(`select 1 from public.text_pool(now()) where lead_id = $1 and block is null`, [c])
    await db.query(`insert into public.messages (lead_id, direction, channel, body, status, source_key, sent_at) values ($1, 'in', 'call', 'Voicemail', 'call_notes', 'cnote:x', now())`, [c])
    const after = await rows(`select 1 from public.text_pool(now()) where lead_id = $1 and block is null`, [c])
    expect(after.length).toBe(before.length)
    expect(after.length).toBeGreaterThan(0)
  })
})
