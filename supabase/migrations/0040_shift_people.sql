-- Who is on shift, on a shared login (2026-10-22 evening).
--
-- Everyone signs in with the one app password (Colin, 2026-10-21), and that account is Colin's team row.
-- So the app could not tell Thalia from Colin: her Calls page showed Colin's tasks (the day's call list is
-- in Thalia's name), and saving "Email for hot pings" in Settings would have overwritten Colin's alerts.
-- Each phone now says who is on it (the app remembers it on the phone), and Thalia's and Adil's alert
-- email and phone live here. team_members is left alone on purpose: several functions read "the signed-in
-- team row" as its first visible row, so a second row there could hand the wrong identity to the voice
-- token that rings incoming calls.

create table if not exists public.shift_people (
  person       public.team_person primary key,
  display_name text not null,
  alert_phone  text check (alert_phone is null or alert_phone ~ '^[0-9]{10}$'),
  alert_email  text check (alert_email is null or alert_email = lower(alert_email)),
  updated_at   timestamptz not null default now()
);
comment on table public.shift_people is
  'Callers on the shared app login: where their hot pings go. Not logins; team_members stays the login list.';

alter table public.shift_people enable row level security;
grant select on public.shift_people to authenticated, service_role;
drop policy if exists shift_people_read on public.shift_people;
create policy shift_people_read on public.shift_people for select to authenticated using (public.is_team());

insert into public.shift_people (person, display_name) values ('thalia', 'Thalia'), ('adil', 'Adil')
on conflict (person) do nothing;

-- One person's alert settings: their own team row when they have a login, else their shift row.
create or replace function public.person_alerts(p_person public.team_person)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r record;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  select alert_phone, alert_email, display_name into r from public.team_members where person = p_person;
  if not found then
    select alert_phone, alert_email, display_name into r from public.shift_people where person = p_person;
  end if;
  if r is null then return jsonb_build_object('ok', false, 'reason', 'not on the team'); end if;
  return jsonb_build_object('ok', true, 'person', p_person, 'name', r.display_name,
                            'alert_phone', r.alert_phone, 'alert_email', r.alert_email);
end $$;

create or replace function public.set_person_alerts(p_person public.team_person, p_phone text, p_email text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare d text; e text;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  d := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  if length(d) = 11 and left(d, 1) = '1' then d := right(d, 10); end if;
  if d <> '' and length(d) <> 10 then return jsonb_build_object('ok', false, 'reason', 'A phone number is 10 digits.'); end if;
  e := lower(btrim(coalesce(p_email, '')));
  if e <> '' and e !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then return jsonb_build_object('ok', false, 'reason', 'That is not an email address.'); end if;
  update public.team_members set alert_phone = nullif(d, ''), alert_email = nullif(e, '') where person = p_person;
  if not found then
    update public.shift_people set alert_phone = nullif(d, ''), alert_email = nullif(e, ''), updated_at = now() where person = p_person;
    if not found then return jsonb_build_object('ok', false, 'reason', 'not on the team'); end if;
  end if;
  return jsonb_build_object('ok', true, 'person', p_person, 'phone', nullif(d, ''), 'email', nullif(e, ''));
end $$;

revoke all on function public.person_alerts(public.team_person), public.set_person_alerts(public.team_person, text, text) from public, anon;
grant execute on function public.person_alerts(public.team_person), public.set_person_alerts(public.team_person, text, text) to authenticated;

-- Hot-ping texts: callers with a login (as before, never the owner: Colin's cell gets every alert anyway)
-- plus the shift rows of callers without one.
create or replace function public.alert_recipients()
returns jsonb language sql stable security definer set search_path = public as $$
  with x as (
    select m.person::text as person, m.alert_phone as phone from public.team_members m where m.role <> 'owner'
    union all
    select s.person::text, s.alert_phone from public.shift_people s
     where not exists (select 1 from public.team_members m where m.person = s.person)
  )
  select coalesce(jsonb_agg(jsonb_build_object('person', person, 'phone', '+1' || right(regexp_replace(phone, '\D', '', 'g'), 10)) order by person), '[]'::jsonb)
    from x where length(regexp_replace(coalesce(phone, ''), '\D', '', 'g')) in (10, 11)
$$;
revoke all on function public.alert_recipients() from public, anon, authenticated;
grant execute on function public.alert_recipients() to service_role;

-- Hot-ping emails: everyone with an alert email, the owner included, one copy per address.
create or replace function public.alert_email_recipients()
returns jsonb language sql stable security definer set search_path = public as $$
  with x as (
    select m.person::text as person, m.alert_email as email from public.team_members m
    union all
    select s.person::text, s.alert_email from public.shift_people s
     where not exists (select 1 from public.team_members m where m.person = s.person)
  ), y as (
    select distinct on (lower(email)) person, lower(email) as email from x
     where coalesce(email, '') ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' order by lower(email), person
  )
  select coalesce(jsonb_agg(jsonb_build_object('person', person, 'email', email) order by person), '[]'::jsonb) from y
$$;
revoke all on function public.alert_email_recipients() from public, anon, authenticated;
grant execute on function public.alert_email_recipients() to service_role;
