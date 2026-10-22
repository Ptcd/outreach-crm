// Adil's synthetic weekend: Sunday blocks seller sends but not staff hot pings,
// and reply work lands with the seller's exact words and closes once done.
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import type { PGlite } from '@electric-sql/pglite'
import { runHotAlerts } from '../supabase/functions/_shared/hotLeads'
import type { Rpc } from '../supabase/functions/_shared/sending'
import { ADIL, as, dayDb, one, serviceRpc } from './dayInLifeHarness'

const LEAD = '00000000-0000-0000-0000-0000000000b1'
let db: PGlite

beforeAll(async () => {
  db = await dayDb()
  await db.exec(`
    update public.team_members set alert_phone = '4145550198' where person = 'adil';
    insert into public.leads (id, wpie_owner_id, owner_name, property_address, municipality, lane, stage)
    values ('${LEAD}', 88, 'DALE NOVAK', '220 S Water St', 'Milwaukee', 'hold', 'opener_queued');
    insert into public.contacts (lead_id, kind, value, value_normalized, line_type, status)
    values ('${LEAD}', 'phone', '4145550188', '4145550188', 'mobile', 'ok');
  `)
})

afterAll(async () => { await db.close() })

describe("Adil's weekend", () => {
  it('never releases a seller text on Sunday, while a Sunday hot reply still pings the on-duty caller', async () => {
    await db.exec(`
      update public.campaign_control set sending_enabled = true, paused = false, laptop_paused = false, daily_cap = 100;
      insert into public.planned_openers
        (plan_date, wpie_owner_id, attempt, lead_id, lane, template_lane, variant, phone, body, body_sha256,
         segments, scheduled_at, window_start_utc, window_end_utc, dnc_state, per_hour, decision, send_status)
      values ('2026-10-22', 88, 1, '${LEAD}', 'hold', 'hold', 'A', '+14145550188',
        'Hi Dale, Colin Merrill here. Would you consider selling 220 S Water St? Reply STOP to opt out.',
        encode(sha256(convert_to('safe-sunday-plan', 'UTF8')), 'hex'), 1, '2026-10-22T15:00:00Z',
        '2026-10-22T15:00:00Z', '2026-10-23T00:00:00Z', 'unknown', 12, 'approved', 'planned');
    `)
    const claim = await one<{ result: { outcome: string; reason: string } }>(db,
      `select public.claim_next_opener(false, '2026-10-25T16:00:00Z'::timestamptz) as result`)
    expect(claim.result).toMatchObject({ outcome: 'idle', reason: 'sunday' })

    await serviceRpc(db, 'hot_record', {
      p_sid: 'SM-adil-sunday', p_lead_id: LEAD, p_phone10: '4145550188', p_first_name: 'Dale',
      p_address: '220 S Water St', p_body: 'yes, call me today', p_is_test: true, p_now: '2026-10-25T16:00:00Z',
    })
    const memberTexts: string[] = []
    const edgeRpc: Rpc = async (fn, args) => {
      try { return { data: await serviceRpc(db, fn, args), error: null } }
      catch (error) { return { data: null, error: { message: String(error) } } }
    }
    const hot = await runHotAlerts({
      rpc: edgeRpc,
      send: async (_text, to) => { if (to) memberTexts.push(to); return { ok: true, sid: 'SM-staff-only' } },
      appUrl: 'https://deals.example.com', now: () => new Date('2026-10-25T16:00:00Z'),
    })
    expect(hot).toMatchObject({ alerts: 1, member_texts: 1 })
    expect(memberTexts).toEqual(['+14145550198'])
  })

  it('gets an email/document task with the seller words, and Done closes it without duplicating it', async () => {
    await db.exec(`insert into public.twilio_inbound (sid, from10, to_number, body, lead_id, received_at)
      values ('SM-adil-task', '4145550188', '+12629996513', 'Can you email the document to dale@example.com?', '${LEAD}', '2026-10-25T16:05:00Z')`)
    const first = await serviceRpc<{ ok: boolean; id: string }>(db, 'reply_create_task', {
      p_sid: 'SM-adil-task', p_kind: 'email', p_title: 'Email them at dale@example.com',
      p_quote: 'Can you email the document to dale@example.com?', p_email: 'dale@example.com', p_now: '2026-10-25T16:05:00Z',
    })
    const repeated = await serviceRpc<{ ok: boolean; id: string }>(db, 'reply_create_task', {
      p_sid: 'SM-adil-task', p_kind: 'email', p_title: 'Email them at dale@example.com',
      p_quote: 'Can you email the document to dale@example.com?', p_email: 'dale@example.com', p_now: '2026-10-25T16:06:00Z',
    })
    expect(first.ok).toBe(true)
    expect(repeated.ok).toBe(false)
    expect(await one(db, `select count(*)::int as n from public.tasks where reply_inbound_sid = 'SM-adil-task'`)).toEqual({ n: 1 })
    expect(await one(db, `select owner::text, kind, quote, email_to, done_at from public.tasks where id = '${first.id}'`))
      .toEqual({ owner: 'adil', kind: 'email', quote: 'Can you email the document to dale@example.com?', email_to: 'dale@example.com', done_at: null })
    await as(db, ADIL, () => db.query(`update public.tasks set done_at = now() where id = $1`, [first.id]))
    expect((await one<{ done: boolean }>(db, `select done_at is not null as done from public.tasks where id = '${first.id}'`)).done).toBe(true)
  })
})
