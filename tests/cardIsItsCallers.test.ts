// 0249 (Colin 2026-11-17, George White's card): a card is its caller's. An alert about a card goes to its caller and the
// owners only, and the other caller cannot text, dial or take over its thread. On the real migrations.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, beforeEach, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'
import { runHotAlerts, type HotPush } from '../supabase/functions/_shared/hotLeads'
import { mayTell, pushAll, type NotifyDeps, type NotifySummary, type PersonSub, type TellOf } from '../supabase/functions/_shared/notify'
import type { Rpc } from '../supabase/functions/_shared/sending'
import { cardCallerOf, mineOrNobodys } from '../src/lib/wpie'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')

let db: PGlite
const one = async <T>(sql: string, params: unknown[] = []) => (await db.query<{ r: T }>(`select ${sql} as r`, params)).rows[0].r
type Json = Record<string, any>
const NOW = '2026-11-17T23:22:00Z'                                    // Tuesday 5:22 PM Central
const GEORGE = '00000000-0000-0000-0000-00000000a001'                 // Thalia's card
const NOBODY = '00000000-0000-0000-0000-00000000a002'                 // no caller yet
const TYLERS = '00000000-0000-0000-0000-00000000a003'                 // Tyler's card, by assignment only
const as = async (email: string | null) => { await db.query(`select set_config('request.jwt.claims', $1, false)`, [email ? JSON.stringify({ email }) : '']) }
const rpc: Rpc = async (fn, args) => {
  const names = Object.keys(args)
  try {
    const r = await db.query<{ r: unknown }>(`select public.${fn}(${names.map((n, i) => `${n} => $${i + 1}`).join(', ')}) as r`, names.map((n) => args[n]))
    return { data: r.rows[0]?.r ?? null, error: null }
  } catch (e) { return { data: null, error: { message: String(e) } } }
}
// who is told, read the way the Edge Function reads it (notifyDeno.cardTell), on a fixed clock
const tell: TellOf = async (card) => {
  const r = card.lead ? await rpc('card_tell', { p_lead_id: card.lead, p_now: NOW }) : await rpc('draft_card_tell', { p_draft_id: card.draft, p_now: NOW })
  const d = r.data as Json | null
  if (r.error || !d) return { everyone: false, people: [], ownersOnly: true }
  return { everyone: d.everyone === true, people: d.people ?? [] }
}
const subs = async () => (await one<PersonSub[]>(`public.push_subscriptions_people()`))

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
  await db.exec(`
    insert into public.team_members (email, role, person, display_name, alert_email, alert_phone) values
      ('colin@example.com', 'owner', 'colin', 'Colin', null, null),
      ('thalia@example.com', 'caller', 'thalia', 'Thalia', 'thalia@example.com', '4145550101'),
      ('adil@example.com', 'caller', 'adil', 'Tyler', 'adil@example.com', '4145550102')
    on conflict (email) do update set role = excluded.role, person = excluded.person, display_name = excluded.display_name,
      alert_email = excluded.alert_email, alert_phone = excluded.alert_phone;
    insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000c1', 'colin@example.com'), ('00000000-0000-0000-0000-0000000000c2', 'adil@example.com');
    insert into public.push_subscriptions (endpoint, p256dh, auth, user_id) values
      ('https://push.example/colin', 'k', 'a', '00000000-0000-0000-0000-0000000000c1'),
      ('https://push.example/tyler', 'k', 'a', '00000000-0000-0000-0000-0000000000c2');
    insert into public.leads (id, wpie_owner_id, owner_name, lane, stage, property_address, municipality, mailing_state, locked_to, assigned_to) values
      ('${GEORGE}', 9001, 'GEORGE M TESTWHITE', 'flip', 'reply_received', '432 W TEST ST', 'VILLAGE OF TEST', 'WI', 'thalia', 'thalia'),
      ('${NOBODY}', 9002, 'NO CALLER YET', 'flip', 'reply_received', '1 TEST AV', 'CITY OF TEST', 'WI', null, 'colin'),
      ('${TYLERS}', 9003, 'TYLERS SELLER', 'flip', 'reply_received', '2 TEST AV', 'CITY OF TEST', 'WI', null, 'adil');
    -- a new card is given a caller at once (split_new_card); these two are the cards that have no lock
    update public.leads set locked_to = null, locked_at = null where id in ('${NOBODY}', '${TYLERS}');
    update public.leads set assigned_to = 'colin' where id = '${NOBODY}';
    update public.leads set assigned_to = 'adil' where id = '${TYLERS}';
    insert into public.contacts (lead_id, kind, value, value_normalized, line_type) values
      ('${GEORGE}', 'phone', '6125550177', '6125550177', 'mobile'), ('${TYLERS}', 'phone', '6125550188', '6125550188', 'mobile');
    insert into public.messages (lead_id, direction, channel, body, status, provider_sid, from_number, to_number, sent_at) values
      ('${GEORGE}', 'out', 'sms', 'Hi George, this is Thalia. Are you the current owner of 432 W TEST ST? Reply STOP to opt out.', 'delivered', 'SM-g1', '+12625550843', '+16125550177', now() - interval '4 days');`)
}, 120_000)
beforeEach(async () => {
  await as(null)
  await db.exec(`delete from public.caller_off; delete from public.tasks where lead_id = '${GEORGE}'; delete from public.hot_alerts;
    update public.leads set locked_to = null, locked_at = null, assigned_to = 'colin' where id = '${NOBODY}';
    update public.leads set human_takeover_at = null, human_takeover_by = null, human_takeover_key = null, human_takeover_phone = null where id = '${GEORGE}'`)
})

