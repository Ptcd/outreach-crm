-- The morning-of reminders say "today around {time}", and {time} printed the weekday too ("today around Tue 6:00 PM").
-- Only those two reminders use {time}, so it is now the clock time alone ("today around 6:00 PM").
create or replace function public.belt_fmt_time(p_at timestamptz, p_tz text) returns text language sql immutable as $$
  select case when p_at is null then 'the time we set'
              else ltrim(to_char(p_at at time zone p_tz, 'FMHH12:MI AM'), '0') end
$$;
