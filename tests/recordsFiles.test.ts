// Records files between the agent and the laptop (0222): the portal worklist built from the notices, a file the agent
// hands to the laptop, and an attachment the agent asks the laptop for. On the real migrations; the storage links
// themselves are made in the function (agent-mcp) and are not part of this test.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'
import { TOOLS, handleMessage, type Agent, type DoorDb } from '../supabase/functions/_shared/agentDoor'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')

let db: PGlite
const one = async <T>(sql: string, params: unknown[] = []) => (await db.query<{ r: T }>(`select ${sql} as r`, params)).rows[0].r
let janesville = ''
let stoughton = ''
let reply = ''

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
  const req = async (name: string, county: string) => (await db.query<{ id: string }>(
    `insert into public.records_requests (kind, name, county, status) values ('municipal', $1, $2, 'sent') returning id`, [name, county])).rows[0].id
  janesville = await req('Janesville Water Utility', 'Rock')
  stoughton = await req('Stoughton Water Utility', 'Dane')
  const note = (rid: string, from: string, subject: string, at: string, body = '') => db.query(
    `insert into public.records_replies (request_id, message_id, from_addr, subject, received_at, body, attachments)
     values ($1, $2, $3, $4, $5, $6, '[]'::jsonb)`, [rid, `<${subject}-${at}>`, from, subject, at, body])
  await note(janesville, 'messages@nextrequest.com', 'Your City of Janesville, WI public records request #26-1698 has been submitted.', '2026-11-10T15:00:00Z',
    'Manage it at https://cityofjanesville.nextrequest.com/settings?id=1')
  await note(janesville, 'messages@nextrequest.com', '[Document Released to Requester] City of Janesville, WI public records request #26-1698', '2026-11-10T18:00:00Z')
  await note(janesville, 'messages@nextrequest.com', '[Invoice Created] City of Janesville, WI public records request #26-1636', '2026-11-13T14:00:00Z')
  await note(stoughton, 'stoughtonwi@request.justfoia.com', 'City of Stoughton Public Records Request # 340-2026', '2026-11-11T14:00:00Z')
  reply = (await db.query<{ id: string }>(
    `insert into public.records_replies (request_id, message_id, from_addr, subject, received_at, body, attachments)
     values ($1, '<a1>', 'clerk@cityofstoughton.com', 'Public records request', '2026-11-05T14:00:00Z', 'See attached.',
             '[{"name": "860exp.csv", "bytes": 912, "saved": "data\\\\records\\\\received\\\\2026-11-05\\\\ab\\\\860exp.csv"}]'::jsonb) returning id`, [stoughton])).rows[0].id
}, 120_000)

