// 0302 (Colin 2026-11-22: "When we text dead lines we know that and they get marked as dead on the cards right?").
// A bounce marked the phone bad on the cards that held it then; a row made later with the same number started "ok".
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')

let db: PGlite
const A = '00000000-0000-0000-0000-00000000b301', B = '00000000-0000-0000-0000-00000000b302'
const phone = async (lead: string, v: string) => (await db.query<{ status: string; note: string | null; line_type: string | null }>(
  `select status::text, note, line_type from public.contacts where lead_id = $1 and value_normalized = $2`, [lead, v])).rows[0]
const add = (lead: string, v: string) => db.query(`insert into public.contacts (lead_id, kind, value, value_normalized, line_type) values ($1, 'phone', $2, $2, 'mobile')`, [lead, v])
const sent = (lead: string, v: string, st: string, code: string | null, at: string) =>
  db.query(`insert into public.planned_openers (plan_date, wpie_owner_id, attempt, lead_id, lane, phone, body, scheduled_at, send_status, error_code, sent_at, step)
            values ($5::date, 1, (select coalesce(max(attempt), 0) + 1 from public.planned_openers), $1, 'agent', $2, 'Hi, test. Reply STOP to opt out.', $5::timestamptz, $3, $4, $5::timestamptz, 1)`, [lead, `+1${v}`, st, code, at])

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
  await db.exec(`insert into public.leads (id, wpie_owner_id, owner_name, lane, stage, property_address, municipality, county, mailing_state) values
    ('${A}', 9801, 'DEAD LINE', 'flip', 'opener_sent', '1 A ST', 'Racine', 'Racine', 'WI'),
    ('${B}', 9802, 'SAME OWNER', 'flip', 'opener_queued', '2 B ST', 'Racine', 'Racine', 'WI')`)
}, 180_000)

describe('a dead number stays dead', () => {
  it('a bounce marks the phone bad where it is; the same number loaded later lands bad too', async () => {
    await add(A, '2625550301')
    await sent(A, '2625550301', 'undelivered', '30005', '2026-11-20T16:00:00Z')
    expect(await phone(A, '2625550301')).toMatchObject({ status: 'bad' })                    // 0071, as before
    await add(B, '2625550301')                                                                // an agent loads it again on another card
    const b = await phone(B, '2625550301')
    expect(b.status).toBe('bad')
    expect(b.note).toBe('carrier 30005 on Nov 20 (not in service)')
  })

  it('a number delivered to since its bounce is not dead; a filtered or unknown bounce is not either', async () => {
    await add(A, '2625550302')
    await sent(A, '2625550302', 'undelivered', '30003', '2026-11-10T16:00:00Z')
    await db.query(`update public.contacts set status = 'ok' where value_normalized = '2625550302'`)
    await sent(A, '2625550302', 'delivered', null, '2026-11-15T16:00:00Z')
    await add(B, '2625550302')
    expect((await phone(B, '2625550302')).status).toBe('ok')
    await add(A, '2625550303')
    await sent(A, '2625550303', 'undelivered', '30008', '2026-11-20T16:00:00Z')            // unknown: may be temporary
    await add(B, '2625550303')
    expect((await phone(B, '2625550303')).status).toBe('ok')
  })

  it('a landline bounce marks the line type when none is known', async () => {
    await db.query(`insert into public.contacts (lead_id, kind, value, value_normalized) values ($1, 'phone', '2625550304', '2625550304')`, [A])
    await sent(A, '2625550304', 'undelivered', '30006', '2026-11-21T16:00:00Z')
    await db.query(`insert into public.contacts (lead_id, kind, value, value_normalized) values ($1, 'phone', '2625550304', '2625550304')`, [B])
    expect(await phone(B, '2625550304')).toMatchObject({ status: 'bad', line_type: 'landline' })
  })
})
