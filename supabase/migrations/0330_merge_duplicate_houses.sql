-- 0330 (2026-11-27). Colin: "Merge duplicate parcels and split the load giving some to thalia and some to tyler".
-- The desk found 58 houses with two or three live cards (one parcel, or one street address and one owner, loaded once
-- by the laptop and again by an agent with a unit added or the town spelled "City of X"). Half were split between
-- the two callers, which breaks one owner per card.
--
-- 1. agent_merge_cards: the town is compared by muni_key ("CITY OF MADISON" is "Madison"), for everyone. The desk and
--    Colin are not held to the same-address test (their finding is the parcel number, which the laptop writes with a
--    county prefix and an agent without), and may close a duplicate that was texted and never answered. A duplicate a
--    seller wrote back on, one with a promised callback, and one in a deal are refused for everyone, as before.
-- 2. phone_is_shared: a card closed as a duplicate is not a second owner. Before this, the kept card's numbers still
--    read as "shared by two owners" whenever the two cards spelled the name differently ("CAIN, ADAM M" and "ADAM M
--    CAIN"), and the card could not be texted.

CREATE OR REPLACE FUNCTION public.agent_merge_cards(p_keep_lead_id uuid, p_drop_lead_id uuid, p_why text, p_agent text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  who  text := case when lower(coalesce(p_agent, '')) in ('desk', 'colin') then initcap(p_agent) else 'Muse (' || coalesce(p_agent, 'agent') || ')' end;
  people_folded integer := 0;
  why  text := nullif(btrim(coalesce(p_why, '')), '');
  k    public.leads;
  d    public.leads;
  same_property boolean;
  phones_moved integer := 0;
  people_moved integer := 0;
  tasks_closed integer := 0;
  made_dnc boolean := false;
  -- 0330: the desk and Colin merge on their own finding (a parcel number with a county prefix, a street spelled two
  -- ways); an agent still has to show the same parcel or the same address in the same town
  desk_ boolean := lower(coalesce(p_agent, '')) in ('desk', 'colin');
begin
  if why is null then return jsonb_build_object('ok', false, 'reason', 'say why these are one property (reason)'); end if;
  if p_keep_lead_id = p_drop_lead_id then return jsonb_build_object('ok', false, 'reason', 'keep and drop are the same card'); end if;
  select * into k from public.leads where id = p_keep_lead_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card (keep)'); end if;
  select * into d from public.leads where id = p_drop_lead_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card (drop)'); end if;
  same_property := (k.parcel_id is not null and d.parcel_id is not null and k.county is not distinct from d.county and k.parcel_id = d.parcel_id)
                or (public.addr_key_unitless(public.addr_main(k.property_address)) = public.addr_key_unitless(public.addr_main(d.property_address))
                    and (coalesce(lower(k.municipality), '') = coalesce(lower(d.municipality), '')
                         or (public.muni_key(k.municipality) <> '' and public.muni_key(k.municipality) = public.muni_key(d.municipality))));
  if not same_property and not desk_ then
    return jsonb_build_object('ok', false, 'reason', 'not the same property (parcel or address and municipality differ; a unit must agree too): link_cards if they are related, merge nothing');
  end if;
  if d.stage in ('under_contract', 'closed_won', 'offer', 'walkthrough_booked', 'handoff', 'colin_call', 'walk_decision') then
    return jsonb_build_object('ok', false, 'reason', 'the duplicate is in a deal (' || d.stage::text || '): keep it, close the other one instead, or ask');
  end if;
  -- 0330: texts that nobody answered are not a conversation; the desk may close such a duplicate (its texts stop,
  -- the kept card's go on). A seller who wrote back, or a promised callback, still stops everyone.
  if exists (select 1 from public.messages m where m.lead_id = d.id and m.channel = 'sms' and m.provider_sid is not null
                and (not desk_ or m.direction = 'in'))
     or exists (select 1 from public.twilio_inbound ti where ti.lead_id = d.id)
     or exists (select 1 from public.tasks t where t.lead_id = d.id and t.done_at is null and t.kind = 'callback') then
    return jsonb_build_object('ok', false, 'reason', 'the duplicate has a texting thread or a promised callback: link_cards (same_person) and keep both, a merge would cut the conversation off');
  end if;
  -- a stop on the duplicate is a stop on the property
  if d.stage = 'dnc' and k.stage <> 'dnc' then
    perform public.belt_event(k.id, 'move', jsonb_build_object('belt', 'dnc', 'reason', 'do-not-contact on duplicate card ' || d.id::text), who);
    update public.leads set stage = 'dnc' where id = k.id and stage <> 'dnc';
    made_dnc := true;
  end if;
  -- people the kept card does not have (before the phones: contacts_person links a moved phone to a person already on the card by name)
  insert into public.interests (lead_id, person_id, role, status, status_reason, status_at, notes, source, created_at)
  select k.id, i.person_id, i.role, i.status, i.status_reason, i.status_at, i.notes, coalesce(i.source, 'merged from duplicate card'), now()
    from public.interests i where i.lead_id = d.id and not exists (select 1 from public.interests j where j.lead_id = k.id and j.person_id = i.person_id);
  get diagnostics people_moved = row_count;
  -- phones and emails the kept card does not have
  update public.contacts c set lead_id = k.id, updated_at = now()
   where c.lead_id = d.id
     and not exists (select 1 from public.contacts c2 where c2.lead_id = k.id and coalesce(c2.value_normalized, c2.value) = coalesce(c.value_normalized, c.value));
  get diagnostics phones_moved = row_count;
  -- 0298: the same person loaded on both cards is one person on the kept card, and a death is never undone
  people_folded := public.card_fold_same_people(k.id, who);
  -- a number both cards hold: the newer word on whose it is stands when the kept card had it under someone who died, or under nobody
  update public.contacts kc set person_id = dc.person_id, person_name = coalesce(dc.person_name, kc.person_name), updated_at = now()
    from public.contacts dc
   where dc.lead_id = d.id and kc.lead_id = k.id and coalesce(kc.value_normalized, kc.value) = coalesce(dc.value_normalized, dc.value)
     and dc.person_id is not null and dc.person_id is distinct from kc.person_id
     and exists (select 1 from public.interests i join public.people p on p.id = i.person_id
                  where i.lead_id = k.id and i.person_id = dc.person_id and p.status = 'active' and i.status = 'active')
     and (kc.person_id is null or exists (select 1 from public.people p where p.id = kc.person_id and p.status = 'deceased'));
  -- reasons and notes
  update public.leads set
         reasons_to_sell = coalesce((select array_agg(distinct r) from unnest(coalesce(k.reasons_to_sell, '{}') || coalesce(d.reasons_to_sell, '{}')) r), '{}'),
         notes = concat_ws(' | ', notes, 'Merged from duplicate card ' || d.id::text || ' (' || coalesce(d.owner_name, '') || '): ' || left(coalesce(d.notes, ''), 1500)),
         elderly_or_ill = coalesce(elderly_or_ill, false) or coalesce(d.elderly_or_ill, false),
         grief = coalesce(grief, false) or coalesce(d.grief, false),
         updated_at = now()
   where id = k.id;
  insert into public.prospect_reasons (lead_id, kind, detail, event_date, amount, source)
  select k.id, r.kind, r.detail, r.event_date, r.amount, r.source from public.prospect_reasons r
   where r.lead_id = d.id and not exists (select 1 from public.prospect_reasons q where q.lead_id = k.id and q.kind = r.kind and q.detail is not distinct from r.detail);
  insert into public.lead_links (lead_id, other_id, kind, note, added_by) values (k.id, d.id, 'same_person', 'duplicate card merged in', who)
  on conflict (lead_id, other_id, kind) do nothing;
  -- the duplicate closes, its open tasks with it
  perform set_config('wpie.task_outcome', '1', true);
  update public.tasks set done_at = now(), note = concat_ws(' | ', note, 'closed: duplicate card merged into ' || k.id::text || ' by ' || who), updated_at = now()
   where lead_id = d.id and done_at is null;
  get diagnostics tasks_closed = row_count;
  perform set_config('wpie.task_outcome', '', true);
  if d.stage <> 'dnc' then
    update public.leads set stage = 'dead', dead_reason = 'duplicate of card ' || k.id::text || ' (' || why || ')', updated_at = now() where id = d.id;
    perform public.belt_event(d.id, 'move', jsonb_build_object('belt', 'dead', 'reason', 'duplicate of card ' || k.id::text), who);
  end if;
  insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
  values (k.id, 'cards_merged', k.belt, k.belt, k.belt_step, jsonb_build_object('duplicate', d.id, 'phones_moved', phones_moved, 'people_moved', people_moved, 'tasks_closed', tasks_closed, 'made_dnc', made_dnc, 'why', why), now(), who);
  insert into public.messages (lead_id, direction, channel, body, status, sent_at)
  values (k.id, 'out', 'note', 'Duplicate card merged in (' || who || '): ' || phones_moved || ' phone(s), ' || people_moved || ' person record(s). ' || why, null, now());
  return jsonb_build_object('ok', true, 'kept', k.id, 'closed', d.id, 'phones_moved', phones_moved, 'people_moved', people_moved, 'tasks_closed', tasks_closed, 'made_dnc', made_dnc, 'people_folded', people_folded);
end $function$;


create or replace function public.phone_is_shared(p_phone10 text)
 returns boolean
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  with held as (
    select ct.lead_id, ct.person_id, ll.owner_name
      from public.contacts ct join public.leads ll on ll.id = ct.lead_id
     where ct.value_normalized = p_phone10
       and not (ll.stage = 'dead' and coalesce(ll.dead_reason, '') like 'duplicate of card %'))
  select (select count(distinct lead_id) from held) > 1
     and (select count(distinct coalesce(person_id::text, lead_id::text)) from held) > 1
     and (select count(distinct upper(regexp_replace(coalesce(owner_name, ''), '[^A-Za-z0-9]', '', 'g'))) from held) > 1
$function$;
