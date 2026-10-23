// Migration 0036 on the real migrations (PGlite): phone_is_blocked, the question pm-phone's in-app dialer asks
// before it places a call (Codex's audit, 2026-10-22: the app hid the Call button, the dialer service did not
// check). A number on suppressed_phones, or on a contact flagged suppressed / dnc_app / dnc_vendor /
// dnc_scrub = 'dnc' / status = 'bad', is blocked with a reason that names why; only service_role may ask.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, beforeEach, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')
const LEAD = '00000000-0000-0000-0000-0000000000b1'
const OTHER = '00000000-0000-0000-0000-0000000000b2'

let db: PGlite
async function asRole<T>(role: 'service_role' | 'authenticated' | 'anon', fn: () => Promise<T>): Promise<T> {
  await db.exec(`set role ${role}`)
  try { return await fn() } finally { await db.exec('reset role') }
}
const check = async (phone: string) =>
  (await db.query<{ r: { blocked: boolean; reason: string | null } }>(`select public.phone_is_blocked($1) as r`, [phone])).rows[0].r

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
})

beforeEach(async () => {
  await db.exec(`
    truncate public.suppressed_phones, public.contacts, public.leads cascade;
    insert into public.leads (id, wpie_owner_id, owner_name, property_address, municipality, stage) values
      ('${LEAD}', 71, 'JANE ROE', '100 N Main St', 'Milwaukee', 'opener_sent'),
      ('${OTHER}', 72, 'JOHN ROE', '200 N Main St', 'Milwaukee', 'opener_sent');
    insert into public.contacts (lead_id, kind, value, value_normalized, status) values
      ('${LEAD}', 'phone', '4145550177', '4145550177', 'ok'),
      ('${OTHER}', 'phone', '4145550188', '4145550188', 'ok');
  `)
})

describe('phone_is_blocked (migration 0036)', () => {
  it('a clean number is not blocked, however it is written', async () => {
    expect(await check('4145550177')).toEqual({ blocked: false, reason: null })
    expect(await check('+1 (414) 555-0177')).toEqual({ blocked: false, reason: null })
    expect(await check('4145559999')).toEqual({ blocked: false, reason: null })   // unknown to the app: not blocked
  })

  it('a number on suppressed_phones is blocked with the row’s reason', async () => {
    await db.exec(`insert into public.suppressed_phones (phone10, reason, source) values ('4145550177', 'stop_reply', 'twilio_inbound')`)
    expect(await check('4145550177')).toEqual({ blocked: true, reason: 'suppressed: stop_reply' })
    expect(await check('+14145550177')).toMatchObject({ blocked: true })
    expect(await check('4145550188')).toEqual({ blocked: false, reason: null })   // the other number stands
  })

  it('each contact flag blocks on its own, and the reason names which', async () => {
    const flag = async (set: string, expected: string) => {
      await db.exec(`update public.contacts set suppressed = false, dnc_app = false, dnc_vendor = false, dnc_scrub = 'unknown', status = 'ok'`)
      await db.exec(`update public.contacts set ${set} where value_normalized = '4145550177'`)
      expect(await check('4145550177')).toEqual({ blocked: true, reason: `contact: ${expected}` })
      expect(await check('4145550188')).toEqual({ blocked: false, reason: null })
    }
    await flag(`suppressed = true`, 'texted STOP / suppressed')
    await flag(`dnc_app = true`, 'do-not-contact (app)')
    await flag(`dnc_vendor = true`, 'do-not-contact (vendor)')
    await flag(`dnc_scrub = 'dnc'`, 'do-not-contact (scrub)')
    await flag(`status = 'bad'`, 'bad number')
    await flag(`dnc_app = true, status = 'bad'`, 'bad number, do-not-contact (app)')
  })

  it('a flag on any lead’s contact for that number blocks it, not just the first', async () => {
    await db.exec(`insert into public.contacts (lead_id, kind, value, value_normalized, status, dnc_app)
      values ('${OTHER}', 'phone', '4145550177', '4145550177', 'ok', true)`)
    expect(await check('4145550177')).toEqual({ blocked: true, reason: 'contact: do-not-contact (app)' })
  })

  it('the real paths write what it reads: a STOP reply and a do-not-contact call both block', async () => {
    await db.exec(`insert into public.team_members (email, role, person, display_name) values ('colin@example.com', 'owner', 'colin', 'Colin') on conflict do nothing`)
    await db.query(`select public.record_inbound('SMstop1', '+14145550177', '+12629996513', 'STOP', true, now())`)
    expect(await check('4145550177')).toMatchObject({ blocked: true, reason: /suppressed: stop/ })
    await db.query(`select set_config('request.jwt.claims', $1, false)`, [JSON.stringify({ sub: '00000000-0000-0000-0000-00000000000c', email: 'colin@example.com' })])
    await asRole('authenticated', () => db.query(`select public.log_call($1, '4145550188', 'dnc', null)`, [OTHER]))
    expect(await check('4145550188')).toMatchObject({ blocked: true, reason: /suppressed: dnc_call/ })
  })

  it('anything that is not a 10-digit number is blocked', async () => {
    expect(await check('555')).toEqual({ blocked: true, reason: 'not a 10-digit number' })
    expect(await check('')).toEqual({ blocked: true, reason: 'not a 10-digit number' })
    expect(await check('client:someone')).toEqual({ blocked: true, reason: 'not a 10-digit number' })
  })

  it('only service_role may ask', async () => {
    await db.exec(`insert into public.suppressed_phones (phone10, reason, source) values ('4145550177', 'stop_reply', 'twilio_inbound')`)
    expect(await asRole('service_role', () => check('4145550177'))).toEqual({ blocked: true, reason: 'suppressed: stop_reply' })
    await expect(asRole('authenticated', () => check('4145550177'))).rejects.toThrow(/permission denied/)
    await expect(asRole('anon', () => check('4145550177'))).rejects.toThrow(/permission denied/)
  })
})
