-- 0298: what Muse 2 was stuck on (desk 364, 365; room 160, 162, 171), and Colin 2026-11-22: "2100 illinois st merge
-- cards. Fix stuff for muse 2, read posts and the room".
--
--   * A load for a house we already have made a second card when the ZIP differed (the card had 53403, Muse 2 sent
--     53405): one house, two cards, two callers, and the new one in line for a first text by name on an estate.
--     agent_add_prospect now also matches on the same street address in the same town.
--   * A merge of two cards put the same people on the kept card twice, and brought the owner who died back as a
--     living owner. card_fold_same_people makes same-named people on one card one person; the stricter status wins.
--   * phones_wanted handed Muse 2 back owners it had already traced with no number found (30 of 50 on Nov 22):
--     there was nothing to mark. agent_phones_wanted_none marks them; they are not handed out again for 30 days.
--   * Muse 2's key gets the tools it was told to use and did not have: estate_people, estate_people_done and
--     category_instructions (read only).

create or replace function public.muni_key(p text) returns text
language sql immutable as $fn$
  select regexp_replace(regexp_replace(regexp_replace(lower(btrim(coalesce(p, ''))), '^(city|village|town|township) of ', ''),
                                       '\s*\((city|village|town)\)$', ''), '[^a-z0-9]', '', 'g')
$fn$;

-- same-named people on one card are one person: the oldest record is kept (a death or a do-not-contact first), the
-- phones follow, and the other record goes
create or replace function public.card_fold_same_people(p_lead_id uuid, p_by text default null) returns integer
language plpgsql security definer set search_path = public as $fn$
declare g record; keep_i public.interests; keep_p public.people; o record; n integer := 0; st_ text;
begin
  for g in
    select p.name_key from public.interests i join public.people p on p.id = i.person_id
     where i.lead_id = p_lead_id and coalesce(p.name_key, '') <> '' group by p.name_key having count(distinct p.id) > 1
  loop
    select i.* into keep_i from public.interests i join public.people p on p.id = i.person_id
     where i.lead_id = p_lead_id and p.name_key = g.name_key
     order by (p.status = 'deceased' or i.status = 'deceased') desc, (p.status = 'do_not_contact' or i.status = 'do_not_contact') desc, i.created_at, i.id limit 1;
    select * into keep_p from public.people where id = keep_i.person_id;
    for o in select i.id as interest_id, i.status as i_status, i.status_reason as i_reason, p.* from public.interests i join public.people p on p.id = i.person_id
              where i.lead_id = p_lead_id and p.name_key = g.name_key and p.id <> keep_p.id loop
      st_ := case when 'deceased' in (keep_p.status, o.status) then 'deceased' when 'do_not_contact' in (keep_p.status, o.status) then 'do_not_contact' else keep_p.status end;
      update public.people set status = st_, status_reason = case when st_ <> keep_p.status then coalesce(o.status_reason, status_reason) else status_reason end,
             notes = concat_ws(' | ', notes, nullif(o.notes, '')),
             mailing_street = coalesce(mailing_street, o.mailing_street), mailing_city = coalesce(mailing_city, o.mailing_city),
             mailing_state = coalesce(mailing_state, o.mailing_state), mailing_zip = coalesce(mailing_zip, o.mailing_zip), updated_at = now()
       where id = keep_p.id;
      if keep_i.status = 'active' and o.i_status <> 'active' then
        update public.interests set status = o.i_status, status_reason = o.i_reason, status_at = now() where id = keep_i.id;
      end if;
      update public.contacts set person_id = keep_p.id, updated_at = now() where person_id = o.id;
      -- the same person on another card (the duplicate that was closed): that card points at the kept record too
      update public.interests x set person_id = keep_p.id
       where x.person_id = o.id and x.lead_id <> p_lead_id
         and not exists (select 1 from public.interests y where y.lead_id = x.lead_id and y.person_id = keep_p.id);
      delete from public.interests where person_id = o.id;
      delete from public.people where id = o.id and not exists (select 1 from public.contacts c where c.person_id = o.id);
      n := n + 1;
    end loop;
  end loop;
  if n > 0 then
    insert into public.messages (lead_id, direction, channel, body, status, sent_at)
    values (p_lead_id, 'out', 'note', n::text || ' duplicate person record' || case when n = 1 then '' else 's' end || ' on this card folded into the same-named person'
            || coalesce(' (' || nullif(btrim(p_by), '') || ')', '') || '. Phones kept; a death or a do-not-contact stands.', null, now());
  end if;
  return n;
