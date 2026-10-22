// Thalia's synthetic weekday: settings, a hot reply, the earned visit, call logging,
// repeat-safe handoff, and STOP/DNC. No live browser, Supabase project, or seller is touched.
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import type { PGlite } from '@electric-sql/pglite'
import { bookingVerdict } from '../src/lib/bookingVerdict'
import { runHotAlerts } from '../supabase/functions/_shared/hotLeads'
import type { Rpc } from '../supabase/functions/_shared/sending'
import { THALIA, as, dayDb, one, rpc, serviceRpc } from './dayInLifeHarness'

const LEAD = '00000000-0000-0000-0000-0000000000a1'
const STOP_LEAD = '00000000-0000-0000-0000-0000000000a2'
const RACE_LEAD = '00000000-0000-0000-0000-0000000000a3'
let db: PGlite

beforeAll(async () => {
  db = await dayDb()
  await db.exec(`
    insert into public.leads (id, wpie_owner_id, owner_name, property_address, municipality, lane, stage)
    values ('${LEAD}', 77, 'JANE ROE', '100 N Main St', 'Milwaukee', 'flip', 'reply_received'),
           ('${STOP_LEAD}', 78, 'BO KIM', '400 N Pine St', 'Milwaukee', 'hold', 'reply_received'),
           ('${RACE_LEAD}', 79, 'SAM FOX', '500 N Oak St', 'Milwaukee', 'flip', 'reply_received');
    insert into public.contacts (lead_id, kind, value, value_normalized, line_type, status) values
      ('${LEAD}', 'phone', '4145550177', '4145550177', 'mobile', 'ok'),
      ('${STOP_LEAD}', 'phone', '4145550181', '4145550181', 'mobile', 'ok'),
      ('${STOP_LEAD}', 'phone', '2625550182', '2625550182', 'landline', 'ok'),
      ('${RACE_LEAD}', 'phone', '4145550183', '4145550183', 'mobile', 'ok');
  `)
})

afterAll(async () => { await db.close() })

