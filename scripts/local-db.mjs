// A throwaway local Postgres (PGlite, in memory) with the WPIE migration applied,
// for testing `python -m wpie.live.sync push/pull` without a Supabase project.
//
//   npm run db:local            # listens on 127.0.0.1:5433 until Ctrl+C
//   SUPABASE_DB_URL="postgresql://postgres@127.0.0.1:5433/postgres?sslmode=disable"
//
// It stands in for Supabase's auth schema and roles only as far as the migration
// needs. Data is lost when it stops. One client connection at a time.
import { readFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { PGlite } from '@electric-sql/pglite'
import { PGLiteSocketServer } from '@electric-sql/pglite-socket'

const here = path.dirname(fileURLToPath(import.meta.url))
const migration = readFileSync(path.join(here, '..', 'supabase', 'migrations', '0001_wpie_live.sql'), 'utf8')
const port = Number(process.env.PORT || 5433)

const stub = `
create role anon nologin;
create role authenticated nologin;
create role service_role nologin bypassrls;
create schema auth;
grant usage on schema auth to anon, authenticated, service_role;
create function auth.jwt() returns jsonb language sql stable as
  $$ select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb $$;
create function auth.uid() returns uuid language sql stable as
  $$ select nullif(auth.jwt() ->> 'sub', '')::uuid $$;
`

const db = await PGlite.create()
await db.exec(stub)
await db.exec(migration)
await db.exec(`insert into public.team_members (email, role, person, display_name) values
  ('colin@example.com', 'owner', 'colin', 'Colin'), ('thalia@example.com', 'caller', 'thalia', 'Thalia')`)
const server = new PGLiteSocketServer({ db, port, host: '127.0.0.1' })
await server.start()
console.log(`local WPIE Postgres ready on 127.0.0.1:${port} (in memory; Ctrl+C to stop)`)
