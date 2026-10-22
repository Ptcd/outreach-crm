// Applies supabase/migrations/0001_wpie_live.sql to an in-memory Postgres (PGlite)
// with a small stand-in for Supabase's auth schema and roles, then checks the
// triggers, the gate rule, the scoreboard views and row-level security.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'

// Every migration, in order (0001 schema, 0002 gate round 2, ...).
const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')


const COLIN = { sub: '00000000-0000-0000-0000-00000000000c', email: 'colin@example.com' }
const THALIA = { sub: '00000000-0000-0000-0000-00000000000a', email: 'thalia@example.com' }
const STRANGER = { sub: '00000000-0000-0000-0000-0000000000ff', email: 'someone@example.com' }

let db: PGlite

async function as<T>(who: { sub: string; email: string }, fn: () => Promise<T>): Promise<T> {
  await db.exec('reset role')
  await db.query(`select set_config('request.jwt.claims', $1, false)`, [JSON.stringify(who)])
  await db.exec('set role authenticated')
  try {
    return await fn()
  } finally {
    await db.exec('reset role')
    await db.query(`select set_config('request.jwt.claims', '', false)`)
  }
}

let leadId = ''

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
  await db.exec(`
    insert into public.team_members (email, role, person, display_name) values
      ('colin@example.com', 'owner', 'colin', 'Colin'),
      ('thalia@example.com', 'caller', 'thalia', 'Thalia');
  `)
  const r = await db.query<{ id: string }>(`
    insert into public.leads (wpie_owner_id, owner_name, lane, county, property_address, reasons_to_sell, score, mailed_on)
    values (100561, 'JOHN DOE', 'hold', 'Milwaukee', '2825 S LOGAN AV', array['tired landlord','vacant + distress'], 474.3, '2026-10-20')
    returning id`)
  leadId = r.rows[0].id
})

