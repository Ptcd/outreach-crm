// 0253 (Colin 2026-11-19, the morning after 991 Howard St was signed: "Probably gotta build out the system for
// everything post offer signing now?"). A signature opens a track of dated steps from the contract's own terms, gives
// Colin one task (the next step due), and stops the selling: the belt ends, the caller's open tasks close, a waiting
// belt text is withdrawn. The track is Colin's: a caller cannot read it or tick it. On the real migrations.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')

let db: PGlite
type Json = Record<string, any>
const ESTATE = '00000000-0000-0000-0000-00000000c001'   // a probate card, Tyler's, on the "said yes" belt
const PLAIN = '00000000-0000-0000-0000-00000000c002'    // an ordinary card, title company named in the offer
const SIGNED = '2026-11-18T22:51:14Z'                   // Wednesday 4:51 PM Central
const as = async (email: string | null) => { await db.query(`select set_config('request.jwt.claims', $1, false)`, [email ? JSON.stringify({ email }) : '']) }
const rows = async <T>(sql: string, params: unknown[] = []) => (await db.query<T>(sql, params)).rows
const asUser = async <T>(email: string, sql: string, params: unknown[] = []) => {
  await as(email); await db.exec('set role authenticated')
  try { return (await db.query<T>(sql, params)).rows } finally { await db.exec('reset role'); await as(null) }
}
const steps = (lead: string) => rows<{ key: string; label: string; due: string | null; done: boolean; skipped: boolean; id: string }>(
  `select key, label, due_on::text due, done_at is not null done, skipped, id::text from public.closing_steps where lead_id = $1 order by due_on nulls last, sort`, [lead])
const task = async (lead: string) => (await rows<{ title: string; owner: string; due: string; done: boolean; note: string | null }>(
  `select title, owner::text, to_char(due_at at time zone 'America/Chicago', 'YYYY-MM-DD HH24:MI') due, done_at is not null done, note
     from public.tasks where lead_id = $1 and source = 'closing'`, [lead]))[0]

async function sign(lead: string, terms: Json): Promise<Json> {
  const id = (await rows<{ id: string }>(
    `insert into public.contracts (lead_id, form, status, terms, buyer_name, buyer_signed_at, offer_path, offer_sha256)
     values ($1, 'WB-11 10-1-2026', 'sent', $2, 'WeLiveWI LLC', $3, 'x/offer.pdf', 'aa') returning id::text`, [lead, JSON.stringify(terms), SIGNED]))[0].id
  await db.query(`insert into public.contract_signers (contract_id, position, name, token_hash, expires_at, signed_at, signed_name)
                  values ($1, 1, 'Seller', $2, $3::timestamptz + interval '5 days', $3, 'Seller')`, [id, `h-${id}`, SIGNED])
  await db.exec('set role service_role')
  try {
    return (await rows<{ r: Json }>(`select public.contract_sealed($1, 'x/final.pdf', 'bb', $2) as r`, [id, SIGNED]))[0].r
  } finally { await db.exec('reset role') }
}

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
  await db.exec(`
    insert into public.team_members (email, role, person, display_name) values
      ('colin@example.com', 'owner', 'colin', 'Colin'), ('adil@example.com', 'caller', 'adil', 'Tyler')
    on conflict (email) do update set role = excluded.role, person = excluded.person, display_name = excluded.display_name;
    insert into public.leads (id, wpie_owner_id, owner_name, lane, stage, property_address, municipality, mailing_state, reasons_to_sell, locked_to, assigned_to) values
      ('${ESTATE}', 9101, 'JASON TESTESTATE', 'flip', 'colin_call', '991 TEST ST', 'CITY OF TEST', 'WI', array['Probate — Brown County case 2026PR000001'], 'adil', 'adil'),
      ('${PLAIN}', 9102, 'PLAIN TESTSELLER', 'flip', 'colin_call', '12 PLAIN AV', 'CITY OF TEST', 'WI', array['Tax delinquent'], 'adil', 'adil');
    update public.leads set belt = 'yes_unbooked', belt_step = 3, next_stop_at = '2026-11-20T16:00:00Z', next_stop_who = 'thalia_call', next_stop_say = 'call'
     where id = '${ESTATE}';
    insert into public.tasks (lead_id, due_at, kind, owner, source, title) values
      ('${ESTATE}', '2026-11-20T16:00:00Z', 'call', 'adil', 'belt', 'Said yes, not booked: stop 3 of 4'),
      ('${ESTATE}', '2026-11-16T21:13:00Z', 'appointment', 'adil', 'reply', 'They want to meet'),
      ('${ESTATE}', '2026-11-21T16:00:00Z', 'other', 'colin', null, 'Colin''s own note to self');`)
}, 180_000)