describe('whose card it is', () => {
  it('the lock when it names a caller, else the assignment when it names a caller, else nobody', async () => {
    expect(await one<string | null>(`public.card_caller($1)::text`, [GEORGE])).toBe('thalia')
    expect(await one<string | null>(`public.card_caller($1)::text`, [TYLERS])).toBe('adil')
    expect(await one<string | null>(`public.card_caller($1)::text`, [NOBODY])).toBeNull()
    expect(cardCallerOf({ locked_to: 'thalia', assigned_to: 'adil' })).toBe('thalia')
    expect(cardCallerOf({ locked_to: null, assigned_to: 'adil' })).toBe('adil')
    expect(cardCallerOf({ locked_to: null, assigned_to: 'colin' })).toBeNull()
  })
  it('a caller\'s lists show their own cards and cards with no caller, never the other caller\'s', () => {
    expect(mineOrNobodys('adil', 'thalia')).toBe(false)
    expect(mineOrNobodys('adil', 'adil')).toBe(true)
    expect(mineOrNobodys('adil', null)).toBe(true)
    expect(mineOrNobodys('adil', undefined)).toBe(false)             // still being read: wait, do not show
    expect(mineOrNobodys(null, 'thalia')).toBe(true)                 // Colin sees everything
  })
})

describe('who is told about a card', () => {
  it('its caller and the owners; everyone only when it has no caller', async () => {
    const g = await one<Json>(`public.card_tell($1, $2)`, [GEORGE, NOW])
    expect(g).toMatchObject({ everyone: false, card_caller: 'thalia', covering: false })
    expect([...g.people].sort()).toEqual(['colin', 'muse', 'thalia'])       // the owners are Colin and Muse
    expect(await one<Json>(`public.card_tell($1, $2)`, [NOBODY, NOW])).toEqual({ everyone: true })
    expect(await one<Json>(`public.card_tell(null, $1)`, [NOW])).toEqual({ everyone: true })
  })
  it('the other caller when its caller is off today, and a caller who holds a task on it', async () => {
    await db.exec(`insert into public.caller_off (person, day, note, set_by) values ('thalia', date '2026-11-17', 'off', 'desk')`)
    const off = await one<Json>(`public.card_tell($1, $2)`, [GEORGE, NOW])
    expect(off.covering).toBe(true)
    expect([...off.people].sort()).toEqual(['adil', 'colin', 'muse'])
    await db.exec(`delete from public.caller_off; insert into public.tasks (lead_id, due_at, kind, owner, note, source, title) values ('${GEORGE}', now(), 'call', 'adil', 'Colin gave Tyler this call', 'power_hour', 'Call George')`)
    expect([...(await one<Json>(`public.card_tell($1, $2)`, [GEORGE, NOW])).people].sort()).toEqual(['adil', 'colin', 'muse', 'thalia'])
  })
  it('every registered phone is known by whose it is', async () => {
    expect((await subs()).map((s) => `${s.person}:${s.role}`).sort()).toEqual(['adil:caller', 'colin:owner'])
  })
  it('mayTell: everyone, the people named, or the owners when the rule could not be read', () => {
    expect(mayTell({ person: 'adil', role: 'caller' }, null)).toBe(true)
    expect(mayTell({ person: 'adil', role: 'caller' }, { everyone: true, people: [] })).toBe(true)
    expect(mayTell({ person: 'adil', role: 'caller' }, { everyone: false, people: ['colin', 'thalia'] })).toBe(false)
    expect(mayTell({ person: 'thalia' }, { everyone: false, people: ['colin', 'thalia'] })).toBe(true)
    expect(mayTell({ person: 'adil', role: 'caller' }, { everyone: false, people: [], ownersOnly: true })).toBe(false)
    expect(mayTell({ person: 'colin', role: 'owner' }, { everyone: false, people: [], ownersOnly: true })).toBe(true)
    expect(mayTell({}, { everyone: false, people: ['colin'] })).toBe(false)     // a phone nobody is logged in on
  })
})

