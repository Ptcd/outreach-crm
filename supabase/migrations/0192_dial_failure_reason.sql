-- 0192: an in-app dial that never reached the phone company records WHY (Adil 2026-11-05: 56 dials in a row
-- failed in 1.4 s with "Call failed ... undefined" and the event only said "the call never reached the phone
-- company"; nothing on the server said what the phone saw). The app passes the dialer's own error text and the
-- Twilio device state; they ride in the human_call_resumed event's payload as client_error. Same release as
-- before otherwise. The two-argument form is dropped (a default on the new one would make the named call
-- ambiguous); every caller names its arguments or passes two positionals, which the default covers.
drop function if exists public.release_unclaimed_human_call(uuid, text);

create or replace function public.release_unclaimed_human_call(p_lead_id uuid, p_key text, p_error text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare who text; r jsonb; e text := nullif(left(btrim(coalesce(p_error, '')), 300), '');
begin
  if not public.is_team() then raise exception 'team only'; end if;
  select tm.display_name into who from public.team_members tm where lower(tm.email) = lower(auth.jwt() ->> 'email');
  r := public.release_unclaimed_call_core(p_lead_id, p_key, 'the call never reached the phone company', coalesce(who, 'team'), now());
  if e is not null and coalesce((r->>'released')::boolean, false) then
    update public.belt_events set payload = payload || jsonb_build_object('client_error', e)
     where lead_id = p_lead_id and event = 'human_call_resumed' and payload->>'key' = 'human_resume:' || p_key;
  end if;
  return r;
end $function$;

revoke all on function public.release_unclaimed_human_call(uuid, text, text) from public;
grant execute on function public.release_unclaimed_human_call(uuid, text, text) to authenticated;
