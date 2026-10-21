// The Edge Functions run as service_role. 2026-10-21 every run failed in production with
// "permission denied for table campaign_control" because the tables lacked service_role grants.
// This runs the functions' own direct table reads/writes AS service_role, plus the test phone.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'

const MIGRATION = readdirSync(path.resolve(__dirname, '../supabase/migrations')).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.resolve(__dirname, '../supabase/migrations', f), 'utf8')).join('\n')
const COLIN = { sub: '00000000-0000-0000-0000-00000000000c', email: 'colin@example.com' }
let db: PGlite

async function asService<T>(fn: () => Promise<T>) {
  await db.exec('set role service_role')
  try { return await fn() } finally { await db.exec('reset role') }
}
async function asColin<T>(fn: () => Promise<T>) {
  await db.query(`select set_config('request.jwt.claims', $1, false)`, [JSON.stringify(COLIN)])
  await db.exec('set role authenticated')
  try { return await fn() } finally { await db.exec('reset role') }
}

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  // the stub runs as the database owner; on Supabase the functions are a separate role
  await db.exec(MIGRATION)
  await db.exec(`insert into public.team_members (email, role, person, display_name) values ('colin@example.com', 'owner', 'colin', 'Colin')`)
})

describe('service_role (the Edge Functions)', () => {
  it('can read and write every table the functions touch directly', async () => {
    await asService(async () => {
      const c = await db.query(`select max_per_run, last_inbound_poll_at, reply_numbers, redteam_version, agent_last_run_at from public.campaign_control where id = 1`)
      expect(c.rows.length).toBe(1)
      for (const t of ['planned_openers', 'reply_drafts', 'twilio_inbound', 'suppressed_phones', 'opener_send_events', 'messages', 'leads', 'contacts', 'team_members']) {
        await db.query(`select count(*) from public.${t}`)
      }
      await db.query(`update public.campaign_control set updated_at = now() where id = 1`)
      expect((await db.query(`select public.reply_claim_inbound(5) as r`)).rows.length).toBe(1)
    })
  })
})

describe('test phone', () => {
  it("plays a sample owner, never touches a real lead, is marked TEST, and a STOP from it can be reset", async () => {
    await db.exec(`insert into public.leads (id, wpie_owner_id, owner_name, stage) values ('00000000-0000-0000-0000-0000000000c1', 9, 'REAL OWNER', 'opener_sent');
                   insert into public.contacts (lead_id, kind, value, value_normalized) values ('00000000-0000-0000-0000-0000000000c1', 'phone', '4145550909', '4145550909');`)
    await expect(db.query(`select public.set_test_phone('4145550909')`)).rejects.toThrow(/only Colin/)
    await asColin(() => db.query(`select public.set_test_phone('(414) 555-0909')`))
    await db.query(`select public.record_inbound('SMt1', '+14145550909', '+12629996513', 'Test', false, now())`)
    const claimed = (await asService(() => db.query<{ r: { lead_id: string | null; is_test: boolean; owner_name: string; property_address: string }[] }>(
      `select public.reply_claim_inbound(5) as r`))).rows[0].r
    expect(claimed[0]).toMatchObject({ lead_id: null, is_test: true, owner_name: "TEST - Colin's phone", property_address: '1234 N Test St, Milwaukee' })
    await asService(() => db.query(`select public.reply_record_decision('SMt1', 'statement', 'candidate', false, 'open', 'Hi there', 'claude', 'n', 'v')`))
    expect((await db.query(`select is_test, lead_id from public.reply_drafts`)).rows).toEqual([{ is_test: true, lead_id: null }])
    // a STOP from the test phone is honoured, the real lead sharing that number is untouched, and Colin can reset it
    await db.query(`select public.record_inbound('SMt2', '+14145550909', '+12629996513', 'STOP', true, now())`)
    expect((await db.query(`select stage::text from public.leads`)).rows).toEqual([{ stage: 'opener_sent' }])
    expect((await db.query(`select count(*)::int as n from public.suppressed_phones`)).rows).toEqual([{ n: 1 }])
    const n = await asColin(() => db.query<{ n: number }>(`select public.reset_test_phones() as n`))
    expect(n.rows[0].n).toBe(1)
    expect((await db.query(`select count(*)::int as n from public.suppressed_phones`)).rows).toEqual([{ n: 0 }])
  })
})
