// 0267 (Colin 2026-11-20: "figure out the story of what's going on with the house ahead of time and then make a
// detailed script like I got for the Jason call where I got a contract ... I knew the real number I had to clear was
// a 34k mortgage and maybe some estate shit"). A yes asks Muse for the story and a script; Muse writes what is owed
// row by row; the server adds up what has to be paid at closing; the card's caller reads it, and nobody else's caller.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'
import { callTool, type Agent, type DoorDb } from '../supabase/functions/_shared/agentDoor'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')

let db: PGlite
type Json = Record<string, any>
const ESTATE = '00000000-0000-0000-0000-00000000b001'   // Tyler's card: an estate, the Howard St shape
const OTHER = '00000000-0000-0000-0000-00000000b002'    // Thalia's card
const asUser = async <T>(email: string, sql: string, params: unknown[] = []) => {
  await db.query(`select set_config('request.jwt.claims', $1, false)`, [JSON.stringify({ email })])
  await db.exec('set role authenticated')
  try { return (await db.query<T>(sql, params)).rows } finally { await db.exec('reset role'); await db.query(`select set_config('request.jwt.claims', '', false)`) }
}
const records = async (fn: string, args: Record<string, unknown>) => {
  const keys = Object.keys(args)
  await db.exec('set role service_role')
  try { return (await db.query<{ r: unknown }>(`select public.${fn}(${keys.map((k, i) => `${k} => $${i + 1}`).join(', ')}) as r`, keys.map((k) => typeof args[k] === 'object' && args[k] !== null ? JSON.stringify(args[k]) : args[k]))).rows[0].r }
  finally { await db.exec('reset role') }
}
const muse: Agent = { id: 'k1', name: 'Muse', role: 'agent', scopes: ['marks'], tools: null }
const call = async (name: string, args: Json = {}) => (await callTool(name, args, muse, { records } as unknown as DoorDb)) as { value: any; isError?: boolean }
const SCRIPT = `**Open**\n"Hey, this is Tyler. First off, sorry about your dad."\n\n**What the estate owes**\n"You mentioned the estate owes around 33, 35 thousand. Walk me through what makes that up."\n"There is one big claim with no name on it in the court file. Do you know what that one is?"\n\n**Close - if the big claim is not a mortgage**\n"Let me run the numbers with what you told me and call you back tomorrow with a real number."\n\n**Close - if it is the mortgage**\n"That changes it. I will find out what the bank would take."`
const OWED = [
  { kind: 'mortgage', creditor: 'the lender (name not known)', amount: 34000, basis: 'the seller said 33 to 35 thousand', follows_house: 'yes' },
  { kind: 'estate_claim', creditor: 'Aurora Medical Group', amount: 55368.36, basis: 'court record, claim filed 08-24', follows_house: 'no' },
  { kind: 'estate_claim', creditor: 'not named on the record', amount: 139221.16, basis: 'court record, claim filed 09-09', follows_house: 'unknown', note: 'if this is the mortgage the whole call changes' },
]

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
  await db.exec(`
    insert into public.team_members (email, role, person, display_name) values
      ('colin@example.com', 'owner', 'colin', 'Colin'), ('adil@example.com', 'caller', 'adil', 'Tyler'), ('thalia@example.com', 'caller', 'thalia', 'Thalia')
    on conflict (email) do update set role = excluded.role, person = excluded.person, display_name = excluded.display_name;
    insert into public.leads (id, wpie_owner_id, owner_name, lane, stage, property_address, municipality, county, mailing_state, locked_to, assigned_to) values
      ('${ESTATE}', 9501, 'ESTATE OF TEST', 'flip', 'reply_received', '991 TEST ST', 'CITY OF TEST', 'Brown', 'WI', 'adil', 'adil'),
      ('${OTHER}', 9502, 'OTHER SELLER', 'flip', 'reply_received', '5 OTHER ST', 'CITY OF TEST', 'Brown', 'WI', 'thalia', 'thalia');`)
}, 180_000)

