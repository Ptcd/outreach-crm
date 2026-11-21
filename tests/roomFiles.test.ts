// 0264 (Colin 2026-11-20: "Make it so files and images can be uploaded in the chat"). A file belongs to a line:
// whoever may read the line may open the file and nobody else, so a caller opens only what is on their own lines and
// on lines written to them by name. The bucket is reached only through the server; a link is asked of the database.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'
import { callTool, toolAllowed, type Agent, type DoorDb } from '../supabase/functions/_shared/agentDoor'
import { roomFileLink, roomFileUpload, withFileLinks, type RoomFilePorts } from '../supabase/functions/_shared/roomFiles'

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
const records = async (fn: string, args: Record<string, unknown>) => {
  const keys = Object.keys(args)
  await db.exec('set role service_role')
  try { return (await db.query<{ r: unknown }>(`select public.${fn}(${keys.map((k, i) => `${k} => $${i + 1}`).join(', ')}) as r`, keys.map((k) => args[k]))).rows[0].r }
  finally { await db.exec('reset role') }
}
// the storage, faked: a path gets an upload link and, once "put", a read link
const stored = new Set<string>()
const ports: RoomFilePorts = {
  rpc: records,
  uploadUrl: async (p) => ({ url: `https://files.example/up/${encodeURIComponent(p)}`, token: `tok-${p.length}` }),
  link: async (p) => (stored.has(p) ? `https://files.example/get/${encodeURIComponent(p)}?sig=x` : null),
}
const put = async (who: string, name: string, mime: string | null = null, size: number | null = null) => {
  const r = await roomFileUpload(ports, who, { name, mime, size }) as Json
  if (r.ok) stored.add(r.path)
  return r
}
const muse: Agent = { id: 'k1', name: 'Muse', role: 'agent', scopes: ['channel'], tools: null }
const door = { records, roomFileUpload: (who: string, x: any) => roomFileUpload(ports, who, x), roomFileLinks: (who: string, read: unknown) => withFileLinks(ports, who, read) } as unknown as DoorDb
const call = async (name: string, args: Json = {}) => (await callTool(name, args, muse, door)) as { value: Json; isError?: boolean }

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
  await db.exec(`insert into public.team_members (email, role, person, display_name) values
      ('colin@example.com', 'owner', 'colin', 'Colin'), ('adil@example.com', 'caller', 'adil', 'Tyler'), ('thalia@example.com', 'caller', 'thalia', 'Thalia')
    on conflict (email) do update set role = excluded.role, person = excluded.person, display_name = excluded.display_name;`)
}, 180_000)

