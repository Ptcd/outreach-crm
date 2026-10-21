-- One-time setup for Sam, the reply agent. Run in the Supabase SQL editor AFTER the
-- reply-agent Edge Function is deployed (and after send_openers_cron.sql, which creates the
-- shared secret). It sends nothing by itself: routine replies need the "Sam handles routine
-- replies" switch (off), every other reply needs Colin's Approve, and with the function secret
-- TWILIO_LIVE_SENDING unset every send is recorded as "would send".
--
-- Every minute, all day: new texts are read and decided at once (removals take effect
-- immediately); what may be SENT waits for quiet hours to end (campaign_control.quiet_*).
-- To stop it: select cron.unschedule('wpie-reply-agent');

select cron.schedule(
  'wpie-reply-agent',
  '* * * * *',
  $$
  select net.http_post(
    url := 'https://jyfetargyaaxcqmxdgft.supabase.co/functions/v1/reply-agent',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-wpie-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'send_openers_cron_secret')),
    body := '{}'::jsonb,
    timeout_milliseconds := 55000);
  $$
);
