// Call desk on the real migrations (PGlite), as a signed-in team member: phone lookup by the last
// digits, a new-caller card, script answers saved on the lead (next step sets the next action),
// and "log this call" with each outcome (do not contact blocks every phone like a STOP).
// Plus the call answers -> walk gate suggestions.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, beforeEach, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'
import { gateFromCall, stopsFromCall, type CallFacts } from '../src/lib/callGate'
import { CALL_SCRIPT, PHONE_SCRIPT, callScript } from '../src/lib/callScript'

const MIGRATION = readdirSync(path.resolve(__dirname, '../supabase/migrations')).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.resolve(__dirname, '../supabase/migrations', f), 'utf8')).join('\n')
const ADIL = { sub: '00000000-0000-0000-0000-0000000000ad', email: 'adil@example.com' }
const A = '00000000-0000-0000-0000-0000000000a1'
const B = '00000000-0000-0000-0000-0000000000b2'
let db: PGlite

async function call<T = Record<string, unknown>>(sql: string, params: unknown[] = []): Promise<T> {
  await db.query(`select set_config('request.jwt.claims', $1, false)`, [JSON.stringify(ADIL)])
  await db.exec('set role authenticated')
  try { return (await db.query<{ r: T }>(sql, params)).rows[0].r } finally { await db.exec('reset role') }
}
const one = async <T>(sql: string) => (await db.query<T>(sql)).rows[0]

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
  await db.exec(`insert into public.team_members (email, role, person, display_name) values ('adil@example.com', 'owner', 'adil', 'Adil')`)
})

beforeEach(async () => {
  await db.exec(`
    truncate public.messages, public.contacts, public.suppressed_phones, public.leads cascade;
    insert into public.leads (id, wpie_owner_id, owner_name, property_address, municipality, lane, stage) values
      ('${A}', 1, 'JOHN W PANKIEWICZ JR', '2825 S LOGAN AV', 'Milwaukee', 'hold', 'opener_sent'),
      ('${B}', 2, 'RITA SCHMIDT', '100 N MAIN ST', 'Waukesha', 'flip', 'opener_sent');
    insert into public.contacts (lead_id, kind, value, value_normalized, person_name) values
      ('${A}', 'phone', '4144776435', '4144776435', 'JOHN PANKIEWICZ'),
      ('${A}', 'phone', '4145550001', '4145550001', null),
      ('${B}', 'phone', '2625556435', '2625556435', 'RITA SCHMIDT');
  `)
})