describe('files and images in the room', () => {
  it('a caller attaches a screenshot to a question; the agents and Colin can open it, the other caller cannot', async () => {
    expect(await records('room_who_email', { p_email: 'ADIL@example.com' })).toBe('adil')
    const shot = await put('adil', 'Huss card.png', 'image/png', 48_000)
    expect(shot).toMatchObject({ ok: true, name: 'Huss card.png', token: expect.any(String) })
    expect(shot.path).toMatch(/^adil\/[0-9a-f-]{36}\/Huss_card\.png$/)                 // the stored name is plain; the shown name is kept
    // before it is on a line it is the uploader's alone
    expect((await roomFileLink(ports, 'adil', shot.file_id)).ok).toBe(true)
    expect(await roomFileLink(ports, 'muse', shot.file_id)).toEqual({ ok: false, reason: 'no such file' })

    const q = (await asUser<{ r: Json }>('adil@example.com', `select public.room_ask('Which number do I call?', null, $1::uuid[]) as r`, [[shot.file_id]]))[0].r
    expect(q).toMatchObject({ ok: true, files: 1, to: 'muse, desk' })
    // Muse reads the line with a link on the file; Colin sees it on his page; Thalia sees nothing of it
    const m = (await call('chat_read')).value
    const line = m.lines.find((l: Json) => l.id === q.id)
    expect(line.files).toEqual([{ id: shot.file_id, name: 'Huss card.png', mime: 'image/png', size: 48_000,
      url: `https://files.example/get/${encodeURIComponent(shot.path)}?sig=x`, expires_in_seconds: 600 }])
    const page = (await asUser<{ r: Json }>('colin@example.com', `select public.room_page(50) as r`))[0].r
    expect(page.lines.find((l: Json) => l.id === q.id).files[0]).toMatchObject({ id: shot.file_id, name: 'Huss card.png' })
    expect((await roomFileLink(ports, 'colin', shot.file_id)).ok).toBe(true)
    expect(await roomFileLink(ports, 'thalia', shot.file_id)).toEqual({ ok: false, reason: 'no such file' })
    expect((await asUser<{ r: Json }>('thalia@example.com', `select public.room_mine(50) as r`))[0].r.lines).toEqual([])
    // no path leaves the database in a line, to anyone
    expect(JSON.stringify(page) + JSON.stringify((await asUser<{ r: Json }>('adil@example.com', `select public.room_mine(50) as r`))[0].r)).not.toMatch(/adil\/[0-9a-f-]{36}/)
  })

  it('an agent puts a file up through the door and answers the caller with it; a file with no words is still a line', async () => {
    const up = await call('chat_file_upload', { filename: 'call script.pdf', mime: 'application/pdf' })
    expect(up.value).toMatchObject({ ok: true, name: 'call script.pdf', upload_url: expect.stringContaining('https://files.example/up/muse') })
    expect(JSON.stringify(up.value)).not.toMatch(/"path"|"token"/)                      // the agent gets the link, not the storage's inner names
    const id = up.value.file_id
    stored.add((await records('room_file_for', { p_file_id: id, p_who: 'muse' }) as Json).path)
    const a = await call('chat_post', { to: ['tyler'], files: [id] })                  // no body: the file is the line
    expect(a.value).toMatchObject({ ok: true, files: 1, to: 'tyler' })
    const mine = (await asUser<{ r: Json }>('adil@example.com', `select public.room_mine(50) as r`))[0].r
    expect(mine.lines.at(-1)).toMatchObject({ from: 'muse', body: 'Sent call script.pdf', files: [{ id, name: 'call script.pdf', mime: 'application/pdf', size: null }] })
    expect((await roomFileLink(ports, 'adil', id)).ok).toBe(true)                      // written to Tyler by name: his to open
    expect((await roomFileLink(ports, 'thalia', id)).ok).toBe(false)
    // the same file cannot go on a second line, and another person's file cannot be named
    expect((await call('chat_post', { body: 'again', files: [id] })).value.reason).toMatch(/not one you put up, or is already on a line/)
    const tylers = await put('adil', 'x.png')
    expect((await call('chat_post', { body: 'not mine', files: [tylers.file_id] })).value.reason).toMatch(/not one you put up/)
    expect((await call('chat_post', { body: 'bad', files: ['nope'] })).value.reason).toMatch(/file_id values/)
  })

  it('refuses a file with no name, one over 25 MB, a ninth file on a line, and anyone not in the room', async () => {
    expect(await put('adil', '   ')).toEqual({ ok: false, reason: 'the file needs a name' })
    expect(await put('adil', 'movie.mov', 'video/quicktime', 26 * 1024 * 1024)).toEqual({ ok: false, reason: 'too big: a file in the room is 25 MB at most' })
    expect(await roomFileUpload(ports, null, { name: 'a.png' })).toEqual({ ok: false, reason: 'you are not in the room' })
    expect((await records('room_file_new', { p_who: 'dots', p_name: 'a.png' }) as Json).ok).toBe(false)
    const nine: string[] = []
    for (let i = 0; i < 9; i++) nine.push((await put('thalia', `p${i}.jpg`)).file_id)
    expect((await records('room_post', { p_author: 'thalia', p_body: 'photos', p_files: nine }) as Json).reason).toMatch(/eight files on one line/)
    expect((await records('room_post', { p_author: 'thalia', p_body: 'photos', p_files: nine.slice(0, 8) }) as Json).files).toBe(8)
    // a caller login cannot call the file functions or read the table
    await expect(asUser('adil@example.com', `select public.room_file_new('adil', 'a.png')`)).rejects.toThrow(/permission denied/)
    await expect(asUser('adil@example.com', `select public.room_file_for(gen_random_uuid(), 'colin')`)).rejects.toThrow(/permission denied/)
    expect(await asUser('adil@example.com', `select id from public.room_files`)).toEqual([])
    // and the door does not list the tool to a key outside the room
    const dots: Agent = { id: 'k3', name: 'dots', role: 'agent', scopes: ['channel'], tools: null }
    expect(toolAllowed(dots, { name: 'chat_file_upload', role: 'channel' })).toBe(false)
  })
})
