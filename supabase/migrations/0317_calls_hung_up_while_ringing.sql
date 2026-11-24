-- 0317: a seller who hangs up while it is still ringing is a missed call like any other.
--
-- Colin 2026-11-24: "There was a second call wasn't there". Juan (3524 Buckingham Rd) called at 10:58, 11:10 and 12:15;
-- only 11:10 reached the card. The phone server writes a missed call (inbound_call_log) only when the ringing runs its
-- course, so a caller who gives up first left nothing: no line on the card, no call-back task, no alert. Twilio shows 90
-- calls to the seller lines in 30 days and 28 never logged. "yes duh" to the fix.
--
-- The call-notes function (?event=rings, pg_cron every minute) lists the calls Twilio finished in the last two hours and
-- hands them here; every one to a seller line that nothing logged becomes inbound_call_log(..., 'missed'), which does what
-- a missed call always did (the card's line, "They called us: call back" for whoever takes missed calls). A call the
-- phone server or the assistant is still writing up is left alone: only calls that ended 90 seconds ago or more come in.

-- the numbers sellers call us on: every line a seller call was ever logged on, and every number we text from
create or replace function public.seller_line_numbers() returns text[]
language sql stable security definer set search_path = public as $fn$
  select coalesce(array_agg(distinct n), '{}') from (
    select '+1' || right(regexp_replace(to_number, '\D', '', 'g'), 10) n from public.inbound_calls where coalesce(to_number, '') <> ''
    union
    select '+1' || right(regexp_replace(from_number, '\D', '', 'g'), 10) from public.messages
     where channel = 'sms' and direction = 'out' and coalesce(from_number, '') ~ '\d{10}') x
  where n ~ '^\+1[2-9][0-9]{9}$'
$fn$;

-- p_calls: [{sid, from, to, start_time, duration}] from Twilio, finished calls only. p_backfill: write each at the time it
-- was made (a one-off look back) instead of now.
create or replace function public.inbound_rings_missed(p_calls jsonb, p_backfill boolean default false, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare lines text[] := public.seller_line_numbers(); c jsonb; sid text; fr text; tn text; n_logged int := 0; n_seen int := 0; res jsonb;
  hits jsonb := '[]'::jsonb; at timestamptz;
begin
  for c in select * from jsonb_array_elements(coalesce(p_calls, '[]'::jsonb)) loop
    sid := c->>'sid'; fr := c->>'from'; tn := '+1' || right(regexp_replace(coalesce(c->>'to', ''), '\D', '', 'g'), 10);
    if coalesce(sid, '') !~ '^CA[0-9A-Fa-f]{32}$' or coalesce(fr, '') !~ '^\+1[2-9][0-9]{9}$' or not (tn = any (lines)) then continue; end if;
    n_seen := n_seen + 1;
    if exists (select 1 from public.inbound_calls i where i.call_sid = sid) or exists (select 1 from public.voice_calls v where v.call_sid = sid) then continue; end if;
    -- a team phone calling a seller line (Colin dialling out through it) is not a seller
    if exists (select 1 from public.team_members m where right(fr, 10) in (right(regexp_replace(coalesce(m.alert_whatsapp, ''), '\D', '', 'g'), 10), right(regexp_replace(coalesce(m.alert_phone, ''), '\D', '', 'g'), 10))) then continue; end if;
    at := case when p_backfill then coalesce(nullif(c->>'start_time', '')::timestamptz, p_now) else p_now end;
    res := public.inbound_call_log(sid, fr, tn, 'missed', nullif(c->>'duration', '')::int, null, at);
    n_logged := n_logged + 1;
    hits := hits || jsonb_build_object('sid', sid, 'from', right(fr, 10), 'matched', res->'matched', 'owner', res->'owner');
  end loop;
  return jsonb_build_object('seller_calls', n_seen, 'logged_now', n_logged, 'calls', hits);
end $fn$;

revoke all on function public.seller_line_numbers(), public.inbound_rings_missed(jsonb, boolean, timestamptz) from public, anon, authenticated;
grant execute on function public.seller_line_numbers(), public.inbound_rings_missed(jsonb, boolean, timestamptz) to service_role;

do $do$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') and exists (select 1 from pg_extension where extname = 'pg_net') then
    if exists (select 1 from cron.job where jobname = 'wpie-missed-rings') then perform cron.unschedule('wpie-missed-rings'); end if;
    perform cron.schedule('wpie-missed-rings', '* * * * *', $job$
      select net.http_post(
        url := 'https://jyfetargyaaxcqmxdgft.supabase.co/functions/v1/call-notes?event=rings',
        headers := jsonb_build_object('Content-Type', 'application/json',
          'x-wpie-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'send_openers_cron_secret')),
        body := '{}'::jsonb, timeout_milliseconds := 30000)
    $job$);
  end if;
end
$do$;