describe('the closing track', () => {
  it('a signature opens dated steps from the contract, gives Colin the first one, and stops the selling', async () => {
    const r = await sign(ESTATE, { price: 60000, closing: 'December 18, 2026', closingOn: '2026-12-18', earnestMoney: 500, earnestDays: 5,
      earnestHolder: 'the title company selected by Buyer', proofOfFundsDays: 7, inspection: false })
    expect(r.ok).toBe(true)
    expect((await steps(ESTATE)).map((s) => [s.key, s.due])).toEqual([
      ['title', '2026-11-19'], ['earnest', '2026-11-23'], ['seller_papers', '2026-11-23'], ['who_signs', '2026-11-23'],
      ['proof', '2026-11-25'], ['payoff', '2026-11-25'], ['title_back', '2026-11-28'], ['access', '2026-11-28'],
      ['walk', '2026-12-11'], ['numbers', '2026-12-15'], ['clear', '2026-12-17'], ['closing', '2026-12-18'],
    ])
    expect((await steps(ESTATE)).find((s) => s.key === 'earnest')!.label).toBe('Earnest money ($500) to the title company')
    expect(await task(ESTATE)).toMatchObject({ title: 'Closing: Pick the title company and send them the signed contract: 991 TEST ST',
      owner: 'colin', due: '2026-11-19 09:00', done: false })
    expect(r.task_id).toBeTruthy()

    const [d] = await rows<Json>(`select status::text, price::int price, closing_on::text closing_on, title_company from public.deals where lead_id = $1`, [ESTATE])
    expect(d).toEqual({ status: 'signed_to_title', price: 60000, closing_on: '2026-12-18', title_company: null })
    const [l] = await rows<Json>(`select stage::text, belt, next_stop_at, next_stop_who from public.leads where id = $1`, [ESTATE])
    expect(l).toEqual({ stage: 'under_contract', belt: null, next_stop_at: null, next_stop_who: null })
    // the caller's call and the reply's task are closed; Colin's own note is left alone
    const open = await rows<{ title: string }>(`select title from public.tasks where lead_id = $1 and done_at is null order by title`, [ESTATE])
    expect(open.map((t) => t.title)).toEqual(['Closing: Pick the title company and send them the signed contract: 991 TEST ST', "Colin's own note to self"])
    expect((await rows<Json>(`select payload->>'tasks_closed' n from public.belt_events where lead_id = $1 and event = 'contract_signed'`, [ESTATE]))[0].n).toBe('2')

    // 0254: the card says what is next in the closing: to Colin the step, to the caller that the selling has stopped
    const colin = (await asUser<{ r: Json }>('colin@example.com', `select public.card_brief($1) as r`, [ESTATE]))[0].r
    expect(colin.next_plain).toBe('Under contract at $60,000, closing Dec 18. Next: Pick the title company and send them the signed contract, by Thu Nov 19.')
    expect(colin.mine_next.note).toBeNull()   // Colin's own note to self, not the closing task said twice
    const tyler = (await asUser<{ r: Json }>('adil@example.com', `select public.card_brief($1) as r`, [ESTATE]))[0].r
    expect(tyler.next_plain).toBe('Under contract, closing Dec 18. Colin has it from here: no more calls or texts to sell.')
  })

  it('an ordinary card has no probate steps, and a named title company is in the first step', async () => {
    await sign(PLAIN, { price: 182500, closing: 'December 30, 2026', earnestMoney: 1000, earnestDays: 3, earnestHolder: 'Knight Barry Title, Milwaukee',
      proofOfFundsDays: 5, inspection: true, inspectionDays: 10 })
    const s = await steps(PLAIN)
    expect(s.map((x) => x.key)).toEqual(['title', 'earnest', 'proof', 'payoff', 'inspection', 'title_back', 'access', 'walk', 'numbers', 'clear', 'closing'])
    expect(s[0].label).toBe('Signed contract to Knight Barry Title, Milwaukee')
    expect(s.find((x) => x.key === 'closing')!.due).toBe('2026-12-30')   // read from the written date
    expect((await rows<Json>(`select title_company from public.deals where lead_id = $1`, [PLAIN]))[0].title_company).toBe('Knight Barry Title, Milwaukee')
  })

  it('is Colin\'s: a caller cannot read it or tick it', async () => {
    expect(await asUser('adil@example.com', `select id from public.closing_steps`)).toEqual([])
    expect((await asUser('colin@example.com', `select id from public.closing_steps where lead_id = $1`, [ESTATE])).length).toBe(12)
    const first = (await steps(ESTATE))[0].id
    await expect(asUser('adil@example.com', `select public.closing_step_set($1, true)`, [first])).rejects.toThrow(/only Colin/)
    await expect(asUser('adil@example.com', `select public.closing_track_open(gen_random_uuid())`)).rejects.toThrow(/permission denied/)
  })

  it('ticking a step moves Colin\'s one task to the next step due; a date can move, a step can be skipped or added', async () => {
    const id = async (key: string) => (await steps(ESTATE)).find((s) => s.key === key)!.id
    await asUser('colin@example.com', `select public.closing_step_set($1, true, null, null, 'Sent to the title company')`, [await id('title')])
    expect(await task(ESTATE)).toMatchObject({ title: 'Closing: Earnest money ($500) to the title company: 991 TEST ST', due: '2026-11-23 09:00', done: false })
    expect((await rows<Json>(`select done_by, note from public.closing_steps where id = $1`, [await id('title')]))[0]).toEqual({ done_by: 'Colin', note: 'Sent to the title company' })
    // the payoff letter is asked for early: it is now the next step due
    await asUser('colin@example.com', `select public.closing_step_set($1, null, null, '2026-11-20')`, [await id('payoff')])
    expect((await task(ESTATE)).title).toBe('Closing: Payoff letter ordered for every loan on the house: 991 TEST ST')
    await asUser('colin@example.com', `select public.closing_step_set($1, null, true)`, [await id('payoff')])
    expect((await task(ESTATE)).title).toBe('Closing: Earnest money ($500) to the title company: 991 TEST ST')
    const deal = (await rows<{ id: string }>(`select id::text from public.deals where lead_id = $1`, [ESTATE]))[0].id
    await asUser('colin@example.com', `select public.closing_step_add($1, 'Brother signs the consent', '2026-11-21')`, [deal])
    expect((await task(ESTATE)).title).toBe('Closing: Brother signs the consent: 991 TEST ST')
    expect((await rows<Json>(`select count(*)::int n from public.tasks where lead_id = $1 and source = 'closing'`, [ESTATE]))[0].n).toBe(1)
  })

  it('ticking Closing closes the deal and the card; unticking puts them back; a dead deal drops the task', async () => {
    const closing = (await steps(ESTATE)).find((s) => s.key === 'closing')!.id
    await asUser('colin@example.com', `select public.closing_step_set($1, true)`, [closing])
    expect((await rows<Json>(`select status::text, close_date is not null closed from public.deals where lead_id = $1`, [ESTATE]))[0]).toEqual({ status: 'closed', closed: true })
    expect((await rows<Json>(`select stage::text from public.leads where id = $1`, [ESTATE]))[0].stage).toBe('closed_won')
    expect((await task(ESTATE)).done).toBe(true)
    await asUser('colin@example.com', `select public.closing_step_set($1, false)`, [closing])
    expect((await rows<Json>(`select status::text from public.deals where lead_id = $1`, [ESTATE]))[0].status).toBe('signed_to_title')
    expect((await rows<Json>(`select stage::text from public.leads where id = $1`, [ESTATE]))[0].stage).toBe('under_contract')
    expect((await task(ESTATE)).done).toBe(false)
    await asUser('colin@example.com', `update public.deals set status = 'dead' where lead_id = $1`, [ESTATE])
    expect((await task(ESTATE)).done).toBe(true)
  })
})
