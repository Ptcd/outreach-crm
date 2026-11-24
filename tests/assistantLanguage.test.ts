// 0316: the assistant greets a Spanish-speaking seller in Spanish, and a seller does not ring 45 seconds into an empty
// room. phone_lang reads the thread; callers_working reads caller_call_hours; inbound_call_ring carries both.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'
import { greetingFor, callBlock } from '../supabase/functions/_shared/voicePrompt'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')

let db: PGlite
const one = async <T>(sql: string, params: unknown[] = []) => (await db.query<{ r: T }>(`select ${sql} as r`, params)).rows[0].r
let lead = ''

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
  lead = (await db.query<{ id: string }>(`insert into public.leads (wpie_owner_id, owner_name, lane, stage, property_address, municipality, locked_to)
    values (9901, 'Ellen Kupper', 'flip', 'follow_up', '3524 Buckingham Rd', 'Sturtevant', 'thalia') returning id`)).rows[0].id
  await db.query(`insert into public.contacts (lead_id, kind, value, value_normalized) values ($1, 'phone', '2626641903', '2626641903'), ($1, 'phone', '4145550101', '4145550101')`, [lead])
  for (const [to, body] of [['+12626641903', 'sí, te lo prometo, solo le voy a hablar a tu papá de la casa'], ['+12626641903', 'gracias, de verdad'],
                             ['+14145550101', 'Hi, do you still own the house on Buckingham Rd?'], ['+14145550101', 'Thanks, talk soon']])
    await db.query(`insert into public.messages (lead_id, channel, direction, status, body, to_number, sent_at) values ($1, 'sms', 'out', 'sent', $2, $3, now())`, [lead, body, to])
  await db.query(`insert into public.reply_drafts (phone10, lead_id, inbound_body, inbound_at, intent, kind, status) values ('2626641903', $1, 'Te daré 500$', now(), 'statement', 'candidate', 'no_reply')`, [lead])
  await db.exec(`delete from public.caller_call_hours; insert into public.caller_call_hours (person, days, t_from, t_to) values ('thalia', '{1,2,3,4,5}', '15:30', '18:00')`)
  await db.exec(`delete from public.caller_off_weekly`)
})

describe('which language a phone speaks', () => {
  it('reads short Spanish texts as Spanish and leaves English and French alone', async () => {
    for (const b of ['Por favor', 'Te daré 500$', 'Eres mi ídolo', 'Si']) expect(await one(`public.text_is_spanish($1)`, [b])).toBe(true)
    for (const b of ['Yes I would sell', 'No thank you', 'Stop', 'Who is this', 'Ok', 'Tu n\'es rien d\'autre qu\'un escroc, laisse les gens tranquilles'])
      expect(await one(`public.text_is_spanish($1)`, [b])).toBe(false)
    expect(await one(`public.phone_lang('2626641903')`)).toBe('es')
    expect(await one(`public.phone_lang('4145550101')`)).toBe('en')
    expect(await one(`public.phone_lang('9999999999')`)).toBe('en')
  })
})

describe('the ring lookup', () => {
  it('carries the card\'s language, and says nobody is working outside the callers\' hours', async () => {
    const off = await one<{ staffed: boolean; card: { lang: string } }>(`public.inbound_call_ring('2626641903', '2026-11-24 17:12:00+00')`)
    expect(off.card.lang).toBe('es')
    expect(off.staffed).toBe(false)          // Tuesday 11:12 AM Central: Thalia starts at 3:30
    const on = await one<{ staffed: boolean }>(`public.inbound_call_ring('2626641903', '2026-11-24 22:00:00+00')`)
    expect(on.staffed).toBe(true)            // Tuesday 4 PM Central
    await db.query(`insert into public.caller_off (person, day) values ('thalia', '2026-11-24')`)
    expect((await one<{ staffed: boolean }>(`public.inbound_call_ring('2626641903', '2026-11-24 22:00:00+00')`)).staffed).toBe(false)
  })
})

describe('what the assistant says', () => {
  it('opens with the house, says it is automated in the second sentence, and in Spanish for a Spanish card', () => {
    const en = greetingFor({ address: '3524 Buckingham Rd' })
    expect(en.startsWith('Hi, thanks for calling about the house on 3524 Buckingham Rd.')).toBe(true)
    expect(en).toContain('automated assistant')
    const es = greetingFor({ address: '3524 Buckingham Rd', lang: 'es' })
    expect(es.startsWith('Hola, gracias por llamar sobre la casa en 3524 Buckingham Rd.')).toBe(true)
    expect(es).toContain('asistente automático')
    expect(callBlock({ address: '3524 Buckingham Rd', lang: 'es' }, '+12626641903', es)).toContain('Speak Spanish for the whole call')
    expect(callBlock({ address: '3524 Buckingham Rd' }, '+12626641903', en)).not.toContain('Spanish')
  })
})