describe('call desk', () => {
  it('finds owners by the last 4 digits, lists a shared suffix, and narrows on more digits', async () => {
    const four = await call<{ lead_id: string; owner_name: string; property_address: string; lane: string; stage: string }[]>(
      `select public.phone_lookup('6435') as r`)
    expect(four.map((x) => x.owner_name).sort()).toEqual(['JOHN W PANKIEWICZ JR', 'RITA SCHMIDT'])
    expect(four.find((x) => x.lead_id === A)).toMatchObject({ property_address: '2825 S LOGAN AV', lane: 'hold', stage: 'opener_sent' })
    const more = await call<unknown[]>(`select public.phone_lookup('776435') as r`)
    expect(more).toHaveLength(1)
    const full = await call<{ exact: boolean }[]>(`select public.phone_lookup('(414) 477-6435') as r`)
    expect(full).toEqual([expect.objectContaining({ lead_id: A, exact: true })])
    expect(await call(`select public.phone_lookup('12') as r`)).toEqual([])
    expect(await call(`select public.phone_lookup('9999') as r`)).toEqual([])
  })

  it('makes a card from a text with no card, ties that number\'s drafts and texts to it, and reuses it', async () => {
    await db.exec(`
      insert into public.twilio_inbound (sid, from10, to_number, body, received_at) values
        ('SMx1', '4147930000', '+12624180202', 'Derek here, you inquired about 1 Sample St', now());
      insert into public.reply_drafts (id, phone10, our_number, inbound_sid, inbound_body, inbound_at, kind, status, body) values
        ('00000000-0000-0000-0000-0000000000d1', '4147930000', '+12624180202', 'SMx1', 'Derek here, you inquired about 1 Sample St', now(),
         'candidate', 'awaiting_approval', 'Thanks for getting back to me.');
    `)
    const r = await call<{ ok: boolean; lead_id: string; existing: boolean }>(
      `select public.card_from_text('00000000-0000-0000-0000-0000000000d1') as r`)
    expect(r).toMatchObject({ ok: true, existing: false })
    expect(await one(`select owner_name, stage::text from public.leads where id = '${r.lead_id}'`))
      .toEqual({ owner_name: 'New texter (414) 793-0000', stage: 'colin_call' })
    expect(await one(`select lead_id from public.reply_drafts where id = '00000000-0000-0000-0000-0000000000d1'`)).toEqual({ lead_id: r.lead_id })
    expect(await one(`select lead_id from public.twilio_inbound where sid = 'SMx1'`)).toEqual({ lead_id: r.lead_id })
    expect(await call(`select public.card_from_text('00000000-0000-0000-0000-0000000000d1') as r`))
      .toMatchObject({ ok: true, lead_id: r.lead_id, existing: true })
  })

  it('makes a new-caller card once, and finds an existing number instead', async () => {
    expect(await call(`select public.new_caller('9999', null) as r`)).toMatchObject({ ok: false })
    const n = await call<{ ok: boolean; lead_id: string; existing: boolean }>(`select public.new_caller('262-555-0199', null) as r`)
    expect(n).toMatchObject({ ok: true, existing: false })
    expect(await one(`select owner_name, stage::text from public.leads where id = '${n.lead_id}'`))
      .toEqual({ owner_name: 'New caller (262) 555-0199', stage: 'colin_call' })
    expect(await call(`select public.new_caller('2625550199', 'Bob') as r`)).toMatchObject({ lead_id: n.lead_id, existing: true })
    expect(await call(`select public.new_caller('4144776435', null) as r`)).toMatchObject({ lead_id: A, existing: true })
    expect(await call<unknown[]>(`select public.phone_lookup('0199') as r`)).toHaveLength(1)
  })

  it('saves script answers on the lead; the next step books the walk-through', async () => {
    await call(`select public.call_answer('${A}', 'motivation', '{"choices":["tired_landlord"],"text":"done with tenants"}') as r`)
    await call(`select public.call_answer('${A}', 'next_step', '{"choices":["walk"],"kind":"walk","at":"2026-10-23T20:00:00Z","when":"2026-10-23T20:00:00Z"}') as r`)
    const l = await one<{ call_facts: CallFacts; stage: string; next_action: string; next_action_at: string }>(
      `select call_facts, stage::text, next_action, to_char(next_action_at at time zone 'UTC', 'YYYY-MM-DD HH24:MI') next_action_at from public.leads where id = '${A}'`)
    expect(l.call_facts.motivation).toMatchObject({ value: { choices: ['tired_landlord'], text: 'done with tenants' }, by: 'Adil' })
    expect(l).toMatchObject({ stage: 'walkthrough_booked', next_action: 'Walk-through' })
    expect(l.next_action_at).toBe('2026-10-23 20:00')
    await call(`select public.call_answer('${A}', 'motivation', 'null') as r`)
    expect((await one<{ call_facts: CallFacts }>(`select call_facts from public.leads where id = '${A}'`)).call_facts.motivation).toBeUndefined()
    expect(await call(`select public.call_answer('${A}', 'Bad Key!', '{}') as r`)).toMatchObject({ ok: false })
  })

  it('logs each outcome on the history and moves the stage', async () => {
    const outcome = async (o: string, note: string | null = null) => {
      await call(`select public.log_call('${A}', '4144776435', '${o}', ${note ? `'${note}'` : 'null'}) as r`)
      return (await one<{ stage: string }>(`select stage::text from public.leads where id = '${A}'`)).stage
    }
    expect(await outcome('interested', 'wants Colin to call')).toBe('colin_call')
    expect(await outcome('not_now')).toBe('follow_up')
    expect(await outcome('not_interested')).toBe('dead')
    expect(await outcome('wrong_number')).toBe('data_fix')
    expect((await one<{ status: string }>(`select status::text from public.contacts where value_normalized = '4144776435'`)).status).toBe('bad')
    const m = (await db.query<{ body: string; channel: string; seen_at: string | null }>(
      `select body, channel::text, seen_at::text from public.messages where lead_id = '${A}' order by sent_at, body`)).rows
    expect(m).toHaveLength(4)
    expect(m.every((x) => x.channel === 'call' && x.seen_at)).toBe(true)
    expect(m.map((x) => x.body)).toContain('Call (Adil) from 4144776435: Interested\nwants Colin to call')
    expect(await call(`select public.log_call('${A}', null, 'maybe', null) as r`)).toMatchObject({ ok: false })
  })

  it('"do not contact" blocks every phone of the owner, like a texted STOP', async () => {
    await call(`select public.log_call('${A}', '4144776435', 'dnc', 'asked never to be called') as r`)
    expect((await db.query<{ phone10: string; reason: string; source: string }>(`select phone10, reason, source from public.suppressed_phones order by 1`)).rows)
      .toEqual([{ phone10: '4144776435', reason: 'dnc_call', source: 'app' }, { phone10: '4145550001', reason: 'dnc_call', source: 'app' }])
    expect((await db.query<{ suppressed: boolean; dnc_app: boolean }>(`select suppressed, dnc_app from public.contacts where lead_id = '${A}'`)).rows
      .every((c) => c.suppressed && c.dnc_app)).toBe(true)
    expect((await one<{ stage: string }>(`select stage::text from public.leads where id = '${A}'`)).stage).toBe('dnc')
    expect((await one<{ suppressed: boolean }>(`select suppressed from public.contacts where lead_id = '${B}'`)).suppressed).toBe(false)
    const look = await call<{ lead_id: string; blocked: boolean }[]>(`select public.phone_lookup('6435') as r`)
    expect(look.find((x) => x.lead_id === A)?.blocked).toBe(true)
  })

  it('is for the team only', async () => {
    await db.query(`select set_config('request.jwt.claims', '{}', false)`)
    await db.exec('set role anon')
    try {
      await expect(db.query(`select public.phone_lookup('6435')`)).rejects.toThrow(/permission denied/)
    } finally { await db.exec('reset role') }
  })
})

