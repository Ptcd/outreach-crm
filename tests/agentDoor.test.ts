// The agent door (Colin 2026-10-25: "design it agent first"): the MCP routing and key roles, the wording check, and on
// the real migrations a key Colin makes, an intake agent's prospect becoming a card, a sender agent's text queued
// inside the recipient's window and then claimed by the same send check the laptop's texts pass.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'
import { TOOLS, handleMessage, keyFrom, textProblem, type DoorDb } from '../supabase/functions/_shared/agentDoor'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')
const COLIN = { sub: '00000000-0000-0000-0000-00000000000c', email: 'colin@example.com' }
const OPENER = "Hi Pat, Colin Merrill here. Are you still the owner of 12 Maple St? Reply STOP if you'd rather not hear from me."

const fakeDb = (over: Partial<DoorDb> = {}): DoorDb => ({
  addProspect: async () => ({ status: 'created', lead_id: 'L1' }), findProspects: async () => [], prospectCounts: async () => ({}),
  status: async () => ({ paused: false }), readyToText: async () => [], queueText: async () => ({ status: 'queued', text_id: 'T1' }),
  queue: async () => [], withdraw: async () => true, pause: async () => ({ paused: true }), resume: async () => ({ paused: false }),
  results: async () => ({}), testResults: async () => ({}), repliesWaiting: async () => [], markCard: async () => ({ ok: true }), dueToday: async () => ({ due: [], stuck: [] }), records: async () => ({}), linkCards: async () => ({ ok: true }), sendReply: async () => ({ outcome: 'sent' }), ...over,
})
const intake = { id: 'k1', name: 'Muse intake', role: 'intake' as const }
const sender = { id: 'k2', name: 'Muse sender', role: 'sender' as const }
const call = async (agent: typeof intake | typeof sender, name: string, args: unknown, db = fakeDb()) => {
  const r = await handleMessage({ jsonrpc: '2.0', id: 7, method: 'tools/call', params: { name, arguments: args } }, agent, db)
  const res = (r as { result: { content: { text: string }[]; isError: boolean } }).result
  return { isError: res.isError, value: JSON.parse(res.content[0].text) }
}

