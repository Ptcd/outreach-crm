// 0243: a time Colin set with a seller alerts his phone. Colin 2026-11-16: "Have the app send me a notification then?"
// Only the stop of a booked call or visit; the thousands of other stops on his list never alert.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')
const SLOT = '2099-11-18T16:00:00Z'          // Wednesday 10:00 AM Central

let db: PGlite
const rows = async <T>(sql: string, params: unknown[] = []) => (await db.query<T>(sql, params)).rows
const due = async (at: string) => (await rows<{ r: { person: string; kind: string; address: string }[] }>(`select public.followups_due_to_alert($1) as r`, [at]))[0].r
const card = async (ownerId: number, belt: string) => (await rows<{ id: string }>(
  `insert into public.leads (wpie_owner_id, owner_name, lane, stage, property_address, locked_to, assigned_to, belt, belt_step, mailing_state)
   values ($1, 'STANLEY TEST', 'flip', 'colin_call', $2, 'thalia', 'colin', $3, 1, 'WI') returning id`, [ownerId, `${ownerId} Booked St`, belt]))[0].id
const task = (lead: string, kind: string, source: string) => db.query(
  `insert into public.tasks (lead_id, due_at, kind, owner, source, title) values ($1, $2, $3, 'colin', $4, 'stop')`, [lead, SLOT, kind, source])

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
  await db.exec(`insert into public.team_members (email, role, person, display_name) values ('colin@example.com', 'owner', 'colin', 'Colin') on conflict do nothing`)
  await task(await card(401, 'call_booked'), 'call', 'belt')
  await task(await card(402, 'visit_booked'), 'visit', 'belt')
  await task(await card(403, 'hold_not_now'), 'call', 'belt')          // a belt stop that is not a booked time
  await task(await card(404, 'call_booked'), 'text', 'belt')           // a draft for his tap, not a call
}, 120_000)

describe("Colin's booked time", () => {
  it('alerts him ten minutes before, for the booked call and the booked visit only', async () => {
    const hit = await due('2099-11-18T15:52:00Z')
    expect(hit.map((r) => `${r.person} ${r.kind} ${r.address}`).sort()).toEqual(['colin call 401 Booked St', 'colin visit 402 Booked St'])
  })
  it('says nothing an hour before, or once it has been sent', async () => {
    expect(await due('2099-11-18T15:00:00Z')).toEqual([])
    await db.exec(`update public.tasks set notified_at = now() where owner = 'colin'`)
    expect(await due('2099-11-18T15:52:00Z')).toEqual([])
  })
})
