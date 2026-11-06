// Migration 0193 on the real migrations (PGlite): a dead card ignores a seller's text (Hamilton Jr, 2026-11-06:
// the reply pipeline's second pass over his "Yes" re-opened a card closed dead six minutes earlier and Adil dialed
// a seller who had just said he is keeping the house). A human reopen, an explicit move and the seller calling us
// still move a dead card.
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import type { PGlite } from '@electric-sql/pglite'
import { dayDb, one } from './dayInLifeHarness'

let db: PGlite
const DEAD = '10000000-0000-4000-8000-000000000193'

async function enter(lead: string, belt: string, event: string, said = 'Yes') {
  return (await db.query<{ r: { ok: boolean; belt: string; ignored?: boolean } }>(
    `select public.belt_enter($1, $2, 1, $3, $4::jsonb, 'agent', '2026-11-06T17:10:00Z'::timestamptz) as r`,
    [lead, belt, event, JSON.stringify({ said, intent: 'interested' })])).rows[0].r
}

async function card() {
  return one<{ belt: string | null; stage: string; open_tasks: number }>(db,
    `select belt, stage::text as stage, (select count(*)::int from public.tasks t where t.lead_id = l.id and t.done_at is null) as open_tasks
       from public.leads l where id = $1`, [DEAD])
}

beforeAll(async () => {
  db = await dayDb()
  await db.exec(`
    insert into public.leads (id, wpie_owner_id, owner_name, property_address, municipality, mailing_state, lane, stage, belt, belt_step, dead_reason)
      values ('${DEAD}', 9193, 'CLAUDE HAMILTON JR', '1520 WINSLOW ST', 'Racine', 'WI', 'flip', 'dead', 'dead', 0, 'No sale - keeping it');
    insert into public.contacts (lead_id, kind, value, value_normalized, line_type)
      values ('${DEAD}', 'phone', '2628229981', '2628229981', 'mobile');`)
}, 120_000)

afterAll(async () => { await db?.close() })

describe('a dead card ignores texts (0193)', () => {
  it('a text read after the close changes nothing: no belt, no stage, no call task', async () => {
    const r = await enter(DEAD, 'yes_unbooked', 'inbound_text')
    expect(r.ok).toBe(true)
    expect(r.ignored).toBe(true)
    expect(r.belt).toBe('dead')
    expect(await card()).toEqual({ belt: 'dead', stage: 'dead', open_tasks: 0 })
    const ev = await one<{ to_belt: string; ignored: string }>(db,
      `select to_belt, payload->>'ignored' as ignored from public.belt_events where lead_id = $1 order by at desc, id desc limit 1`, [DEAD])
    expect(ev).toEqual({ to_belt: 'dead', ignored: 'dead only reopens by hand' })
  })

  it('a human reopen still moves it, and the next text then runs the belt as before', async () => {
    const r = await enter(DEAD, 'yes_unbooked', 'reopened')
    expect(r.ok).toBe(true)
    expect(r.ignored).toBeUndefined()
    const c = await card()
    expect(c.belt).toBe('yes_unbooked')
    expect(c.stage).not.toBe('dead')
    expect(c.open_tasks).toBeGreaterThan(0)
  })

  it('a STOP still closes a dead card to do-not-contact', async () => {
    await db.query(`update public.leads set belt = 'dead', stage = 'dead' where id = $1`, [DEAD])
    const r = await enter(DEAD, 'dnc', 'stop', 'STOP')
    expect(r.ok).toBe(true)
    expect((await card()).belt).toBe('dnc')
  })
})
