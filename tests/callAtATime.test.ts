// 0297 (Colin 2026-11-22: "Go review muses texting and tell me it's gonna get us deals", then "Go and then tell muse how
// it should work now"). 125 threads: about 20 real openings, a call asked for once. The rules told Muse to keep such a
// seller on text, and the booking tool it had needs a calendar that is not connected. Now: a call at a time with the
// card's caller, booked on the belt; replies checked for what lost threads; the comp is Grok's first.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'
import { callTool, TEXTING_RULES, TOOLS, type Agent, type DoorDb } from '../supabase/functions/_shared/agentDoor'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')

let db: PGlite
type Json = Record<string, any>
const TYLERS = '00000000-0000-0000-0000-00000000a701'   // Tyler's card: a seller who asks what we would pay
const THALIAS = '00000000-0000-0000-0000-00000000a702'  // Thalia's card: not the owner, a relative
const NOBODY = '00000000-0000-0000-0000-00000000a703'   // no caller
const MON_NOON = '2026-11-23T18:00:00Z'                  // Monday, noon Central
const MON_4PM = '2026-11-23T22:00:00Z'                   // Monday, 4 PM Central: both callers on
const records = async (fn: string, args: Record<string, unknown>) => {
  const keys = Object.keys(args)
  await db.exec('set role service_role')
  try {
    return (await db.query<{ r: unknown }>(`select public.${fn}(${keys.map((k, i) => `${k} => $${i + 1}`).join(', ')}) as r`,
      keys.map((k) => typeof args[k] === 'object' && args[k] !== null ? JSON.stringify(args[k]) : args[k]))).rows[0].r
  } finally { await db.exec('reset role') }
}
const muse: Agent = { id: 'k1', name: 'Muse', role: 'agent', scopes: ['marks', 'texting'], tools: null }
const call = async (name: string, args: Json = {}) => (await callTool(name, args, muse, { records } as unknown as DoorDb)) as { value: any; isError?: boolean }
const why = async (lead: string, body: string, now = MON_NOON) =>
  (await db.query<{ r: string | null }>(`select public.text_rule_problem($1, $2, 0, $3::timestamptz) as r`, [lead, body, now])).rows[0].r
const theySaid = (lead: string, from10: string, body: string, at: string) =>
  db.query(`insert into public.twilio_inbound (sid, from10, to_number, body, is_opt_out, lead_id, received_at) values ($1, $2, '+12624180202', $3, false, $4, $5::timestamptz)`,
    [`SM${Math.random().toString(36).slice(2)}`, from10, body, lead, at])
const weSaid = (lead: string, to10: string, body: string, at: string) =>
  db.query(`insert into public.messages (lead_id, direction, channel, body, from_number, to_number, status, sent_at) values ($1, 'out', 'sms', $2, '+12624180202', $3, 'delivered', $4::timestamptz)`,
    [lead, body, `+1${to10}`, at])

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
  await db.exec(`
    insert into public.team_members (email, role, person, display_name) values
      ('colin@example.com', 'owner', 'colin', 'Colin'), ('adil@example.com', 'caller', 'adil', 'Tyler'), ('thalia@example.com', 'caller', 'thalia', 'Thalia')
    on conflict (email) do update set role = excluded.role, person = excluded.person, display_name = excluded.display_name;
    insert into public.leads (id, wpie_owner_id, owner_name, lane, stage, property_address, municipality, county, mailing_state, locked_to, assigned_to) values
      ('${TYLERS}', 9711, 'JOHN SELLER', 'flip', 'reply_received', '2810 PORTER CT', 'VILLAGE OF TEST', 'Portage', 'WI', 'adil', 'adil'),
      ('${THALIAS}', 9712, 'ELLEN OWNER', 'flip', 'reply_received', '3524 TEST RD', 'CITY OF TEST', 'Racine', 'WI', 'thalia', 'thalia'),
      ('${NOBODY}', 9713, 'NO CALLER', 'flip', 'reply_received', '3 EMPTY CT', 'CITY OF TEST', 'Brown', 'NY', null, null);
    insert into public.contacts (lead_id, kind, value, value_normalized, line_type) values
      ('${TYLERS}', 'phone', '7155550101', '7155550101', 'mobile'), ('${THALIAS}', 'phone', '2625550102', '2625550102', 'mobile');`)
  await weSaid(TYLERS, '7155550101', 'Hi John, this is Tyler. Are you the current owner of 2810 PORTER CT? Reply STOP to opt out.', '2026-11-22T20:15:00Z')
  await theySaid(TYLERS, '7155550101', "I'm not sure. How much would you offer me for it", '2026-11-23T17:55:00Z')
}, 180_000)

