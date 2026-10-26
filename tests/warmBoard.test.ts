// The Warm Leads board (Colin 2026-10-25): every card past the cold texts in the section the team works it in, with
// an unlogged call, an overdue call and a missing next step pulled up to "Needs a decision".
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'
import { groupRows, nextLine, type WarmRow } from '../src/lib/warm'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')
const COLIN = { sub: '00000000-0000-0000-0000-00000000000c', email: 'colin@example.com' }
const NOW = '2026-10-25T18:00:00Z'
let db: PGlite

const card = async (name: string, belt: string, extra = '', vals: unknown[] = []) => {
  const r = await db.query<{ id: string }>(
    `insert into public.leads (owner_name, property_address, stage, belt, next_stop_at, next_stop_who ${extra ? ', ' + extra.split('=')[0] : ''})
     values ($1, '1 Test St', 'reply_received', $2, '2026-10-26T14:00:00Z', 'thalia_call' ${extra ? ', $3' : ''}) returning id`, [name, belt, ...vals])
  return r.rows[0].id
}

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
  await db.exec(`insert into public.team_members (email, role, person, display_name) values ('colin@example.com', 'owner', 'colin', 'Colin')`)
})

describe('warm_board', () => {
  it('puts each card in its section and pulls the stuck ones up to Needs a decision', async () => {
    await card('Hot Harry', 'yes_unbooked')
    const booked = await card('Booked Betty', 'call_booked')
    await db.query(`update public.leads set named_date = '2026-10-27T15:00:00Z', named_event = 'call' where id = $1`, [booked])
    await card('Quiet Quinn', 'questions_quiet')
    await card('Dated Dana', 'not_now_dated')
    await card('Estate Ed', 'estate_waiting')
    const stuck = await card('Unlogged Una', 'yes_unbooked')
    await db.query(`update public.leads set human_takeover_at = '2026-10-25T17:00:00Z' where id = $1`, [stuck])
    const late = await card('Late Larry', 'yes_unbooked')
    await db.query(`update public.leads set next_stop_at = '2026-10-23T14:00:00Z' where id = $1`, [late])
    const lost = await card('Lost Lou', 'replied_quiet')
    await db.query(`update public.leads set next_stop_at = null, next_stop_who = null where id = $1`, [lost])
    await card('Cold Carl', 'cold_texts')
    await card('Dead Dave', 'dead')
    await card('Dormant never replied', 'dormant')

    await db.query(`select set_config('request.jwt.claims', $1, false)`, [JSON.stringify(COLIN)])
    await db.exec('set role authenticated')
    const rows = (await db.query<{ r: WarmRow[] }>(`select public.warm_board($1::timestamptz) as r`, [NOW])).rows[0].r
    await db.exec('reset role')

    const g = groupRows(rows)
    const names = (k: keyof typeof g) => g[k].map((r) => r.owner_name).sort()
    expect(names('decide')).toEqual(['Late Larry', 'Lost Lou', 'Unlogged Una'])
    expect(names('hot')).toEqual(['Hot Harry'])
    expect(names('booked')).toEqual(['Booked Betty'])
    expect(names('talking')).toEqual(['Quiet Quinn'])
    expect(names('callback')).toEqual(['Dated Dana'])
    expect(names('nurture')).toEqual(['Estate Ed'])
    expect(rows.map((r) => r.owner_name)).not.toContain('Cold Carl')
    expect(rows.map((r) => r.owner_name)).not.toContain('Dormant never replied')
    expect(g.decide.find((r) => r.owner_name === 'Unlogged Una')?.why).toMatch(/never logged/)
    expect(nextLine(g.decide.find((r) => r.owner_name === 'Late Larry')!, new Date(NOW).getTime()).late).toBe(true)
    expect(nextLine(g.booked[0]).text).toMatch(/^Call /)
  })

  it('is for the team only', async () => {
    await db.query(`select set_config('request.jwt.claims', '', false)`)
    await expect(db.query(`select public.warm_board()`)).rejects.toThrow(/not on the team/)
  })
})
