-- 0326: two new numbers in, and the two flagged numbers released once sellers stop answering them.
--
-- Colin 2026-11-25, of 262-418-0202 (the main seller line) and 262-429-9057 (Thalia's line), both shown as spam on
-- his phone: "Ditch that number and 0202 ... get new numbers", then "Fine keep em but release them 1 month after no
-- response from this date, put a biweekly cron on this. Yes buy them".
--
-- So, from 2026-11-25: neither number dials (call_lines.dial = false, 0325) and 0202 is out of the text sender pool
-- (CAMPAIGN_OPENER_FROM). Both still take calls and texts back. A number is released (deleted at Twilio, which cannot
-- be undone) once 30 days have passed with no seller calling or texting it, counted from 2026-11-25 or from the last
-- time someone did, whichever is later. The check runs on the 1st and the 15th (pg_cron wpie-line-release, the
-- line-release function). It only ever releases a number listed here, never one we still dial or text from.
--
-- The two numbers bought the same day (262-440-9051, 262-228-9462) join the dialing pool now. They are in the texting
-- service, but stay out of the first-text pool until carriers have registered them (a number added to the service
-- sends 30024 for days); that is a later change to CAMPAIGN_OPENER_FROM.

insert into public.call_lines (number, dial, note) values
  ('+12624409051', true, 'Bought 2026-11-25 to replace the two flagged numbers.'),
  ('+12622289462', true, 'Bought 2026-11-25 to replace the two flagged numbers (Cedarburg).')
on conflict (number) do nothing;

update public.campaign_control
   set reply_numbers = reply_numbers || array['+12624409051', '+12622289462']::text[]
 where id = 1 and not ('+12624409051' = any (reply_numbers));

create table if not exists public.line_retirements (
  number          text primary key check (number ~ '^\+1[0-9]{10}$'),
  retired_on      date not null,
  quiet_days      int not null default 30,
  last_inbound_at timestamptz,
  due_on          date,
  checked_at      timestamptz,
  released_at     timestamptz,
  note            text
);
alter table public.line_retirements enable row level security;
grant select on public.line_retirements to authenticated, service_role;
drop policy if exists line_retirements_owner_read on public.line_retirements;
create policy line_retirements_owner_read on public.line_retirements for select to authenticated using (public.is_owner());

insert into public.line_retirements (number, retired_on, note) values
  ('+12624180202', date '2026-11-25', 'Main seller line, shown as spam on Colin''s phone. No longer dials or sends first texts.'),
  ('+12624299057', date '2026-11-25', 'Thalia''s line, shown as spam on Colin''s phone. No longer dials.')
on conflict (number) do nothing;

-- the last time a seller called or texted this number (a team phone does not count)
create or replace function public.line_last_inbound(p_number text) returns timestamptz
language sql stable security definer set search_path = public as $fn$
  with d as (select right(regexp_replace(coalesce(p_number, ''), '\D', '', 'g'), 10) as n),
  team as (
    select right(regexp_replace(x, '\D', '', 'g'), 10) as ph
      from public.team_members m, unnest(array[m.alert_phone, m.alert_whatsapp]) x where coalesce(x, '') <> '')
  select greatest(
    (select max(t.received_at) from public.twilio_inbound t, d
      where right(regexp_replace(coalesce(t.to_number, ''), '\D', '', 'g'), 10) = d.n and t.from10 not in (select ph from team)),
    (select max(i.created_at) from public.inbound_calls i, d
      where right(regexp_replace(coalesce(i.to_number, ''), '\D', '', 'g'), 10) = d.n and i.status <> 'blocked'
        and coalesce(i.from10, '') not in (select ph from team)))
$fn$;

-- which retired numbers are due for release; refreshes each one's last inbound and due date
create or replace function public.line_release_due(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare r public.line_retirements; last timestamptz; due date; out jsonb := '[]'::jsonb; ready jsonb := '[]'::jsonb;
begin
  for r in select * from public.line_retirements where released_at is null order by number loop
    last := public.line_last_inbound(r.number);
    -- counted in Central days from whichever is later: the day it was retired, or the day of the last contact
    due := greatest(r.retired_on, coalesce((last at time zone 'America/Chicago')::date, r.retired_on)) + r.quiet_days;
    update public.line_retirements set last_inbound_at = last, due_on = due, checked_at = p_now where number = r.number;
    out := out || jsonb_build_object('number', r.number, 'last_inbound_at', last, 'due_on', due);
    -- never a number we still dial from
    if due <= (p_now at time zone 'America/Chicago')::date
       and not exists (select 1 from public.call_lines c where c.number = r.number and c.dial) then
      ready := ready || to_jsonb(r.number);
    end if;
  end loop;
  return jsonb_build_object('lines', out, 'due', ready);
end $fn$;

-- the number was released at Twilio: record it, and take it out of everything that still names it
create or replace function public.line_released(p_number text, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $fn$
begin
  update public.line_retirements set released_at = now(), note = concat_ws('; ', note, p_note)
   where number = p_number and released_at is null;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not a retired number, or already released'); end if;
  update public.call_lines set dial = false, note = concat_ws('; ', note, 'released ' || to_char(now() at time zone 'America/Chicago', 'YYYY-MM-DD')),
         updated_at = now() where number = p_number;
  update public.campaign_control set reply_numbers = array_remove(reply_numbers, p_number) where id = 1;
  delete from public.caller_numbers where number = p_number;
  return jsonb_build_object('ok', true);
end $fn$;

revoke all on function public.line_last_inbound(text), public.line_release_due(timestamptz), public.line_released(text, text) from public, anon, authenticated;
grant execute on function public.line_last_inbound(text), public.line_release_due(timestamptz), public.line_released(text, text) to service_role;

do $do$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') and exists (select 1 from pg_extension where extname = 'pg_net') then
    if exists (select 1 from cron.job where jobname = 'wpie-line-release') then perform cron.unschedule('wpie-line-release'); end if;
    -- the 1st and the 15th, 9 AM Central (15:00 UTC; 10 AM in summer)
    perform cron.schedule('wpie-line-release', '0 15 1,15 * *', $job$
      select net.http_post(
        url := 'https://jyfetargyaaxcqmxdgft.supabase.co/functions/v1/line-release',
        headers := jsonb_build_object('Content-Type', 'application/json',
          'x-wpie-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'send_openers_cron_secret')),
        body := '{}'::jsonb, timeout_milliseconds := 60000)
    $job$);
  end if;
end $do$;
