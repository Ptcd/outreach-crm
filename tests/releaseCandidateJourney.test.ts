// One synthetic release-candidate journey across the existing conveyor, human takeover and visit packet.
// External transports are not present: PGlite is the database fixture and every provider result is local.
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import type { PGlite } from '@electric-sql/pglite'
import { buildAppointmentPacket } from '../src/lib/appointmentPacket'
import type { CallFacts } from '../src/lib/callGate'
import type { Lead } from '../src/lib/types'
import { ADIL, COLIN, THALIA, as, dayDb, one, rpc, serviceRpc } from './dayInLifeHarness'

const LEAD = '00000000-0000-0000-0000-0000000000e1'
const STOP_FIRST = '00000000-0000-0000-0000-0000000000e2'
const CLAIM_FIRST = '00000000-0000-0000-0000-0000000000e3'
const SID1 = `CA${'1'.repeat(32)}`
const SID2 = `CA${'2'.repeat(32)}`
let db: PGlite

beforeAll(async () => {
  db = await dayDb()
  await db.exec(`
    insert into public.leads (id, wpie_owner_id, owner_name, property_address, municipality, mailing_state, lane, stage)
    values ('${LEAD}', 981, 'JANE JOURNEY', '100 N MAIN ST', 'Milwaukee', 'WI', 'flip', 'opener_sent'),
           ('${STOP_FIRST}', 982, 'STOP FIRST', '200 N MAIN ST', 'Milwaukee', 'WI', 'hold', 'opener_sent'),
           ('${CLAIM_FIRST}', 983, 'CLAIM FIRST', '300 N MAIN ST', 'Milwaukee', 'WI', 'hold', 'opener_sent');
    insert into public.contacts (lead_id, kind, value, value_normalized, line_type, status) values
      ('${LEAD}', 'phone', '4145550177', '4145550177', 'mobile', 'ok'),
      ('${STOP_FIRST}', 'phone', '4145550188', '4145550188', 'mobile', 'ok'),
      ('${CLAIM_FIRST}', 'phone', '4145550199', '4145550199', 'mobile', 'ok');
  `)
})

afterAll(async () => { await db.close() })

