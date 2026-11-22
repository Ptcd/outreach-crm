// 0259 (Colin 2026-11-20: "Build a chatroom for you, muse and muse2"). One stream of short lines between the desk,
// Muse, Muse 2 and Colin. Each reader has a place; an agent is told about new lines on every tool call; a line names
// who it is for or is for everyone; nobody else is in the room; a caller cannot read it.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'
import { callTool, toolAllowed, type Agent, type DoorDb } from '../supabase/functions/_shared/agentDoor'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')

let db: PGlite
type Json = Record<string, any>
const asUser = async <T>(email: string, sql: string, params: unknown[] = []) => {
  await db.query(`select set_config('request.jwt.claims', $1, false)`, [JSON.stringify({ email })])
  await db.exec('set role authenticated')
  try { return (await db.query<T>(sql, params)).rows } finally { await db.exec('reset role'); await db.query(`select set_config('request.jwt.claims', '', false)`) }
}
const svc = async <T>(sql: string, params: unknown[] = []) => {
  await db.exec('set role service_role')
  try { return (await db.query<{ r: T }>(`select ${sql} as r`, params)).rows[0].r } finally { await db.exec('reset role') }
}
const records = async (fn: string, args: Record<string, unknown>) => {
  const keys = Object.keys(args)
  return svc(`public.${fn}(${keys.map((k, i) => `${k} => $${i + 1}`).join(', ')})`, keys.map((k) => args[k]))
}
const door = { records } as unknown as DoorDb
const muse: Agent = { id: 'k1', name: 'Muse', role: 'agent', scopes: ['channel'], tools: null }
const muse2: Agent = { id: 'k2', name: 'Muse 2', role: 'agent', scopes: ['channel'], tools: ['chat_read', 'chat_post'] }
const dots: Agent = { id: 'k3', name: 'dots', role: 'agent', scopes: ['channel'], tools: null }
const call = async (a: Agent, name: string, args: Json = {}) => (await callTool(name, args, a, door)) as { value: Json; isError?: boolean }

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
  await db.exec(`insert into public.team_members (email, role, person, display_name) values
      ('colin@example.com', 'owner', 'colin', 'Colin'), ('adil@example.com', 'caller', 'adil', 'Tyler')
    on conflict (email) do update set role = excluded.role, person = excluded.person, display_name = excluded.display_name;`)
}, 180_000)

