// Missed calls and voicemails on Today, and a voicemail on the card (Colin 2026-10-27): a missed call shows with the
// voicemail's words, a closed card's call still shows (marked, never dialed), and the card's history titles a voicemail
// as one, its words first.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'
import { timelineOf } from '../src/lib/inbox'
import type { Message } from '../src/lib/types'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')
let db: PGlite

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
})

describe('missed calls and voicemails', () => {
  it('lists missed calls with the voicemail words; a closed card is marked, not hidden', async () => {
    const lead = ((await db.query<{ r: { lead_id: string } }>(`select public.agent_add_prospect($1::jsonb, 'Muse') as r`,
      [JSON.stringify({ owner_name: 'DAVE VOICEMAIL', address: '30 Missed Test Ln', phones: ['7155553001'] })])).rows[0].r).lead_id
    const m = (await db.query<{ id: string }>(`insert into public.messages (lead_id, direction, channel, body, from_number, status, sent_at)
      values ($1, 'in', 'call', $2, '+17155553001', 'inbound_missed', now() - interval '1 hour') returning id`,
      [lead, 'Missed call: (715) 555-3001 called our (262) 418-0202. Call them back.\nLeft a voicemail (21 s).\nVoicemail: "Call me back about the house."'])).rows[0].id
    await db.query(`insert into public.inbound_calls (call_sid, lead_id, from10, to_number, status, voicemail, message_id, created_at)
      values ('CA1', $1, '7155553001', '+12624180202', 'missed', true, $2, now() - interval '1 hour')`, [lead, m])
    await db.query(`insert into public.inbound_calls (call_sid, lead_id, from10, to_number, status, voicemail, created_at)
      values ('CA0', $1, '7155553001', '+12624180202', 'answered', false, now() - interval '2 hours')`, [lead])
    let rows = (await db.query<{ r: { call_sid: string; words: string; closed: boolean; called_back: boolean }[] }>(`select public.missed_calls_recent(48) as r`)).rows[0].r
    expect(rows.map((x) => [x.call_sid, x.words, x.closed, x.called_back])).toEqual([['CA1', 'Call me back about the house.', false, false]])
    await db.query(`update public.leads set stage = 'dnc' where id = $1`, [lead])
    rows = (await db.query<{ r: { closed: boolean }[] }>(`select public.missed_calls_recent(48) as r`)).rows[0].r
    expect(rows[0].closed).toBe(true)
  })

  it('the card history shows a voicemail as a voicemail, the words first', () => {
    const items = timelineOf({ ownerName: 'DAVE VOICEMAIL', messages: [{ id: 'm1', lead_id: 'L', direction: 'in', channel: 'call', status: 'inbound_missed',
      sent_at: '2026-10-27T18:04:32Z', is_opener: false, is_opt_out: false,
      body: 'Missed call: (715) 555-3001 called our (262) 418-0202. Call them back.\nLeft a voicemail (21 s).\nVoicemail: "Call me back about the house."' } as unknown as Message] })
    expect(items[0]).toMatchObject({ title: 'Voicemail from Dave', badges: expect.arrayContaining(['voicemail']) })
    expect(items[0].body.startsWith('"Call me back about the house."')).toBe(true)
    expect(items[0].body).toContain('Left a voicemail (21 s).')
  })
})
