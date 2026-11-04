// What Supabase provides before any migration runs.
export const SUPABASE_STUB = `
create role anon nologin;
create role authenticated nologin;
create role service_role nologin bypassrls;
create schema auth;
grant usage on schema auth to anon, authenticated, service_role;
create function auth.jwt() returns jsonb language sql stable as
  $$ select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb $$;
create function auth.uid() returns uuid language sql stable as
  $$ select nullif(auth.jwt() ->> 'sub', '')::uuid $$;
grant execute on function auth.jwt(), auth.uid() to anon, authenticated, service_role;
-- auth.users, as the migrations since 0167 read it (a caller's person from their login)
create table auth.users (id uuid primary key default gen_random_uuid(), email text, created_at timestamptz default now());
grant select on auth.users to anon, authenticated, service_role;
`