describe('the room', () => {
  it('a line from one is new for the others, in order, and reading moves each one\'s own place', async () => {
    const first = await call(muse, 'chat_post', { body: 'Which switch stops the server writing the day?', to: ['desk'] })
    expect(first.value).toMatchObject({ ok: true, to: 'desk' })
    const ans = await svc<Json>(`public.room_post('desk', 'day_backstop. day_rules_on is the records gate: never that one.', array['muse'], $1)`, [first.value.id])
    expect(ans.ok).toBe(true)
    await call(muse2, 'chat_post', { body: 'July judgments: lane 3 landed.' })

    const m = (await call(muse, 'chat_read')).value
    expect(m.you).toBe('muse')
    expect(m.lines.map((l: Json) => [l.from, l.to, l.for_you])).toEqual([['muse', 'desk', false], ['desk', 'muse', true], ['muse 2', 'everyone', true]])
    expect(m.lines[1].reply_to).toBe(first.value.id)
    expect((await call(muse, 'chat_read')).value).toMatchObject({ new: 0, nothing_new: true })   // her place moved
    // Muse 2 has not read yet: all three are new for it, and a peek leaves its place alone
    expect((await call(muse2, 'chat_read', { peek: true })).value.new).toBe(3)
    expect((await call(muse2, 'chat_read')).value.new).toBe(3)
    expect((await call(muse2, 'chat_read')).value.nothing_new).toBe(true)
  })

  it('an agent is told about new lines on its next tool call, and only lines that are for it', async () => {
    await svc(`public.room_post('desk', 'Muse 2: deposit the July feedstock through court_rows_deposit.', array['muse 2'], null)`)
    const a2 = await svc<Json | null>(`public.agent_attention('Muse 2')`)
    expect(a2?.room).toMatch(/^1 new line in the room \(1 to you by name\), the newest from desk: "Muse 2: deposit the July feedstock/)
    expect((await svc<Json | null>(`public.agent_attention('Muse')`))?.room).toBeUndefined()   // not named, so not hers
    await call(muse2, 'chat_read')
    expect((await svc<Json | null>(`public.agent_attention('Muse 2')`))?.room).toBeUndefined()
  })

  it('refuses a line that is empty, too long, to nobody in the room, or from someone who is not in it; a retry is one line', async () => {
    expect((await call(muse, 'chat_post', { body: '  ' })).isError).toBe(true)
    const long = await call(muse, 'chat_post', { body: 'x'.repeat(2001) })
    expect(long.value.reason).toMatch(/too long for the room/)
    expect((await call(muse, 'chat_post', { body: 'hello', to: ['bob'] })).value.reason).toMatch(/nobody in the room is called "bob"/)
    // a key that is none of the four: the database refuses it, and the door does not even list the tools to it
    expect((await call(dots, 'chat_post', { body: 'hello' })).value.reason).toBe('the room is the desk, Muse, Muse 2, Colin and the callers')
    expect((await call(dots, 'chat_read')).isError).toBe(true)
    const chat = { name: 'chat_read', role: 'channel' }
    expect([toolAllowed(dots, chat), toolAllowed(muse, chat), toolAllowed(muse2, chat)]).toEqual([false, true, true])
    const a = await call(muse, 'chat_post', { body: 'Restack done.' })
    const b = await call(muse, 'chat_post', { body: 'Restack done.' })
    expect(b.value).toMatchObject({ ok: true, id: a.value.id, already: true })
  })

  it('Colin reads the room in the app, sees how far each has read, and says a line; a caller cannot', async () => {
    const page = (await asUser<{ r: Json }>('colin@example.com', `select public.room_page(100) as r`))[0].r
    expect(page.lines.length).toBeGreaterThanOrEqual(5)
    expect(Object.keys(page.seen).sort()).toEqual(['colin', 'muse', 'muse 2'])   // the desk has not read yet
    const said = (await asUser<{ r: Json }>('colin@example.com', `select public.room_say('Keep the backstop on.', array['muse', 'desk']) as r`))[0].r
    expect(said).toMatchObject({ ok: true, to: 'muse, desk' })
    expect((await call(muse, 'chat_read')).value.lines.at(-1)).toMatchObject({ from: 'colin', for_you: true, body: 'Keep the backstop on.' })
    await expect(asUser('adil@example.com', `select public.room_page(10)`)).rejects.toThrow(/Colin/)
    await expect(asUser('adil@example.com', `select public.room_say('hi')`)).rejects.toThrow(/only Colin/)
    await expect(asUser('adil@example.com', `select public.room_post('desk', 'hi')`)).rejects.toThrow(/permission denied/)
    expect(await asUser('adil@example.com', `select id from public.room_messages`)).toEqual([])
  })

  // 0263 (Colin 2026-11-20: "give Tyler and thalia access to the chat too so they can ask for help"). A caller is in the
  // room through a line of their own: what they wrote and what was written to them by name, nothing else.
  it('a caller asks for help and sees only their own line: not the room, not the other caller', async () => {
    await db.exec(`insert into public.team_members (email, role, person, display_name) values ('thalia@example.com', 'caller', 'thalia', 'Thalia')
                   on conflict (email) do update set role = excluded.role, person = excluded.person, display_name = excluded.display_name;`)
    const mine = async (email: string) => (await asUser<{ r: Json }>(email, `select public.room_mine(100) as r`))[0].r
    // nothing of the agents' traffic is Tyler's to read, though the room is full of it
    expect((await mine('adil@example.com')).lines).toEqual([])
    await call(muse2, 'chat_read')                                                 // Muse 2 is up to date before the callers write
    const q = (await asUser<{ r: Json }>('adil@example.com', `select public.room_ask('The Huss card shows two numbers. Which one do I call?') as r`))[0].r
    expect(q).toMatchObject({ ok: true, to: 'muse, desk' })                        // named nobody: Muse and the desk
    await asUser('thalia@example.com', `select public.room_ask('Is Sutton still mine to call tonight?')`)

    // the agents see both questions, marked as a caller's, and the tool tells Muse on its next call
    const seen = (await call(muse, 'chat_read')).value.lines.filter((l: Json) => l.from_caller)
    expect(seen.map((l: Json) => [l.from, l.for_you])).toEqual([['tyler', true], ['thalia', true]])
    expect((await svc<Json | null>(`public.agent_attention('Muse 2')`))?.room).toBeUndefined()     // not Muse 2's to answer

    // Muse answers Tyler by name; a line that names nobody stays the agents'
    const a = await call(muse, 'chat_post', { body: 'Call the 262 number: the other one is his brother.', to: ['tyler'], reply_to: q.id })
    expect(a.value).toMatchObject({ ok: true, to: 'tyler' })
    await call(muse, 'chat_post', { body: 'Restack for Thalia is done: Sutton first.' })
    expect((await asUser<{ n: number }>('adil@example.com', `select public.room_mine_unread() as n`))[0].n).toBe(1)
    const t = await mine('adil@example.com')
    expect(t.you).toBe('tyler')
    expect(t.lines.map((l: Json) => [l.from, l.body])).toEqual([
      ['tyler', 'The Huss card shows two numbers. Which one do I call?'], ['muse', 'Call the 262 number: the other one is his brother.']])
    expect((await asUser<{ n: number }>('adil@example.com', `select public.room_mine_unread() as n`))[0].n).toBe(0)   // reading it clears the badge
    // Thalia sees her own question and nothing of Tyler's thread
    const th = await mine('thalia@example.com')
    expect(th.lines.map((l: Json) => l.body)).toEqual(['Is Sutton still mine to call tonight?'])
    expect(JSON.stringify(th)).not.toMatch(/Huss|262 number|Restack/)

    // a caller cannot write to the other caller, cannot answer a line they cannot see, and cannot read the tables
    expect((await svc<Json>(`public.room_post('adil', 'hey', array['thalia'], null)`)).reason).toMatch(/does not write to the other caller/)
    const hidden = (await svc<{ id: number }[]>(`(select jsonb_agg(jsonb_build_object('id', id)) from public.room_messages where author = 'thalia')`))[0].id
    expect((await svc<Json>(`public.room_post('adil', 'me too', null, $1)`, [hidden])).reason).toMatch(/not in the room/)
    expect(await asUser('adil@example.com', `select id from public.room_messages`)).toEqual([])
    await expect(asUser('adil@example.com', `select public.room_page(10)`)).rejects.toThrow(/Colin/)
    // Colin sees all of it on his page and can write to a caller; Colin has no help line of his own
    const page = (await asUser<{ r: Json }>('colin@example.com', `select public.room_page(100) as r`))[0].r
    expect(page.lines.filter((l: Json) => l.from_caller).length).toBe(2)
    expect((await asUser<{ r: Json }>('colin@example.com', `select public.room_say('Tyler: good catch on Huss.', array['tyler']) as r`))[0].r).toMatchObject({ ok: true, to: 'tyler' })
    expect((await mine('adil@example.com')).lines.at(-1)).toMatchObject({ from: 'colin', body: 'Tyler: good catch on Huss.' })
    await expect(asUser('colin@example.com', `select public.room_mine(10)`)).rejects.toThrow(/callers' help line/)
  })
})

describe('a seat for Grok (0275)', () => {
  const grok: Agent = { id: 'k9', name: 'Grok', role: 'agent', scopes: ['channel'], tools: null }
  it('a key named Grok speaks as Grok, not as Muse, in the room and on the desk', async () => {
    const said = await call(grok, 'chat_post', { body: 'Grok here. Starting on the foreclosure and probate pulls.', to: ['desk'] })
    expect(said.isError).toBeFalsy()
    const last = (await db.query<Json>(`select author, to_whom from public.room_messages order by id desc limit 1`)).rows[0]
    expect(last).toEqual({ author: 'grok', to_whom: ['desk'] })
    const d = await call(grok, 'desk_post', { for: 'desk', kind: 'note', topic: 'Grok: first report', body: 'Nothing banked yet.' })
    expect(d.isError).toBeFalsy()
    expect((await db.query<Json>(`select author from public.desk_messages order by id desc limit 1`)).rows[0]).toEqual({ author: 'grok' })
  })
  it('Grok is told about a line written to it, on its next tool call, and Muse is not', async () => {
    await svc(`public.room_post('desk', 'Grok: Kenosha judgments are yours this week.', array['grok'], null)`)
    expect(String((await svc<Json | null>(`public.agent_attention('Grok')`))?.room)).toMatch(/new lines? in the room \(1 to you by name\)/)
    const r = await call(grok, 'chat_read', {})
    expect(r.value.lines.at(-1)).toMatchObject({ from: 'desk', to: 'grok', for_you: true })
    expect((await svc<Json | null>(`public.agent_attention('Grok')`))?.room).toBeUndefined()
  })
})
