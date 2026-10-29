-- Who a seller calling in should ring (Colin 2026-10-29: "separate them so they don't get the other's cards while
-- dialing"). The forwarding app (pm-phone) asks this before it builds the <Dial> for a seller line; the answer is
-- {ring: [app identities], return_call: bool, dialed_by: who}.
--   1. a return call: the caller who dialed this number from the app in the last hour. That person's app alone, and
--      not Colin's cell (Colin: "if this is a return call it shouldn't ring me, it should be ringing whichever caller
--      called it"), so the seller lands on the screen that just dialed them;
--   2. otherwise, on a weekday 4-6 PM CT both callers are in Power hour: both ring;
--   3. otherwise the person on shift (on_shift_person); off hours, everyone. Colin's cell rings alongside these.
-- A caller is known from belt_events human_call_started (the app's dialer writes one per call, with the phone).
create or replace function public.inbound_call_ring(p_digits text, p_at timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public as $$
  with d as (select right(regexp_replace(coalesce(p_digits, ''), '\D', '', 'g'), 10) as ph),
  last_dialer as (
    select lower(e.by) as who from public.belt_events e, d
     where e.event = 'human_call_started' and e.at > p_at - interval '60 minutes' and e.at <= p_at
       and right(regexp_replace(coalesce(e.payload->>'phone', ''), '\D', '', 'g'), 10) = d.ph and d.ph <> ''
       and lower(e.by) in ('thalia', 'adil', 'colin')
     order by e.at desc limit 1),
  shift as (select public.on_shift_person(p_at)::text as who,
                   extract(isodow from p_at at time zone 'America/Chicago') between 1 and 5
                   and (p_at at time zone 'America/Chicago')::time >= time '16:00' and (p_at at time zone 'America/Chicago')::time < time '18:00' as power_hour)
  select jsonb_build_object(
    'ring', to_jsonb(case
      when (select who from last_dialer) is not null then array[(select who from last_dialer)]
      when (select power_hour from shift) then array['thalia', 'adil']
      when (select who from shift) = 'colin' then array['colin', 'thalia', 'adil']
      else array[(select who from shift)] end),
    'return_call', (select who from last_dialer) is not null,
    'dialed_by', (select who from last_dialer))
$$;
revoke all on function public.inbound_call_ring(text, timestamptz) from public, anon, authenticated;
grant execute on function public.inbound_call_ring(text, timestamptz) to service_role;
