-- 0324: what the machine check said about each line of a three-line round.
--
-- 2026-11-25, the first real three-line rounds with voicemails on the other end: a voicemail that answered was kept as
-- a person, and nothing recorded what Twilio's machine check had reported or when, so there was no way to tell a slow
-- verdict from a missing one. The phone server (voice/amd) now writes one row per line it hears about: the verdict
-- (human, machine_start, fax, unknown), how long after the call was placed it came, and what was done (left alone,
-- hung up, or the recorded message). It is a record only; nothing reads it to decide anything.

create table if not exists public.line_screens (
  call_sid     text primary key,                 -- the seller's leg
  parent_sid   text,                             -- the caller's leg of that line
  lead_id      uuid references public.leads(id) on delete set null,
  person       text,
  phone10      text,
  answered_by  text,
  did          text,                             -- left_alone | hung_up | message
  secs         numeric,                          -- seconds from the seller's leg being created to the verdict
  at           timestamptz not null default now()
);
create index if not exists line_screens_at on public.line_screens (at desc);
alter table public.line_screens enable row level security;
grant select on public.line_screens to authenticated, service_role;
drop policy if exists line_screens_owner_read on public.line_screens;
create policy line_screens_owner_read on public.line_screens for select to authenticated using (public.is_owner());

create or replace function public.line_screen_log(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $fn$
begin
  if coalesce(p->>'call_sid', '') !~ '^CA[0-9A-Fa-f]{32}$' then return jsonb_build_object('ok', false); end if;
  insert into public.line_screens (call_sid, parent_sid, lead_id, person, phone10, answered_by, did, secs)
  values (p->>'call_sid', nullif(p->>'parent_sid', ''),
          case when coalesce(p->>'lead_id', '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                    and exists (select 1 from public.leads l where l.id = (p->>'lead_id')::uuid) then (p->>'lead_id')::uuid end,
          nullif(left(p->>'person', 20), ''), nullif(right(regexp_replace(coalesce(p->>'phone', ''), '\D', '', 'g'), 10), ''),
          left(p->>'answered_by', 40), left(p->>'did', 20), nullif(p->>'secs', '')::numeric)
  on conflict (call_sid) do update set answered_by = excluded.answered_by, did = excluded.did, secs = excluded.secs, at = now();
  return jsonb_build_object('ok', true);
end $fn$;
revoke all on function public.line_screen_log(jsonb) from public, anon, authenticated;
grant execute on function public.line_screen_log(jsonb) to service_role;
