-- A test call to one person's phone, the way a seller's call reaches it.
--
-- Colin 2026-11-14, after the softphone was fixed and call alerts were built: "Test calling me", again and again,
-- with the app shut. The desk could only ring an app that was already open (a call straight to the softphone), which
-- says nothing about a phone in a pocket. The ring-test function does what the phone server does for a real call:
-- buzzes the phone, then tries the softphone every few seconds for 45 seconds until it is answered.
--
--   ring_tests            one row a test: who, asked by whom, and what happened (buzzed, tries, answered, after how long)
--   ring_test(person)     the desk's way in: asks the ring-test function for that person, now or after a delay
--
-- A team member starts their own from Settings ("Test a call to this phone"), which calls the function directly.
-- Nothing here touches a seller, a seller line or a card.

create table if not exists public.ring_tests (
  id               uuid primary key default gen_random_uuid(),
  person           public.team_person not null,
  asked_by         text not null,
  asked_at         timestamptz not null default now(),
  delay_s          int not null default 0,
  pushed           int,
  tries            int,
  answered         boolean,
  answered_after_s int,
  note             text,
  finished_at      timestamptz
);
create index if not exists ring_tests_person_at on public.ring_tests (person, asked_at desc);
alter table public.ring_tests enable row level security;
drop policy if exists ring_tests_team_read on public.ring_tests;
create policy ring_tests_team_read on public.ring_tests for select to authenticated using (public.is_team());
grant select on public.ring_tests to authenticated;

create or replace function public.ring_test(p_person public.team_person, p_delay int default 0)
returns jsonb language plpgsql security definer set search_path = public as $$
declare secret text;
begin
  if not exists (select 1 from pg_extension where extname = 'pg_net') or to_regclass('vault.decrypted_secrets') is null then
    return jsonb_build_object('ok', false, 'error', 'this database cannot call the app''s functions');
  end if;
  execute $q$select decrypted_secret from vault.decrypted_secrets where name = 'send_openers_cron_secret'$q$ into secret;
  if secret is null then return jsonb_build_object('ok', false, 'error', 'no shared secret'); end if;
  execute $q$select net.http_post(
      url := 'https://jyfetargyaaxcqmxdgft.supabase.co/functions/v1/ring-test',
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-wpie-cron-secret', $1),
      body := jsonb_build_object('person', $2, 'delay', $3, 'asked_by', 'desk'),
      timeout_milliseconds := 10000)$q$ using secret, p_person::text, greatest(0, least(30, coalesce(p_delay, 0)));
  return jsonb_build_object('ok', true, 'person', p_person, 'delay', greatest(0, least(30, coalesce(p_delay, 0))));
end $$;
revoke all on function public.ring_test(public.team_person, int) from public, anon, authenticated;
grant execute on function public.ring_test(public.team_person, int) to service_role;
