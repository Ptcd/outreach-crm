// 0258 (Muse, desk 323, 2026-11-20, from Colin): one how-to-run document per Research Board job, kept in WPIE. An
// agent writes it through the door, Colin on the Research page; every version is kept; a write against an old
// version is refused; a caller reads and cannot write.
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
const muse: Agent = { id: 'k1', name: 'Muse', role: 'agent', scopes: ['marks'], tools: null }
const door = { records } as unknown as DoorDb
const call = async (name: string, args: Json) => (await callTool(name, args, muse, door)) as { value: Json; isError?: boolean }

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
  await db.exec(`insert into public.team_members (email, role, person, display_name) values
      ('colin@example.com', 'owner', 'colin', 'Colin'), ('adil@example.com', 'caller', 'adil', 'Tyler')
    on conflict (email) do update set role = excluded.role, person = excluded.person, display_name = excluded.display_name;`)
}, 180_000)

describe('category instructions', () => {
  it('the folder lists every board job; an agent writes one whole and reads it back', async () => {
    const f = (await call('category_instructions', {})).value.folder as Json[]
    expect(f).toHaveLength(20)
    expect(f.every((r) => r.written === false)).toBe(true)
    const w = await call('category_instructions_set', { job: 'money_judgments', body: '# Money judgments\nRead this first.', base_version: 0 })
    expect(w.value).toMatchObject({ ok: true, job: 'money_judgments', version: 1 })
    const r = (await call('category_instructions', { job: 8 })).value
    expect(r).toMatchObject({ ok: true, key: 'money_judgments', body: '# Money judgments\nRead this first.', version: 1, updated_by: 'Muse', written: true })
    expect(((await call('category_instructions', {})).value.folder as Json[]).find((x) => x.key === 'money_judgments')).toMatchObject({ written: true, version: 1, updated_by: 'Muse' })
  })

  it('a write against an old version is refused; the same text again changes nothing; every version is kept', async () => {
    const stale = await call('category_instructions_set', { job: 'money_judgments', body: 'overwrite', base_version: 0 })
    expect(stale.isError).toBe(true)
    expect(stale.value).toMatchObject({ ok: false, version: 1, updated_by: 'Muse' })
    expect((await call('category_instructions_set', { job: 'money_judgments', body: '# Money judgments\nRead this first.' })).value).toMatchObject({ ok: true, unchanged: true, version: 1 })
    expect((await call('category_instructions_set', { job: 'money_judgments', body: '# Money judgments\nSection 7A added.', base_version: 1 })).value).toMatchObject({ ok: true, version: 2 })
    const v = (await db.query<Json>(`select version, by, body from public.research_doc_versions order by version`)).rows
    expect(v.map((x) => [x.version, x.by])).toEqual([[1, 'Muse'], [2, 'Muse']])
    expect(v[0].body).toBe('# Money judgments\nRead this first.')
    expect((await call('category_instructions_set', { job: 'nope', body: 'x' })).isError).toBe(true)
    expect((await call('category_instructions_set', { job: 'divorce_fa', body: '   ' })).isError).toBe(true)
  })

  it('Colin edits on the page; a caller reads but cannot write, and cannot reach the agent writer', async () => {
    const s = (await asUser<{ r: Json }>('colin@example.com', `select public.research_doc_save('money_judgments', 'The edit Colin made.', 2) as r`))[0].r
    expect(s).toMatchObject({ ok: true, version: 3 })
    const read = (await asUser<{ r: Json }>('adil@example.com', `select public.research_doc('money_judgments') as r`))[0].r
    expect(read).toMatchObject({ body: 'The edit Colin made.', version: 3, updated_by: 'Colin' })
    await expect(asUser('adil@example.com', `select public.research_doc_save('money_judgments', 'caller edit', 3)`)).rejects.toThrow(/only Colin/)
    await expect(asUser('adil@example.com', `select public.agent_research_doc_set('money_judgments', 'x', 'Tyler')`)).rejects.toThrow(/permission denied/)
    await expect(asUser('adil@example.com', `update public.research_docs set body = 'x'`)).rejects.toThrow()
  })
})
