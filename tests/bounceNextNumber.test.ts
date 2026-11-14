// 0225: a card whose first text bounced on a dead number goes on the day's list for its next number; a card whose
// text may have arrived does not. And agent_attention: offer steps and unread desk posts, where the agent already looks.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')
const NOW = '2026-11-12T16:00:00Z'          // Thursday 10:00 AM Central
const NEXT = '2026-11-13T16:00:00Z'

let db: PGlite
const rows = async <T>(sql: string, params: unknown[] = []) => (await db.query<T>(sql, params)).rows
const one = async <T>(sql: string, params: unknown[] = []) => (await rows<{ r: T }>(`select ${sql} as r`, params))[0].r
const card = async (ownerId: number, owner: string, phones: string[]) => {
  const id = (await rows<{ id: string }>(
    `insert into public.leads (wpie_owner_id, owner_name, lane, stage, property_address, locked_to, reasons_to_sell, mailing_state)
     values ($1, $2, 'flip', 'opener_queued', $3, 'thalia', '{foreclosure}', 'WI') returning id`, [ownerId, owner, `${ownerId} Bounce St`]))[0].id
  let i = 0
  for (const p of phones) {
    await db.query(`insert into public.contacts (lead_id, kind, value, value_normalized, line_type, person_name, created_at) values ($1, 'phone', $2, $2, 'mobile', $3, $4::timestamptz + make_interval(secs => $5))`,
      [id, p, owner, '2026-11-01T00:00:00Z', i++])
  }
  await db.query(`insert into public.text_fitness (wpie_owner_id, verdict, need, need_why, tier, equity, as_of) values ($1, 'ok', true, 'test', 'B', 'likely', '2026-11-12')`, [ownerId])
  return id
}
const queue = (lead: string, phone: string, body: string, now = NOW) =>
  one<{ status: string; reason?: string }>(`public.agent_queue_text($1, $2, $3, 1, null, 'Muse', $4)`, [lead, phone, body, now])
/** The queued first text went out and came back: delivered, or bounced with a carrier code (which marks the phone bad). */
const outcome = async (lead: string, phone: string, status: 'delivered' | 'undelivered', sid: string) => {
  await db.query(`update public.planned_openers set send_status = $2, sent_at = $3, provider_sid = $4, error_code = $5 where lead_id = $1 and step = 1 and phone like '%' || $6`,
    [lead, status, NOW, sid, status === 'undelivered' ? '30005' : null, phone])
  await db.query(`insert into public.messages (lead_id, direction, channel, body, provider_sid, is_opener, sent_at, status, to_number)
                  values ($1, 'out', 'sms', 'first text', $2, true, $3, $4, $5)`, [lead, sid, NOW, status, '+1' + phone])
  await db.query(`update public.leads set stage = 'opener_sent' where id = $1`, [lead])
  if (status === 'undelivered') await db.query(`update public.contacts set status = 'bad' where lead_id = $1 and value_normalized = $2`, [lead, phone])
}
const nextNumbers = (now = NEXT) => rows<{ lead_id: string; phone: string; block: string | null }>(
  `select lead_id, phone, block from public.text_pool($1) where kind = 'next_number' order by ord`, [now])

const C: Record<string, string> = {}

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
  await db.exec(`insert into public.team_members (email, role, person, display_name) values
    ('colin@example.com', 'owner', 'colin', 'Colin'), ('thalia@example.com', 'caller', 'thalia', 'Thalia'), ('adil@example.com', 'caller', 'adil', 'Tyler')
    on conflict do nothing`)
  C.bounced = await card(901, 'BETTY BOUNCE', ['4145559011', '4145559012'])
  C.arrived = await card(902, 'ARNIE ARRIVED', ['4145559021', '4145559022'])
  C.alone = await card(903, 'ALMA ALONE', ['4145559031'])
  await db.query(`select public.text_day_build($1)`, [NOW])
  for (const [k, p] of [['bounced', '4145559011'], ['arrived', '4145559021'], ['alone', '4145559031']] as const) {
    expect(await queue(C[k], p, `Hi there, this is Thalia. Are you the current owner of ${k} St? Reply STOP to opt out.`)).toMatchObject({ status: 'queued' })
  }
  await outcome(C.bounced, '4145559011', 'undelivered', 'SMb1')
  await outcome(C.arrived, '4145559021', 'delivered', 'SMa1')
  await outcome(C.alone, '4145559031', 'undelivered', 'SMl1')
}, 120_000)

describe('a first text that bounced', () => {
  it('puts the card on the list for its next number, and only that card', async () => {
    expect(await nextNumbers()).toEqual([{ lead_id: C.bounced, phone: '4145559012', block: null }])
  })
  it('the next day\'s list carries it, and the text to the second number is taken', async () => {
    await db.query(`select public.text_day_build($1)`, [NEXT])
    const day = await rows<{ lead_id: string; kind: string; phone: string }>(`select lead_id, kind, phone from public.text_day where day = '2026-11-13' and kind = 'next_number'`)
    expect(day).toEqual([{ lead_id: C.bounced, kind: 'next_number', phone: '4145559012' }])
    expect(await queue(C.bounced, '4145559011', 'Hi Betty, this is Thalia. Are you the current owner of 901 Bounce St? Reply STOP to opt out.', NEXT))
      .toMatchObject({ status: 'refused' })                       // the dead number is never texted again
    expect(await queue(C.bounced, '4145559012', 'Hi Betty, this is Thalia. Are you the current owner of 901 Bounce St? Reply STOP to opt out.', NEXT))
      .toMatchObject({ status: 'queued' })
    expect(await nextNumbers()).toEqual([])                       // queued: off the pool
  })
  it('a text that arrived keeps its card off the next-number list, with a second number or not', async () => {
    const ready = await one<{ next_numbers: { lead_id: string }[] }>('public.agent_ready_to_text(50, true, false, $1)', [NEXT])
    expect(ready.next_numbers.map((c) => c.lead_id)).not.toContain(C.arrived)
    expect(ready.next_numbers.map((c) => c.lead_id)).not.toContain(C.alone)
  })
})

describe('what is waiting on the agent', () => {
  it('nothing to say when nothing waits', async () => {
    await db.query(`insert into public.agent_keys (name, role, key_sha256, key_hint, created_by) values ('Muse', 'agent', 'x', 'x', 'test')`)
    await db.query(`insert into public.agent_calls (key_id, tool, scope, ok, ms, at) select id, 'desk_inbox', 'channel', true, 1, now() from public.agent_keys where name = 'Muse'`)
    expect(await one<unknown>(`public.agent_attention('Muse', now() + interval '1 minute')`)).toBeNull()
  })
  it('an offer step that is hers and a desk post she has not read', async () => {
    await db.query(`select public.agent_offer_open($1, 'asked_number', 'What would you pay?', '4145559021', 'desk')`, [C.arrived])
    await db.query(`select public.desk_post('desk', 'muse', 'note', 'Read this', 'body')`)
    await db.query(`update public.desk_messages set at = now() + interval '30 seconds' where topic = 'Read this'`)
    const a = await one<{ desk: string; offers: { say: string; steps: { address: string; step: string; do: string }[] } }>(`public.agent_attention('Muse', now() + interval '1 minute')`)
    expect(a.desk).toContain('1 post for you on the desk')
    expect(a.offers.steps).toEqual([expect.objectContaining({ address: '902 Bounce St', step: 'ask_condition' })])
    expect(a.offers.say).toContain('1 seller asked for a number')
    expect(await one<unknown>(`public.agent_attention('Muse 2', now() + interval '1 minute')`)).toBeNull()
  })
})
