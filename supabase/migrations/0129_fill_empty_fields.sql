-- Verified data fills a card's empty fields (WPIE dev priorities 2026-10-28, item 2). When Muse sent a property the app
-- already had, agent_add_prospect appended what it verified to the card's notes and left the structured fields empty:
-- property ZIP, mailing address, units. Now each EMPTY field is filled from the payload and a filled one is never
-- touched; the result says which fields it filled ('filled'). A mailing address goes in whole or not at all.
-- The laptop push (wpie/live/sync.py) no longer blanks these fields when the laptop itself has nothing for them.

CREATE OR REPLACE FUNCTION public.agent_add_prospect(p jsonb, p_agent text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
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
  select * into ex from public.leads l
   where (public.addr_key(l.property_address) = ak or public.addr_key(public.addr_main(l.property_address)) = akm)
     and (zip = '' or coalesce(l.property_zip, '') = '' or left(l.property_zip, 5) = zip)
   order by (public.addr_key(l.property_address) = ak) desc, (lower(l.owner_name) = lower(owner)) desc, (l.wpie_owner_id > 0) desc, l.created_at limit 1;
  select coalesce(array_agg(distinct coalesce(nullif(x->>'label', ''), x->>'kind')), '{}') into reasons
    from jsonb_array_elements(coalesce(p->'reasons', '[]'::jsonb)) x where coalesce(x->>'kind', '') <> '';
  if ex.id is null then
    insert into public.leads (wpie_owner_id, owner_name, owner_type, mailing_street, mailing_city, mailing_state, mailing_zip,
                              lane, county, municipality, property_address, property_zip, property_type, units,
                              reasons_to_sell, stage, source, notes)
    values (-nextval('public.agent_prospect_seq'), owner, nullif(p->>'owner_type', ''),
            nullif(coalesce(p->>'mailing_street', own->>'mailing_street'), ''), nullif(coalesce(p->>'mailing_city', own->>'mailing_city'), ''),
            nullif(coalesce(p->>'mailing_state', own->>'mailing_state'), ''), nullif(coalesce(p->>'mailing_zip', own->>'mailing_zip'), ''),
            case when p->>'lane' = 'hold' then 'hold'::public.lead_lane else 'flip'::public.lead_lane end,
            nullif(p->>'county', ''), nullif(coalesce(p->>'city', p->>'municipality'), ''), btrim(p->>'address'),
            nullif(p->>'zip', ''), nullif(p->>'property_type', ''), nullif(p->>'units', '')::int,
            reasons, 'opener_queued', coalesce(nullif(p->>'source', ''), 'muse'), nullif(p->>'notes', ''))
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
    'existing', case when ex.id is null then null else jsonb_build_object('owner_name', ex.owner_name, 'stage', ex.stage,
      'source', coalesce(ex.source, case when ex.wpie_owner_id > 0 then 'laptop' end),
      'texted', exists (select 1 from public.messages m where m.lead_id = ex.id and m.direction = 'out' and m.channel = 'sms')) end);
end $$;