end $fn$;
revoke all on function public.card_fold_same_people(uuid, text) from public, anon, authenticated;
grant execute on function public.card_fold_same_people(uuid, text) to service_role;

alter table public.phones_wanted add column if not exists tried_at timestamptz;
alter table public.phones_wanted add column if not exists tried_by text;
alter table public.phones_wanted add column if not exists tried_note text;

create or replace function public.agent_phones_wanted_none(p_agent text, p_ids jsonb, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare ids integer[]; n integer;
begin
  if jsonb_typeof(p_ids) <> 'array' or jsonb_array_length(p_ids) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'no_number is a list of wpie_owner_id values: the owners you traced and found no number for');
  end if;
  select array_agg((x #>> '{}')::integer) into ids from jsonb_array_elements(p_ids) x where (x #>> '{}') ~ '^[0-9]+$';
  update public.phones_wanted w set tried_at = now(), tried_by = p_agent, tried_note = left(nullif(btrim(coalesce(p_note, '')), ''), 500), updated_at = now()
   where w.wpie_owner_id = any (coalesce(ids, '{}')) and w.done_at is null;
  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'marked', n, 'sent', jsonb_array_length(p_ids),
    'say', n::text || ' owner' || case when n = 1 then '' else 's' end || ' marked as traced with no number found. They are not handed out again for 30 days.');
end $fn$;
revoke all on function public.agent_phones_wanted_none(text, jsonb, text) from public, anon, authenticated;
grant execute on function public.agent_phones_wanted_none(text, jsonb, text) to service_role;

-- Muse 2's key (0214: its own tool list): the tools it was pointed at and did not have
update public.agent_keys set tools = (select array_agg(distinct t) from unnest(tools || array['estate_people', 'estate_people_done', 'category_instructions']) t)
 where name = 'Muse 2' and tools is not null and revoked_at is null;

CREATE OR REPLACE FUNCTION public.agent_add_prospect(p jsonb, p_agent text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  ak     text := public.addr_key(p->>'address');
  akm    text := public.addr_key(public.addr_main(p->>'address'));
  zip    text := left(coalesce(p->>'zip', ''), 5);
  ints   jsonb;
  it     jsonb;
  own    jsonb;
  owner  text;
  lid    uuid;
  ex     public.leads;
  status text := 'created';
  ph     jsonb;
  r      jsonb;
  num    text;
  pid    uuid;
  iid    uuid;
  v_kind text;
  firstnum text;
  added  jsonb := '[]'::jsonb;
  skipped jsonb := '[]'::jsonb;
  results jsonb := '[]'::jsonb;
  mine   jsonb;
  reasons text[];
  filled text[] := '{}';
  -- the parcel: the door's parcel field, else a single "Parcel:" line in the notes (two different ones: none) (0161)
  v_parcel text := coalesce(nullif(left(btrim(coalesce(p->>'parcel', p->>'parcel_id')), 80), ''),
                            case when cardinality(public.notes_parcels(p->>'notes')) = 1 then (public.notes_parcels(p->>'notes'))[1] end);
  roles  text[] := array['owner_of_record', 'co_owner', 'personal_representative', 'special_administrator', 'heir', 'trustee', 'spouse', 'occupant', 'other'];
begin
  if ak is null then return jsonb_build_object('status', 'rejected', 'reason', 'no address'); end if;
  ints := case when jsonb_typeof(p->'interests') = 'array' and jsonb_array_length(p->'interests') > 0 then p->'interests'
               else jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('name', p->>'owner_name', 'role', 'owner_of_record', 'legacy', true,
                      'mailing_street', p->>'mailing_street', 'mailing_city', p->>'mailing_city', 'mailing_state', p->>'mailing_state',
                      'mailing_zip', p->>'mailing_zip', 'phones', coalesce(p->'phones', '[]'::jsonb)))) end;
  for it in select * from jsonb_array_elements(ints) loop
    if coalesce(btrim(it->>'name'), '') = '' then return jsonb_build_object('status', 'rejected', 'reason', 'every person needs a name'); end if;
    if coalesce(it->>'role', 'other') <> all(roles) then
      return jsonb_build_object('status', 'rejected', 'reason', 'role is one of ' || array_to_string(roles, ', '));
    end if;
  end loop;
  select x into own from jsonb_array_elements(ints) x where x->>'role' = 'owner_of_record' limit 1;
  owner := coalesce(nullif(btrim(p->>'owner_name'), ''), own->>'name', ints->0->>'name');
  if coalesce(btrim(owner), '') = '' then return jsonb_build_object('status', 'rejected', 'reason', 'no owner name'); end if;
  own := coalesce(own, '{}'::jsonb);
  -- the laptop's owner id (phones_wanted, 0190): the card for that owner, whatever its address spelling
  if coalesce(p->>'wpie_owner_id', '') ~ '^[0-9]+$' then
    select * into ex from public.leads l where l.wpie_owner_id = (p->>'wpie_owner_id')::int;
  end if;
  if ex.id is null then
  select * into ex from public.leads l
   where (public.addr_key(l.property_address) = ak or public.addr_key(public.addr_main(l.property_address)) = akm)
     -- 0298: a ZIP that differs is not a different house when the town is the same (2100 Illinois St, Racine: the card
     -- said 53403, the load said 53405, and a second card was made for one house, with a second caller)
     and (zip = '' or coalesce(l.property_zip, '') = '' or left(l.property_zip, 5) = zip
          or (public.muni_key(l.municipality) <> '' and public.muni_key(l.municipality) = public.muni_key(coalesce(p->>'city', p->>'municipality'))
              and (coalesce(l.county, '') = '' or coalesce(p->>'county', '') = '' or lower(btrim(l.county)) = lower(btrim(p->>'county')))))
   order by (public.addr_key(l.property_address) = ak) desc, (lower(l.owner_name) = lower(owner)) desc, (l.wpie_owner_id > 0) desc, l.created_at limit 1;
  end if;
  select coalesce(array_agg(distinct coalesce(nullif(x->>'label', ''), x->>'kind')), '{}') into reasons
    from jsonb_array_elements(coalesce(p->'reasons', '[]'::jsonb)) x where coalesce(x->>'kind', '') <> '';
  if ex.id is null then
    insert into public.leads (wpie_owner_id, owner_name, owner_type, mailing_street, mailing_city, mailing_state, mailing_zip,
                              lane, county, municipality, property_address, property_zip, property_type, units,
                              reasons_to_sell, stage, source, notes, parcel_id)
    values (case when coalesce(p->>'wpie_owner_id', '') ~ '^[0-9]+$' then (p->>'wpie_owner_id')::int else -nextval('public.agent_prospect_seq') end, owner, nullif(p->>'owner_type', ''),
            nullif(coalesce(p->>'mailing_street', own->>'mailing_street'), ''), nullif(coalesce(p->>'mailing_city', own->>'mailing_city'), ''),
            nullif(coalesce(p->>'mailing_state', own->>'mailing_state'), ''), nullif(coalesce(p->>'mailing_zip', own->>'mailing_zip'), ''),
            case when p->>'lane' = 'hold' then 'hold'::public.lead_lane else 'flip'::public.lead_lane end,
            nullif(p->>'county', ''), nullif(coalesce(p->>'city', p->>'municipality'), ''), btrim(p->>'address'),
            nullif(p->>'zip', ''), nullif(p->>'property_type', ''), nullif(p->>'units', '')::int,
            reasons, 'opener_queued', coalesce(nullif(p->>'source', ''), 'muse'), nullif(p->>'notes', ''), v_parcel)
    returning id into lid;
  else
    lid := ex.id;
    status := case when ex.wpie_owner_id < 0 then 'updated' else 'already_have' end;
    -- verified facts fill the card's EMPTY fields, never overwrite one (0129): before, they only went into the notes
    if ex.property_zip is null and nullif(p->>'zip', '') is not null then filled := filled || 'property_zip'::text; end if;
    if ex.mailing_street is null and nullif(coalesce(p->>'mailing_street', own->>'mailing_street'), '') is not null then filled := filled || 'mailing_address'::text; end if;
    if ex.units is null and coalesce(p->>'units', '') ~ '^[0-9]+$' then filled := filled || 'units'::text; end if;
    if ex.property_type is null and nullif(p->>'property_type', '') is not null then filled := filled || 'property_type'::text; end if;
    if ex.county is null and nullif(p->>'county', '') is not null then filled := filled || 'county'::text; end if;
    if ex.municipality is null and nullif(coalesce(p->>'city', p->>'municipality'), '') is not null then filled := filled || 'municipality'::text; end if;
    if ex.owner_type is null and nullif(p->>'owner_type', '') is not null then filled := filled || 'owner_type'::text; end if;
    -- an agent card's empty parcel is filled (0161); a laptop card's parcel is the laptop's, never the agent's
    if ex.wpie_owner_id < 0 and coalesce(btrim(ex.parcel_id), '') = '' and v_parcel is not null then filled := filled || 'parcel_id'::text; end if;
    update public.leads set reasons_to_sell = coalesce((select array_agg(distinct x) from unnest(reasons_to_sell || reasons) x), '{}'::text[]),
           notes = case when nullif(p->>'notes', '') is null then notes else concat_ws(' | ', notes, 'Muse: ' || (p->>'notes')) end,
           property_zip = coalesce(property_zip, nullif(left(p->>'zip', 10), '')),
           -- the mailing address goes in whole or not at all: never one card's street with another's ZIP
           mailing_street = case when 'mailing_address' = any(filled) then nullif(coalesce(p->>'mailing_street', own->>'mailing_street'), '') else mailing_street end,
           mailing_city = case when 'mailing_address' = any(filled) then nullif(coalesce(p->>'mailing_city', own->>'mailing_city'), '') else mailing_city end,
           mailing_state = case when 'mailing_address' = any(filled) then nullif(coalesce(p->>'mailing_state', own->>'mailing_state'), '') else mailing_state end,
           mailing_zip = case when 'mailing_address' = any(filled) then nullif(coalesce(p->>'mailing_zip', own->>'mailing_zip'), '') else mailing_zip end,
           units = coalesce(units, case when coalesce(p->>'units', '') ~ '^[0-9]+$' then (p->>'units')::int end),
           property_type = coalesce(property_type, nullif(p->>'property_type', '')),
           county = coalesce(county, nullif(p->>'county', '')),
           municipality = coalesce(municipality, nullif(coalesce(p->>'city', p->>'municipality'), '')),
           owner_type = coalesce(owner_type, nullif(p->>'owner_type', '')),
           parcel_id = case when 'parcel_id' = any(filled) then v_parcel else parcel_id end,
           updated_at = now()
     where id = lid;
  end if;
  for it in select * from jsonb_array_elements(ints) loop
    mine := '[]'::jsonb;
    pid := null; iid := null;
    if not (it ? 'legacy') then
      v_kind := case when it->>'kind' in ('person', 'entity', 'household') then it->>'kind'
                   when it->>'role' = 'owner_of_record' and (coalesce(p->>'owner_type', '') not in ('individual', 'couple', '') or public.is_entity_name(it->>'name')) then 'entity'
                   when it->>'role' = 'owner_of_record' and (p->>'owner_type' = 'couple' or (it->>'name') ~ '&| AND ') then 'household'
                   when public.is_entity_name(it->>'name') then 'entity' else 'person' end;
      -- the same name already on this card is the same person
      select i.person_id into pid from public.interests i join public.people pe on pe.id = i.person_id
       where i.lead_id = lid and pe.name_key = public.person_key(it->>'name', v_kind) limit 1;
      if pid is null then
        select right(regexp_replace(coalesce(case when jsonb_typeof(x) = 'string' then x #>> '{}' else x->>'number' end, ''), '\D', '', 'g'), 10) into firstnum
          from jsonb_array_elements(coalesce(it->'phones', '[]'::jsonb)) x limit 1;
        pid := public.person_for(it->>'name', v_kind, nullif(it->>'mailing_street', ''), nullif(it->>'mailing_city', ''), nullif(it->>'mailing_state', ''),
                                 nullif(it->>'mailing_zip', ''), nullif(firstnum, ''), 'muse:' || coalesce(p_agent, 'agent'));
      end if;
      iid := public.add_interest(lid, pid, coalesce(it->>'role', 'other'), 'muse:' || coalesce(p_agent, 'agent'));
      -- a known role from the agent replaces the guess the backfill made ("other")
      update public.interests set role = coalesce(it->>'role', role), notes = coalesce(nullif(it->>'notes', ''), notes)
       where id = iid and (role = 'other' or it->>'role' is not null) and not (role = 'owner_of_record' and coalesce(it->>'role', '') = 'other');
      update public.people set mailing_street = coalesce(nullif(it->>'mailing_street', ''), mailing_street), mailing_city = coalesce(nullif(it->>'mailing_city', ''), mailing_city),
             mailing_state = coalesce(nullif(it->>'mailing_state', ''), mailing_state), mailing_zip = coalesce(nullif(it->>'mailing_zip', ''), mailing_zip),
             mail_key = coalesce(public.mail_key(nullif(it->>'mailing_street', ''), nullif(it->>'mailing_zip', '')), mail_key), updated_at = now()
       where id = pid;
      if it->>'status' in ('deceased', 'do_not_contact') then
        update public.people set status = it->>'status', status_reason = coalesce(nullif(it->>'status_reason', ''), 'from the import'), status_at = now() where id = pid;
        update public.interests set status = it->>'status', status_at = now() where person_id = pid;
      elsif it->>'status' in ('not_the_contact', 'closed') then
        update public.interests set status = it->>'status', status_reason = nullif(it->>'status_reason', ''), status_at = now() where id = iid;
      end if;
    end if;
    for ph in select * from jsonb_array_elements(coalesce(it->'phones', '[]'::jsonb)) loop
      num := right(regexp_replace(coalesce(case when jsonb_typeof(ph) = 'string' then ph #>> '{}' else ph->>'number' end, ''), '\D', '', 'g'), 10);
      if num !~ '^[2-9][0-9]{2}[2-9][0-9]{6}$' then
        skipped := skipped || jsonb_build_object('number', coalesce(ph->>'number', ph #>> '{}'), 'why', 'not a US phone number');
        continue;
      end if;
      if (pid is null and exists (select 1 from public.contacts c where c.lead_id = lid and c.value_normalized = num))
         or (pid is not null and exists (select 1 from public.contacts c where c.lead_id = lid and c.value_normalized = num and c.person_id = pid)) then
        skipped := skipped || jsonb_build_object('number', num, 'why', 'already on this card');
        continue;
      end if;
      insert into public.contacts (lead_id, kind, value, value_normalized, person_name, line_type, source, confidence, note, person_id)
      values (lid, 'phone', num, num, coalesce(nullif(ph->>'name', ''), case when pid is not null then it->>'name' end), nullif(lower(ph->>'type'), ''),
              'muse:' || coalesce(p_agent, 'agent'), nullif(ph->>'confidence', '')::numeric, nullif(ph->>'note', ''), pid);
      added := added || to_jsonb(num);
      mine := mine || jsonb_strip_nulls(jsonb_build_object('number', num,
        'also_on', (select jsonb_agg(distinct jsonb_build_object('lead_id', c.lead_id, 'address', l2.property_address))
                      from public.contacts c join public.leads l2 on l2.id = c.lead_id where c.value_normalized = num and c.lead_id <> lid)));
      if exists (select 1 from public.suppressed_phones s where s.phone10 = num) then
        skipped := skipped || jsonb_build_object('number', num, 'why', 'opted out before: kept on the card, never texted');
      end if;
    end loop;
    results := results || jsonb_build_object('name', it->>'name', 'role', coalesce(it->>'role', 'other'),
      'interest_id', coalesce(iid, (select i.id from public.interests i where i.lead_id = lid and i.role = 'owner_of_record' limit 1)),
      'phones_added', mine);
  end loop;
  for r in select * from jsonb_array_elements(coalesce(p->'reasons', '[]'::jsonb)) loop
    if coalesce(r->>'kind', '') = '' then continue; end if;
    insert into public.prospect_reasons (lead_id, kind, detail, event_date, amount, source, added_by)
    values (lid, r->>'kind', nullif(r->>'detail', ''), nullif(r->>'date', '')::date, nullif(r->>'amount', '')::numeric,
            nullif(r->>'source', ''), p_agent)
    on conflict do nothing;
  end loop;
  return jsonb_build_object('status', status, 'lead_id', lid, 'phones_added', added, 'phones_skipped', skipped, 'interests', results,
    'filled', to_jsonb(filled),
    'parcel', coalesce(nullif(btrim(ex.parcel_id), ''), v_parcel),
    -- an agent card that already has a different parcel keeps it; the result says so
    'parcel_conflict', case when ex.wpie_owner_id < 0 and coalesce(btrim(ex.parcel_id), '') <> '' and v_parcel is not null
                             and regexp_replace(upper(ex.parcel_id), '[^0-9A-Z]', '', 'g') <> regexp_replace(upper(v_parcel), '[^0-9A-Z]', '', 'g')
                            then jsonb_build_object('card', ex.parcel_id, 'sent', v_parcel) end,
    'existing', case when ex.id is null then null else jsonb_build_object('owner_name', ex.owner_name, 'stage', ex.stage,
      'source', coalesce(ex.source, case when ex.wpie_owner_id > 0 then 'laptop' end),
      'texted', exists (select 1 from public.messages m where m.lead_id = ex.id and m.direction = 'out' and m.channel = 'sms')) end);
end $function$;

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
begin
  if why is null then return jsonb_build_object('ok', false, 'reason', 'say why these are one property (reason)'); end if;
  if p_keep_lead_id = p_drop_lead_id then return jsonb_build_object('ok', false, 'reason', 'keep and drop are the same card'); end if;
  select * into k from public.leads where id = p_keep_lead_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card (keep)'); end if;
  select * into d from public.leads where id = p_drop_lead_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card (drop)'); end if;
  same_property := (k.parcel_id is not null and d.parcel_id is not null and k.county is not distinct from d.county and k.parcel_id = d.parcel_id)
                or (public.addr_key_unitless(public.addr_main(k.property_address)) = public.addr_key_unitless(public.addr_main(d.property_address))
                    and coalesce(lower(k.municipality), '') = coalesce(lower(d.municipality), ''));
  if not same_property then
    return jsonb_build_object('ok', false, 'reason', 'not the same property (parcel or address and municipality differ; a unit must agree too): link_cards if they are related, merge nothing');
  end if;
  if d.stage in ('under_contract', 'closed_won', 'offer', 'walkthrough_booked', 'handoff', 'colin_call', 'walk_decision') then
    return jsonb_build_object('ok', false, 'reason', 'the duplicate is in a deal (' || d.stage::text || '): keep it, close the other one instead, or ask');
  end if;
  if exists (select 1 from public.messages m where m.lead_id = d.id and m.channel = 'sms' and m.provider_sid is not null)
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

CREATE OR REPLACE FUNCTION public.agent_phones_wanted(p_agent text, p_limit integer DEFAULT 100, p_county text DEFAULT NULL::text, p_need text DEFAULT NULL::text, p_counts_only boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare ids integer[]; out jsonb; counts jsonb;
begin
  select jsonb_build_object(
           'open', count(*) filter (where done_at is null and (claimed_at is null or claimed_at < now() - interval '2 days') and (tried_at is null or tried_at < now() - interval '30 days')),
           'tried_no_number', count(*) filter (where done_at is null and tried_at >= now() - interval '30 days'),
           'open_real_need', count(*) filter (where done_at is null and need = 'real need' and (claimed_at is null or claimed_at < now() - interval '2 days')),
           'claimed', count(*) filter (where done_at is null and claimed_at >= now() - interval '2 days'),
           'yours', count(*) filter (where done_at is null and claimed_by = p_agent and claimed_at >= now() - interval '2 days'),
           'done_7d', count(*) filter (where done_at > now() - interval '7 days'),
           'by_county', (select coalesce(jsonb_object_agg(county, n), '{}'::jsonb) from (
               select county, count(*) n from public.phones_wanted where done_at is null group by county order by n desc limit 30) c))
    into counts from public.phones_wanted;
  if coalesce(p_counts_only, false) then return jsonb_build_object('counts', counts, 'owners', '[]'::jsonb); end if;
  with pick as (
    select w.wpie_owner_id from public.phones_wanted w
     where w.done_at is null and (w.claimed_at is null or w.claimed_at < now() - interval '2 days' or w.claimed_by = p_agent)
       -- 0298: an owner someone traced and found no number for is not handed out again for 30 days
       and (w.tried_at is null or w.tried_at < now() - interval '30 days')
       and (p_county is null or w.county = p_county)
       and (p_need is null or w.need = p_need)
     order by (w.need = 'real need') desc, w.tax_years desc, w.listed_on, w.wpie_owner_id
     limit greatest(1, least(coalesce(p_limit, 100), 500))
     for update skip locked),
  u as (update public.phones_wanted w set claimed_by = p_agent, claimed_at = now(), updated_at = now()
          from pick where w.wpie_owner_id = pick.wpie_owner_id returning w.wpie_owner_id)
  select coalesce(array_agg(wpie_owner_id), '{}') into ids from u;
  select coalesce(jsonb_agg(jsonb_build_object(
           'wpie_owner_id', w.wpie_owner_id, 'owner_name', w.owner_name, 'owner_type', w.owner_type,
           'mailing_street', w.mailing_street, 'mailing_city', w.mailing_city, 'mailing_state', w.mailing_state, 'mailing_zip', w.mailing_zip,
           'address', w.property_address, 'city', w.municipality, 'zip', w.property_zip, 'county', w.county, 'parcel', w.parcel_id,
           'lane', w.lane, 'reasons', to_jsonb(w.reasons), 'tax_years', w.tax_years, 'need', w.need, 'why', w.why,
           'est_value', w.est_value, 'assessed', w.assessed, 'year_built', w.year_built, 'sqft', w.building_sqft,
           'existing_card', (select l.id from public.leads l where l.wpie_owner_id = w.wpie_owner_id))
           order by (w.need = 'real need') desc, w.tax_years desc, w.listed_on, w.wpie_owner_id), '[]'::jsonb)
    into out from public.phones_wanted w where w.wpie_owner_id = any(ids);
  return jsonb_build_object('counts', counts, 'owners', out);
end $function$;
