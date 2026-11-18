// 0249, 0250 (Colin 2026-11-17, George White's card: "Cards should have one fucking owner end to end the other caller
// shouldn't see it"). An alert about a card goes to its caller and the owners only; the other caller cannot read it in
// the database, find it in a list, or text, dial, log or note it; lock, assignment and open tasks name one caller.
// No exceptions: not a day off, not a task. On the real migrations.
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
    expect(g).toMatchObject({ everyone: false, card_caller: 'thalia' })
    expect([...g.people].sort()).toEqual(['colin', 'muse', 'thalia'])       // the owners are Colin and Muse
    expect(await one<Json>(`public.card_tell($1, $2)`, [NOBODY, NOW])).toEqual({ everyone: true })
    expect(await one<Json>(`public.card_tell(null, $1)`, [NOW])).toEqual({ everyone: true })
  })
  it('nobody covers: the same people when its caller is off today', async () => {
    await db.exec(`insert into public.caller_off (person, day, note, set_by) values ('thalia', date '2026-11-17', 'off', 'desk')`)
    expect([...(await one<Json>(`public.card_tell($1, $2)`, [GEORGE, NOW])).people].sort()).toEqual(['colin', 'muse', 'thalia'])
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
  it('does not reach Tyler when Thalia is off today either', async () => {
    await db.exec(`insert into public.caller_off (person, day, note, set_by) values ('thalia', date '2026-11-17', 'off', 'desk')`)
    await hot(GEORGE)
    await run()
    expect(pushed).toEqual(['https://push.example/colin'])
    expect(mailed).toEqual(['thalia@example.com'])
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
  const words = /This is Thalia's card\. Only Thalia and Colin see it or work it\./
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
  it('no exceptions: not when Thalia is off today, and a task for Tyler on her card becomes hers', async () => {
    await db.exec(`insert into public.caller_off (person, day, note, set_by) values ('thalia', (now() at time zone 'America/Chicago')::date, 'off', 'desk')`)
    await as('adil@example.com')
    expect(await one<string | null>(`public.card_not_yours($1)`, [GEORGE])).toMatch(words)
    await as(null)
    await db.exec(`delete from public.caller_off; insert into public.tasks (lead_id, due_at, kind, owner, note, source, title) values ('${GEORGE}', now(), 'call', 'adil', 'the laptop call list gave Tyler this call', 'call_list', 'Call George')`)
    expect(await one<string>(`(select owner::text from public.tasks where lead_id = '${GEORGE}' and done_at is null)`)).toBe('thalia')
    await as('adil@example.com')
    expect(await one<string | null>(`public.card_not_yours($1)`, [GEORGE])).toMatch(words)
    expect((await one<Json>(`public.begin_human_call($1, '6125550177', 'app', 'key-tyler-0002', now())`, [GEORGE])).ok).toBe(false)
  })
})

describe('one owner', () => {
  it('lock and assignment never name two callers, and a card that moves takes its open tasks along', async () => {
    await db.exec(`update public.leads set assigned_to = 'adil' where id = '${GEORGE}'`)
    expect(await one<string>(`(select assigned_to::text from public.leads where id = '${GEORGE}')`)).toBe('thalia')
    await db.exec(`insert into public.tasks (lead_id, due_at, kind, owner, note, source, title) values ('${GEORGE}', now(), 'callback', 'thalia', 'Callback promised', 'belt', 'Call George')`)
    await as('colin@example.com')
    expect(await one<Json>(`public.card_reassign($1, 'adil', 'Colin moved it')`, [GEORGE])).toMatchObject({ ok: true })
    await as(null)
    expect(await one<Json>(`(select jsonb_build_object('locked', locked_to::text, 'assigned', assigned_to::text) from public.leads where id = '${GEORGE}')`)).toEqual({ locked: 'adil', assigned: 'adil' })
    expect(await one<string[]>(`(select array_agg(distinct owner::text) from public.tasks where lead_id = '${GEORGE}' and done_at is null)`)).toEqual(['adil'])
    await db.exec(`update public.leads set locked_to = 'thalia', locked_at = now() where id = '${GEORGE}'`)                  // and back, by any write
    expect(await one<string[]>(`(select array_agg(distinct owner::text) from public.tasks where lead_id = '${GEORGE}' and done_at is null)`)).toEqual(['thalia'])
    expect(await one<string>(`(select assigned_to::text from public.leads where id = '${GEORGE}')`)).toBe('thalia')
  })
  it('a card a caller makes from an incoming call is theirs', async () => {
    await as('adil@example.com')
    const made = await one<Json>(`public.new_caller('4145550909', 'Pat Newcaller')`)
    await as(null)
    expect(await one<string>(`public.card_caller($1)::text`, [made.lead_id])).toBe('adil')
  })
})

describe('the database hides the other caller\'s card', () => {
  // as the app reads it: the login's own role, the read rules in force
  const read = async <T>(email: string, sql: string, params: unknown[] = []) => {
    await as(email); await db.exec('set role authenticated')
    try { return (await db.query<T>(sql, params)).rows } finally { await db.exec('reset role'); await as(null) }
  }
  const count = async (email: string, table: string) => (await read<{ n: number }>(email, `select count(*)::int n from public.${table} where lead_id = $1`, [GEORGE]))[0].n
  it('Tyler reads nothing of George: not the card, its texts, phones, tasks or drafts', async () => {
    await db.exec(`insert into public.tasks (lead_id, due_at, kind, owner, note, source, title) values ('${GEORGE}', now(), 'call', 'thalia', 'x', 'belt', 'Call George')`)
    expect(await read('adil@example.com', `select id from public.leads where id = $1`, [GEORGE])).toEqual([])
    for (const t of ['messages', 'contacts', 'tasks', 'reply_drafts', 'belt_events', 'hot_alerts'])
      expect(await count('adil@example.com', t), t).toBe(0)
    expect((await read<{ id: string }>('adil@example.com', `select id from public.leads where id = $1`, [TYLERS])).length).toBe(1)
    expect((await read<{ id: string }>('adil@example.com', `select id from public.leads where id = $1`, [NOBODY])).length).toBe(1)
  })
  it('Thalia and Colin read all of it', async () => {
    for (const who of ['thalia@example.com', 'colin@example.com']) {
      expect((await read(who, `select id from public.leads where id = $1`, [GEORGE])).length, who).toBe(1)
      expect(await count(who, 'messages'), who).toBeGreaterThan(0)
      expect(await count(who, 'contacts'), who).toBe(1)
    }
    expect((await read('colin@example.com', `select id from public.leads`)).length).toBeGreaterThanOrEqual(3)
  })
  it('Tyler cannot change it either', async () => {
    await read('adil@example.com', `update public.leads set notes = 'mine now' where id = $1`, [GEORGE])
    expect((await one<string | null>(`(select notes from public.leads where id = '${GEORGE}')`)) ?? '').not.toMatch(/mine now/)
  })
  it('the lists leave it out: a phone search, the live texts, My cards', async () => {
    await db.exec(`insert into public.twilio_inbound (sid, from10, body, lead_id, received_at) values ('SM-in-george', '6125550177', 'Yes I will sell it', '${GEORGE}', now())`)
    await as('adil@example.com')
    expect(await one<Json[]>(`public.phone_lookup('6125550177')`)).toEqual([])
    expect((await one<Json[]>(`public.texts_live(48, 80)`)).filter((t) => t.lead_id === GEORGE)).toEqual([])
    expect(JSON.stringify(await one<Json>(`public.my_piles()`))).not.toContain(GEORGE)
    await as('thalia@example.com')
    expect((await one<Json[]>(`public.phone_lookup('6125550177')`)).map((x) => x.lead_id)).toEqual([GEORGE])
    expect((await one<Json[]>(`public.texts_live(48, 80)`)).filter((t) => t.lead_id === GEORGE).length).toBe(1)
  })
  it('every card action refuses Tyler: a call logged, a note, a follow-up, a move', async () => {
    const words = /This is Thalia's card\./
    await as('adil@example.com')
    await expect(db.query(`select public.log_call($1, '6125550177', 'interested', 'talked to him', null)`, [GEORGE])).rejects.toThrow(words)
    await expect(db.query(`select public.note_add($1, 'my note')`, [GEORGE])).rejects.toThrow(words)
    await expect(db.query(`select public.followup_set($1, now() + interval '1 day', 'call', 'call him')`, [GEORGE])).rejects.toThrow(words)
    await expect(db.query(`select public.belt_event($1, 'move', '{"belt":"dead"}'::jsonb, 'adil', now())`, [GEORGE])).rejects.toThrow(words)
    await expect(db.query(`select public.card_brief($1)`, [GEORGE])).rejects.toThrow(words)
    await as('thalia@example.com')
    expect((await db.query(`select public.note_add($1, 'her note')`, [GEORGE])).rows.length).toBe(1)
  })
  it('no card action a caller login can run is left without the check', async () => {
    // a later migration that rewrites one of these from an old copy drops the check: this is what catches it
    const open = await one<string[] | null>(`(select array_agg(p.proname order by p.proname) from pg_proc p
      join pg_namespace ns on ns.oid = p.pronamespace join pg_language l on l.oid = p.prolang
     where ns.nspname = 'public' and l.lanname = 'plpgsql' and p.prosecdef and 'p_lead_id' = any (p.proargnames)
       and has_function_privilege('authenticated', p.oid, 'execute')
       and p.proname not in ('card_not_yours', 'card_guard', 'lock_card_to', 'card_reassign')
       and p.prosrc !~ 'card_guard|card_not_yours')`)
    expect(open ?? []).toEqual([])
  })
})