describe('records files (0222)', () => {
  it('the portal worklist: one item per town and request number, with where it stands and what is waiting', async () => {
    const items = await one<Record<string, unknown>[]>('public.records_portals()')
    const by = Object.fromEntries(items.map((i) => [`${i.office} ${i.number}`, i]))
    expect(by['Janesville Water Utility 26-1698']).toMatchObject({ state: 'documents released', waiting: true, portal: 'nextrequest.com',
      site: 'https://cityofjanesville.nextrequest.com', files_brought_in: 0 })
    expect(by['Janesville Water Utility 26-1636']).toMatchObject({ state: 'invoice: a fee, Colin decides', waiting: false })
    expect(by['Stoughton Water Utility 340-2026']).toMatchObject({ state: 'submitted', waiting: false, site: 'https://stoughtonwi.justfoia.com' })
  })

  it('a file the agent hands to the laptop: asked, ready with a link, done; then the portal item is no longer waiting', async () => {
    expect(await one('public.records_file_new($1, $2, null, null, null, $3)', [janesville, 'no extension', 'Muse']))
      .toMatchObject({ ok: false, reason: expect.stringContaining('extension') })
    expect(await one('public.records_file_new($1, $2, null, null, null, $3)', ['00000000-0000-0000-0000-000000000000', 'a.pdf', 'Muse']))
      .toMatchObject({ ok: false, reason: expect.stringContaining('no such request') })
    const f = await one<{ ok: boolean; file_id: string; path: string; office: string }>(
      'public.records_file_new($1, $2, $3, $4, $5, $6)', [janesville, 'Delinquent accounts 2026.xlsx', 'nextrequest.com', '26-1698', 'released Nov 10', 'Muse'])
    expect(f).toMatchObject({ ok: true, office: 'Janesville Water Utility' })
    expect(f.path).toMatch(/^in\/[0-9a-f-]{36}\/Delinquent accounts 2026\.xlsx$/)
    expect(await one('public.records_file_mark($1, $2, $3)', [f.file_id, 'ready', 'https://signed.example/read']))
      .toMatchObject({ ok: true, status: 'ready', direction: 'to_laptop' })
    const row = (await db.query<{ status: string; url: string; by: string; number: string }>(
      `select status, url, by, number from public.records_files where id = $1`, [f.file_id])).rows[0]
    expect(row).toEqual({ status: 'ready', url: 'https://signed.example/read', by: 'Muse', number: '26-1698' })
    const items = await one<Record<string, unknown>[]>('public.records_portals()')
    expect(items.find((i) => i.number === '26-1698')).toMatchObject({ waiting: false, files_brought_in: 1 })
    expect(await one('public.records_file_mark($1, $2)', [f.file_id, 'done'])).toMatchObject({ status: 'done' })
    expect((await db.query<{ url: string | null }>(`select url from public.records_files where id = $1`, [f.file_id])).rows[0].url).toBeNull()
  })

  it('an attachment the agent asks the laptop for: one ask per file, by the name on the reply', async () => {
    expect(await one('public.records_file_want($1, $2, $3)', [reply, 'nope.pdf', 'Muse']))
      .toMatchObject({ ok: false, attachments: ['860exp.csv'] })
    const w = await one<{ file_id: string; status: string; has_url: boolean; path: string }>('public.records_file_want($1, $2, $3)', [reply, '860EXP.csv', 'Muse'])
    expect(w).toMatchObject({ ok: true, status: 'waiting', has_url: false, path: `out/${reply}/860exp.csv` })
    const again = await one<{ file_id: string }>('public.records_file_want($1, $2, $3)', [reply, '860exp.csv', 'Muse'])
    expect(again.file_id).toBe(w.file_id)
    await one('public.records_file_mark($1, $2, $3, $4)', [w.file_id, 'ready', null, 912])
    expect(await one('public.records_file_want($1, $2, $3)', [reply, '860exp.csv', 'Muse'])).toMatchObject({ status: 'ready' })
  })

  it('the door: the four tools are records tools, and reach the ports with what the agent sent', async () => {
    const names = TOOLS.filter((t) => t.role === 'records').map((t) => t.name)
    expect(names).toEqual(expect.arrayContaining(['records_portals', 'records_file_upload', 'records_file_done', 'records_file_get']))
    const seen: unknown[] = []
    const fake = { records: async (fn: string) => { seen.push(fn); return [] },
      recordsFileUpload: async (a: unknown, who: string) => { seen.push([a, who]); return { ok: true, file_id: 'F1', upload_url: 'https://up' } },
      recordsFileDone: async (id: string) => { seen.push(id); return { ok: false, reason: 'the file is not there yet' } },
      recordsFileGet: async (r: string, n: string) => { seen.push([r, n]); return { ok: true, status: 'asked' } } } as unknown as DoorDb
    const agent: Agent = { id: 'k', name: 'Muse', role: 'records' }
    const call = async (name: string, args: unknown) => {
      const r = await handleMessage({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name, arguments: args } }, agent, fake)
      const res = (r as { result: { content: { text: string }[]; isError: boolean } }).result
      return { isError: res.isError, value: JSON.parse(res.content[0].text) }
    }
    expect((await call('records_portals', {})).isError).toBeFalsy()
    expect((await call('records_file_upload', { request_id: 'R1', filename: 'a.xlsx', portal: 'nextrequest.com', number: '26-1698' })).value)
      .toMatchObject({ ok: true, upload_url: 'https://up' })
    expect((await call('records_file_done', { file_id: 'F1' })).isError).toBe(true)
    expect((await call('records_file_get', { reply_id: 'P1', name: 'a.csv' })).value).toMatchObject({ status: 'asked' })
    expect(seen).toEqual(['records_portals', [{ request_id: 'R1', filename: 'a.xlsx', portal: 'nextrequest.com', number: '26-1698', note: null }, 'Muse'],
      'F1', ['P1', 'a.csv']])
  })
})