describe('the hot alert that started this', () => {
  let texts: string[]; let memberTexts: string[]; let pushed: string[]; let mailed: string[]
  const push: HotPush = { subscriptions: subs, push: async (sub) => { pushed.push(sub.endpoint); return { ok: true, gone: false, status: 201 } } }
  const run = () => runHotAlerts({ rpc, appUrl: 'https://deals.example.com', now: () => new Date(NOW), push, tell,
    send: async (t, to) => { if (to) memberTexts.push(to); else texts.push(t); return { ok: true, sid: 'SM1' } },
    email: { recipients: async () => (await one<{ person: string; email: string }[]>(`public.alert_email_recipients()`)), send: async (m) => { mailed.push(m.to) } } })
  beforeEach(() => { texts = []; memberTexts = []; pushed = []; mailed = [] })
  const hot = (lead: string | null) => rpc('hot_record', { p_sid: `agent:${lead}:202611171722`, p_lead_id: lead, p_phone10: '6125550177', p_first_name: 'GEORGE',
    p_address: '432 W TEST ST', p_body: 'Muse: Comp run 2026-11-17', p_is_test: false, p_now: NOW })

  it('on Thalia\'s card reaches Colin and Thalia, and not Tyler', async () => {
    expect((await hot(GEORGE)).error).toBeNull()
    const s = await run()
    expect(s.alerts).toBe(1)
    expect(texts.length).toBe(1)                                      // Colin's cell, as ever
    expect(pushed).toEqual(['https://push.example/colin'])
    expect(mailed).toEqual(['thalia@example.com'])
    expect(memberTexts).toEqual(['+14145550101'])
  })
  it('with no card behind it (a number we do not know) still reaches everyone', async () => {
    await hot(null)
    await run()
    expect(pushed.sort()).toEqual(['https://push.example/colin', 'https://push.example/tyler'])
    expect(mailed.sort()).toEqual(['adil@example.com', 'thalia@example.com'])
  })
  it('reaches Tyler when Thalia is off today', async () => {
    await db.exec(`insert into public.caller_off (person, day, note, set_by) values ('thalia', date '2026-11-17', 'off', 'desk')`)
    await hot(GEORGE)
    await run()
    expect(pushed.sort()).toEqual(['https://push.example/colin', 'https://push.example/tyler'])
    expect(mailed).toEqual(['adil@example.com'])
  })
  it('any other push about a card follows the same rule, and the owners only when the rule cannot be read', async () => {
    const sent: string[] = []
    const deps: NotifyDeps = { rpc, appUrl: 'https://deals.example.com', emailTo: null, email: null, tell, subscriptions: subs,
      push: async (sub) => { sent.push(sub.endpoint); return { ok: true, gone: false, status: 201 } } }
    const s: NotifySummary = { drafts: 0, reminders: 0, tasks: 0, pushes_ok: 0, pushes_failed: 0, emails: 0, email_errors: [] }
    await pushAll(deps, { title: 'Task for Thalia' }, s, { lead: GEORGE })
    expect(sent).toEqual(['https://push.example/colin'])
    sent.length = 0
    await pushAll(deps, { title: 'WPIE test' }, s)                    // not about a card: every phone
    expect(sent.length).toBe(2)
    sent.length = 0
    await pushAll({ ...deps, tell: async () => ({ everyone: false, people: [], ownersOnly: true }) }, { title: 'x' }, s, { lead: GEORGE })
    expect(sent).toEqual(['https://push.example/colin'])
  })
})