describe('call answers -> walk gate', () => {
  const f = (o: Record<string, unknown>): CallFacts => Object.fromEntries(Object.entries(o).map(([k, v]) => [k, { value: v as never, at: '' }]))

  it('scores what the call settled and never suggests "numbers close"', () => {
    const h = gateFromCall(f({
      motivation: { choices: ['tired_landlord'] }, timeline: { choices: ['under_30'] },
      decision_makers: { choices: ['spouse'] }, all_at_walk: { choices: ['yes'] },
      price: { number: '150000', choices: ['own_need'] }, flexibility: { choices: ['terms'] },
      occupancy: { choices: ['tenants'] }, condition: { choices: ['roof'] },
    }))
    expect(Object.fromEntries(Object.entries(h).map(([k, v]) => [k, v!.score]))).toEqual({
      reason_and_clock: 2, decision_makers: 2, number_and_anchor: 2, flexibility: 1, condition: 2 })
    expect(h.numbers_close).toBeUndefined()
  })

  it('gives partial credit, reads the seller texts, and flags a listing as a hard stop', () => {
    const h = gateFromCall(f({ motivation: { choices: ['just_price'] }, timeline: { choices: ['no_rush'] }, price: { choices: ['online'], number: '200000' } }),
      { condition: 'roof is old' })
    expect(h.reason_and_clock?.score).toBe(0)
    expect(h.number_and_anchor?.score).toBe(1)
    expect(h.condition).toEqual({ score: 1, why: 'Condition known, occupancy not yet' })
    expect(gateFromCall(f({ price: { choices: ['refused'] } })).number_and_anchor?.score).toBe(0)
    expect(stopsFromCall(f({ other_buyer: { choices: ['listed'] } }))).toEqual(['listed_active'])
    expect(gateFromCall({}, null)).toEqual({})
  })

  it("asks the phone script in its order, every question tied to its gate items, in Colin's voice", () => {
    expect(CALL_SCRIPT.map((q) => q.qid)).toEqual(PHONE_SCRIPT.questions.map((q) => q.id))
    expect(CALL_SCRIPT.map((q) => q.id)).toEqual(['owner', 'interest', 'identity', 'motivation', 'layout', 'condition', 'occupancy', 'work_list', 'happened',
      'photos', 'timeline', 'decision_makers', 'price', 'anchor', 'flexibility', 'debt', 'behind', 'other_buyers', 'concerns', 'ready'])
    expect(CALL_SCRIPT.find((q) => q.id === 'motivation')?.gate).toEqual([1])
    expect(CALL_SCRIPT.find((q) => q.id === 'ready')?.gate).toEqual([2, 6])
    expect(CALL_SCRIPT.every((q) => q.choices?.length || q.text || q.number)).toBe(true)
    const all = JSON.stringify(PHONE_SCRIPT)
    expect(all).not.toMatch(/\bSam\b/)
    expect(PHONE_SCRIPT.objections).toHaveLength(24)
    // Thalia's packet (2026-10-27): her own name, Colin is "my partner", never as-is, never a number on the first call
    expect(all).not.toMatch(/I buy as-is|Colin Merrill's assistant|before I leave/)
    expect(callScript({ street: '2825 S Logan Av', first_name: 'John' })[0].say[0]).toBe('Are you still the owner of 2825 S Logan Av?')
  })

  it('firm on a real need is a 1, and an agent or a sale inside 14 days is a hard stop', () => {
    expect(gateFromCall(f({ anchor: { choices: ['own_need'] }, flexibility: { choices: ['firm'] } })).flexibility?.score).toBe(1)
    expect(gateFromCall(f({ anchor: { choices: ['online'] }, flexibility: { choices: ['firm'] } })).flexibility?.score).toBe(0)
    expect(gateFromCall(f({ decision_makers: { choices: ['spouse'] }, ready: { choices: ['yes'] } })).decision_makers?.score).toBe(2)
    expect(stopsFromCall(f({ identity: { choices: ['agent'] }, behind: { choices: ['sale_14'] } }))).toEqual(['listed_active', 'sheriff_inside_14_days'])
  })
})