describe('migration 0001_wpie_live', () => {
  it('logs the first stage and every stage change', async () => {
    await db.query(`update public.leads set stage = 'opener_sent' where id = $1`, [leadId])
    await db.query(`update public.leads set stage = 'opener_sent', owner_name = 'JOHN DOE' where id = $1`, [leadId])
    const ev = await db.query<{ from_stage: string | null; to_stage: string; source: string }>(
      `select from_stage, to_stage, source from public.lead_stage_events where lead_id = $1 order by id`, [leadId])
    expect(ev.rows).toEqual([
      { from_stage: null, to_stage: 'postcard_mailed', source: 'sync' },
      { from_stage: 'postcard_mailed', to_stage: 'opener_sent', source: 'sync' },
    ])
  })

  it('applies the written walk rule', async () => {
    const q = async (s: number[], stops: string[] = []) =>
      (await db.query<{ d: string }>(
        `select public.gate_suggestion($1::smallint,$2::smallint,$3::smallint,$4::smallint,$5::smallint,$6::smallint,$7::text[]) as d`,
        [...s, stops])).rows[0].d
    expect(await q([2, 2, 2, 2, 1, 1])).toBe('walk')            // total 10
    expect(await q([1, 2, 1, 0, 1, 2])).toBe('walk')            // numbers_close 2, total 7
    expect(await q([2, 1, 2, 2, 2, 1])).toBe('one_more_call')   // decision makers not 2
    expect(await q([2, 2, 2, 2, 2, 0])).toBe('no_walk')         // numbers_close 0
    expect(await q([1, 1, 1, 1, 1, 1])).toBe('no_walk')         // total 6
    expect(await q([2, 2, 2, 2, 2, 2], ['listed_active'])).toBe('no_walk')
  })

  it('counts an inbound reply as a connect and shows it on the scoreboard', async () => {
    await db.query(`insert into public.messages (lead_id, direction, channel, body, provider_sid, status, is_opener, sent_at)
                    values ($1, 'out', 'sms', 'Hi', 'SM1', 'delivered', true, '2026-10-21T15:00:00Z')`, [leadId])
    await db.query(`insert into public.messages (lead_id, direction, channel, body, sent_at, source_key)
                    values ($1, 'in', 'sms', 'Who is this?', '2026-10-21T16:00:00Z', 'ledger:1:1:replied')`, [leadId])
    const ms = await db.query(`select kind from public.lead_milestones where lead_id = $1`, [leadId])
    expect(ms.rows).toEqual([{ kind: 'connect' }])
    const sb = await db.query<Record<string, unknown>>(
      `select lane, openers_sent::int, delivered::int, replies::int, connects::int, reply_rate::text
         from public.scoreboard_weekly where week_start = '2026-10-19' order by lane`)
    expect(sb.rows).toEqual([
      { lane: 'all', openers_sent: 1, delivered: 1, replies: 1, connects: 1, reply_rate: '1.0000' },
      { lane: 'hold', openers_sent: 1, delivered: 1, replies: 1, connects: 1, reply_rate: '1.0000' },
    ])
    const sig = await db.query(`select signal, openers_sent::int from public.scoreboard_weekly_by_signal order by signal`)
    expect(sig.rows).toEqual([
      { signal: 'tired landlord', openers_sent: 1 },
      { signal: 'vacant + distress', openers_sent: 1 },
    ])
  })

  it('shows nothing to anon or to a signed-in stranger', async () => {
    await db.exec('set role anon')
    await expect(db.query('select * from public.leads')).rejects.toThrow(/permission denied/)
    await db.exec('reset role')
    const n = await as(STRANGER, async () => (await db.query('select id from public.leads')).rows.length)
    expect(n).toBe(0)
  })

  it('lets Thalia work the lead but not edit WPIE facts, score the gate or see deals', async () => {
    await as(THALIA, async () => {
      expect((await db.query('select id from public.leads')).rows.length).toBe(1)
      await db.query(`update public.leads set stage = 'colin_call', next_action = 'call back', assigned_to = 'colin' where id = $1`, [leadId])
      await expect(db.query(`update public.leads set owner_name = 'X' where id = $1`, [leadId])).rejects.toThrow(/permission denied/)
      await db.query(`insert into public.tasks (lead_id, due_at, owner, kind) values ($1, now(), 'colin', 'call')`, [leadId])
      await db.query(`insert into public.messages (lead_id, direction, channel, body) values ($1, 'out', 'note', 'left voicemail')`, [leadId])
      await expect(db.query(`insert into public.messages (lead_id, direction, channel, body) values ($1, 'out', 'sms', 'fake')`, [leadId]))
        .rejects.toThrow(/row-level security/)
      await expect(db.query(`insert into public.gate_scores (lead_id, reason_and_clock, decision_makers, number_and_anchor, flexibility, condition, numbers_close, decision)
                             values ($1, 2,2,2,2,2,2,'walk')`, [leadId])).rejects.toThrow(/row-level security/)
      expect((await db.query('select id from public.deals')).rows.length).toBe(0)
      await expect(db.query(`insert into public.deals (lead_id, status) values ($1, 'offer')`, [leadId])).rejects.toThrow()
      await db.query(`insert into public.lead_milestones (lead_id, kind) values ($1, 'contact')`, [leadId])
    })
    const ev = await db.query<{ source: string }>(`select source from public.lead_stage_events where to_stage = 'colin_call'`)
    expect(ev.rows).toEqual([{ source: 'app' }])
  })

  it('lets Colin score the gate and type his own offer, and nobody else', async () => {
    await as(COLIN, async () => {
      const g = await db.query<{ total: number; suggested_decision: string }>(
        `insert into public.gate_scores (lead_id, reason_and_clock, decision_makers, number_and_anchor, flexibility, condition, numbers_close, decision, decided_by_name)
         values ($1, 2,2,1,1,1,1,'walk','Colin') returning total, suggested_decision`, [leadId])
      expect(g.rows[0]).toEqual({ total: 8, suggested_decision: 'one_more_call' })
      await db.query(`insert into public.deals (lead_id, status, colin_offer) values ($1, 'offer', 100000)`, [leadId])
    })
    // the sync's connection (no signed-in user) cannot write the offer
    await expect(db.query(`update public.deals set colin_offer = 1 where lead_id = $1`, [leadId])).rejects.toThrow(/only be entered by Colin/)
  })

  it('lets any team member approve a planned opener (Colin 2026-10-22: the callers approve the texts), never edit its words', async () => {
    await db.query(`insert into public.planned_openers (plan_date, wpie_owner_id, attempt, body) values ('2026-10-21', 100561, 1, 'Hi John')`)
    await as(THALIA, async () => {
      const r = await db.query(`update public.planned_openers set decision = 'approved', decided_at = now() returning id`)
      expect(r.rows.length).toBe(1)
      await expect(db.query(`update public.planned_openers set body = 'changed'`)).rejects.toThrow(/permission denied/)
    })
    await as(COLIN, async () => {
      const r = await db.query(`update public.planned_openers set decision = 'skipped', decided_at = now() returning id`)
      expect(r.rows.length).toBe(1)
      await expect(db.query(`update public.planned_openers set body = 'changed'`)).rejects.toThrow(/permission denied/)
    })
  })

  it('reports follow-up debt for leads 2+ days past their next action', async () => {
    await db.query(`update public.leads set next_action_at = now() - interval '3 days' where id = $1`, [leadId])
    const r = await db.query<{ days_late: number }>(`select days_late from public.followup_debt`)
    expect(r.rows).toEqual([{ days_late: 3 }])
  })
})

