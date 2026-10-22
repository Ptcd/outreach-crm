import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { SUPABASE_STUB } from './supabaseStub'

export const COLIN = { sub: '00000000-0000-0000-0000-00000000000c', email: 'colin@example.com' }
export const THALIA = { sub: '00000000-0000-0000-0000-00000000000d', email: 'thalia@example.com' }
export const ADIL = { sub: '00000000-0000-0000-0000-00000000000e', email: 'adil@example.com' }

const migrationsDir = path.resolve(__dirname, '../supabase/migrations')
const migrationFiles = readdirSync(migrationsDir).filter((f) => f.endsWith('.sql')).sort()

export async function dayDb(before?: { migration: string; sql: string }): Promise<PGlite> {
  const db = new PGlite()
  await db.exec(SUPABASE_STUB)
  for (const file of migrationFiles) {
    if (before?.migration === file) await db.exec(before.sql)
    await db.exec(readFileSync(path.join(migrationsDir, file), 'utf8'))
  }
  await db.exec(`insert into public.team_members (email, role, person, display_name) values
    ('colin@example.com', 'owner', 'colin', 'Colin'),
    ('thalia@example.com', 'caller', 'thalia', 'Thalia'),
    ('adil@example.com', 'caller', 'adil', 'Adil')`)
  return db
}

export async function as<T>(db: PGlite, who: { sub: string; email: string }, fn: () => Promise<T>): Promise<T> {
  await db.exec('reset role')
  await db.query(`select set_config('request.jwt.claims', $1, false)`, [JSON.stringify(who)])
  await db.exec('set role authenticated')
  try {
    return await fn()
  } finally {
    await db.exec('reset role')
    await db.query(`select set_config('request.jwt.claims', '', false)`)
  }
}

export async function rpc<T>(db: PGlite, fn: string, args: Record<string, unknown>): Promise<T> {
  const names = Object.keys(args)
  const values = names.map((name) => {
    const value = args[name]
    return value !== null && typeof value === 'object' ? JSON.stringify(value) : value
  })
  const result = await db.query<{ result: T }>(
    `select public.${fn}(${names.map((name, i) => `${name} => $${i + 1}`).join(', ')}) as result`, values)
  return result.rows[0]?.result
}

export async function serviceRpc<T>(db: PGlite, fn: string, args: Record<string, unknown>): Promise<T> {
  await db.exec('set role service_role')
  try {
    return await rpc<T>(db, fn, args)
  } finally {
    await db.exec('reset role')
  }
}

export async function one<T>(db: PGlite, sql: string, params: unknown[] = []): Promise<T> {
  return (await db.query<T>(sql, params)).rows[0]
}