describe('a seller who opens up is offered a call at a time', () => {
  it('the rules say so, and the old "stays with you by text" rule is gone', () => {
    expect(TEXTING_RULES).toMatch(/your NEXT reply offers a call/)
    expect(TEXTING_RULES).toMatch(/call_times gives the card's caller/)
    expect(TEXTING_RULES).toMatch(/Grok's first/)
    expect(TEXTING_RULES).not.toMatch(/stays with you by text \(Colin 2026-11-13\): the offer path takes them to a number with no call/)
    expect(TEXTING_RULES).not.toMatch(/Book a call with Colin only when the seller asks to talk to someone/)
    for (const n of ['call_times', 'book_call']) expect(TOOLS.find((t) => t.name === n)?.role).toBe('sender')
  })

  it('call_times: the card\'s caller, whether they are on now, and times in words; nothing for a card with no caller', async () => {
    const noon = await records('agent_call_times', { p_lead_id: TYLERS, p_now: MON_NOON }) as Json
    expect(noon).toMatchObject({ ok: true, caller: 'Tyler', on_now: false, seller_time_zone: 'America/Chicago' })
    expect(noon.suggest.map((s: Json) => s.say)).toEqual(['today at 2:00 PM', 'today at 3:00 PM', 'tomorrow at 2:00 PM'])
    expect(noon.say).toMatch(/does today at 2:00 PM work for a quick call\?/)
    const four = await records('agent_call_times', { p_lead_id: THALIAS, p_now: MON_4PM }) as Json
    expect(four).toMatchObject({ caller: 'Thalia', on_now: true })
    expect(four.suggest.map((s: Json) => s.say)).toEqual(['today at 4:30 PM', 'today at 5:30 PM', 'tomorrow at 3:30 PM'])   // 20 minutes out, on the quarter hour
    expect(four.say).toMatch(/Thalia is on the phones now.*call_next/i)
    // a day the caller is off is skipped
    await db.query(`insert into public.caller_off (person, day, note, set_by) values ('thalia', '2026-11-24', 'off', 'colin')`).catch(async () =>
      db.query(`select public.caller_off_set('thalia', '2026-11-24', 'off', 'colin')`))
    expect(((await records('agent_call_times', { p_lead_id: THALIAS, p_now: MON_4PM })) as Json).suggest.map((s: Json) => s.say)).toEqual(['today at 4:30 PM', 'today at 5:30 PM', 'Wednesday at 3:30 PM'])
    expect(await records('agent_call_times', { p_lead_id: '00000000-0000-0000-0000-00000000a7ff', p_now: MON_NOON })).toMatchObject({ ok: false, reason: 'no such card' })
  })

  it('book_call books it on the belt for the card\'s caller, and refuses a time the caller does not work', async () => {
    const bad = await records('agent_book_call', { p_lead_id: TYLERS, p_at: '2026-11-24T15:00:00Z', p_phone: '7155550101', p_words: 'sure', p_agent: 'Muse', p_now: MON_NOON }) as Json
    expect(bad).toMatchObject({ ok: false })                                                    // 9 AM Central
    expect(bad.reason).toBe('Tyler does not take calls then. Offer one of these instead.')
    expect(bad.suggest).toHaveLength(3)
    const ok = await records('agent_book_call', { p_lead_id: TYLERS, p_at: '2026-11-23T21:00:00Z', p_phone: '(715) 555-0101', p_words: 'Yes 3 works', p_agent: 'Muse', p_now: MON_NOON }) as Json
    expect(ok).toMatchObject({ ok: true, caller: 'Tyler' })
    expect(ok.say).toBe('Booked: Tyler calls them Monday at 3:00 PM their time. Confirm that time in one short reply, in the name this thread already uses, and say nothing about price.')
    const l = (await db.query<Json>(`select belt, named_event, named_date from public.leads where id = $1`, [TYLERS])).rows[0]
    expect(l).toMatchObject({ belt: 'call_booked', named_event: 'call' })
    expect(new Date(l.named_date).toISOString()).toBe('2026-11-23T21:00:00.000Z')
    const task = (await db.query<Json>(`select owner::text, due_at from public.tasks where lead_id = $1 and done_at is null order by created_at desc limit 1`, [TYLERS])).rows[0]
    expect(task.owner).toBe('adil')
    const note = (await db.query<{ body: string }>(`select body from public.messages where lead_id = $1 and channel = 'note' order by created_at desc limit 1`, [TYLERS])).rows[0].body
    expect(note).toBe('Call booked by text (Muse) for Monday Nov 23 at 3:00 PM their time, on (715) 555-0101. They wrote: "Yes 3 works"')
    // the door: a time with no offset is refused before it reaches the server
    expect((await call('book_call', { lead_id: TYLERS, at: 'tomorrow at 3', phone: '7155550101', words: 'ok' })).isError).toBe(true)
    expect((await call('call_times', { lead_id: '00000000-0000-0000-0000-00000000a7ff' })).isError).toBe(true)
  })
})

describe('what an agent may not write in a reply', () => {
  it('their trouble is not named until someone in the thread has', async () => {
    expect(await why(TYLERS, 'Saw 2810 Porter Ct is going through probate and wanted to ask if selling is something you are thinking about?')).toMatch(/names their trouble \(a probate\)/)
    expect(await why(TYLERS, "What's got you two thinking about it - is it the back taxes piling up, or are you just ready to be done with the place?")).toMatch(/names their trouble \(back taxes\)/)
    expect(await why(TYLERS, 'Your name came up in the county estate records, and this number was listed with it.')).toMatch(/names their trouble/)
    expect(await why(TYLERS, 'I look through public property records for houses around here, and that one came up.')).toBeNull()
    // once the seller raises it, it can be spoken of
    await theySaid(TYLERS, '7155550101', 'its in foreclosure, I know', '2026-11-23T17:56:00Z')
    expect(await why(TYLERS, 'Understood. Is the foreclosure the main reason you would sell?')).toBeNull()
  })

  it('no buyer but the writer, no claim to be a person, no price question after a no', async () => {
    expect(await why(TYLERS, 'let me run it by my buyer tonight and see what he says')).toMatch(/someone else is the buyer/)
    expect(await why(TYLERS, 'Depends on the deal - some I keep, some I pass to a partner.')).toMatch(/someone else is the buyer/)
    expect(await why(TYLERS, 'lol nah not spam, real person here. i do buy houses around here.')).toMatch(/do not claim to be a person/)
    expect(await why(TYLERS, 'fair enough - what number would work for you?')).toBeNull()             // they have not said no
    await theySaid(THALIAS, '2625550102', 'Not interested in selling', '2026-11-23T17:00:00Z')
    expect(await why(THALIAS, 'fair enough - what number would work for you?')).toBe('they just said they are not selling: do not ask for a price. Thank them, leave the door open in one line, and mark the card.')
    expect(await why(THALIAS, 'ok got it, thanks for letting me know. if anything changes down the road just text me here')).toBeNull()
  })

  it('one reply per text from them, never the same text twice; a number coming back is not held', async () => {
    await weSaid(TYLERS, '7155550101', 'depends on the shape it is in honestly. any big stuff wrong with it?', '2026-11-23T17:58:00Z')
    expect(await why(TYLERS, 'Depends on the shape it is in, honestly. Any big stuff wrong with it?')).toBe('you already sent this exact text 2 minutes ago and they have not written since')
    expect(await why(TYLERS, 'also, is anyone living there?')).toBe('you answered their last text 2 minutes ago and they have not written since: one reply per text from them. Wait for their answer.')
    expect(await why(TYLERS, 'also, is anyone living there?', '2026-11-23T18:30:00Z')).toBeNull()                     // half an hour on
    await theySaid(TYLERS, '7155550101', 'roof is bad', '2026-11-23T17:59:00Z')
    expect(await why(TYLERS, 'also, is anyone living there?')).toBeNull()                                              // they wrote again
  })

  it('someone who is not the owner is asked twice at most for another person\'s number', async () => {
    const ask3 = 'ah ok, tu papá entonces. ¿me puedes pasar su número? así hablo directo con él de la casa'
    await weSaid(THALIAS, '2625550102', 'Oh I\'m sorry. Are you related to the owner, or do you know how to get ahold of them?', '2026-11-22T22:41:00Z')
    await theySaid(THALIAS, '2625550102', 'I think is Juan the one who handle the house', '2026-11-23T17:10:00Z')
    expect(await why(THALIAS, 'Thanks, that helps. Do you have a number for Juan, or his last name?')).toBeNull()      // the second ask
    await weSaid(THALIAS, '2625550102', 'Thanks, that helps. Do you have a number for Juan, or his last name?', '2026-11-23T17:12:00Z')
    await theySaid(THALIAS, '2625550102', 'Es mi papá', '2026-11-23T17:30:00Z')
    expect(await why(THALIAS, ask3)).toMatch(/asked on this thread for someone else's number 2 times: do not ask again/)
    expect(await why(THALIAS, 'ok, gracias por decirme. no te molesto más.')).toBeNull()
    // a seller's own number, and "the numbers", are not that ask
    expect((await db.query<{ r: boolean }>(`select public.text_asks_for_a_number('I can''t get anywhere near that number') as r`)).rows[0].r).toBe(false)
    expect((await db.query<{ r: boolean }>(`select public.text_asks_for_a_number('Is this the best number to reach you at?') as r`)).rows[0].r).toBe(false)
  })
})

describe('the comp on a yes is Grok\'s first', () => {
  const live = async (who: string, now: string) => await records('agent_live_work', { p_now: now, p_who: who }) as Json
  it('Muse is handed the card only when Grok has been away ten minutes, or the card has waited twenty', async () => {
    const t0 = '2026-11-23T20:00:00Z'
    await db.query(`insert into public.text_offers (lead_id, opened_by, trigger, trigger_text, opened_at) values ($1, 'system', 'yes_to_selling', 'Yes I''ll sell it', $2::timestamptz)`, [THALIAS, t0])
    const grok = (await db.query<{ id: string }>(`insert into public.agent_keys (name, role, key_sha256, key_hint) values ('Grok', 'agent', 'x-grok', 'grok') returning id`)).rows[0].id
    // Grok has not been at the door: the card is Muse's at once, as before
    expect((await live('Muse', '2026-11-23T20:02:00Z')).live).toBe(1)
    // Grok is at the door: Muse is told it is with Grok, and Grok has it
    await db.query(`insert into public.agent_calls (key_id, tool, scope, ok, ms, at) values ($1, 'live_work', 'marks', true, 5, '2026-11-23T20:01:00Z')`, [grok])
    const m = await live('Muse', '2026-11-23T20:02:00Z')
    expect(m).toMatchObject({ live: 0, with_grok: 1 })
    expect(m.say).toMatch(/1 with Grok first/)
    expect((await live('Grok', '2026-11-23T20:02:00Z')).cards.map((c: Json) => c.lead_id)).toEqual([THALIAS])
    // twenty minutes on and still open: Muse gets it too
    await db.query(`insert into public.agent_calls (key_id, tool, scope, ok, ms, at) values ($1, 'live_work', 'marks', true, 5, '2026-11-23T20:19:00Z')`, [grok])
    expect((await live('Muse', '2026-11-23T20:21:00Z')).live).toBe(1)
  })
})

// 0299 (Muse, after its first pass under the new rules: "the helper doesn't expose the call-booking tools"). The door did
// offer them; Muse's own run calls a fixed set of tools. So the call offer rides on replies_waiting and send_reply.
describe('the call offer from the tools a texting run already has', () => {
  const LAST = '00000000-0000-0000-0000-00000000a704'
  const sent: Json[] = []
  const door = { records, sendReply: async (x: Json) => { sent.push(x); return { outcome: 'sent' } } } as unknown as DoorDb
  const tool = async (name: string, args: Json) => (await callTool(name, args, muse, door)) as { value: any; isError?: boolean }

  it('replies_waiting carries the call on the row; send_reply books the time, then sends the confirmation', async () => {
    await db.exec(`insert into public.leads (id, wpie_owner_id, owner_name, lane, stage, property_address, municipality, county, mailing_state, locked_to, assigned_to)
      values ('${LAST}', 9714, 'GEORGE SELLER', 'flip', 'reply_received', '432 W TEST ST', 'VILLAGE OF TEST', 'Pierce', 'WI', 'adil', 'adil');
      insert into public.contacts (lead_id, kind, value, value_normalized, line_type) values ('${LAST}', 'phone', '6125550177', '6125550177', 'mobile');`)
    await theySaid(LAST, '6125550177', "Yes I'll sell it. tomorrow afternoon is fine", new Date(Date.now() - 60_000).toISOString())
    const times = await records('agent_call_times', { p_lead_id: LAST }) as Json
    expect(times.ok).toBe(true)
    const row = ((await records('agent_replies_waiting', { p_days: 7 })) as Json[]).find((r) => r.lead_id === LAST)
    if (row) expect(row.call).toMatchObject({ ok: true, caller: 'Tyler' })
    const at = times.suggest[times.suggest.length - 1].at as string
    // a time with no offset is refused and nothing is sent
    expect((await tool('send_reply', { lead_id: LAST, phone: '6125550177', body: 'sounds good, talk then', book_call_at: 'tomorrow 3pm' })).isError).toBe(true)
    // a time the caller does not work: not booked, not sent, and the answer carries times to offer
    const off = await tool('send_reply', { lead_id: LAST, phone: '6125550177', body: 'sounds good, talk then', book_call_at: '2026-12-25T03:00:00-06:00' })
    expect(off.isError).toBe(true)
    expect(off.value.reason).toMatch(/^the call was not booked, so the reply was not sent/)
    expect(sent).toHaveLength(0)
    const ok = await tool('send_reply', { lead_id: LAST, phone: '6125550177', body: 'sounds good, talk then', book_call_at: at })
    expect(ok.isError).toBeFalsy()
    expect(ok.value).toMatchObject({ outcome: 'sent', call: { ok: true, caller: 'Tyler' } })
    expect(sent).toEqual([{ lead_id: LAST, phone: '6125550177', body: 'sounds good, talk then' }])
    expect((await db.query<Json>(`select belt from public.leads where id = $1`, [LAST])).rows[0].belt).toBe('call_booked')
    // the words that agree were the seller's latest text
    const note = (await db.query<{ body: string }>(`select body from public.messages where lead_id = $1 and channel = 'note' and body like 'Call booked by text%'`, [LAST])).rows[0].body
    expect(note).toMatch(/They wrote: "Yes I'll sell it\. tomorrow afternoon is fine"$/)
    expect(TEXTING_RULES).toMatch(/send_reply takes book_call_at/)
  })
})
