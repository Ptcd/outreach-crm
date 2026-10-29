-- Weekdays 5-6 PM CT belong to Adil (Colin 2026-10-29: Adil's weekday calling session is 4-6 PM; Thalia's shift ends
-- at 5). Until now on_shift_person said "colin" from 5 PM on weekdays, so a seller calling back during the second
-- half of Power hour got a call-back task in Colin's name and no caller was told (0139 emails only callers).
-- 4-5 PM stays Thalia's as before; inbound_call_ring already rings both callers 4-6 PM.
create or replace function public.on_shift_person(p_at timestamptz default now())
returns public.team_person language sql stable as $$
  select case
    when extract(isodow from p_at at time zone 'America/Chicago') between 1 and 5
         and (p_at at time zone 'America/Chicago')::time >= time '09:00' and (p_at at time zone 'America/Chicago')::time < time '17:00'
      then 'thalia'
    when extract(isodow from p_at at time zone 'America/Chicago') between 1 and 5
         and (p_at at time zone 'America/Chicago')::time >= time '17:00' and (p_at at time zone 'America/Chicago')::time < time '18:00'
      then 'adil'
    when extract(isodow from p_at at time zone 'America/Chicago') >= 6
         and (p_at at time zone 'America/Chicago')::time >= time '08:00' and (p_at at time zone 'America/Chicago')::time < time '20:00'
      then 'adil'
    else 'colin' end::public.team_person
$$;