describe('the other caller cannot work the card', () => {
  const words = /This is Thalia's card\. Only Thalia or Colin calls or texts it\./
  it('says whose it is to Tyler, and nothing to Thalia, Colin or the system', async () => {
    await as('adil@example.com')
    expect(await one<string | null>(`public.card_not_yours($1)`, [GEORGE])).toMatch(words)
    expect(await one<string | null>(`public.card_not_yours($1)`, [TYLERS])).toBeNull()
    expect(await one<string | null>(`public.card_not_yours($1)`, [NOBODY])).toBeNull()
    for (const who of ['thalia@example.com', 'colin@example.com', null]) {
      await as(who)
      expect(await one<string | null>(`public.card_not_yours($1)`, [GEORGE])).toBeNull()
    }
  })
  it('refuses Tyler\'s text, dial and take-over on Thalia\'s card', async () => {
    await as('adil@example.com')
    await expect(db.query(`select public.start_card_text($1, '6125550177')`, [GEORGE])).rejects.toThrow(words)
    expect(await one<number>(`(select count(*)::int from public.reply_drafts where lead_id = '${GEORGE}')`)).toBe(0)
    const call = await one<Json>(`public.begin_human_call($1, '6125550177', 'app', 'key-tyler-0001', now())`, [GEORGE])
    expect(call.ok).toBe(false)
    expect(call.reason).toMatch(words)
    expect(await one<string | null>(`(select human_takeover_at::text from public.leads where id = '${GEORGE}')`)).toBeNull()
    const take = await one<Json>(`public.thread_take($1, '6125550177', null)`, [GEORGE])
    expect(take.ok).toBe(false)
    expect(await one<number>(`(select count(*)::int from public.thread_owners where phone10 = '6125550177')`)).toBe(0)
  })
  it('lets Thalia text and dial her own card, and Colin any card', async () => {
    await as('thalia@example.com')
    expect(await one<string>(`public.start_card_text($1, '6125550177')::text`, [GEORGE])).toMatch(/^[0-9a-f-]{36}$/)
    expect((await one<Json>(`public.begin_human_call($1, '6125550177', 'app', 'key-thalia-0001', now())`, [GEORGE])).ok).toBe(true)
    await as('colin@example.com')
    expect(await one<string | null>(`public.card_not_yours($1)`, [TYLERS])).toBeNull()
  })
  it('lets Tyler work it when Thalia is off today, or when he holds a task on it', async () => {
    await db.exec(`insert into public.caller_off (person, day, note, set_by) values ('thalia', (now() at time zone 'America/Chicago')::date, 'off', 'desk')`)
    await as('adil@example.com')
    expect(await one<string | null>(`public.card_not_yours($1)`, [GEORGE])).toBeNull()
    await as(null)
    await db.exec(`delete from public.caller_off; insert into public.tasks (lead_id, due_at, kind, owner, note, source, title) values ('${GEORGE}', now(), 'call', 'adil', 'Colin gave Tyler this call', 'power_hour', 'Call George')`)
    await as('adil@example.com')
    expect(await one<string | null>(`public.card_not_yours($1)`, [GEORGE])).toBeNull()
    expect((await one<Json>(`public.begin_human_call($1, '6125550177', 'app', 'key-tyler-0002', now())`, [GEORGE])).ok).toBe(true)
  })
})
