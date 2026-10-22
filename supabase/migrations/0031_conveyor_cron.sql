-- The conveyor's timers. Two pg_cron jobs every 15 minutes: the conveyor Edge Function (due text stops,
-- missed stops, the daily canary, the health heartbeat) and belt_watch(), SQL only, which texts Colin
-- through ops_alerts when the heartbeat is older than an hour, live cards sit with no next stop for an
-- hour, overdue stops pass 10, or the canary fails: one text per issue per day. Skipped where pg_cron,
-- pg_net or the shared secret are absent (the local test database).
-- To stop them: select cron.unschedule('wpie-conveyor'); select cron.unschedule('wpie-belt-watch');

-- The canary runs once a day, after 7 AM Central, from the conveyor's run.
create or replace function public.belt_canary_if_due(p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare c public.campaign_control; today date := (p_now at time zone 'America/Chicago')::date;
begin
  select * into c from public.campaign_control where id = 1 for update;
  if c.belt_canary_date = today or extract(hour from p_now at time zone 'America/Chicago') < 7 then return null; end if;
  return public.belt_canary(p_now);
end $$;
revoke all on function public.belt_canary_if_due(timestamptz) from public, anon, authenticated;
grant execute on function public.belt_canary_if_due(timestamptz) to service_role;

do $do$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron')
     and exists (select 1 from pg_extension where extname = 'pg_net')
     and to_regclass('vault.decrypted_secrets') is not null then
    if exists (select 1 from cron.job where jobname = 'wpie-conveyor') then perform cron.unschedule('wpie-conveyor'); end if;
    perform cron.schedule(
      'wpie-conveyor',
      '*/15 * * * *',
      $job$
      select net.http_post(
        url := 'https://jyfetargyaaxcqmxdgft.supabase.co/functions/v1/conveyor',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'x-wpie-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'send_openers_cron_secret')),
        body := '{}'::jsonb,
        timeout_milliseconds := 55000);
      $job$);
    if exists (select 1 from cron.job where jobname = 'wpie-belt-watch') then perform cron.unschedule('wpie-belt-watch'); end if;
    perform cron.schedule('wpie-belt-watch', '7,22,37,52 * * * *', 'select public.belt_watch()');
  end if;
end
$do$;
