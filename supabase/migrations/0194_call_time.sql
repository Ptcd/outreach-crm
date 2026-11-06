-- 0194: call time, Saturday to Friday, per caller (Colin 2026-11-06: "make a thing to show me and then thalia and adil
-- how much time they've been calling for the week starting Saturday to Friday, individually not together").
--
-- The app never held a call's length: call_recordings is empty and messages' call rows carry only the outcome. The
-- phone company does: every dial from the app is a Twilio leg from client:<person>, with a start, a status and a
-- duration. The laptop already reads the account's calls every ten minutes (calls seen); now it also copies each
-- caller's own legs here (wpie.live.call_legs push), and call_time_week sums them by day.
--
-- Who sees what: Colin sees both callers; a caller sees only herself (the function decides from the login, the
-- table itself has no read policy). A week runs Saturday to Friday, Central time; any date names its week.

create table if not exists public.call_legs (
  call_sid text primary key,
  caller public.team_person not null,
  direction text not null default 'out',
  phone10 text,
  started_at timestamptz not null,
  duration_s integer not null default 0,
  status text,
  updated_at timestamptz not null default now()
);
create index if not exists call_legs_caller_started_idx on public.call_legs (caller, started_at);
alter table public.call_legs enable row level security;
-- no policy: the laptop writes as the database owner, the team reads through call_time_week

create or replace function public.call_time_week(p_week_start date default null)
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare me public.team_person := public.wpie_person();
        today date := (now() at time zone 'America/Chicago')::date;
        ws date; we date; who public.team_person[];
begin
  if not public.is_team() then raise exception 'team only'; end if;
  ws := coalesce(p_week_start, today);
  ws := ws - ((extract(dow from ws)::int + 1) % 7);   -- the Saturday on or before: Sat=6 -> 0 back, Sun=0 -> 1 back, Fri=5 -> 6 back
  we := ws + 6;
  who := case when me in ('thalia', 'adil') then array[me] else array['thalia', 'adil']::public.team_person[] end;
  return jsonb_build_object('week_start', ws, 'week_end', we, 'me', me,
    'people', coalesce((select jsonb_agg(jsonb_build_object('person', p, 'days', (
        select jsonb_agg(jsonb_build_object('day', d.d::date, 'dials', coalesce(x.dials, 0), 'connected', coalesce(x.connected, 0),
                 'talk_s', coalesce(x.talk_s, 0), 'first_at', x.first_at, 'last_at', x.last_at,
                 'span_s', coalesce(extract(epoch from (x.last_at - x.first_at))::int, 0)) order by d.d)
          from generate_series(ws, we, interval '1 day') d(d)
          left join (select (started_at at time zone 'America/Chicago')::date as day, count(*) as dials,
                            count(*) filter (where status = 'completed' and duration_s > 0) as connected,
                            coalesce(sum(duration_s) filter (where status = 'completed'), 0) as talk_s,
                            min(started_at) as first_at, max(started_at) as last_at
                       from public.call_legs where caller = p and (started_at at time zone 'America/Chicago')::date between ws and we
                      group by 1) x on x.day = d.d::date
      )) order by array_position(who, p)) from unnest(who) as p), '[]'::jsonb));
end $$;
revoke all on function public.call_time_week(date) from public, anon;
grant execute on function public.call_time_week(date) to authenticated;