describe('release-candidate seller journey', () => {
  it('moves one seller from reply to exact follow-up, manual/app takeover, handoff and one Colin-owned visit', async () => {
    await rpc(db, 'belt_event', {
      p_lead_id: LEAD, p_event: 'inbound_text', p_payload: { key: 'reply:journey', intent: 'interested', interest: true },
      p_by: 'synthetic', p_now: '2026-10-23T15:00:00Z',
    })
    expect(await one(db, `select belt from public.leads where id = '${LEAD}'`)).toEqual({ belt: 'yes_unbooked' })

    await as(db, THALIA, () => rpc(db, 'log_call', {
      p_lead_id: LEAD, p_phone: '4145550177', p_outcome: 'not_now', p_note: 'Call after the move',
      p_when: '2099-11-05T18:00:00Z',
    }))
    const dated = await one<{ named: string; stop: string; tasks: number }>(db, `
      select l.named_date::text named, l.next_stop_at::text stop,
        (select count(*)::int from public.tasks t where t.lead_id = l.id and t.source = 'belt' and t.done_at is null) tasks
      from public.leads l where l.id = '${LEAD}'`)
    expect(new Date(dated.stop).getTime()).toBeGreaterThanOrEqual(new Date(dated.named).getTime())
    expect(dated.tasks).toBe(1)

    await as(db, THALIA, () => rpc(db, 'log_call', {
      p_lead_id: LEAD, p_phone: '4145550177', p_outcome: 'not_now', p_note: 'Corrected: one week later',
      p_when: '2099-11-12T18:00:00Z',
    }))
    const rescheduled = await one<{ named: string; due: string; owner: string; tasks: number }>(db, `
      select l.named_date::text named, min(t.due_at)::text due, min(t.owner)::text owner, count(t.id)::int tasks
      from public.leads l left join public.tasks t on t.lead_id = l.id and t.source = 'belt' and t.done_at is null
      where l.id = '${LEAD}' group by l.id`)
    expect(new Date(rescheduled.due).getTime()).toBeGreaterThanOrEqual(new Date(rescheduled.named).getTime())
    expect(rescheduled.owner).toBe('colin')
    expect(rescheduled.tasks).toBe(1)
    expect(await as(db, THALIA, () => rpc(db, 'begin_human_call', {
      p_lead_id: LEAD, p_phone: '4145550177', p_source: 'personal', p_key: 'before_named_date_001',
      p_now: '2100-01-01T00:00:00Z',
    }))).toMatchObject({ ok: false, paused: false, reason: 'the seller asked us to wait until the scheduled date' })
    expect(await as(db, THALIA, () => rpc(db, 'begin_human_call', {
      p_lead_id: LEAD, p_phone: '4145550177', p_source: 'app', p_key: 'before_named_date_app_002',
      p_now: '2100-01-01T00:00:00Z',
    }))).toMatchObject({ ok: false, paused: false, reason: 'the seller asked us to wait until the scheduled date' })
    expect(await one(db, `select human_takeover_at is null clean from public.leads where id = '${LEAD}'`)).toEqual({ clean: true })
    await db.exec(`update public.leads set named_date = now() - interval '1 second', next_stop_at = now() - interval '1 second' where id = '${LEAD}'`)

    const manual = await as(db, THALIA, () => rpc<{ ok: boolean; paused: boolean; duplicate: boolean }>(db, 'begin_human_call', {
      p_lead_id: LEAD, p_phone: '4145550177', p_source: 'personal', p_key: 'manual_journey_001',
      p_now: '2026-11-12T16:00:00Z',
    }))
    expect(manual).toMatchObject({ ok: true, paused: true, duplicate: false })
    expect(await as(db, THALIA, () => rpc(db, 'begin_human_call', {
      p_lead_id: LEAD, p_phone: '4145550177', p_source: 'personal', p_key: 'manual_journey_001',
      p_now: '2026-11-12T16:00:01Z',
    }))).toMatchObject({ ok: true, paused: true, duplicate: true })
    expect(await as(db, THALIA, () => rpc(db, 'resume_human_call', {
      p_lead_id: LEAD, p_key: 'manual_journey_001', p_now: '2026-11-12T16:01:00Z',
    }))).toMatchObject({ ok: true, paused: false })

    expect(await as(db, ADIL, () => rpc(db, 'begin_human_call', {
      p_lead_id: LEAD, p_phone: '4145550177', p_source: 'app', p_key: 'app_journey_002',
      p_now: '2026-11-13T16:00:00Z',
    }))).toMatchObject({ ok: true, paused: true, duplicate: false })
    expect(await serviceRpc(db, 'claim_human_call_provider', {
      p_lead_id: LEAD, p_phone10: '4145550177', p_key: 'app_journey_002', p_provider_call_sid: SID1,
    })).toEqual({ allowed: true, duplicate: false })
    expect(await serviceRpc(db, 'claim_human_call_provider', {
      p_lead_id: LEAD, p_phone10: '4145550177', p_key: 'app_journey_002', p_provider_call_sid: SID1,
    })).toEqual({ allowed: true, duplicate: true })

    await as(db, ADIL, () => rpc(db, 'log_call', {
      p_lead_id: LEAD, p_phone: '4145550177', p_outcome: 'interested', p_note: 'Ready for Colin',
    }))
    const answer = (choices: string[], text?: string, number?: string) => ({ choices, ...(text ? { text } : {}), ...(number ? { number } : {}) })
    for (const [key, value] of Object.entries({
      motivation: answer(['moving'], 'moving near family'), timeline: answer(['under_30']),
      decision_makers: answer(['only_them']), condition: answer(['roof'], 'roof is old'),
      price: answer([], undefined, '185000'),
    })) await as(db, THALIA, () => rpc(db, 'call_answer', { p_lead_id: LEAD, p_key: key, p_value: value }))

    const note = 'Moving near family; sole signer; roof is old; asking 185000'
    expect(await as(db, THALIA, () => rpc(db, 'handoff_to_colin', {
      p_lead_id: LEAD, p_note: note, p_now: '2026-11-13T17:00:00Z',
    }))).toMatchObject({ ok: true, duplicate: false })
    expect(await as(db, THALIA, () => rpc(db, 'handoff_to_colin', {
      p_lead_id: LEAD, p_note: note, p_now: '2026-11-13T17:01:00Z',
    }))).toMatchObject({ ok: true, duplicate: true })

    await as(db, COLIN, () => rpc(db, 'call_answer', {
      p_lead_id: LEAD, p_key: 'next_step',
      p_value: { kind: 'walk', at: '2026-11-13T19:00:00Z', choices: ['walk'], when: '2026-11-13T19:00:00Z' },
    }))
    const state = await one<{ stage: string; belt: string; owner: string; tasks: number; call_facts: CallFacts }>(db, `
      select l.stage::text stage, l.belt, l.assigned_to::text owner, l.call_facts,
        (select count(*)::int from public.tasks t where t.lead_id = l.id and t.kind = 'visit' and t.done_at is null) tasks
      from public.leads l where l.id = '${LEAD}'`)
    expect(state).toMatchObject({ stage: 'walkthrough_booked', belt: 'visit_booked', owner: 'colin', tasks: 1 })
    const lead = await one<Record<string, unknown>>(db, `select * from public.leads where id = '${LEAD}'`)
    const packet = buildAppointmentPacket(lead as unknown as Lead, state.call_facts)
    expect(packet.rows.find((r) => r.id === 'motivation')).toMatchObject({ known: true, provenance: { recordedBy: 'Thalia' } })
    expect(packet.rows.find((r) => r.id === 'condition')?.value).toContain('roof is old')
    expect(packet.rows.find((r) => r.id === 'asking_price')?.value).toBe('$185000')
    expect(packet.unresolved).toContain('Who is speaking')
  })

  it('fails closed in both deterministic STOP/provider orderings', async () => {
    await as(db, THALIA, () => rpc(db, 'begin_human_call', {
      p_lead_id: STOP_FIRST, p_phone: '4145550188', p_source: 'app', p_key: 'stop_first_001',
      p_now: '2026-10-23T17:00:00Z',
    }))
    await rpc(db, 'belt_event', {
      p_lead_id: STOP_FIRST, p_event: 'stop', p_payload: { key: 'stop:before-provider' },
      p_by: 'synthetic', p_now: '2026-10-23T17:00:01Z',
    })
    expect(await serviceRpc(db, 'claim_human_call_provider', {
      p_lead_id: STOP_FIRST, p_phone10: '4145550188', p_key: 'stop_first_001', p_provider_call_sid: SID2,
    })).toMatchObject({ allowed: false, reason: 'this card is closed or do-not-contact' })
    expect(await as(db, THALIA, () => rpc(db, 'begin_human_call', {
      p_lead_id: STOP_FIRST, p_phone: '4145550188', p_source: 'personal', p_key: 'stop_first_personal_002',
      p_now: '2026-10-23T17:00:02Z',
    }))).toMatchObject({ ok: false, paused: false })

    await as(db, THALIA, () => rpc(db, 'begin_human_call', {
      p_lead_id: CLAIM_FIRST, p_phone: '4145550199', p_source: 'app', p_key: 'claim_first_002',
      p_now: '2026-10-23T17:05:00Z',
    }))
    const sid = `CA${'3'.repeat(32)}`
    expect(await serviceRpc(db, 'claim_human_call_provider', {
      p_lead_id: CLAIM_FIRST, p_phone10: '4145550199', p_key: 'claim_first_002', p_provider_call_sid: sid,
    })).toMatchObject({ allowed: true })
    await rpc(db, 'belt_event', {
      p_lead_id: CLAIM_FIRST, p_event: 'stop', p_payload: { key: 'stop:after-provider' },
      p_by: 'synthetic', p_now: '2026-10-23T17:05:01Z',
    })
    expect(await serviceRpc(db, 'claim_human_call_provider', {
      p_lead_id: CLAIM_FIRST, p_phone10: '4145550199', p_key: 'claim_first_002', p_provider_call_sid: sid,
    })).toMatchObject({ allowed: false, reason: 'this card is closed or do-not-contact' })
    expect(await one(db, `select count(*)::int n from public.tasks where lead_id in ('${STOP_FIRST}', '${CLAIM_FIRST}') and done_at is null`))
      .toEqual({ n: 0 })
  })
})