describe('the story before the call', () => {
  it('a yes asks Muse for the story 30 minutes out, after the comp; the caller\'s card and call task say it is coming', async () => {
    await db.exec(`update public.leads set belt = 'yes_unbooked', belt_step = 1 where id = '${ESTATE}'`)
    const b = (await db.query<Json>(`select status, wanted_by, round(extract(epoch from due_at - wanted_at) / 60) mins from public.call_briefs where lead_id = $1`, [ESTATE])).rows
    expect(b).toEqual([{ status: 'wanted', wanted_by: 'system', mins: '30' }])
    const w = (await call('call_briefs_wanted')).value
    expect(w).toHaveLength(1)
    expect(w[0]).toMatchObject({ lead_id: ESTATE, caller: 'tyler', late: false, why: 'the seller said yes: a caller is about to phone them' })
    expect((await records('agent_attention', { p_agent: 'Muse' }) as Json).briefs).toMatch(/^1 card about to be called need the story and a script, the first due /)
    await db.query(`insert into public.tasks (lead_id, due_at, kind, owner, source, title, note) values ($1, now(), 'call', 'adil', 'belt', 'Said yes, not booked: stop 1 of 4', 'Say: You asked for a call about 991 TEST ST.')`, [ESTATE])
    const note = (await db.query<{ note: string }>(`select note from public.tasks where lead_id = $1`, [ESTATE])).rows[0].note
    expect(note.split('\n').map((l) => l.slice(0, 40))).toEqual(['NUMBER: Muse is working out the value no', 'STORY: Muse is writing the story and a s', 'Say: You asked for a call about 991 TEST'])
    expect((await asUser<{ r: Json }>('adil@example.com', `select public.call_brief($1) as r`, [ESTATE]))[0].r).toMatchObject({ status: 'wanted', late: false })
  })

  it('Muse writes it: the server adds up what has to be paid at closing, and the caller reads the story, the rows and the script', async () => {
    const story = 'The owner died in July and his son is the personal representative. The house has an old mortgage the son puts at 33 to 35 thousand. About 200 thousand of claims are filed in the estate, most of it medical; one claim of 139 thousand has no name on the record.'
    const r = await call('call_brief_set', { lead_id: ESTATE, story, owed: OWED, unknowns: ['Who filed the 139 thousand claim, and is it secured on the house?'], script: SCRIPT, sources: 'the court record read 2026-11-18; what the seller said on the first call' })
    expect(r.value).toMatchObject({ ok: true, version: 1, to_clear: 34000, owed_total: 228589.52 })
    expect(r.value.owed_line).toBe('Has to be paid at closing: $34,000 (mortgage $34,000). Owed but does not follow the house: $55,368. Not settled which way it falls: not named on the record $139,221.')
    const seen = (await asUser<{ r: Json }>('adil@example.com', `select public.call_brief($1) as r`, [ESTATE]))[0].r
    expect(seen).toMatchObject({ status: 'ready', to_clear: 34000, written_by: 'Muse', story, script: SCRIPT })
    expect(seen.owed.map((o: Json) => [o.kind, o.follows_house])).toEqual([['mortgage', 'yes'], ['estate_claim', 'no'], ['estate_claim', 'unknown']])
    expect((await db.query<{ note: string }>(`select note from public.tasks where lead_id = $1`, [ESTATE])).rows[0].note.split('\n')[1])
      .toBe('STORY: Has to be paid at closing: $34,000 (mortgage $34,000). Owed but does not follow the house: $55,368. Not settled which way it falls: not named on the record $139,221. The full story and the script are on the card: read them before you dial.')
    expect((await call('call_briefs_wanted')).value).toEqual([])                             // done: off Muse's list
    expect((await records('agent_attention', { p_agent: 'Muse' }) as Json | null)?.briefs).toBeUndefined()
    // written again, it replaces; every version is kept
    expect((await call('call_brief_set', { lead_id: ESTATE, story, owed: OWED.slice(0, 2), script: SCRIPT })).value).toMatchObject({ ok: true, version: 2, owed_total: 89368.36 })
    expect((await db.query<{ n: number }>(`select count(*)::int n from public.call_brief_versions where lead_id = $1`, [ESTATE])).rows[0].n).toBe(2)
  })

  it('refuses a brief that is thin, that guesses, or that has no word on what is owed', async () => {
    const good = { lead_id: ESTATE, story: 'x'.repeat(80), owed: OWED, script: SCRIPT }
    expect((await call('call_brief_set', { ...good, story: 'Motivated seller.' })).value.reason).toMatch(/^story: say what is going on/)
    expect((await call('call_brief_set', { ...good, script: 'Call and ask.' })).value.reason).toMatch(/^script: the words for the call/)
    expect((await call('call_brief_set', { ...good, owed: [] })).value.reason).toMatch(/owed is empty: if you looked/)
    expect((await call('call_brief_set', { ...good, owed: [], nothing_owed_found: true })).value.ok).toBe(true)
    expect((await call('call_brief_set', { ...good, owed: [{ kind: 'mortgage', amount: 34000, follows_house: 'yes' }] })).value.reason).toMatch(/owed row 1: basis says where the figure was read/)
    expect((await call('call_brief_set', { ...good, owed: [{ kind: 'vibes', basis: 'x', follows_house: 'yes' }] })).value.reason).toMatch(/owed row 1: kind is mortgage/)
    expect((await call('call_brief_set', { ...good, owed: [{ kind: 'tax', basis: 'tax roll', follows_house: 'maybe' }] })).value.reason).toMatch(/follows_house is yes/)
  })

  it('a card has one owner: the other caller cannot read the brief or ask for one; Colin can do both', async () => {
    await expect(asUser('thalia@example.com', `select public.call_brief($1)`, [ESTATE])).rejects.toThrow(/Tyler's card/)
    await expect(asUser('thalia@example.com', `select public.call_brief_ask($1)`, [ESTATE])).rejects.toThrow(/Tyler's card/)
    expect(await asUser('thalia@example.com', `select lead_id from public.call_briefs`)).toEqual([])
    await expect(asUser('adil@example.com', `select public.agent_call_brief_set('{}'::jsonb, 'Tyler')`)).rejects.toThrow(/permission denied/)
    // Thalia asks for one on her own card; Colin on anyone's
    expect((await asUser<{ r: Json }>('thalia@example.com', `select public.call_brief_ask($1) as r`, [OTHER]))[0].r).toMatchObject({ ok: true, status: 'wanted' })
    expect((await call('call_briefs_wanted')).value.map((x: Json) => [x.lead_id, x.wanted_by, x.caller])).toEqual([[OTHER, 'Thalia', 'thalia']])
    expect((await asUser<{ r: Json }>('colin@example.com', `select public.call_brief($1) as r`, [ESTATE]))[0].r.status).toBe('ready')
  })
})
