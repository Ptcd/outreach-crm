-- Sam's timer: call the reply-agent Edge Function every minute (same as
-- supabase/setup/reply_agent_cron.sql, as a migration so `supabase db push` sets it up).
-- Skipped where pg_cron, pg_net or the shared secret (send_openers_cron.sql) are absent,
-- e.g. the local test database. It sends nothing by itself: routine replies need Colin's
-- switch, real replies need his Approve, and without TWILIO_LIVE_SENDING=1 every send is
-- recorded as "would send". To stop it: select cron.unschedule('wpie-reply-agent');
do $do$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron')
     and exists (select 1 from pg_extension where extname = 'pg_net')
     and to_regclass('vault.decrypted_secrets') is not null then
    if exists (select 1 from cron.job where jobname = 'wpie-reply-agent') then
      perform cron.unschedule('wpie-reply-agent');
    end if;
    perform cron.schedule(
      'wpie-reply-agent',
      '* * * * *',
      $job$
      select net.http_post(
        url := 'https://jyfetargyaaxcqmxdgft.supabase.co/functions/v1/reply-agent',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'x-wpie-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'send_openers_cron_secret')),
        body := '{}'::jsonb,
        timeout_milliseconds := 55000);
      $job$);
  end if;
end
$do$;
