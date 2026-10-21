-- The carrier-filter brake re-tripped on the first send after a clear (2026-10-21): it counted
-- filter codes among the last 50 claimed sends, including the ones that caused the pause, so a
-- clear could never stick until 50 clean sends happened. It now counts only sends claimed after
-- the latest clear, like the laptop watchdog ("the rules now only count sends made from here
-- on"). Threshold unchanged: 3 filtered among the last 50.
-- Who cleared and when is kept on campaign_control (pause_cleared_at / pause_cleared_by) and in
-- opener_send_events. A clear from anywhere (the app's button, the laptop's push, SQL) sets the
-- time: a trigger stamps it whenever paused goes from true to false.

alter table public.campaign_control
  add column if not exists pause_cleared_at timestamptz,
  add column if not exists pause_cleared_by text;

create or replace function public.campaign_control_cleared_stamp() returns trigger
language plpgsql as $$
begin
  if old.paused and not new.paused then
    if new.pause_cleared_at is not distinct from old.pause_cleared_at then new.pause_cleared_at := now(); end if;
    if new.pause_cleared_by is not distinct from old.pause_cleared_by then new.pause_cleared_by := coalesce(
      (select display_name from public.team_members where lower(email) = lower(auth.jwt() ->> 'email')), current_user::text); end if;
  end if;
  return new;
end $$;
drop trigger if exists campaign_control_cleared on public.campaign_control;
create trigger campaign_control_cleared before update of paused on public.campaign_control
  for each row execute function public.campaign_control_cleared_stamp();

drop function if exists public.clear_pause();
create or replace function public.clear_pause(p_by text default null)
returns void language plpgsql security definer set search_path = public as $$
declare who text;
begin
  if not public.is_owner() then raise exception 'only Colin (owner) can clear a pause'; end if;
  select display_name into who from public.team_members where lower(email) = lower(auth.jwt() ->> 'email');
  who := coalesce(nullif(btrim(coalesce(p_by, '')), ''), who, 'owner');
  update public.campaign_control
     set paused = false, pause_reason = null, paused_at = null, pause_cleared_at = now(), pause_cleared_by = who, updated_at = now()
   where id = 1;
  insert into public.opener_send_events (event, actor) values ('pause_cleared', who);
end $$;
revoke all on function public.clear_pause(text) from public, anon;
grant execute on function public.clear_pause(text) to authenticated;

create or replace function public.check_filter_rule(p_now timestamptz default now())
returns void language plpgsql security definer set search_path = public as $$
declare
  c public.campaign_control;
  n integer;
begin
  select * into c from public.campaign_control where id = 1;
  select count(*) into n from (
    select p.error_code from public.planned_openers p
     where p.claim_mode = 'live' and p.claimed_at is not null
       and p.claimed_at > coalesce(c.pause_cleared_at, '-infinity'::timestamptz)
     order by p.claimed_at desc limit c.rolling_sends) x
   where x.error_code = any(c.filter_codes);
  if n >= c.filtered_max then
    perform public.trip_pause(format('%s carrier-filtered texts (%s) among the last %s sends since the last clear',
                                     n, array_to_string(c.filter_codes, '/'), c.rolling_sends), p_now);
  end if;
end $$;
