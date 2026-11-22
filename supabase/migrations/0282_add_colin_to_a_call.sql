-- 0282: a caller adds Colin to their live call (Colin 2026-11-22, "Yeah let's test"). The function call-add asks this
-- first: the card must be the caller's own (card_guard, 0250), and it answers who is asking, which pm-phone matches
-- against the call's own client identity before it moves anything.
create or replace function public.call_add_check(p_lead_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $fn$
declare me text;
begin
  perform public.card_guard(p_lead_id);
  if not public.is_team() then raise exception 'team only'; end if;
  select person::text into me from public.team_members where lower(email) = lower(auth.jwt() ->> 'email');
  if me is null then raise exception 'not on the team'; end if;
  return jsonb_build_object('ok', true, 'person', me);
end $fn$;
revoke all on function public.call_add_check(uuid) from public, anon;
grant execute on function public.call_add_check(uuid) to authenticated, service_role;
