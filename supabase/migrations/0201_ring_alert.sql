-- 0201: what the phone system needs to buzz the caller the moment a seller calls (Colin 2026-11-07, Adil in
-- Pakistan: "It rings like it's a blip ... or it doesn't ring"; forwarding to a cell is out). inbound_call_ring now
-- also returns, for the people it names, their WhatsApp alert numbers (team_members.alert_whatsapp) and the card the
-- calling phone sits on, so pm-phone can push "X is calling now" through the app and WhatsApp while the app rings.

create or replace function public.inbound_call_ring(p_digits text, p_at timestamp with time zone default now())
returns jsonb language sql stable security definer set search_path = public as $$
  with d as (select right(regexp_replace(coalesce(p_digits, ''), '\D', '', 'g'), 10) as ph),
  last_dialer as (
    select lower(e.by) as who from public.belt_events e, d
     where e.event = 'human_call_started' and e.at > p_at - interval '60 minutes' and e.at <= p_at
       and right(regexp_replace(coalesce(e.payload->>'phone', ''), '\D', '', 'g'), 10) = d.ph and d.ph <> ''
       and lower(e.by) in ('thalia', 'adil', 'colin')
     order by e.at desc limit 1),
  card as (
    select l.id, l.owner_name, l.property_address, l.municipality, l.locked_to::text as who
      from public.contacts c join public.leads l on l.id = c.lead_id, d
     where c.kind = 'phone' and c.value_normalized = d.ph and d.ph <> ''
     order by (l.locked_to is not null) desc, l.locked_at desc nulls last limit 1),
  locked as (select who from card where who in ('thalia', 'adil')),
  shift as (select public.on_shift_person(p_at)::text as who,
                   extract(isodow from p_at at time zone 'America/Chicago') between 1 and 5
                   and (p_at at time zone 'America/Chicago')::time >= time '16:00' and (p_at at time zone 'America/Chicago')::time < time '18:00' as power_hour),
  ring as (
    select case
      when (select who from last_dialer) is not null then array[(select who from last_dialer)]
      when (select who from locked) is not null then array[(select who from locked)]
      when (select power_hour from shift) then array['thalia', 'adil']
      when (select who from shift) = 'colin' then array['colin', 'thalia', 'adil']
      else array[(select who from shift)] end as who)
  select jsonb_build_object(
    'ring', to_jsonb((select who from ring)),
    'return_call', (select who from last_dialer) is not null,
    'locked_to', (select who from locked),
    'dialed_by', (select who from last_dialer),
    'whatsapp', (select coalesce(jsonb_object_agg(m.person::text, m.alert_whatsapp), '{}'::jsonb)
                   from public.team_members m where m.person::text in (select unnest(r.who) from ring r) and m.alert_whatsapp is not null),
    'card', (select jsonb_build_object('lead_id', c.id, 'owner_name', c.owner_name, 'address', c.property_address, 'municipality', c.municipality) from card c))
$$;
