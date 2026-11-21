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
    expect((await call(muse, 'chat_post', { body: 'hello', to: ['thalia'] })).value.reason).toMatch(/nobody in the room is called "thalia"/)
    // a key that is none of the four: the database refuses it, and the door does not even list the tools to it
    expect((await call(dots, 'chat_post', { body: 'hello' })).value.reason).toBe('the room is the desk, Muse, Muse 2 and Colin')
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
})
