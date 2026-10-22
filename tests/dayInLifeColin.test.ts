// Colin's synthetic day: receives Thalia's handoff, logs calls, books the visit,
// owns the gate/deal controls, and sees today's milestones roll into the weekly counts.
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import type { PGlite } from '@electric-sql/pglite'
import { COLIN, THALIA, as, dayDb, one, rpc } from './dayInLifeHarness'

const LEAD = '00000000-0000-0000-0000-0000000000c1'
let db: PGlite

beforeAll(async () => {
  db = await dayDb()
  await db.exec(`
    insert into public.leads (id, wpie_owner_id, owner_name, property_address, municipality, lane, stage)
    values ('${LEAD}', 99, 'MARA LEE', '900 W State St', 'Milwaukee', 'flip', 'reply_received');
    insert into public.contacts (lead_id, kind, value, value_normalized, line_type, status)
    values ('${LEAD}', 'phone', '4145550190', '4145550190', 'mobile', 'ok');
  `)
})

afterAll(async () => { await db.close() })

describe("Colin's day", () => {
  it("receives Thalia's complete handoff, logs the call sequence, and books the walk-through", async () => {
    await as(db, THALIA, () => rpc(db, 'handoff_to_colin', {
      p_lead_id: LEAD, p_note: 'Moving for work in 30 days; just her; number rests on payoff', p_now: '2026-10-22T15:00:00Z',
    }))
    expect(await one(db, `select assigned_to::text, stage::text, belt from public.leads where id = '${LEAD}'`))
      .toMatchObject({ assigned_to: 'colin', stage: 'colin_call', belt: 'call_booked' })
    expect(await one(db, `select title, owner::text, note from public.tasks where lead_id = '${LEAD}' and done_at is null`))
      .toMatchObject({ title: 'From Thalia: worth a look', owner: 'colin' })
    expect((await one<{ body: string }>(db, `select body from public.messages where lead_id = '${LEAD}' and channel = 'note'`)).body)
      .toContain('Handed to Colin by Thalia')
    expect((await one<{ body: string }>(db, `select body from public.hot_alerts where lead_id = '${LEAD}'`)).body)
      .toMatch(/^Thalia hands off:/)

    await as(db, COLIN, () => rpc(db, 'log_call', {
      p_lead_id: LEAD, p_phone: '4145550190', p_outcome: 'reached_no_decision', p_note: 'Needs to confirm payoff',
    }))
    await as(db, COLIN, () => rpc(db, 'log_call', {
      p_lead_id: LEAD, p_phone: '4145550190', p_outcome: 'interested', p_note: 'Payoff confirmed',
    }))
    await as(db, COLIN, () => rpc(db, 'call_answer', {
      p_lead_id: LEAD, p_key: 'next_step', p_value: { kind: 'walk', at: '2026-10-23T19:00:00Z', choices: ['walk'], when: '2026-10-23T19:00:00Z' },
    }))
    expect(await one(db, `select stage::text, belt, assigned_to::text from public.leads where id = '${LEAD}'`))
      .toMatchObject({ stage: 'walkthrough_booked', belt: 'visit_booked', assigned_to: 'colin' })
  })

  it("keeps Colin's gate and deal owner-only, while the week's four caller counts move", async () => {
    const gateSql = `insert into public.gate_scores
      (lead_id, reason_and_clock, decision_makers, number_and_anchor, flexibility, condition, numbers_close, hard_stops, decision, note, decided_by_name)
      values ('${LEAD}', 2, 2, 2, 2, 2, 2, '{}', 'walk', 'numbers close', 'Colin')`
    await expect(as(db, THALIA, () => db.exec(gateSql))).rejects.toThrow()
    await as(db, COLIN, () => db.exec(gateSql))
    expect(await one(db, `select total, decision::text, note from public.gate_scores where lead_id = '${LEAD}'`))
      .toEqual({ total: 12, decision: 'walk', note: 'numbers close' })

    const dealSql = `insert into public.deals (lead_id, status, colin_offer, notes) values ('${LEAD}', 'offer', 150000, 'synthetic test only')`
    await expect(as(db, THALIA, () => db.exec(dealSql))).rejects.toThrow()
    await as(db, COLIN, () => db.exec(dealSql))

    await as(db, COLIN, () => db.exec(`insert into public.lead_milestones (lead_id, kind, at) values
      ('${LEAD}', 'connect', '2026-10-22T16:00:00Z'),
      ('${LEAD}', 'contact', '2026-10-22T16:01:00Z'),
      ('${LEAD}', 'lead', '2026-10-22T16:02:00Z'),
      ('${LEAD}', 'handoff', '2026-10-22T16:03:00Z')
      on conflict (lead_id, kind) do nothing`))
    expect(await one(db, `select connects::int, contacts::int, leads::int, handoffs::int
      from public.scoreboard_weekly where week_start = '2026-10-19' and lane = 'all'`))
      .toEqual({ connects: 1, contacts: 1, leads: 1, handoffs: 1 })
  })
})
