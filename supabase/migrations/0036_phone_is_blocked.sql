-- The dialer fails closed on a blocked number (Codex's audit, 2026-10-22; Colin: "Go do it"). The app hides
-- the Call button on a blocked contact, but pm-phone's /api/twilio/voice/client would place a call to any
-- number the browser sent. Now pm-phone asks this function first (as service_role, over the REST endpoint)
-- and dials only on a clean {blocked: false}; a lookup that cannot run is a refusal on its side.
--
-- Blocked: the 10-digit number is on suppressed_phones (STOP replies, do-not-contact calls, WPIE's lists;
-- the row's reason is returned), or any contacts row for it is suppressed / dnc_app / dnc_vendor /
-- dnc_scrub = 'dnc' / status = 'bad' (the reason names which). Anything that is not a 10-digit number is
-- blocked too. Only service_role may call it: a browser never asks the block list through this.
create or replace function public.phone_is_blocked(p_phone10 text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  d text := right(regexp_replace(coalesce(p_phone10, ''), '\D', '', 'g'), 10);
  r text;
  why text[];
begin
  if d !~ '^[0-9]{10}$' then
    return jsonb_build_object('blocked', true, 'reason', 'not a 10-digit number');
  end if;
  select s.reason into r from public.suppressed_phones s where s.phone10 = d;
  if found then
    return jsonb_build_object('blocked', true, 'reason', 'suppressed: ' || coalesce(r, 'on the suppression list'));
  end if;
  select array_agg(distinct f order by f) into why
    from public.contacts c
    cross join lateral unnest(array_remove(array[
      case when c.suppressed then 'texted STOP / suppressed' end,
      case when c.dnc_app then 'do-not-contact (app)' end,
      case when c.dnc_vendor then 'do-not-contact (vendor)' end,
      case when c.dnc_scrub = 'dnc' then 'do-not-contact (scrub)' end,
      case when c.status = 'bad' then 'bad number' end], null)) f
   where c.value_normalized = d;
  if why is not null and array_length(why, 1) > 0 then
    return jsonb_build_object('blocked', true, 'reason', 'contact: ' || array_to_string(why, ', '));
  end if;
  return jsonb_build_object('blocked', false, 'reason', null);
end $$;
revoke all on function public.phone_is_blocked(text) from public, anon, authenticated;
grant execute on function public.phone_is_blocked(text) to service_role;
