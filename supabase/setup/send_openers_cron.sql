-- One-time setup for the send-openers timer. Run in the Supabase SQL editor AFTER the
-- two Edge Functions are deployed. It turns nothing on: with the function secret
-- TWILIO_LIVE_SENDING unset and the app switch off, every run is a dry run.
--
-- What it does:
--   1. makes a random shared secret and keeps it in Vault (nobody types or sees it);
--   2. every 5 minutes, 14:00-00:59 UTC (covers 10:00-18:15 Central in summer and winter;
--      Sundays and the exact window are enforced in the database),
--      every day, calls send-openers with that secret. The database decides
--      whether anything is actually due; outside the window a run does nothing.
--
-- To stop the timer completely: select cron.unschedule('wpie-send-openers');

create extension if not exists pg_cron;
create extension if not exists pg_net;

select vault.create_secret(replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''), 'send_openers_cron_secret',
                           'shared secret pg_cron sends to the send-openers Edge Function')
 where not exists (select 1 from vault.secrets where name = 'send_openers_cron_secret');

select cron.schedule(
  'wpie-send-openers',
  '*/5 14-23,0 * * *',
  $$
  select net.http_post(
    url := 'https://jyfetargyaaxcqmxdgft.supabase.co/functions/v1/send-openers',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-wpie-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'send_openers_cron_secret')),
    body := '{}'::jsonb,
    timeout_milliseconds := 55000);
  $$
);