describe('the MCP routing', () => {
  it('initialize answers with tools capability; a notification gets no reply', async () => {
    const r = await handleMessage({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-03-26' } }, intake, fakeDb())
    expect((r as { result: { protocolVersion: string; capabilities: unknown } }).result).toMatchObject({ protocolVersion: '2025-03-26', capabilities: { tools: {} } })
    expect(await handleMessage({ jsonrpc: '2.0', method: 'notifications/initialized' }, intake, fakeDb())).toBeNull()
  })
  it('each key sees only its own tools, and cannot call the other role\'s', async () => {
    const list = async (a: typeof intake | typeof sender) => ((await handleMessage({ jsonrpc: '2.0', id: 2, method: 'tools/list' }, a, fakeDb())) as
      { result: { tools: { name: string }[] } }).result.tools.map((t) => t.name)
    expect(await list(intake)).toEqual(TOOLS.filter((t) => t.role === 'intake' || t.role === 'any').map((t) => t.name))
    expect(await list(intake)).toContain('mark_card')
    expect(await list(sender)).toContain('queue_texts')
    expect(await list(intake)).not.toContain('queue_texts')
    expect((await call(intake, 'queue_texts', { texts: [] })).isError).toBe(true)
    expect((await call(sender, 'add_prospects', { prospects: [] })).isError).toBe(true)
  })
  it('the key comes from Authorization: Bearer or x-api-key', () => {
    expect(keyFrom(new Headers({ authorization: 'Bearer wpie_sender_abc' }))).toBe('wpie_sender_abc')
    expect(keyFrom(new Headers({ 'x-api-key': 'wpie_intake_xyz' }))).toBe('wpie_intake_xyz')
    expect(keyFrom(new Headers())).toBeNull()
  })
})

describe('the wording check (Colin\'s rules for every text)', () => {
  it('passes a plain first text and refuses what may never go out', () => {
    expect(textProblem(OPENER)).toBeNull()
    expect(textProblem('Hi Pat, is 12 Maple St still yours?')).toMatch(/STOP/)
    expect(textProblem("I'd pay $90k for it. Reply STOP to opt out.")).toMatch(/\$/)
    expect(textProblem('I buy houses for cash. Reply STOP to opt out.')).toMatch(/cash/)
    expect(textProblem('I buy them as-is. Reply STOP to opt out.')).toMatch(/as-is/)
    expect(textProblem('Our team at Maple Holdings LLC buys houses. Reply STOP to opt out.')).toMatch(/business/)
    expect(textProblem('See https://x.co Reply STOP')).toMatch(/links/)
  })
  it('queue_texts refuses a bad text before it reaches the database', async () => {
    let reached = 0
    const r = await call(sender, 'queue_texts', { texts: [{ lead_id: 'L1', phone: '4145550100', body: 'Hi, still yours?' },
      { lead_id: 'L2', phone: '4145550101', body: OPENER }] }, fakeDb({ queueText: async () => { reached++; return { status: 'queued' } } }))
    expect(r.value).toMatchObject({ queued: 1, refused: 1 })
    expect(reached).toBe(1)
  })
})

describe('on the real migrations', () => {
  let db: PGlite
  const one = async <T = Record<string, unknown>>(sql: string, params: unknown[] = []) => (await db.query<T>(sql, params)).rows[0]
  const r = async (sql: string, params: unknown[] = []) => (await one<{ r: Record<string, unknown> }>(`select ${sql} as r`, params)).r
  beforeAll(async () => {
    db = new PGlite()
    await db.exec(SUPABASE_STUB)
    await db.exec(MIGRATION)
    await db.exec(`insert into public.team_members (email, role, person, display_name) values ('colin@example.com', 'owner', 'colin', 'Colin')`)
  })

  it('Colin makes a key in the app; only its hash is kept; a turned-off key stops working', async () => {
    await db.query(`select set_config('request.jwt.claims', $1, false)`, [JSON.stringify(COLIN)])
    await db.exec('set role authenticated')
    const key = (await one<{ k: string }>(`select public.create_agent_key('Muse sender', 'sender') as k`)).k
    const listed = (await db.query<{ name: string; key_hint: string }>(`select * from public.list_agent_keys()`)).rows
    await db.exec('reset role')
    expect(key).toMatch(/^wpie_sender_[0-9a-f]{64}$/)
    expect(listed[0]).toMatchObject({ name: 'Muse sender', key_hint: key.slice(-4) })
    expect(await one(`select count(*)::int n from public.agent_keys where key_sha256 = $1`, [key])).toEqual({ n: 0 })
    expect(await r(`public.agent_key_check($1)`, [key])).toMatchObject({ ok: true, role: 'sender', name: 'Muse sender' })
    expect(await r(`public.agent_key_check('wpie_sender_nope')`)).toEqual({ ok: false })
    await db.exec(`update public.agent_keys set revoked_at = now()`)
    expect(await r(`public.agent_key_check($1)`, [key])).toEqual({ ok: false })
  })

  it('a prospect becomes a card with its phones and reasons; the same one again merges', async () => {
    const p = { owner_name: 'Pat Sample', address: '12 Maple St', city: 'Waukesha', zip: '53186', county: 'Waukesha', mailing_state: 'WI',
      phones: [{ number: '(414) 555-0142', type: 'mobile', name: 'Pat Sample' }, '414-555-01'],
      reasons: [{ kind: 'tax_delinquent', label: 'Behind on taxes 2 years', detail: '2024 and 2025', amount: 6100, source: 'county treasurer' }] }
    const a = await r(`public.agent_add_prospect($1::jsonb, 'Muse intake')`, [JSON.stringify(p)])
    expect(a).toMatchObject({ status: 'created', phones_added: ['4145550142'] })
    expect((a.phones_skipped as unknown[]).length).toBe(1)
    const card = await one<{ wpie_owner_id: number; stage: string; reasons_to_sell: string[]; source: string }>(
      `select wpie_owner_id::int, stage::text, reasons_to_sell, source from public.leads where id = $1`, [a.lead_id])
    expect(card.wpie_owner_id).toBeLessThan(0)
    expect(card).toMatchObject({ stage: 'opener_queued', reasons_to_sell: ['Behind on taxes 2 years'], source: 'muse' })
    const b = await r(`public.agent_add_prospect($1::jsonb, 'Muse intake')`, [JSON.stringify({ ...p, address: '12  MAPLE ST', phones: ['4145550143'] })])
    expect(b).toMatchObject({ status: 'updated', lead_id: a.lead_id, phones_added: ['4145550143'] })
    expect(await r(`public.agent_add_prospect('{"owner_name": "X"}'::jsonb, 'm')`)).toMatchObject({ status: 'rejected' })
    const ready = await r(`public.agent_ready_to_text(10, false, false)`)
    expect((ready.new_cards as { lead_id: string }[]).map((c) => c.lead_id)).toEqual([a.lead_id])
  })

  it('a sender text is queued inside the window, then claimed by the normal send check; refusals say why', async () => {
    const lid = (await one<{ id: string }>(`select id from public.leads where owner_name = 'Pat Sample'`)).id
    const sat = '2026-10-24T20:30:00Z'          // Saturday 3:30 PM Central
    const q = await r(`public.agent_queue_text($1, '4145550142', $2, 1, null, 'Muse sender', $3::timestamptz)`, [lid, OPENER, sat])
    expect(q).toMatchObject({ status: 'queued' })
    expect(await r(`public.agent_queue_text($1, '4145550142', $2, 1, null, 'Muse sender', $3::timestamptz)`, [lid, OPENER, sat]))
      .toMatchObject({ status: 'refused', reason: expect.stringContaining('already waiting') })
    expect(await r(`public.agent_queue_text($1, '4145559999', $2, 1, null, 'Muse sender', $3::timestamptz)`, [lid, OPENER, sat]))
      .toMatchObject({ status: 'refused', reason: expect.stringContaining('not a usable phone') })
    const late = await r(`public.agent_queue_text($1, '4145550143', $2, 2, '2026-10-25T00:30:00Z', 'Muse sender', $3::timestamptz)`, [lid, OPENER, sat])
    expect(late.status).toBe('queued')
    expect(new Date(late.goes_after as string).toISOString()).toBe('2026-10-26T15:00:00.000Z')    // 7:30 PM Sat is past the window -> Monday 10 AM, no Sunday
    const claim = await r(`public.claim_next_opener(true, $1::timestamptz)`, [sat])
    expect(claim).toMatchObject({ outcome: 'would_send' })
    expect((claim.opener as { body: string }).body).toBe(OPENER)
    // a STOP from the card's other phone: nothing more is queued to it, and the card's waiting texts are refused at send
    await db.exec(`update public.planned_openers set send_status = 'planned', claim_mode = null, claimed_at = null where lane = 'agent' and step = 1`)
    await db.exec(`insert into public.suppressed_phones (phone10, reason, source) values ('4145550143', 'inbound_opt_out', 'test')`)
    expect(await r(`public.agent_queue_text($1, '4145550143', $2, 1, null, 'Muse sender', $3::timestamptz)`, [lid, OPENER, sat]))
      .toMatchObject({ status: 'refused', reason: expect.stringMatching(/usable|opted out/) })
    expect(await r(`public.claim_next_opener(true, $1::timestamptz)`, [sat]))
      .toMatchObject({ outcome: 'skipped', reason: 'owner_opted_out_on_another_phone' })
  })

  it('an A/B test: each text carries its variant, and test_results scores the variants side by side', async () => {
    const mk = async (name: string, phone: string) => (await r(`public.agent_add_prospect($1::jsonb, 'Muse intake')`,
      [JSON.stringify({ owner_name: name, address: `${phone.slice(-3)} Oak St`, phones: [phone] })])).lead_id as string
    const a = await mk('Ann Arm', '4145550161'); const b = await mk('Bob Arm', '4145550162')
    const mon = '2026-10-26T16:00:00Z'
    const qa = await r(`public.agent_queue_text($1, '4145550161', $2, 1, null, 'Muse sender', $3::timestamptz, 'a', 'own_q')`, [a, OPENER, mon])
    const qb = await r(`public.agent_queue_text($1, '4145550162', $2, 1, null, 'Muse sender', $3::timestamptz, 'B', 'intent_q')`, [b, OPENER, mon])
    expect(qa).toMatchObject({ status: 'queued', variant: 'A' })
    expect(qb).toMatchObject({ status: 'queued', variant: 'B' })
    await db.query(`update public.planned_openers set send_status = 'delivered', claim_mode = 'live', sent_at = $1::timestamptz where variant in ('A', 'B')`, [mon])
    await db.query(`insert into public.twilio_inbound (sid, from10, to_number, body, is_opt_out, received_at) values
      ('SMa1', '4145550161', '+12624180202', 'Yes why?', false, '2026-10-26T16:05:00Z'),
      ('SMb1', '4145550162', '+12624180202', 'STOP', true, '2026-10-26T16:06:00Z')`)
    const t = await r(`public.agent_test_results(14, 1)`)
    const by = Object.fromEntries((t.variants as { variant: string }[]).map((v) => [v.variant, v]))
    expect(by.A).toMatchObject({ delivered: 1, conversations: 1, stops: 0, reply_rate: 100, templates: ['own_q'] })
    expect(by.B).toMatchObject({ delivered: 1, conversations: 0, stops: 1, stop_rate: 100, templates: ['intent_q'] })
  })

  it('with the switch on, a first text the laptop plans is handed to the agent, which sees the card and the laptop wording', async () => {
    const lid = (await one<{ id: string }>(`insert into public.leads (wpie_owner_id, owner_name, owner_type, property_address, stage)
      values (777, 'Lap Topcard', 'individual', '7 Elm St', 'opener_queued') returning id`)).id
    await db.query(`insert into public.contacts (lead_id, kind, value, value_normalized, line_type) values ($1, 'phone', '4145550177', '4145550177', 'mobile')`, [lid])
    await db.exec(`update public.campaign_control set agent_writes_openers = true`)
    await db.query(`insert into public.planned_openers (plan_date, wpie_owner_id, attempt, lead_id, lane, phone, body, step)
      values ((now() at time zone 'America/Chicago')::date, 777, 1, $1, 'flip', '+14145550177', $2, 1)`, [lid, 'Hi Lap, laptop wording. Reply STOP'])
    expect(await one(`select send_status, send_reason from public.planned_openers where wpie_owner_id = 777`))
      .toEqual({ send_status: 'withdrawn', send_reason: 'handed to the sender agent' })
    const ready = await r(`public.agent_ready_to_text(50, false, false)`)
    const c = (ready.new_cards as { lead_id: string; laptop_text: string; owner_type: string }[]).find((x) => x.lead_id === lid)
    expect(c).toMatchObject({ laptop_text: 'Hi Lap, laptop wording. Reply STOP', owner_type: 'individual' })
    await db.exec(`update public.campaign_control set agent_writes_openers = false`)
    await db.query(`insert into public.planned_openers (plan_date, wpie_owner_id, attempt, lead_id, lane, phone, body, step)
      values ((now() at time zone 'America/Chicago')::date + 1, 777, 1, $1, 'flip', '+14145550177', 'x STOP', 1)`, [lid])
    expect(await one(`select send_status from public.planned_openers where wpie_owner_id = 777 and plan_date > (now() at time zone 'America/Chicago')::date`))
      .toEqual({ send_status: 'planned' })
  })

  it('"do we already have them?": an address the laptop has (spelled differently) merges into that card; a phone on another card is not added', async () => {
    const lap = (await one<{ id: string }>(`insert into public.leads (wpie_owner_id, owner_name, property_address, property_zip, stage)
      values (888, 'SMITH JOHN', '1205 NORTH STATE STREET', '54911', 'opener_queued') returning id`)).id
    await db.query(`insert into public.contacts (lead_id, kind, value, value_normalized) values ($1, 'phone', '9205550111', '9205550111')`, [lap])
    const res = await r(`public.agent_add_prospect($1::jsonb, 'Muse intake')`, [JSON.stringify({ owner_name: 'John Smith',
      address: '1205 N State St', zip: '54911', phones: ['920-555-0112', '920-555-0111'], reasons: [{ kind: 'vacant', label: 'Vacant' }] })])
    expect(res).toMatchObject({ status: 'already_have', lead_id: lap, phones_added: ['9205550112'], existing: { source: 'laptop', texted: false } })
    const elsewhere = await r(`public.agent_add_prospect($1::jsonb, 'Muse intake')`, [JSON.stringify({ owner_name: 'Jane Roe',
      address: '9 Other Rd', phones: ['9205550112'] })])
    expect(elsewhere.status).toBe('created')
    expect(elsewhere.phones_skipped).toEqual([{ number: '9205550112', why: 'already on another card', lead_id: lap }])
  })

  it('with agent_runs_texting on, a reply is read and recorded but not queued or put up for the team; the agent sees it and answers it', async () => {
    const lid = (await r(`public.agent_add_prospect($1::jsonb, 'Muse intake')`, [JSON.stringify({ owner_name: 'Rae Plier',
      address: '3 Reply Ct', phones: ['4145550199'] })])).lead_id as string
    await db.query(`insert into public.messages (lead_id, direction, channel, body, from_number, to_number, status, sent_at, source_key, is_opener, provider_sid)
      values ($1, 'out', 'sms', 'Hi Rae, Colin Merrill here. Still own 3 Reply Ct? Reply STOP', '+12623812196', '+14145550199', 'delivered', now() - interval '1 hour', 'test:o1', true, 'SMo1')`, [lid])
    await db.query(`insert into public.twilio_inbound (sid, from10, to_number, body, is_opt_out, lead_id, received_at)
      values ('SMr1', '4145550199', '+12623812196', 'Yes, why?', false, $1, now() - interval '5 minutes')`, [lid])
    await db.exec(`update public.campaign_control set agent_runs_texting = true, routine_enabled = true`)
    const dec = await r(`public.reply_record_decision('SMr1', 'who_is_this', 'routine', false, 'open', 'Fair question - this is Colin.', 'brain', 'n', 'v1')`)
    expect(dec).toMatchObject({ ok: true, status: 'no_reply' })
    const waiting = await r(`public.agent_replies_waiting(7)`) as unknown as { lead_id: string; reply_to: { text: string; our_number: string };
      reply_agent_read: { intent: string; suggested_reply: string }; conversation: { who: string; text: string }[] }[]
    const w = waiting.find((x) => x.lead_id === lid)!
    expect(w.reply_to).toMatchObject({ text: 'Yes, why?', our_number: '+12623812196' })
    expect(w.reply_agent_read).toMatchObject({ intent: 'who_is_this', suggested_reply: 'Fair question - this is Colin.' })
    expect(w.conversation.map((c) => c.who)).toEqual(['us', 'them'])
    const draft = (await one<{ id: string }>(`select public.agent_start_reply($1, '4145550199', 'Muse sender') as id`, [lid])).id
    expect(await one(`select kind, our_number, status from public.reply_drafts where id = $1`, [draft]))
      .toEqual({ kind: 'team', our_number: '+12623812196', status: 'awaiting_approval' })
    await db.exec(`update public.campaign_control set agent_runs_texting = false`)
  })

  it('mark_card moves a card the way the team buttons do; link_cards shows on both cards', async () => {
    const mk = async (name: string, addr: string, phone: string) => (await r(`public.agent_add_prospect($1::jsonb, 'Muse intake')`,
      [JSON.stringify({ owner_name: name, address: addr, phones: [phone] })])).lead_id as string
    const a = await mk('Mark Able', '1 Mark St', '4145550301'); const b = await mk('Mark Able', '2 Mark St', '4145550302')
    const c = await mk('Dee Enncee', '3 Mark St', '4145550303'); const h = await mk('Hot Holly', '4 Mark St', '4145550304')
    const w = await mk('Wrong Wu', '5 Mark St', '4145550305')
    const card = async (id: string) => one<{ stage: string; belt: string | null; named_event: string | null }>(`select stage::text, belt, named_event from public.leads where id = $1`, [id])
    expect(await r(`public.agent_mark_card($1, 'not_now', 'after the tenant moves out', null, null, 'Muse sender')`, [a])).toMatchObject({ mark: 'not_now' })
    expect(await card(a)).toMatchObject({ stage: 'follow_up', belt: 'not_now_condition', named_event: 'after the tenant moves out' })
    expect(await r(`public.agent_mark_card($1, 'not_now', null, '2026-12-01T16:00:00Z', null, 'Muse sender')`, [b])).toMatchObject({ mark: 'not_now' })
    expect((await card(b)).belt).toBe('not_now_dated')
    expect(await r(`public.agent_mark_card($1, 'dnc', 'said never text me', null, '4145550303', 'Muse sender')`, [c])).toMatchObject({ mark: 'dnc' })
    expect((await card(c)).stage).toBe('dnc')
    expect(await one(`select count(*)::int n from public.suppressed_phones where phone10 = '4145550303'`)).toEqual({ n: 1 })
    expect(await r(`public.agent_mark_card($1, 'hot', 'wants to sell by spring', null, null, 'Muse sender')`, [h])).toMatchObject({ mark: 'hot' })
    expect(await card(h)).toMatchObject({ stage: 'colin_call', belt: 'yes_unbooked' })
    // the ping to Colin comes from the agent's mark, with its reason; the reply agent's own hot read pings nothing while the agent runs texting
    expect(await one(`select body, phone10 from public.hot_alerts where lead_id = $1`, [h])).toEqual({ body: 'Muse: wants to sell by spring', phone10: '4145550304' })
    await db.exec(`update public.campaign_control set agent_runs_texting = true`)
    expect(await r(`public.hot_record('SMjunk', $1, '4145550304', 'Holly', '4 Mark St', 'Yes', false, now())`, [h])).toMatchObject({ ok: false })
    await db.exec(`update public.campaign_control set agent_runs_texting = false`)
    expect(await r(`public.agent_mark_card($1, 'hot', null, null, null, 'Muse sender')`, [w])).toMatchObject({ ok: false })
    expect(await r(`public.agent_mark_card($1, 'wrong_number', null, null, '4145550305', 'Muse sender')`, [w])).toMatchObject({ phone_marked_bad: '4145550305' })
    expect((await card(w)).stage).toBe('data_fix')
    expect(await r(`public.agent_mark_card($1, 'dead', 'x', null, null, 'Muse sender')`, [c])).toMatchObject({ ok: false })   // dnc stays dnc
    expect(await r(`public.agent_mark_card($1, 'bogus', null, null, null, 'Muse sender')`, [a])).toMatchObject({ ok: false })
    expect(await r(`public.agent_link_cards($1, $2, 'same_person', 'both deeds to Mark Able', 'Muse intake')`, [a, b])).toEqual({ ok: true })
    const links = (await r(`public.agent_card($1)`, [b])).links as { lead_id: string; kind: string; note: string }[]
    expect(links).toEqual([{ lead_id: a, owner_name: 'Mark Able', address: '1 Mark St', stage: 'follow_up', kind: 'same_person', note: 'both deeds to Mark Able' }])
    expect(await r(`public.agent_link_cards($1, $2, 'cousin', null, 'x')`, [a, b])).toMatchObject({ ok: false })
  })

  it('due_today: the 30-day guy, the 6-month lady and the unsigned contract show up when their day comes, with why; not before', async () => {
    const mk = async (name: string, addr: string, phone: string) => (await r(`public.agent_add_prospect($1::jsonb, 'Muse intake')`,
      [JSON.stringify({ owner_name: name, address: addr, phones: [phone] })])).lead_id as string
    const guy = await mk('Thirty Day Guy', '30 Day St', '4145550401')
    const lady = await mk('Six Month Lady', '6 Month Rd', '4145550402')
    const signer = await mk('Contract Carl', '7 Sign Ln', '4145550403')
    const later = await mk('Not Yet Nate', '8 Soon Ave', '4145550404')
    await r(`public.agent_mark_card($1, 'not_now', 'renovating first, said call back in a month', '2026-11-25T16:00:00Z', null, 'Muse sender')`, [guy])
    await r(`public.agent_mark_card($1, 'held', 'waiting on probate letters, lawyer said about six months', '2027-04-26T16:00:00Z', null, 'Muse sender')`, [lady])
    await r(`public.agent_mark_card($1, 'not_now', 'after the holidays', '2027-01-15T16:00:00Z', null, 'Muse sender')`, [later])
    const cid = (await one<{ id: string }>(`insert into public.contracts (lead_id, form, status, terms, buyer_name, buyer_signed_at, offer_path, offer_sha256, created_at) values ($1, 'wb11', 'sent', '{}'::jsonb, 'Colin Merrill', '2026-10-20T15:00:00Z', 'offers/test.pdf', 'abc', '2026-10-20T15:00:00Z') returning id`, [signer])).id
    await db.query(`insert into public.contract_signers (contract_id, position, name, phone, token_hash, expires_at) values ($1, 1, 'Carl Contract', '4145550403', 'h', now() + interval '30 days')`, [cid])
    const at = async (iso: string) => ((await r(`public.agent_due_today($1::timestamptz)`, [iso])).due) as { lead_id: string; what: string; why: string; days_late: number }[]
    const oct27 = (await at('2026-10-27T15:00:00Z')).filter((x) => [guy, lady, signer, later].includes(x.lead_id))
    expect(oct27.map((x) => [x.what, x.lead_id])).toEqual([['contract_waiting', signer]])
    expect(oct27[0].why).toMatch(/contract sent Oct 20, not signed \(Carl Contract still to sign\)/)
    const nov26 = (await at('2026-11-26T15:00:00Z')).filter((x) => x.lead_id === guy)
    expect(nov26).toHaveLength(1)
    expect(nov26[0]).toMatchObject({ what: 'check_back', why: 'renovating first, said call back in a month' })
    const may = (await at('2027-05-01T15:00:00Z')).filter((x) => [lady, later].includes(x.lead_id)).map((x) => [x.lead_id, x.what])
    expect(may).toEqual(expect.arrayContaining([[lady, 'check_back'], [later, 'check_back']]))
    expect((await at('2026-11-26T15:00:00Z')).some((x) => x.lead_id === lady || x.lead_id === later)).toBe(false)
    const card = await r(`public.agent_card($1)`, [signer])
    expect((card.contracts as { status: string; signers: { name: string; signed_at: null }[] }[])[0]).toMatchObject({ status: 'sent', signers: [{ name: 'Carl Contract', signed_at: null }] })
  })

  it('the safety net: a card with no date, an unanswered reply, an unlogged call, a stale text, an unknown caller and a misfiled dormant card are all caught', async () => {
    const mk = async (name: string, addr: string, phone: string) => (await r(`public.agent_add_prospect($1::jsonb, 'Muse intake')`,
      [JSON.stringify({ owner_name: name, address: addr, phones: [phone] })])).lead_id as string
    const nodate = await mk('No Date Ned', '1 Lost St', '4145550501')
    await db.query(`update public.leads set belt = 'yes_unbooked', stage = 'colin_call', next_stop_at = null, named_date = null, next_action_at = null where id = $1`, [nodate])
    const quiet = await mk('Quiet Quentin', '2 Lost St', '4145550502')
    await db.query(`insert into public.twilio_inbound (sid, from10, to_number, body, is_opt_out, lead_id, received_at) values ('SMq1', '4145550502', '+12624180202', 'Sure, what do you need?', false, $1, now() - interval '3 hours')`, [quiet])
    const call = await mk('Unlogged Ulla', '3 Lost St', '4145550503')
    await db.query(`update public.leads set human_takeover_at = now() - interval '5 hours', human_takeover_key = 'k-ulla' where id = $1`, [call])
    const stale = await mk('Stale Stan', '4 Lost St', '4145550504')
    await db.query(`insert into public.planned_openers (plan_date, wpie_owner_id, attempt, lead_id, lane, phone, body, step, send_status, window_start_utc, window_end_utc)
      select current_date - 2, wpie_owner_id, 1, id, 'agent', '+14145550504', 'x STOP', 1, 'planned', now() - interval '50 hours', now() - interval '40 hours' from public.leads where id = $1`, [stale])
    await db.query(`insert into public.twilio_inbound (sid, from10, to_number, body, is_opt_out, lead_id, received_at) values ('SMu1', '4145559876', '+12624180202', 'Who is this?', false, null, now() - interval '1 hour')`)
    const dorm = await mk('Dormant Dora', '5 Lost St', '4145550505')
    await db.query(`insert into public.twilio_inbound (sid, from10, to_number, body, is_opt_out, lead_id, received_at) values ('SMd1', '4145550505', '+12624180202', 'Why are you asking?', false, $1, now() - interval '2 days')`, [dorm])
    await db.query(`insert into public.messages (lead_id, direction, channel, body, from_number, to_number, status, sent_at, source_key) values ($1, 'out', 'sms', 'Fair question', '+12624180202', '+14145550505', 'delivered', now() - interval '47 hours', 'test:dora')`, [dorm])
    await db.query(`update public.leads set belt = 'dormant', belt_entered_at = now() - interval '46 hours' where id = $1`, [dorm])
    const fine = await mk('Fine Fiona', '6 Found St', '4145550506')
    await db.query(`update public.leads set belt = 'yes_unbooked', stage = 'colin_call', next_stop_at = now() + interval '1 day' where id = $1`, [fine])

    const net = ((await r(`public.agent_due_today()`)).stuck) as { lead_id?: string; what: string; why: string }[]
    const whats = (id: string) => net.filter((x) => x.lead_id === id).map((x) => x.what)
    expect(whats(nodate)).toEqual(['no_next_step'])
    expect(whats(quiet)).toEqual(['reply_unanswered'])
    expect(whats(call)).toEqual(['unlogged_call'])
    expect(whats(stale)).toEqual(['text_stale'])
    expect(whats(dorm)).toEqual(['dormant_replied'])
    expect(net.filter((x) => x.what === 'unknown_caller').map((x) => x.why)).toEqual(expect.arrayContaining([expect.stringContaining('4145559876')]))
    expect(whats(fine)).toEqual([])
    expect(await one(`select public.warm_stuck_count() as n`)).toMatchObject({ n: net.length })
  })

  it('check-back dates: a year out is refused, a Sunday rolls to Monday, a hold with no date comes back in 45 days', async () => {
    const mk = async (name: string, addr: string, phone: string) => (await r(`public.agent_add_prospect($1::jsonb, 'Muse intake')`,
      [JSON.stringify({ owner_name: name, address: addr, phones: [phone] })])).lead_id as string
    const a = await mk('Far Fred', '1 Date St', '4145550601'); const b = await mk('Sunday Sue', '2 Date St', '4145550602'); const c = await mk('Held Hal', '3 Date St', '4145550603')
    expect(await r(`public.agent_mark_card($1, 'not_now', 'maybe in two years', (now() + interval '400 days')::timestamptz, null, 'Muse sender')`, [a])).toMatchObject({ ok: false })
    await r(`public.agent_mark_card($1, 'not_now', 'after the holidays', '2027-01-03T16:00:00Z', null, 'Muse sender')`, [b])   // a Sunday
    expect(await one(`select to_char(next_action_at at time zone 'America/Chicago', 'Dy') as d from public.leads where id = $1`, [b])).toEqual({ d: 'Mon' })
    await r(`public.agent_mark_card($1, 'held', 'waiting on the estate attorney', null, null, 'Muse sender')`, [c])
    expect(await one(`select (named_date::date - current_date)::int as days from public.leads where id = $1`, [c])).toEqual({ days: 45 })
  })

  it('the time-of-day test: a pm text waits for 5 PM, an am text queued after noon waits for 9 AM tomorrow; scored by slot', async () => {
    const mk = async (name: string, addr: string, phone: string) => (await r(`public.agent_add_prospect($1::jsonb, 'Muse intake')`,
      [JSON.stringify({ owner_name: name, address: addr, phones: [phone], mailing_state: 'WI' })])).lead_id as string
    const a = await mk('Am Amy', '1 Slot St', '4145550701'); const p = await mk('Pm Pat', '2 Slot St', '4145550702')
    const tue1pm = '2026-10-27T18:00:00Z'                          // Tuesday 1 PM Central
    await db.exec(`update public.campaign_control set window_start = '09:00'`)   // the live window since 2026-10-26
    const qa = await r(`public.agent_queue_text($1, '4145550701', $2, 1, null, 'Muse sender', $3::timestamptz, 'A', 'own_q', 'am')`, [a, OPENER, tue1pm])
    const qp = await r(`public.agent_queue_text($1, '4145550702', $2, 1, null, 'Muse sender', $3::timestamptz, 'B', 'intent_q', 'pm')`, [p, OPENER, tue1pm])
    expect(new Date(qa.goes_after as string).toISOString()).toBe('2026-10-28T14:00:00.000Z')     // Wed 9 AM Central
    expect(new Date(qp.goes_after as string).toISOString()).toBe('2026-10-27T22:00:00.000Z')     // Tue 5 PM Central
    expect(qp).toMatchObject({ slot: 'pm' })
    expect(await r(`public.agent_queue_text($1, '4145550701', $2, 1, null, 'Muse sender', $3::timestamptz, 'A', 'own_q', 'noon')`, [a, OPENER, tue1pm]))
      .toMatchObject({ status: 'refused' })
    expect(await one(`select per_hour from public.planned_openers where lead_id = $1`, [p])).toEqual({ per_hour: 100 })
    expect(await one(`select per_hour from public.planned_openers where lead_id = $1`, [a])).toEqual({ per_hour: 270 })
    const t = await r(`public.agent_test_results(14, 1)`)
    expect((t.slots as { slot: string }[]).map((x) => x.slot)).toEqual(expect.arrayContaining(['am', 'pm']))
    expect((t.cells as { cell: string }[]).map((x) => x.cell)).toEqual(expect.arrayContaining(['A/am', 'B/pm']))
    await db.exec(`update public.campaign_control set window_start = '10:00'`)
  })

  it('the agent can lift only its own pause', async () => {
    expect(await r(`public.agent_pause('carrier errors', 'Muse sender')`)).toEqual({ paused: true })
    expect(await r(`public.agent_resume('Muse sender')`)).toEqual({ paused: false })
    await db.exec(`update public.campaign_control set paused = true, pause_reason = 'Colin: holiday'`)
    expect(await r(`public.agent_resume('Muse sender')`)).toMatchObject({ paused: true, refused: expect.stringContaining('only the app') })
  })
})