describe("Thalia's day", () => {
  it('persists her alerts, receives a synthetic hot ping, earns the visit, and prevents the 15-minute re-ping after logging the call', async () => {
    expect(await as(db, THALIA, () => rpc(db, 'set_my_alerts', {
      p_phone: '(414) 555-0199', p_email: 'Thalia@Example.com ',
    }))).toEqual({ ok: true, phone: '4145550199', email: 'thalia@example.com' })
    expect(await one(db, `select alert_phone, alert_email from public.team_members where person = 'thalia'`))
      .toEqual({ alert_phone: '4145550199', alert_email: 'thalia@example.com' })

    await serviceRpc(db, 'hot_record', {
      p_sid: 'SM-thalia-day', p_lead_id: LEAD, p_phone10: '4145550177', p_first_name: 'Jane',
      p_address: '100 N Main St', p_body: 'yes, would sell, what would you pay?', p_is_test: true,
      p_now: '2026-10-22T20:00:00Z',
    })
    const texts: string[] = []
    const memberTexts: string[] = []
    const emails: string[] = []
    const edgeRpc: Rpc = async (fn, args) => {
      try { return { data: await serviceRpc(db, fn, args), error: null } }
      catch (error) { return { data: null, error: { message: String(error) } } }
    }
    const first = await runHotAlerts({
      rpc: edgeRpc,
      send: async (text, to) => { (to ? memberTexts : texts).push(`${to ?? 'colin'}:${text}`); return { ok: true, sid: 'SM-test' } },
      email: {
        recipients: async () => [{ person: 'thalia', email: 'thalia@example.com' }],
        send: async ({ to }) => { emails.push(to) },
      },
      appUrl: 'https://deals.example.com', now: () => new Date('2026-10-22T20:00:00Z'),
    })
    expect(first).toMatchObject({ alerts: 1, member_texts: 1, emails: 1 })
    expect(memberTexts[0]).toContain('4145550199')
    expect(emails).toEqual(['thalia@example.com'])

    const value = (choices: string[], text?: string, number?: string) => ({ choices, ...(text ? { text } : {}), ...(number ? { number } : {}) })
    for (const [key, answer] of Object.entries({
      identity: value(['owner']), motivation: value(['moving'], 'job in Madison'), timeline: value(['under_30']),
      decision_makers: value(['only_them']), ready: value(['yes']), price: value([], undefined, '180000'),
      anchor: value(['own_need']), flexibility: value(['open']), occupancy: value(['owner']), condition: value(['roof'], 'roof is old'),
    })) await as(db, THALIA, () => rpc(db, 'call_answer', { p_lead_id: LEAD, p_key: key, p_value: answer }))
    const callFacts = (await one<{ call_facts: Record<string, { value: unknown }> }>(db, `select call_facts from public.leads where id = '${LEAD}'`)).call_facts
    expect(bookingVerdict(callFacts as never, {}).verdict).toBe('book')
    await as(db, THALIA, () => rpc(db, 'call_answer', {
      p_lead_id: LEAD, p_key: 'next_step', p_value: { kind: 'walk', at: '2026-10-27T19:00:00Z', choices: ['walk'], when: '2026-10-27T19:00:00Z' },
    }))
    await as(db, THALIA, () => rpc(db, 'log_call', { p_lead_id: LEAD, p_phone: '4145550177', p_outcome: 'interested', p_note: 'Moving in 30 days' }))
    expect(await one(db, `select stage::text, belt, assigned_to::text from public.leads where id = '${LEAD}'`))
      .toMatchObject({ stage: 'walkthrough_booked', belt: 'visit_booked' })
    const hot = await one<{ called_at: string | null }>(db, `select called_at::text from public.hot_alerts where lead_id = '${LEAD}'`)
    expect(hot.called_at).toBeTruthy()

    const second = await runHotAlerts({ rpc: edgeRpc, send: async () => ({ ok: true, sid: 'never' }),
      appUrl: 'https://deals.example.com', now: () => new Date('2026-10-22T20:21:00Z') })
    expect(second.second_alerts).toBe(0)
  })

  it('hands a card to Colin repeat-safely and makes STOP final across every phone', async () => {
    const note = 'Would sell; lease ends in December; just him'
    await as(db, THALIA, () => rpc(db, 'handoff_to_colin', { p_lead_id: STOP_LEAD, p_note: note, p_now: '2026-10-26T15:00:00Z' }))
    expect(await as(db, THALIA, () => rpc(db, 'handoff_to_colin', {
      p_lead_id: STOP_LEAD, p_note: note, p_now: '2026-10-26T15:01:00Z',
    }))).toMatchObject({ ok: true, duplicate: true })
    expect(await one(db, `select count(*)::int as n from public.messages where lead_id = '${STOP_LEAD}' and channel = 'note'`)).toEqual({ n: 1 })
    expect(await one(db, `select count(*)::int as n from public.hot_alerts where lead_id = '${STOP_LEAD}'`)).toEqual({ n: 1 })

    // A materially different handoff is genuine even inside the retry window.
    await as(db, THALIA, () => rpc(db, 'handoff_to_colin', {
      p_lead_id: STOP_LEAD, p_note: 'Same card, corrected note', p_now: '2026-10-26T15:02:00Z',
    }))
    expect(await one(db, `select count(*)::int as n from public.tasks where lead_id = '${STOP_LEAD}' and owner = 'colin' and done_at is null`))
      .toEqual({ n: 1 })
    expect(await one(db, `select count(*)::int as n from public.messages where lead_id = '${STOP_LEAD}' and channel = 'note'`)).toEqual({ n: 2 })
    expect(await one(db, `select count(*)::int as n from public.hot_alerts where lead_id = '${STOP_LEAD}'`)).toEqual({ n: 2 })
    await as(db, THALIA, () => rpc(db, 'log_call', { p_lead_id: STOP_LEAD, p_phone: '4145550181', p_outcome: 'dnc', p_note: 'wrong number, STOP' }))
    expect(await one(db, `select stage::text from public.leads where id = '${STOP_LEAD}'`)).toEqual({ stage: 'dnc' })
    expect(await one(db, `select count(*)::int as n from public.contacts where lead_id = '${STOP_LEAD}' and suppressed and dnc_app`))
      .toEqual({ n: 2 })
  })

  it('keeps simultaneous corrected handoffs distinct without duplicating the open task', async () => {
    const at = '2026-10-26T16:00:00Z'
    const results = await as(db, THALIA, () => Promise.all([
      rpc<{ ok: boolean; duplicate: boolean }>(db, 'handoff_to_colin', {
        p_lead_id: RACE_LEAD, p_note: 'Moving this month; confirmed sole owner', p_now: at,
      }),
      rpc<{ ok: boolean; duplicate: boolean }>(db, 'handoff_to_colin', {
        p_lead_id: RACE_LEAD, p_note: 'Correction: spouse also signs', p_now: at,
      }),
    ]))
    expect(results).toEqual([
      expect.objectContaining({ ok: true, duplicate: false }),
      expect.objectContaining({ ok: true, duplicate: false }),
    ])
    expect(await one(db, `select count(*)::int as n from public.messages where lead_id = '${RACE_LEAD}' and channel = 'note'`)).toEqual({ n: 2 })
    expect(await one(db, `select count(*)::int as n from public.hot_alerts where lead_id = '${RACE_LEAD}'`)).toEqual({ n: 2 })
    expect(await one(db, `select count(*)::int as n from public.tasks where lead_id = '${RACE_LEAD}' and owner = 'colin' and done_at is null`)).toEqual({ n: 1 })
  })
})