describe('migration 0022_team_alerts_call_tasks', () => {
  it('lets any team member register a phone for push, and a stranger not', async () => {
    const save = (ep: string) => db.query(`select public.save_push_subscription($1, 'k', 'a', 'Chrome')`, [ep])
    await as(THALIA, async () => { await save('https://fcm.googleapis.com/fcm/send/thalia') })
    await as(COLIN, async () => { await save('https://fcm.googleapis.com/fcm/send/colin') })
    await expect(as(STRANGER, async () => { await save('https://fcm.googleapis.com/fcm/send/x') })).rejects.toThrow(/team only/)
    const rows = await db.query<{ endpoint: string }>('select endpoint from public.push_subscriptions order by endpoint')
    expect(rows.rows.map((r) => r.endpoint)).toEqual(['https://fcm.googleapis.com/fcm/send/colin', 'https://fcm.googleapis.com/fcm/send/thalia'])
    // each person forgets their own phone, not another's
    await as(THALIA, async () => { await db.query(`select public.delete_push_subscription('https://fcm.googleapis.com/fcm/send/colin')`) })
    expect((await db.query('select 1 from public.push_subscriptions')).rows).toHaveLength(2)
    await as(THALIA, async () => { await db.query(`select public.delete_push_subscription('https://fcm.googleapis.com/fcm/send/thalia')`) })
    expect((await db.query('select 1 from public.push_subscriptions')).rows).toHaveLength(1)
  })

  it('alert_recipients: members with a phone on file, normalized, never the owner; service_role only', async () => {
    await db.query(`update public.team_members set alert_phone = '(414) 555-0123' where person = 'thalia'`)
    await db.query(`update public.team_members set alert_phone = '262-555-0100' where person = 'colin'`)
    await db.exec('set role service_role')
    try {
      expect((await db.query<{ r: unknown }>('select public.alert_recipients() as r')).rows[0].r).toEqual([{ person: 'thalia', phone: '+14145550123' }])
      await db.query(`update public.team_members set alert_phone = 'none yet' where person = 'thalia'`)
      expect((await db.query<{ r: unknown }>('select public.alert_recipients() as r')).rows[0].r).toEqual([])
    } finally { await db.exec('reset role') }
    await expect(as(THALIA, async () => { await db.query('select public.alert_recipients()') })).rejects.toThrow(/permission denied/)
  })

  it('tasks.source_key makes the call-list upsert idempotent', async () => {
    const up = () => db.query(`insert into public.tasks (lead_id, due_at, kind, owner, note, source_key)
      values ($1, '2026-10-23T19:00:00Z', 'call', 'thalia', 'from the call list', 'calls:2026-10-23:100561')
      on conflict (source_key) do update set note = excluded.note, due_at = excluded.due_at`, [leadId])
    await up()
    await up()
    const r = await db.query<{ n: string }>(`select count(*)::text as n from public.tasks where source_key like 'calls:%'`)
    expect(r.rows[0].n).toBe('1')
    await db.query(`insert into public.tasks (lead_id, due_at, kind, owner) values ($1, now(), 'call', 'thalia')`, [leadId])  // null keys never collide
    await db.query(`insert into public.tasks (lead_id, due_at, kind, owner) values ($1, now(), 'call', 'thalia')`, [leadId])
  })
})
