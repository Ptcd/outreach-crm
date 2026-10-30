// The agent door (Colin 2026-10-25: "design it agent first"): the MCP routing and key roles, the wording check, and on
// the real migrations a key Colin makes, an intake agent's prospect becoming a card, a sender agent's text queued
// inside the recipient's window and then claimed by the same send check the laptop's texts pass.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'
import { TOOLS, channelAuthor, handleMessage, keyFrom, keyFromUrl, textProblem, type Agent, type DoorDb } from '../supabase/functions/_shared/agentDoor'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')
const COLIN = { sub: '00000000-0000-0000-0000-00000000000c', email: 'colin@example.com' }
const OPENER = "Hi Pat, Colin Merrill here. Are you still the owner of 12 Maple St? Reply STOP if you'd rather not hear from me."

const fakeDb = (over: Partial<DoorDb> = {}): DoorDb => ({
  addProspect: async () => ({ status: 'created', lead_id: 'L1' }), findProspects: async () => [], prospectCounts: async () => ({}),
  status: async () => ({ paused: false }), readyToText: async () => [], queueText: async () => ({ status: 'queued', text_id: 'T1' }),
  queue: async () => [], withdraw: async () => true, pause: async () => ({ paused: true }), resume: async () => ({ paused: false }),
  results: async () => ({}), testResults: async () => ({}), repliesWaiting: async () => [], markCard: async () => ({ ok: true }), dueToday: async () => ({ due: [], stuck: [] }), records: async () => ({}), linkCards: async () => ({ ok: true }), sendReply: async () => ({ outcome: 'sent' }),
  textTemplates: async () => ({}), setTextTemplate: async () => ({ ok: true }), markPerson: async () => ({ ok: true }), ...over,
})
const intake = { id: 'k1', name: 'Muse intake', role: 'intake' as const }
const sender = { id: 'k2', name: 'Muse sender', role: 'sender' as const }
const call = async (agent: Agent, name: string, args: unknown, db = fakeDb()) => {
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
  it('a Dots key with only the channel scope: the desk channel tools and nothing else, posting as Dots; the key may ride in the URL', async () => {
    const dots: Agent = { id: 'k10', name: 'Dots', role: 'agent', scopes: ['channel'] }
    const names = ((await handleMessage({ jsonrpc: '2.0', id: 4, method: 'tools/list' }, dots, fakeDb())) as
      { result: { tools: { name: string }[] } }).result.tools.map((t) => t.name)
    expect(names.sort()).toEqual(['desk_decide', 'desk_inbox', 'desk_post'])
    expect((await call(dots, 'mark_card', { lead_id: 'x', mark: 'note', reason: 'r' })).isError).toBe(true)
    const seen: { fn: string; args: Record<string, unknown> }[] = []
    const db = fakeDb({ records: async (fn: string, args: Record<string, unknown>) => { seen.push({ fn, args }); return { ok: true } } })
    await call(dots, 'desk_post', { kind: 'note', body: 'hello from Dots' }, db)
    await call({ id: 'k9', name: 'Muse', role: 'agent' }, 'desk_inbox', {}, db)
    expect(seen.map((s) => [s.fn, s.args.p_author ?? s.args.p_for])).toEqual([['desk_post', 'dots'], ['desk_read', 'muse']])
    expect([channelAuthor(dots), channelAuthor({ ...dots, name: 'OpenAI dot' }), channelAuthor({ ...dots, name: 'Muse' }), channelAuthor({ ...dots, name: 'Anecdotes' })])
      .toEqual(['dots', 'dots', 'muse', 'muse'])
    const k = 'wpie_agent_' + 'a'.repeat(64)
    expect(keyFromUrl(`https://x.supabase.co/functions/v1/agent-mcp/k/${k}`)).toBe(k)
    expect(keyFromUrl(`https://x.supabase.co/functions/v1/agent-mcp?key=${k}`)).toBe(k)
    expect(keyFromUrl('https://x.supabase.co/functions/v1/agent-mcp/k/not-a-key')).toBeNull()
    expect(keyFrom(new Headers())).toBeNull()
  })
  it('a key over its budget for a tool is refused before the tool runs, and the refusal is logged', async () => {
    const muse: Agent = { id: 'k9', name: 'Muse', role: 'agent' }
    const log: { tool: string; ok: boolean; error: string | null }[] = []
    let ran = 0
    const db = fakeDb({ rateCheck: async (tool: string) => tool === 'find_prospects' ? 'rate limit: find_prospects may be called 30 times a minute per key' : null,
      find: async () => { ran++; return [] }, logCall: async (c) => { log.push(c) } })
    const refused = await call(muse, 'find_prospects', { address: 'x' }, db)
    expect(refused).toMatchObject({ isError: true, value: { error: expect.stringContaining('rate limit') } })
    expect(ran).toBe(0)
    expect((await call(muse, 'sending_status', {}, db)).isError).toBe(false)
    expect(log.map((c) => [c.tool, c.ok])).toEqual([['find_prospects', false], ['sending_status', true]])
    // a check that itself fails never blocks the call
    const db2 = fakeDb({ rateCheck: async () => { throw new Error('db away') }, find: async () => [] })
    expect((await call(muse, 'find_prospects', { address: 'x' }, db2)).isError).toBe(false)
  })
  it('one key with scopes: it sees and calls only what its scopes allow, and every call is logged with its scope', async () => {
    const muse: Agent = { id: 'k9', name: 'Muse', role: 'agent', scopes: ['texting', 'records'] }
    const names = ((await handleMessage({ jsonrpc: '2.0', id: 3, method: 'tools/list' }, muse, fakeDb())) as
      { result: { tools: { name: string }[] } }).result.tools.map((t) => t.name)
    expect(names).toEqual(expect.arrayContaining(['queue_texts', 'records_list', 'records_set_request', 'text_templates', 'set_text_template']))
    for (const n of ['add_prospects', 'mark_card', 'due_today', 'open_slots']) expect(names).not.toContain(n)
    const log: { tool: string; scope: string | null; ok: boolean; error: string | null }[] = []
    const db = fakeDb({ logCall: async (c) => { log.push(c) } })
    const refused = await call(muse, 'add_prospects', { prospects: [{ owner_name: 'x' }] }, db)
    expect(refused).toMatchObject({ isError: true, value: { error: expect.stringContaining('no prospects scope') } })
    expect((await call(muse, 'records_overview', {}, db)).isError).toBe(false)
    expect((await call({ ...muse, scopes: [...muse.scopes!, 'calendar'] }, 'open_slots', {}, db)).isError).toBe(true)   // calendar not wired here
    expect(log.map((c) => [c.tool, c.scope, c.ok])).toEqual([['add_prospects', 'prospects', false], ['records_overview', 'records', true], ['open_slots', 'calendar', false]])
    expect(log[0].error).toMatch(/no prospects scope/)
    const all: Agent = { id: 'k8', name: 'Muse', role: 'agent' }        // no scopes given: all five
    expect((await call(all, 'mark_card', { lead_id: 'L1', mark: 'hot' })).isError).toBe(false)
  })
  it('set_text_template and records_set_request reach the database with the agent name', async () => {
    const muse: Agent = { id: 'k9', name: 'Muse', role: 'agent' }
    let seen: unknown = null
    const db = fakeDb({ setTextTemplate: async (t, a) => { seen = { ...t, a }; return { ok: true, version: 2 } }, records: async (fn, args) => ({ fn, args }) })
    expect((await call(muse, 'set_text_template', { variant: 'b', wording: 'Hi. Reply STOP', note: 'Colin: shorter' }, db)).value).toEqual({ ok: true, version: 2 })
    expect(seen).toMatchObject({ variant: 'B', wording: 'Hi. Reply STOP', note: 'Colin: shorter', a: 'Muse' })
    expect((await call(muse, 'records_set_request', { kind: 'treasurer', name: 'Test County Treasurer', categories: ['tax_delinquency'], cadence_days: 30 }, db)).value)
      .toEqual({ fn: 'records_set_request', args: { p: { kind: 'treasurer', name: 'Test County Treasurer', categories: ['tax_delinquency'], cadence_days: 30 }, p_agent: 'Muse' } })
  })
  it('person marks go to the person; a dnc with no person is the whole card, as before', async () => {
    const seen: string[] = []
    const db = fakeDb({ markPerson: async (m) => { seen.push(`person:${m.mark}:${m.interest_id ?? m.phone}`); return { ok: true } },
      markCard: async (m) => { seen.push(`card:${m.mark}`); return { ok: true } } })
    await call(sender, 'mark_card', { lead_id: 'L1', mark: 'deceased', interest_id: 'I1' }, db)
    await call(sender, 'mark_card', { lead_id: 'L1', mark: 'dnc', phone: '4145550100' }, db)
    await call(sender, 'mark_card', { lead_id: 'L1', mark: 'wrong_person', phone: '4145550101' }, db)
    await call(sender, 'mark_card', { lead_id: 'L1', mark: 'dnc' }, db)
    await call(sender, 'mark_card', { lead_id: 'L1', mark: 'dead', reason: 'retail' }, db)
    expect(seen).toEqual(['person:deceased:I1', 'person:dnc:4145550100', 'person:wrong_person:4145550101', 'card:dnc', 'card:dead'])
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
    // a follow-up may leave the STOP line out (Colin 2026-10-29); the other rules still hold on every step
    expect(textProblem('Hi Pat, Thalia again about 12 Maple St. Still the owner there? Just checking I have the right place.', 2)).toBeNull()
    expect(textProblem('Hi Pat, Thalia again about 12 Maple St. Still the owner there?', 1)).toMatch(/first text needs a STOP/)
    expect(textProblem('Thalia again. We buy for cash.', 2)).toMatch(/cash/)
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

  it('the queue takes a follow-up without a STOP line and refuses a first text without one (0143, Colin 2026-10-30)', async () => {
    const p = { owner_name: 'Sam Follow', address: '9 Elm Ct', city: 'Waukesha', zip: '53186', county: 'Waukesha', mailing_state: 'WI',
      phones: [{ number: '4145550777', type: 'mobile', name: 'Sam Follow' }] }
    const a = await r(`public.agent_add_prospect($1::jsonb, 'Muse intake')`, [JSON.stringify(p)])
    const noStop = 'Hi Sam, Colin again about 9 Elm Ct. Still the owner there? Just making sure I have the right person.'
    const tue = '2026-10-27T17:00:00Z'
    expect(await r(`public.agent_queue_text($1, '4145550777', $2, 1, null, 'Muse sender', $3::timestamptz)`, [a.lead_id, noStop, tue]))
      .toMatchObject({ status: 'refused', reason: expect.stringContaining('needs a STOP line') })
    expect(await r(`public.agent_queue_text($1, '4145550777', $2, 2, null, 'Muse sender', $3::timestamptz, 'G')`, [a.lead_id, noStop, tue]))
      .toMatchObject({ status: 'queued' })
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

  it('"do we already have them?": an address the laptop has (spelled differently) merges into that card; a phone on another card is attached and reported', async () => {
    const lap = (await one<{ id: string }>(`insert into public.leads (wpie_owner_id, owner_name, property_address, property_zip, stage)
      values (888, 'SMITH JOHN', '1205 NORTH STATE STREET', '54911', 'opener_queued') returning id`)).id
    await db.query(`insert into public.contacts (lead_id, kind, value, value_normalized) values ($1, 'phone', '9205550111', '9205550111')`, [lap])
    const res = await r(`public.agent_add_prospect($1::jsonb, 'Muse intake')`, [JSON.stringify({ owner_name: 'John Smith',
      address: '1205 N State St', zip: '54911', phones: ['920-555-0112', '920-555-0111'], reasons: [{ kind: 'vacant', label: 'Vacant' }] })])
    expect(res).toMatchObject({ status: 'already_have', lead_id: lap, phones_added: ['9205550112'], existing: { source: 'laptop', texted: false } })
    const elsewhere = await r(`public.agent_add_prospect($1::jsonb, 'Muse intake')`, [JSON.stringify({ owner_name: 'Jane Roe',
      address: '9 Other Rd', phones: ['9205550112'] })])
    expect(elsewhere.status).toBe('created')
    // one card per property, numbers belong to people (2026-10-27): never dropped, attached and reported as also on the other card
    expect(elsewhere).toMatchObject({ phones_added: ['9205550112'], phones_skipped: [] })
    expect((elsewhere.interests as { phones_added: { also_on: { lead_id: string }[] }[] }[])[0].phones_added[0].also_on).toEqual([{ lead_id: lap, address: '1205 NORTH STATE STREET' }])
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

  it('one agent key: all six scopes by default, Colin switches one off, the switch holds, calls are counted', async () => {
    await db.query(`select set_config('request.jwt.claims', $1, false)`, [JSON.stringify(COLIN)])
    await db.exec('set role authenticated')
    const key = (await one<{ k: string }>(`select public.create_agent_key('Muse', 'agent') as k`)).k
    const id = (await one<{ id: string }>(`select id from public.list_agent_keys() where name = 'Muse' and revoked_at is null`)).id
    await db.exec('reset role')
    expect(key).toMatch(/^wpie_agent_/)
    expect(await r(`public.agent_key_check($1)`, [key])).toMatchObject({ ok: true, role: 'agent', scopes: ['prospects', 'texting', 'calendar', 'records', 'marks', 'channel'] })
    await db.query(`select set_config('request.jwt.claims', '', false)`)
    await expect(db.query(`select public.set_agent_key_scopes($1, array['texting'])`, [id])).rejects.toThrow(/only Colin/)
    await db.query(`select set_config('request.jwt.claims', $1, false)`, [JSON.stringify(COLIN)])
    await db.exec('set role authenticated')
    await one(`select public.set_agent_key_scopes($1, array['texting', 'records', 'marks'])`, [id])
    await expect(db.query(`select public.set_agent_key_scopes($1, array['everything'])`, [id])).rejects.toThrow(/scopes are/)
    await db.exec('reset role')
    expect(await r(`public.agent_key_check($1)`, [key])).toMatchObject({ scopes: ['texting', 'records', 'marks'] })
    await db.query(`select public.agent_log_call($1, 'queue_texts', 'texting', true, null, 40)`, [id])
    await db.query(`select public.agent_log_call($1, 'add_prospects', 'prospects', false, 'this key has no prospects scope', 2)`, [id])
    await db.exec('set role authenticated')
    const row = await one(`select calls_24h::int c, refused_24h::int f, scopes from public.list_agent_keys() where id = $1`, [id])
    await db.exec('reset role')
    expect(row).toEqual({ c: 2, f: 1, scopes: ['texting', 'records', 'marks'] })
    await db.query(`select set_config('request.jwt.claims', '', false)`)
    // an old single-role key keeps what its role had
    const old = (await one<{ key_sha256: string }>(`insert into public.agent_keys (name, role, key_sha256, key_hint) values ('old intake', 'intake',
      encode(sha256(convert_to('wpie_intake_old', 'UTF8')), 'hex'), '_old') returning key_sha256`))
    expect(old).toBeTruthy()
    expect(await r(`public.agent_key_check('wpie_intake_old')`)).toMatchObject({ role: 'intake', scopes: ['prospects', 'marks'] })
  })

  it('first-text wording is versioned: a change opens v2, texts carry their version, test_results reports by version', async () => {
    const t0 = await r(`public.agent_text_templates()`)
    expect((t0.active as { variant: string; name: string; version: number }[]).map((x) => [x.variant, x.name, x.version])).toEqual([['A', 'own_q', 1], ['B', 'intent_q', 1]])
    expect(await r(`public.agent_set_text_template('B', 'intent_q', 'I''m looking to buy a house around {city}. Would you sell {address}?', 'Colin: test', 'Muse')`))
      .toMatchObject({ ok: false, reason: expect.stringContaining('STOP') })
    expect(await r(`public.agent_set_text_template('B', 'intent_q', 'Would you take cash for {address}? Reply STOP', 'Colin: test', 'Muse')`)).toMatchObject({ ok: false })
    expect(await r(`public.agent_set_text_template('B', 'intent_q', 'Is {address} yours? Reply STOP', '', 'Muse')`)).toMatchObject({ ok: false })
    const before = await one<{ n: number }>(`select count(*)::int n from public.planned_openers where variant = 'B' and template_version = 1`)
    expect(await r(`public.agent_set_text_template('B', 'intent_q_short', 'Hi {First}, Colin Merrill here. Thinking of selling {address}? Reply STOP if you''d rather not hear from me.', 'Colin 10/26: B stops 5x A', 'Muse')`))
      .toMatchObject({ ok: true, variant: 'B', version: 2 })
    const t1 = await r(`public.agent_text_templates()`)
    expect((t1.active as { variant: string; version: number }[]).find((x) => x.variant === 'B')).toMatchObject({ version: 2, name: 'intent_q_short' })
    expect((t1.history as { variant: string; version: number; to: string | null }[]).filter((x) => x.variant === 'B').map((x) => [x.version, x.to !== null]))
      .toEqual([[1, true], [2, false]])
    expect(await one<{ n: number }>(`select count(*)::int n from public.planned_openers where variant = 'B' and template_version = 1`)).toEqual(before)   // history kept
    const lead = (await r(`public.agent_add_prospect($1::jsonb, 'Muse intake')`,
      [JSON.stringify({ owner_name: 'Vee Version', address: '3 Wording Way', phones: ['4145550801'], mailing_state: 'WI' })])).lead_id as string
    const q = await r(`public.agent_queue_text($1, '4145550801', $2, 1, null, 'Muse sender', '2026-10-27T15:00:00Z'::timestamptz, 'B', 'intent_q_short')`, [lead, OPENER])
    expect(q).toMatchObject({ status: 'queued' })
    expect(await one(`select template_version from public.planned_openers where lead_id = $1`, [lead])).toEqual({ template_version: 2 })
    const t = await r(`public.agent_test_results(14, 1)`)
    const v = (t.versions as { version: string; ran_from: string | null; ran_to: string | null; name: string }[])
    expect(v.find((x) => x.version === 'B v2')).toMatchObject({ name: 'intent_q_short', ran_to: null })
    expect(v.find((x) => x.version === 'B v1')?.ran_to).toBeTruthy()
  })

  it('the next phone: when the first text bounces, a first text may go to the next phone on the card, and its follow-ups follow it', async () => {
    const lid = (await r(`public.agent_add_prospect($1::jsonb, 'Muse intake')`,
      [JSON.stringify({ owner_name: 'Tom Nextphone', address: '9 Retry Rd', phones: ['4145550901', '4145550902', '4145550903'], mailing_state: 'WI' })])).lead_id as string
    const tue = '2026-10-27T20:00:00Z'                                   // Tuesday 3 PM Central
    await db.exec(`update public.planned_openers set send_status = 'withdrawn' where send_status in ('planned', 'would_send')`)
    const q1 = await r(`public.agent_queue_text($1, '4145550901', $2, 1, null, 'Muse sender', $3::timestamptz, 'A', 'own_q')`, [lid, OPENER, tue])
    expect(q1).toMatchObject({ status: 'queued', next_phone: false })
    // it went out; no delivery result yet: the next phone waits
    await db.query(`update public.planned_openers set send_status = 'sent', claim_mode = 'live', claimed_at = $2::timestamptz, sent_at = $2::timestamptz where id = $1`, [q1.text_id, tue])
    await db.query(`update public.leads set stage = 'opener_sent' where id = $1`, [lid])
    expect(await r(`public.agent_queue_text($1, '4145550902', $2, 1, null, 'Muse sender', $3::timestamptz, 'A', 'own_q')`, [lid, OPENER, tue]))
      .toMatchObject({ status: 'refused', reason: expect.stringContaining('may have arrived') })
    // the carrier says undelivered and the bounce marks the phone bad: the next phone may have a first text
    await db.query(`update public.planned_openers set send_status = 'undelivered', error_code = '30003' where id = $1`, [q1.text_id])
    await db.query(`update public.contacts set status = 'bad' where lead_id = $1 and value_normalized = '4145550901'`, [lid])
    const q2 = await r(`public.agent_queue_text($1, '4145550902', $2, 1, null, 'Muse sender', $3::timestamptz, 'A', 'own_q')`, [lid, OPENER, tue])
    expect(q2).toMatchObject({ status: 'queued', next_phone: true })
    expect(await one(`select attempt, step from public.planned_openers where id = $1`, [q2.text_id])).toEqual({ attempt: 2, step: 1 })
    expect(await r(`public.agent_queue_text($1, '4145550901', $2, 1, null, 'Muse sender', $3::timestamptz)`, [lid, OPENER, tue])).toMatchObject({ status: 'refused' })
    // the send check lets it through (it would have said owner_already_texted)
    const claim = await r(`public.claim_next_opener(true, $1::timestamptz)`, [tue])
    expect(claim).toMatchObject({ outcome: 'would_send', opener: { id: q2.text_id } })
    // it is delivered: no third phone, and the follow-up belongs to the phone that got it
    await db.query(`update public.planned_openers set send_status = 'delivered', claim_mode = 'live', sent_at = $2::timestamptz where id = $1`, [q2.text_id, tue])
    expect(await r(`public.agent_queue_text($1, '4145550903', $2, 1, null, 'Muse sender', $3::timestamptz)`, [lid, OPENER, tue]))
      .toMatchObject({ status: 'refused', reason: expect.stringContaining('may have arrived') })
    const f2 = await r(`public.agent_queue_text($1, '4145550902', $2, 2, '2026-10-30T15:00:00Z', 'Muse sender', $3::timestamptz)`, [lid, OPENER, tue])
    expect(f2.status).toBe('queued')
    expect(await one(`select attempt, step from public.planned_openers where id = $1`, [f2.text_id])).toEqual({ attempt: 22, step: 2 })
    // a reply from the good phone ends the next-phone path for good
    await db.query(`update public.planned_openers set send_status = 'undelivered' where id = $1`, [q2.text_id])
    await db.exec(`insert into public.twilio_inbound (sid, from10, to_number, body, is_opt_out, received_at) values ('SMnp1', '4145550902', '+12624180202', 'who is this', false, '2026-10-27T21:00:00Z')`)
    expect(await r(`public.next_phone_problem($1, '4145550903')`, [lid])).toBe('they texted back from a good phone')
    await db.exec(`update public.planned_openers set send_status = 'withdrawn' where send_status in ('planned', 'would_send')`)
  })

  it('a dead card the laptop closed only because its phones bounced reopens for the next phone; a real close stays closed', async () => {
    const tue = '2026-10-27T20:00:00Z'
    await db.query(`select set_config('request.jwt.claims', '', false)`)     // the laptop sync, not a person in the app
    const card = async (name: string, nums: string[]) => {
      const id = (await r(`public.agent_add_prospect($1::jsonb, 'Muse intake')`,
        [JSON.stringify({ owner_name: name, address: `${nums[0].slice(-3)} Closed Ct`, phones: nums, mailing_state: 'WI' })])).lead_id as string
      await db.query(`update public.contacts set line_type = 'mobile' where lead_id = $1`, [id])
      return id
    }
    // first text out and bounced, phone marked bad, then the laptop closes the card (through the sync: no person)
    const bounce = async (id: string, num: string, status = 'undelivered', code = '30003') => {
      const q = await r(`public.agent_queue_text($1, $2, $3, 1, null, 'Muse sender', $4::timestamptz)`, [id, num, OPENER, tue])
      expect(q.status).toBe('queued')
      await db.query(`update public.planned_openers set send_status = $2, error_code = $3, claim_mode = 'live', claimed_at = $4::timestamptz, sent_at = $4::timestamptz where id = $1`,
        [q.text_id, status, code, tue])
      if (status !== 'delivered') await db.query(`update public.contacts set status = 'bad' where lead_id = $1 and value_normalized = $2`, [id, num])
      await db.query(`update public.leads set stage = 'closed_no_contact' where id = $1`, [id])
      await db.query(`update public.leads set stage = 'dead', dead_reason = 'no_contact' where id = $1`, [id])
    }
    await db.exec(`update public.planned_openers set send_status = 'withdrawn' where send_status in ('planned', 'would_send')`)
    const a = await card('Dee Deadphone', ['4145550951', '4145550952', '4145550953'])
    await db.query(`update public.contacts set line_type = 'landline' where lead_id = $1 and value_normalized = '4145550953'`, [a])
    await bounce(a, '4145550951')
    const q = (n: string, id = a) => r(`public.agent_queue_text($1, $2, $3, 1, null, 'Muse sender', $4::timestamptz, 'A', 'own_q', 'pm')`, [id, n, OPENER, tue])
    expect(await q('4145550953')).toMatchObject({ status: 'refused', reason: expect.stringContaining('phone not textable (landline') })
    expect(await q('4145550951')).toMatchObject({ status: 'refused', reason: 'phone already tried on this card' })
    expect(await r(`public.agent_queue_text($1, '4145550952', $2, 2, null, 'Muse sender', $3::timestamptz)`, [a, OPENER, tue]))
      .toMatchObject({ status: 'refused', reason: 'card is closed (dead)' })            // only a first text reopens
    const ok = await q('4145550952')
    expect(ok).toMatchObject({ status: 'queued', next_phone: true, reopened: true })
    const after = await one<Record<string, unknown>>(`select stage::text, belt, dead_reason, reopened_at is not null as reopened, reopened_reason, notes from public.leads where id = $1`, [a])
    expect(after).toMatchObject({ stage: 'opener_queued', belt: null, dead_reason: null, reopened: true })
    expect(after.reopened_reason).toMatch(/every first text bounced \(30003\); next phone 4145550952/)
    expect(after.notes).toMatch(/reopened by Muse/)
    expect(await one(`select source from public.lead_stage_events where lead_id = $1 and to_stage = 'opener_queued' order by id desc limit 1`, [a]))
      .toEqual({ source: 'agent: delivery-failure reopen' })
    expect(await one(`select count(*)::int n from public.belt_events where lead_id = $1 and event = 'reopened'`, [a])).toEqual({ n: 1 })
    const claim = await r(`public.claim_next_opener(true, '2026-10-27T22:30:00Z'::timestamptz)`)
    expect(claim).toMatchObject({ outcome: 'would_send', opener: { id: ok.text_id } })
    // controls: a delivered text, a reply from the dead phone, a person's close, a filtered (30007) text
    const b = await card('Del Ivered', ['4145550961', '4145550962'])
    await bounce(b, '4145550961', 'delivered', '')
    expect(await q('4145550962', b)).toMatchObject({ status: 'refused', reason: expect.stringContaining('was delivered') })
    const c = await card('Rep Lied', ['4145550971', '4145550972'])
    await bounce(c, '4145550971')
    await db.exec(`insert into public.twilio_inbound (sid, from10, to_number, body, is_opt_out, received_at) values ('SMrl1', '4145550971', '+12624180202', 'not interested', false, '2026-10-27T21:00:00Z')`)
    expect(await q('4145550972', c)).toMatchObject({ status: 'refused', reason: 'card has a reply' })
    const d = await card('Hugh Mann', ['4145550981', '4145550982'])
    await bounce(d, '4145550981')
    await db.query(`update public.leads set dead_reason = 'not_interested' where id = $1`, [d])
    expect(await q('4145550982', d)).toMatchObject({ status: 'refused', reason: 'card is closed (dead)' })
    const e = await card('Phil Tered', ['4145550991', '4145550992'])
    await bounce(e, '4145550991', 'undelivered', '30007')
    await db.query(`update public.contacts set status = 'ok' where lead_id = $1`, [e])
    expect(await q('4145550992', e)).toMatchObject({ status: 'refused', reason: expect.stringContaining('not a dead number') })
    await db.exec(`update public.planned_openers set send_status = 'withdrawn' where send_status in ('planned', 'would_send')`)
  })

  it('the desk channel: the desk asks, Muse in charge decides and reviews letters, Colin keeps money and can switch the grant off', async () => {
    const q = await r(`public.desk_post('desk', 'muse', 'question', 'record cards', 'Send the Butler letter?', '[{"id":"send","label":"Send it"},{"id":"hold","label":"Hold"}]'::jsonb)`)
    expect(q).toMatchObject({ ok: true })
    expect(await r(`public.desk_post('desk', 'muse', 'question', 't', 'one option only', '[{"id":"a","label":"A"}]'::jsonb)`)).toMatchObject({ ok: false })
    const inbox = await r(`public.desk_read('muse', 0, true)`) as { open_questions: { id: number }[]; in_charge: { muse_in_charge: boolean; colin_only: string[] } }
    expect(inbox.in_charge.muse_in_charge).toBe(true)
    expect(inbox.in_charge.colin_only.join(' ')).toContain('money')
    expect(inbox.open_questions.map((x) => x.id)).toContain(q.id)
    expect(await r(`public.desk_decide($1, 'maybe', 'x', 'muse')`, [q.id])).toMatchObject({ ok: false, reason: expect.stringContaining('send, hold') })
    expect(await r(`public.desk_decide($1, 'send', '', 'muse')`, [q.id])).toMatchObject({ ok: false })
    expect(await r(`public.desk_decide($1, 'send', 'it closes 25 unit legs at no cost', 'muse')`, [q.id])).toMatchObject({ ok: true, choice: 'send' })
    expect(await r(`public.desk_decide($1, 'hold', 'again', 'muse')`, [q.id])).toMatchObject({ ok: false, reason: expect.stringContaining('answered') })
    expect(await one(`select status, choice, decided_by from public.desk_messages where id = $1`, [q.id]))
      .toEqual({ status: 'answered', choice: 'send', decided_by: "Muse (in charge, Colin's delegation)" })
    const req = (await one<{ id: string }>(`insert into public.records_requests (kind, name, to_email) values ('municipal', 'Desk test office', 'clerk@example.gov') returning id`)).id
    const draft = async (purpose: string, body: string) => (await one<{ id: string }>(
      `insert into public.records_drafts (request_id, purpose, to_email, subject, body, status, written_by) values ($1, $2, 'clerk@example.gov', 's', $3, 'draft', 'Claude (laptop desk)') returning id`,
      [req, purpose, body])).id
    const plain = await draft('request', 'Please send the property record cards. Records Desk')
    const money = await draft('request', 'We will pay the $20 fee. Records Desk')
    const fee = await draft('fee', 'Please narrow the charge. Records Desk')
    // nothing auto-sends: a first request still waits for a review; Muse in charge may release it, never money or a fee letter
    expect(await one(`select public.records_draft_standing($1) s`, [plain])).toEqual({ s: 'a first request: Colin approves it in the app' })
    expect(await one(`select public.records_muse_may_release($1) s`, [plain])).toEqual({ s: null })
    expect(await one(`select public.records_muse_may_release($1) s`, [money])).toEqual({ s: 'mentions money: Colin approves it' })
    expect((await one<{ s: string }>(`select public.records_muse_may_release($1) s`, [fee])).s).toContain('Colin approves it')
    await db.exec(`update public.campaign_delegation set muse_in_charge = false`)
    expect(await one(`select public.records_muse_may_release($1) s`, [plain])).toEqual({ s: 'a first request: Colin approves it in the app' })
    const q2 = await r(`public.desk_post('desk', 'muse', 'question', 't', 'b', '[{"id":"a","label":"A"},{"id":"b","label":"B"}]'::jsonb)`)
    expect(await r(`public.desk_decide($1, 'a', 'why', 'muse')`, [q2.id])).toMatchObject({ ok: false, reason: expect.stringContaining('waits for him') })
    await db.exec(`update public.campaign_delegation set muse_in_charge = true`)
    const q3 = await r(`public.desk_post('desk', 'all', 'question', 't', 'b', '[{"id":"a","label":"A"},{"id":"b","label":"B"}]'::jsonb)`)
    expect(await r(`public.desk_post('dots', 'desk', 'note', 't', 'my view: a', null, $1)`, [q3.id])).toMatchObject({ ok: true })
    expect(await r(`public.desk_decide($1, 'a', 'why', 'dots')`, [q3.id])).toMatchObject({ ok: false, reason: expect.stringContaining("Muse's") })
    expect(await r(`public.desk_decide($1, 'a', 'Dots agrees', 'muse')`, [q3.id])).toMatchObject({ ok: true })
  })

  it('the rate limit counts a key\'s calls to one tool in the last minute; the work tools have none', async () => {
    const kid = (await one<{ id: string }>(`insert into public.agent_keys (name, role, key_sha256, key_hint, created_by) values ('rate', 'agent', 'rate', 'rate', 'colin') returning id`)).id
    expect(await one(`select public.agent_rate_check($1, 'find_prospects') s`, [kid])).toEqual({ s: null })
    for (let i = 0; i < 30; i++) await db.query(`select public.agent_log_call($1, 'find_prospects', 'prospects', true, null, 5)`, [kid])
    expect((await one<{ s: string }>(`select public.agent_rate_check($1, 'find_prospects') s`, [kid])).s).toMatch(/30 times a minute.*30 in the last minute/)
    expect(await one(`select public.agent_rate_check($1, 'sending_status') s`, [kid])).toEqual({ s: null })
    for (let i = 0; i < 200; i++) await db.query(`select public.agent_log_call($1, 'queue_texts', 'texting', true, null, 5)`, [kid])
    expect(await one(`select public.agent_rate_check($1, 'queue_texts') s`, [kid])).toEqual({ s: null })
    await db.query(`update public.agent_calls set at = now() - interval '2 minutes' where key_id = $1`, [kid])
    expect(await one(`select public.agent_rate_check($1, 'find_prospects') s`, [kid])).toEqual({ s: null })
  })
  it('a seller calling back rings only the caller who dialed them; otherwise the shift (inbound_call_ring, 2026-10-29)', async () => {
    const a = await r(`public.agent_add_prospect($1::jsonb, 'Muse intake')`, [JSON.stringify({ owner_name: 'Ring Test', address: '9 Ring Rd', city: 'Waukesha', zip: '53186', county: 'Waukesha', mailing_state: 'WI', phones: ['4145550777'] })])
    const wk = '2026-10-28T19:30:00Z'   // Wednesday 2:30 PM CT: Thalia's shift
    expect(await r(`public.inbound_call_ring('+1 (414) 555-0777', $1::timestamptz)`, [wk])).toEqual({ ring: ['thalia'], return_call: false, dialed_by: null })
    expect(await r(`public.inbound_call_ring('4145550777', '2026-10-28T22:00:00Z'::timestamptz)`)).toMatchObject({ ring: ['thalia', 'adil'], return_call: false })   // weekday 5 PM: both in Power hour
    expect(await one(`select public.on_shift_person('2026-10-28T22:30:00Z'::timestamptz)::text s`)).toEqual({ s: 'adil' })   // weekday 5:30 PM is Adil's hour (0140)
    expect(await one(`select public.on_shift_person('2026-10-28T21:30:00Z'::timestamptz)::text s`)).toEqual({ s: 'thalia' })
    expect(await r(`public.inbound_call_ring('4145550777', '2026-10-25T15:00:00Z'::timestamptz)`)).toMatchObject({ ring: ['adil'] })   // Saturday
    expect(await r(`public.inbound_call_ring('4145550777', '2026-10-28T04:00:00Z'::timestamptz)`)).toMatchObject({ ring: ['colin', 'thalia', 'adil'] })   // 11 PM
    await db.query(`insert into public.belt_events (lead_id, event, payload, at, by) values ($1, 'human_call_started', '{"phone": "4145550777", "source": "app"}', '2026-10-28T22:05:00Z', 'Adil')`, [a.lead_id])
    expect(await r(`public.inbound_call_ring('+14145550777', '2026-10-28T22:06:00Z'::timestamptz)`)).toEqual({ ring: ['adil'], return_call: true, dialed_by: 'adil' })
    expect(await r(`public.inbound_call_ring('+14145550777', '2026-10-29T00:00:00Z'::timestamptz)`)).toMatchObject({ return_call: false })   // two hours later it is no longer a return call
  })

  it('a missed call belongs to the caller who dialed that number out (7 days), else the shift (missed_call_person, 0144)', async () => {
    const tue10 = '2026-10-27T15:00:00Z'      // Tuesday 10 AM CT: Thalia's shift
    expect(await one(`select public.missed_call_person('4145550991', $1::timestamptz)::text p`, [tue10])).toEqual({ p: 'thalia' })
    expect(await one(`select public.missed_call_person('4145550991', '2026-10-25T15:00:00Z'::timestamptz)::text p`)).toEqual({ p: 'adil' })   // Saturday
    const lid = (await one<{ id: string }>(`select id from public.leads where owner_name = 'Pat Sample'`)).id
    await db.query(`insert into public.belt_events (lead_id, event, payload, at, by) values ($1, 'human_call_started', '{"phone": "+14145550991"}', '2026-10-24T21:00:00Z', 'Adil')`, [lid])
    // Adil dialed it Friday 4 PM: his call-back on Tuesday morning too, not Thalia's
    expect(await one(`select public.missed_call_person('(414) 555-0991', $1::timestamptz)::text p`, [tue10])).toEqual({ p: 'adil' })
    // eight days on, the dial is forgotten and the shift decides again
    expect(await one(`select public.missed_call_person('4145550991', '2026-11-03T15:00:00Z'::timestamptz)::text p`)).toEqual({ p: 'thalia' })
    // a later dial by Thalia takes it over
    await db.query(`insert into public.belt_events (lead_id, event, payload, at, by) values ($1, 'human_call_started', '{"phone": "4145550991"}', '2026-10-26T20:00:00Z', 'Thalia')`, [lid])
    expect(await one(`select public.missed_call_person('4145550991', $1::timestamptz)::text p`, [tue10])).toEqual({ p: 'thalia' })
  })

  it('a missed seller call for a caller is listed for an email once, at their alert email or sign-in email (0139)', async () => {
    const a = await r(`public.agent_add_prospect($1::jsonb, 'Muse intake')`, [JSON.stringify({ owner_name: 'Missed Caller', address: '7 Ring Rd', city: 'Waukesha', zip: '53186', county: 'Waukesha', mailing_state: 'WI', phones: ['4145550778'] })])
    await db.exec(`insert into public.team_members (email, role, person, display_name) values ('thalia@example.com', 'caller', 'thalia', 'Thalia') on conflict do nothing`)
    const tid = (await one<{ id: string }>(`insert into public.tasks (lead_id, due_at, kind, owner, title, source) values ($1, now(), 'call', 'thalia', 'They called us: call back', 'belt') returning id`, [a.lead_id])).id
    await db.query(`insert into public.inbound_calls (call_sid, lead_id, from10, to_number, status, voicemail, task_id) values ('CAtest1', $1, '4145550778', '+12624180202', 'missed', false, $2)`, [a.lead_id, tid])
    const rows = await r(`public.missed_calls_to_alert()`) as { call_sid: string; person: string; email: string | null; owner_name: string }[]
    expect(rows).toHaveLength(1)
    // the sign-in address is not a mailbox: with no alert_email the row says so (0144), it does not fall back
    expect(rows[0]).toMatchObject({ call_sid: 'CAtest1', person: 'thalia', email: null, owner_name: 'Missed Caller' })
    await db.exec(`update public.team_members set alert_email = 'thalia.alerts@example.com' where person = 'thalia'`)
    expect(((await r(`public.missed_calls_to_alert()`)) as { email: string }[])[0].email).toBe('thalia.alerts@example.com')
    await db.exec(`update public.team_members set alert_whatsapp = '+923246343665' where person = 'thalia'`)
    expect(((await r(`public.missed_calls_to_alert()`)) as { whatsapp: string }[])[0].whatsapp).toBe('+923246343665')
    await db.query(`select set_config('request.jwt.claims', $1, false)`, [JSON.stringify({ sub: '00000000-0000-0000-0000-00000000000c', email: 'thalia@example.com' })])
    expect(await one(`select (public.set_person_alerts('thalia', '', '', '634 3665')->>'reason') s`)).toEqual({ s: expect.stringContaining('country code') })
    expect(await one(`select (public.set_person_alerts('thalia', '', '', '+92 324 6343665')->>'whatsapp') s`)).toEqual({ s: '+923246343665' })
    await db.exec(`select public.missed_call_alerted('CAtest1')`)
    expect(await r(`public.missed_calls_to_alert()`)).toEqual([])
    // Colin's own missed calls are not emailed here: his cell already gets the forwarding app's text
    await db.query(`update public.tasks set owner = 'colin' where id = $1`, [tid])
    await db.query(`update public.inbound_calls set alerted_at = null where call_sid = 'CAtest1'`)
    expect(await r(`public.missed_calls_to_alert()`)).toEqual([])
  })

  it('an unknown caller\'s missed call alerts the shift with no card; WhatsApp alerts are logged and deduped 15 minutes (0145)', async () => {
    await db.exec(`insert into public.team_members (email, role, person, display_name) values ('thalia@example.com', 'caller', 'thalia', 'Thalia') on conflict do nothing`)
    await db.exec(`update public.team_members set alert_email = 'thalia.alerts@example.com', alert_whatsapp = '+639753125183' where person = 'thalia'`)
    await db.query(`insert into public.inbound_calls (call_sid, lead_id, from10, to_number, status, voicemail, created_at) values ('CAunknown1', null, '4145550666', '+12624180202', 'missed', false, '2026-10-27T15:00:00Z')`)
    const rows = await r(`public.missed_calls_to_alert('2026-10-27T16:00:00Z'::timestamptz)`) as { call_sid: string; person: string; lead_id: string | null; owner_name: string | null; email: string; whatsapp: string }[]
    const u = rows.find((x) => x.call_sid === 'CAunknown1')!
    expect(u).toMatchObject({ person: 'thalia', lead_id: null, owner_name: null, email: 'thalia.alerts@example.com', whatsapp: '+639753125183' })   // Tuesday 10 AM: Thalia's shift
    // the alert log: one per caller per unknown number per 15 minutes
    const b1 = await r(`public.whatsapp_alert_begin('CAunknown1', null, '4145550666', 'thalia', '+639753125183', '{"1": "(414) 555-0666", "2": "unknown property", "3": "10:00 AM"}'::jsonb)`) as { ok: boolean; id: string }
    expect(b1.ok).toBe(true)
    await db.exec(`select public.whatsapp_alert_finish('${b1.id}', 'sent', 'wamid.TEST1', null)`)
    expect(await r(`public.whatsapp_alert_begin('CAunknown2', null, '4145550666', 'thalia', '+639753125183', null)`)).toMatchObject({ ok: false, reason: 'duplicate' })
    expect(await r(`public.whatsapp_alert_begin('CAunknown2', null, '4145550667', 'thalia', '+639753125183', null)`)).toMatchObject({ ok: true })   // another number: its own alert
    expect(await one(`select status, message_id from public.whatsapp_alerts where id = $1`, [b1.id])).toEqual({ status: 'sent', message_id: 'wamid.TEST1' })
    // the template status cache
    expect(await r(`public.meta_wa_template_get('missed_call_alert')`)).toBeNull()
    await db.exec(`select public.meta_wa_template_set('missed_call_alert', 'PENDING')`)
    expect(await r(`public.meta_wa_template_get('missed_call_alert')`)).toMatchObject({ status: 'PENDING' })
  })

  it('the agent can lift only its own pause', async () => {
    expect(await r(`public.agent_pause('carrier errors', 'Muse sender')`)).toEqual({ paused: true })
    expect(await r(`public.agent_resume('Muse sender')`)).toEqual({ paused: false })
    await db.exec(`update public.campaign_control set paused = true, pause_reason = 'Colin: holiday'`)
    expect(await r(`public.agent_resume('Muse sender')`)).toMatchObject({ paused: true, refused: expect.stringContaining('only the app') })
  })
})
