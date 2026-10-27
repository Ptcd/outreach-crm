-- One property card, many interests, step 2: the agent door (Muse's spec for Colin, 2026-10-27).
--   * add_prospects takes interests[] (name, role, their own mailing address, their phones, a status). The old flat
--     owner_name + phones shape still works as one owner of record. Cards match on the property address only, ranges
--     included ("2825 2827 S Logan Av" is 2825 S Logan Av). A number already on another card is attached anyway, to
--     the person it belongs to, and reported as also_on; it is never dropped.
--   * person marks (agent_mark_person): deceased, dnc and wrong_person close one person, not the property. Deceased and
--     dnc follow the person onto every card; wrong_person is this card only. A dnc from an owner (owner of record or
--     co-owner) still closes the property card as before, so nobody is texted about a house its owner said stop on.
--     A person closing never buries a live one (the Orlich rule): a card that died only as no contact or by a death
--     reopens when a live person with a phone remains; when nobody live remains, the card holds for a re-trace.
--   * a text goes to a person (interest_id, or the phone's person on the card): never to a number a do-not-contact or
--     deceased person owns, on any card; a person closed on the card hands the first text to the next person.
--   * the send check: a number on several cards is no longer "shared" when it is one person's.
-- Windows, the cap, variant and slot assignment and every other guardrail are unchanged.

alter table public.planned_openers add column if not exists interest_id uuid references public.interests(id) on delete set null;

-- "2825 2827 S LOGAN AV" -> "2825 S LOGAN AV"
create or replace function public.addr_main(p text) returns text language sql immutable as $$
  select regexp_replace(coalesce(p, ''), '^\s*(\d+)\s*(-|&|\s)\s*\d+\s+', '\1 ')
$$;

-- why a number may not be texted because of who owns it, or null: a do-not-contact person's number, on any card; a
-- deceased person's number unless a living person shares it (a widow who kept the line, a PR at the same house)
create or replace function public.phone_person_block(p_phone10 text) returns text language sql stable security definer set search_path = public as $$
  select 'that number is ' || pe.name || '''s, marked ' || replace(pe.status, '_', ' ')
    from public.contacts c join public.people pe on pe.id = c.person_id
   where c.value_normalized = p_phone10
     and (pe.status = 'do_not_contact'
          or (pe.status = 'deceased' and not exists (select 1 from public.contacts c2 join public.people p2 on p2.id = c2.person_id
                                                      where c2.value_normalized = p_phone10 and p2.status = 'active')))
   order by (pe.status = 'do_not_contact') desc limit 1
$$;

-- after a person closes: hold the card when nobody live with a phone is left, or reopen a card that died only as no
-- contact or by a death when someone live is (the Orlich rule)
create or replace function public.card_after_person_change(p_lead_id uuid, p_who text) returns text
language plpgsql security definer set search_path = public as $$
declare l public.leads; live boolean;
begin
  select * into l from public.leads where id = p_lead_id for update;
  if not found then return null; end if;
  live := exists (select 1 from public.interests i join public.people pe on pe.id = i.person_id
                    join public.contacts c on c.person_id = i.person_id and c.lead_id = i.lead_id
                   where i.lead_id = p_lead_id and i.status = 'active' and pe.status = 'active' and c.kind = 'phone'
                     and c.status::text = 'ok' and not c.suppressed and not c.dnc_app
                     and public.phone_person_block(c.value_normalized) is null);
  if not live and l.stage::text in ('postcard_mailed', 'opener_queued', 'opener_sent', 'reply_received', 'follow_up') then
    update public.leads set stage = 'data_fix', named_event = 'no live person on this card: re-trace', next_action = 'Re-trace: no live person on this card',
           notes = concat_ws(' | ', notes, to_char(now() at time zone 'America/Chicago', 'YYYY-MM-DD') || ' ' || p_who || ': held, no live person left on this card')
     where id = p_lead_id;
    return 'held';
  end if;
  if live and l.stage::text = 'dead' and coalesce(l.dead_reason, '') ~* '(no_contact|deceas|died|passed|death|estate|probate)' then
    update public.leads set stage = case when exists (select 1 from public.messages m where m.lead_id = p_lead_id and m.direction = 'out' and m.channel = 'sms')
                                                or exists (select 1 from public.planned_openers p where p.lead_id = p_lead_id and p.send_status = any(public.opener_live_statuses()))
                                         then 'opener_sent'::public.lead_stage else 'opener_queued'::public.lead_stage end,
           belt = null, belt_step = 0, next_stop_at = null, next_stop_who = null, dead_reason = null, reopened_at = now(),
           reopened_reason = 'a live person remains on the card (was dead: ' || coalesce(l.dead_reason, '') || ')',
           notes = concat_ws(' | ', notes, to_char(now() at time zone 'America/Chicago', 'YYYY-MM-DD') || ' ' || p_who
                   || ': reopened, the card was closed (' || coalesce(l.dead_reason, '') || ') but a live person with a phone remains')
     where id = p_lead_id;
    insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
    values (p_lead_id, 'reopened', l.belt, null, null, jsonb_build_object('from_stage', l.stage::text, 'why', 'a live person remains', 'was', l.dead_reason), now(), p_who);
    return 'reopened';
  end if;
  return null;
end $$;

-- close one person: deceased (everywhere), dnc (everywhere), wrong_person (this card)
create or replace function public.agent_mark_person(p_lead_id uuid, p_mark text, p_interest_id uuid, p_phone text, p_reason text, p_agent text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  who  text := 'Muse (' || coalesce(p_agent, 'agent') || ')';
  d    text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10);
  why  text := nullif(btrim(coalesce(p_reason, '')), '');
  iv   public.interests;
  pe   public.people;
  n    integer;
  r    record;
  cards jsonb := '[]'::jsonb;
  res  text;
  owner_side boolean;
begin
  if p_mark not in ('deceased', 'dnc', 'wrong_person') then
    return jsonb_build_object('ok', false, 'reason', 'a person mark is deceased, dnc or wrong_person');
  end if;
  if p_interest_id is not null then
    select * into iv from public.interests i where i.id = p_interest_id and i.lead_id = p_lead_id;
    if not found then return jsonb_build_object('ok', false, 'reason', 'no such person on this card (interest_id)'); end if;
  elsif d ~ '^[0-9]{10}$' then
    select count(distinct c.person_id) into n from public.contacts c where c.lead_id = p_lead_id and c.value_normalized = d and c.person_id is not null;
    if n = 0 then return jsonb_build_object('ok', false, 'reason', 'that phone is not on this card'); end if;
    if n > 1 then
      return jsonb_build_object('ok', false, 'reason', 'that phone is shared by ' || (select string_agg(distinct pe2.name, ' and ') from public.contacts c
        join public.people pe2 on pe2.id = c.person_id where c.lead_id = p_lead_id and c.value_normalized = d) || ': say which (interest_id)');
    end if;
    select i.* into iv from public.interests i where i.lead_id = p_lead_id
       and i.person_id = (select c.person_id from public.contacts c where c.lead_id = p_lead_id and c.value_normalized = d and c.person_id is not null limit 1);
  else
    return jsonb_build_object('ok', false, 'reason', 'which person? pass interest_id or their phone');
  end if;
  select * into pe from public.people where id = iv.person_id;
  owner_side := iv.role in ('owner_of_record', 'co_owner') and pe.kind <> 'entity';
  if p_mark = 'wrong_person' then
    update public.interests set status = 'not_the_contact', status_reason = coalesce(why, 'not the right person (texting agent)'), status_at = now() where id = iv.id;
  else
    update public.people set status = case p_mark when 'deceased' then 'deceased' else 'do_not_contact' end,
           status_reason = coalesce(why, case p_mark when 'deceased' then 'died' else 'asked not to be contacted' end), status_at = now(), updated_at = now()
     where id = pe.id;
    update public.interests set status = case p_mark when 'deceased' then 'deceased' else 'do_not_contact' end,
           status_reason = coalesce(why, p_mark), status_at = now() where person_id = pe.id;
    if p_mark = 'dnc' and d ~ '^[0-9]{10}$' then
      insert into public.suppressed_phones (phone10, reason, source) values (d, 'dnc_agent', 'agent') on conflict (phone10) do nothing;
      update public.contacts set suppressed = true, dnc_app = true where value_normalized = d;
    end if;
  end if;
  -- an owner who says stop closes the property too (nobody is texted about a house its owner said stop on)
  if p_mark = 'dnc' and owner_side then
    perform public.agent_mark_card(p_lead_id, 'dnc', coalesce(why, pe.name || ' asked not to be contacted'), null, nullif(d, ''), p_agent);
  end if;
  for r in select distinct i.lead_id from public.interests i where i.person_id = pe.id and (p_mark <> 'wrong_person' or i.lead_id = p_lead_id) loop
    res := public.card_after_person_change(r.lead_id, who);
    cards := cards || jsonb_build_object('lead_id', r.lead_id, 'result', res,
      'stage', (select l.stage from public.leads l where l.id = r.lead_id));
  end loop;
  update public.leads set notes = concat_ws(' | ', notes, 'Muse (' || p_mark || ', ' || pe.name || '): ' || coalesce(why, '')), updated_at = now() where id = p_lead_id;
  return jsonb_build_object('ok', true, 'mark', p_mark, 'person', pe.name, 'person_id', pe.id, 'interest_id', iv.id, 'cards', cards);
end $$;

-- the import: interests[] or the old flat shape; one card per property
create or replace function public.agent_add_prospect(p jsonb, p_agent text) returns jsonb
language plpgsql security definer set search_path = public as $$
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
    update public.leads set reasons_to_sell = coalesce((select array_agg(distinct x) from unnest(reasons_to_sell || reasons) x), '{}'::text[]),
           notes = case when nullif(p->>'notes', '') is null then notes else concat_ws(' | ', notes, 'Muse: ' || (p->>'notes')) end,
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
    'existing', case when ex.id is null then null else jsonb_build_object('owner_name', ex.owner_name, 'stage', ex.stage,
      'source', coalesce(ex.source, case when ex.wpie_owner_id > 0 then 'laptop' end),
      'texted', exists (select 1 from public.messages m where m.lead_id = ex.id and m.direction = 'out' and m.channel = 'sms')) end);
end $$;

CREATE OR REPLACE FUNCTION public.next_phone_problem(p_lead_id uuid, p_phone10 text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  l      public.leads;
  phones text[];
  bad    text[];
  firsts integer;
begin
  select * into l from public.leads where id = p_lead_id;
  if not found then return 'no such card'; end if;
  if l.stage::text not in ('opener_queued', 'opener_sent', 'reply_received', 'data_fix') then
    return 'a first text is for a new card';
  end if;
  select coalesce(array_agg(distinct ct.value_normalized), '{}'),
         coalesce(array_agg(distinct ct.value_normalized) filter (where ct.status::text in ('bad', 'dead')), '{}')
    into phones, bad
    from public.contacts ct join public.leads ll on ll.id = ct.lead_id
   where ll.wpie_owner_id = l.wpie_owner_id and ct.kind = 'phone' and ct.value_normalized is not null;
  -- a phone whose people on this card are all closed (deceased, do not contact, not the contact) is done with, like a
  -- bad one: the next person on the card may have their first text (0083, one person at a time)
  bad := bad || coalesce((select array_agg(distinct ct.value_normalized) from public.contacts ct
     where ct.lead_id = p_lead_id and ct.kind = 'phone' and ct.person_id is not null
       and not exists (select 1 from public.contacts c2 join public.interests i on i.person_id = c2.person_id and i.lead_id = p_lead_id
                         join public.people pe on pe.id = c2.person_id
                        where c2.lead_id = p_lead_id and c2.value_normalized = ct.value_normalized and i.status = 'active' and pe.status = 'active')), '{}');
  with f as (
    select right(regexp_replace(p.phone, '\D', '', 'g'), 10) ph, p.send_status st from public.planned_openers p
     where p.wpie_owner_id = l.wpie_owner_id and p.step = 1 and p.send_status = any(public.opener_live_statuses())
    union all
    select right(regexp_replace(m.to_number, '\D', '', 'g'), 10), m.status from public.messages m
     where m.lead_id = p_lead_id and m.direction = 'out' and m.is_opener and m.provider_sid is not null)
  select count(*) into firsts from f;
  if firsts = 0 then return 'a first text is for a new card'; end if;
  if exists (select 1 from public.planned_openers p where p.wpie_owner_id = l.wpie_owner_id and p.step = 1
               and p.send_status = any(public.opener_live_statuses()) and right(regexp_replace(p.phone, '\D', '', 'g'), 10) = p_phone10)
     or exists (select 1 from public.messages m where m.lead_id = p_lead_id and m.direction = 'out' and m.is_opener and m.provider_sid is not null
               and right(regexp_replace(m.to_number, '\D', '', 'g'), 10) = p_phone10) then
    return 'this phone already had its first text';
  end if;
  if exists (select 1 from public.planned_openers p where p.wpie_owner_id = l.wpie_owner_id and p.step = 1
               and p.send_status in ('sending', 'sent', 'delivered', 'uncertain')
               and not (right(regexp_replace(p.phone, '\D', '', 'g'), 10) = any(bad)))
     or exists (select 1 from public.messages m where m.lead_id = p_lead_id and m.direction = 'out' and m.is_opener and m.provider_sid is not null
               and coalesce(m.status, '') not in ('undelivered', 'failed')
               and not (right(regexp_replace(m.to_number, '\D', '', 'g'), 10) = any(bad))) then
    return 'an earlier first text may have arrived (wait for its delivery result, or mark that phone wrong_number)';
  end if;
  if exists (select 1 from public.twilio_inbound t where t.from10 = any(phones) and not (t.from10 = any(bad)))
     or exists (select 1 from public.messages m where m.lead_id = p_lead_id and m.direction = 'in' and m.channel = 'sms'
                  and not (right(regexp_replace(coalesce(m.from_number, ''), '\D', '', 'g'), 10) = any(bad))) then
    return 'they texted back from a good phone';
  end if;
  return null;
end $function$;

CREATE OR REPLACE FUNCTION public.claim_next_opener(p_dry_run boolean DEFAULT true, p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c          public.campaign_control;
  o          public.planned_openers;
  l          public.leads;
  local_ts   timestamp;
  today      date;
  mode       text := case when p_dry_run then 'dry' else 'live' end;
  counted    text[];
  used       integer;
  last_hour  integer;
  pace       integer;
  v_phone10    text;
  owner_phones text[];
  why        text;
  retry      boolean := false;
  w          text;
begin
  perform pg_advisory_xact_lock(hashtext('wpie.claim_next_opener'));
  select * into c from public.campaign_control where id = 1;
  if not found then
    return jsonb_build_object('outcome', 'idle', 'reason', 'no_control_row');
  end if;
  if not p_dry_run and not c.sending_enabled then
    return jsonb_build_object('outcome', 'idle', 'reason', 'switch_off');
  end if;
  if c.paused or c.laptop_paused then
    return jsonb_build_object('outcome', 'idle', 'reason', 'paused',
                              'detail', coalesce(c.pause_reason, c.laptop_pause_reason));
  end if;
  local_ts := p_now at time zone c.timezone;
  today := local_ts::date;
  if c.no_sundays and extract(isodow from local_ts) = 7 then
    return jsonb_build_object('outcome', 'idle', 'reason', 'sunday');
  end if;
  if local_ts::time < c.window_start or local_ts::time >= c.window_end then
    return jsonb_build_object('outcome', 'idle', 'reason', 'outside_window');
  end if;

  -- Daily cap: one cap across app sends, laptop campaign sends and the reply agent's own openers.
  counted := case when p_dry_run then array['would_send'] else public.opener_live_statuses() end;
  select count(distinct coalesce(x.lead_id::text, x.k)) into used from (
    select p.lead_id, p.wpie_owner_id::text || ':' || p.attempt as k
      from public.planned_openers p
     where p.send_status = any(counted) and p.claim_mode = mode
       and (p.claimed_at at time zone c.timezone)::date = today
    union all
    select m.lead_id, m.id::text
      from public.messages m
     where not p_dry_run and m.direction = 'out' and m.is_opener and m.provider_sid is not null
       and (m.sent_at at time zone c.timezone)::date = today
  ) x;
  if not p_dry_run and c.external_openers_date = today then
    used := used + c.external_openers;
  end if;
  if used >= c.daily_cap then
    return jsonb_build_object('outcome', 'idle', 'reason', 'daily_cap_reached', 'used', used);
  end if;

  -- Follow-ups' own brake (0018): re-checked before picking, so a trip stops texts 2-3 right away.
  if not c.followups_paused then
    perform public.check_followup_kill(p_now);
    select * into c from public.campaign_control where id = 1;
  end if;

  -- Pick the earliest due approved entry whose recipient window is open now. Follow-ups (texts 2
  -- and 3) go first: a due follow-up loses value faster than a new opener, so under the cap
  -- the new openers wait.
  select * into o from public.planned_openers p
   where p.plan_date = today
     and (p.send_status = 'planned' or (not p_dry_run and p.send_status = 'would_send'))
     and (p_dry_run or p.decision = 'approved')
     and p.decision <> 'skipped'
     and coalesce(p.scheduled_at, p_now) <= p_now
     and (p.window_start_utc is null or (p.window_start_utc <= p_now and p_now < p.window_end_utc))
     and (p.step = 1 or not c.followups_paused)
   order by (p.step > 1) desc, p.scheduled_at nulls last, p.id
   limit 1
   for update skip locked;
  if not found then
    return jsonb_build_object('outcome', 'idle', 'reason', 'nothing_due', 'used', used);
  end if;

  -- Hourly pace (the plan's per_hour; the cap when the plan has none).
  pace := coalesce(nullif(o.per_hour, 0), c.daily_cap);
  select count(*) into last_hour from public.planned_openers p
   where p.send_status = any(counted) and p.claim_mode = mode
     and p.claimed_at > p_now - interval '1 hour' and p.claimed_at <= p_now;
  if last_hour >= pace then
    return jsonb_build_object('outcome', 'idle', 'reason', 'hourly_pace_reached', 'last_hour', last_hour);
  end if;

  -- ---------------------------------------------------------------- per-entry checks
  v_phone10 := right(regexp_replace(coalesce(o.phone, ''), '\D', '', 'g'), 10);
  select * into l from public.leads where id = o.lead_id;
  select coalesce(array_agg(distinct ct.value_normalized), '{}') into owner_phones
    from public.contacts ct join public.leads ll on ll.id = ct.lead_id
   where ll.wpie_owner_id = o.wpie_owner_id and ct.kind = 'phone' and ct.value_normalized is not null;
  owner_phones := array_append(owner_phones, v_phone10);
  -- the next phone on the card (0079): a first text to another phone when every earlier first text never arrived
  retry := o.step = 1 and o.attempt between 2 and 9 and public.next_phone_problem(o.lead_id, v_phone10) is null;

  if o.window_start_utc is null or o.window_end_utc is null then
    why := 'no_recipient_window';
  elsif o.body_sha256 is null or o.body_sha256 <> encode(sha256(convert_to(o.body, 'UTF8')), 'hex') then
    why := 'body_changed_since_plan';
  elsif o.phone is null or o.phone !~ '^\+1[2-9][0-9]{2}[2-9][0-9]{6}$' then
    why := 'phone_invalid';
  elsif o.lead_id is null or l.id is null then
    why := 'no_lead';
  elsif o.step = 1 and not retry and l.stage not in ('postcard_mailed', 'opener_queued') then
    why := 'lead_stage_' || l.stage::text;
  elsif o.step > 1 and l.stage <> 'opener_sent' then
    why := 'lead_stage_' || l.stage::text;
  elsif exists (select 1 from public.suppressed_phones s where s.phone10 = v_phone10) then
    why := 'phone_suppressed';
  elsif exists (select 1 from public.suppressed_phones s where s.phone10 = any(owner_phones))
     or exists (select 1 from public.contacts ct where ct.value_normalized = any(owner_phones) and ct.suppressed) then
    why := 'owner_opted_out_on_another_phone';
  elsif not retry and (exists (select 1 from public.messages m where m.lead_id = o.lead_id and m.direction = 'in' and m.channel = 'sms')
     or exists (select 1 from public.twilio_inbound t where t.from10 = any(owner_phones))) then
    why := 'owner_replied';
  elsif exists (select 1 from public.contacts ct where ct.value_normalized = v_phone10
                  and (ct.dnc_vendor or ct.dnc_scrub = 'dnc' or ct.dnc_app)) then
    why := 'phone_dnc_positive';
  elsif exists (select 1 from public.contacts ct where ct.value_normalized = v_phone10 and ct.lead_id = o.lead_id and ct.status = 'bad') then
    why := 'phone_marked_bad';
  elsif public.phone_person_block(v_phone10) is not null then
    why := 'person_do_not_contact';
  -- a number on several cards is fine when it is one person's (0083); two different people on two cards is not
  elsif (select count(distinct ct.lead_id) from public.contacts ct where ct.value_normalized = v_phone10) > 1
    and (select count(distinct coalesce(ct.person_id::text, ct.lead_id::text)) from public.contacts ct where ct.value_normalized = v_phone10) > 1 then
    why := 'phone_shared';
  elsif c.dnc_policy = 'require_scrub' and (coalesce(o.dnc_state, '') <> 'screened'
        or exists (select 1 from public.contacts ct where ct.value_normalized = v_phone10 and ct.dnc_scrub <> 'clear')) then
    why := 'dnc_unscreened_under_require_scrub';
  elsif c.dnc_policy = 'require_scrub' and (c.scrub_date is null or today - c.scrub_date > 31) then
    why := 'dnc_scrub_older_than_31_days';
  elsif o.step = 1 and not retry and (exists (select 1 from public.planned_openers p
                 where p.id <> o.id and (p.wpie_owner_id = o.wpie_owner_id or p.phone = o.phone)
                   and p.send_status = any(public.opener_live_statuses()))
     or exists (select 1 from public.messages m
                 where m.direction = 'out' and m.is_opener and m.provider_sid is not null
                   and (m.lead_id = o.lead_id or m.to_number = o.phone))) then
    why := 'owner_already_texted';
  -- Texts 2 and 3 (docs/FOLLOWUP_CADENCE.md section 2), in place of "already texted":
  elsif o.step > 1 and not (
        exists (select 1 from public.planned_openers p where p.wpie_owner_id = o.wpie_owner_id and p.attempt = o.attempt / 10
                  and p.phone = o.phone and p.send_status = 'delivered')
     or exists (select 1 from public.messages m where m.lead_id = o.lead_id and m.is_opener and m.direction = 'out'
                  and m.to_number = o.phone and m.status = 'delivered')) then
    why := 'opener_not_delivered';
  elsif o.step = 3 and not exists (select 1 from public.planned_openers p where p.wpie_owner_id = o.wpie_owner_id
                  and p.attempt = (o.attempt / 10) * 10 + 2 and p.phone = o.phone and p.send_status = 'delivered') then
    why := 'text_2_not_delivered';
  elsif o.step > 1 and exists (select 1 from public.planned_openers p where p.id <> o.id and p.wpie_owner_id = o.wpie_owner_id
                  and p.attempt = o.attempt and p.send_status = any(public.opener_live_statuses())) then
    why := 'step_already_sent';
  elsif o.step > 1 and exists (select 1 from public.twilio_inbound t where t.from10 = v_phone10) then
    why := 'owner_replied';
  elsif o.step > 1 and exists (select 1 from public.contacts ct where ct.value_normalized = v_phone10 and ct.status::text in ('bad', 'dead')) then
    why := 'phone_marked_bad';
  elsif o.step > 1 and (select count(*) from (
          select p.id::text from public.planned_openers p where p.wpie_owner_id = o.wpie_owner_id and p.id <> o.id
             and p.send_status = any(public.opener_live_statuses()) and p.send_status not in ('undelivered', 'failed')
          union
          select coalesce(m.provider_sid, m.id::text) from public.messages m where m.lead_id = o.lead_id
             and m.direction = 'out' and m.channel = 'sms' and m.provider_sid is not null
             and not exists (select 1 from public.planned_openers p2 where p2.provider_sid = m.provider_sid)) n) >= 5 then
    why := 'all_texts_sent';
  elsif o.step > 1 and (select greatest(
          (select max(coalesce(p.sent_at, p.claimed_at)) from public.planned_openers p where p.phone = o.phone and p.id <> o.id
              and p.send_status = any(public.opener_live_statuses())),
          (select max(m.sent_at) from public.messages m where m.to_number = o.phone and m.direction = 'out' and m.channel = 'sms')))
        > p_now - interval '36 hours' then
    why := 'too_soon';
  elsif position('STOP' in o.body) = 0 then
    why := 'template:no_stop_line';
  elsif position('$' in o.body) > 0 then
    why := 'template:price_symbol';
  else
    foreach w in array c.banned_words loop
      if w <> '' and position(lower(w) in lower(o.body)) > 0 then
        why := 'template:names_business';
      end if;
    end loop;
  end if;

  if why is not null then
    update public.planned_openers set send_status = 'skipped', send_reason = why, send_updated_at = p_now where id = o.id;
    insert into public.opener_send_events (opener_id, plan_date, wpie_owner_id, attempt, event, reason, actor, at)
    values (o.id, o.plan_date, o.wpie_owner_id, o.attempt, 'skipped', why, 'server', p_now);
    return jsonb_build_object('outcome', 'skipped', 'reason', why,
                              'opener', jsonb_build_object('id', o.id, 'wpie_owner_id', o.wpie_owner_id, 'attempt', o.attempt, 'step', o.step));
  end if;

  update public.planned_openers
     set send_status = case when p_dry_run then 'would_send' else 'sending' end,
         claim_mode = mode, claimed_at = p_now, send_reason = null, send_updated_at = p_now
   where id = o.id;
  insert into public.opener_send_events (opener_id, plan_date, wpie_owner_id, attempt, event, actor, at)
  values (o.id, o.plan_date, o.wpie_owner_id, o.attempt, case when p_dry_run then 'would_send' else 'sending' end, 'server', p_now);
  return jsonb_build_object('outcome', case when p_dry_run then 'would_send' else 'send' end,
                            'opener', jsonb_build_object('id', o.id, 'phone', o.phone, 'body', o.body,
                                                         'wpie_owner_id', o.wpie_owner_id, 'attempt', o.attempt,
                                                         'step', o.step, 'plan_date', o.plan_date));
end $function$;

drop function if exists public.agent_queue_text(uuid, text, text, integer, timestamptz, text, timestamptz, text, text, text);
CREATE OR REPLACE FUNCTION public.agent_queue_text(p_lead_id uuid, p_phone text, p_body text, p_step integer, p_send_after timestamp with time zone, p_agent text, p_now timestamp with time zone DEFAULT now(), p_variant text DEFAULT NULL::text, p_template text DEFAULT NULL::text, p_slot text DEFAULT NULL::text, p_interest_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c     public.campaign_control;
  l     public.leads;
  num   text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10);
  tz    text;
  t     timestamptz;
  d     date;
  ws    timestamptz;
  we    timestamptz;
  i     integer;
  att   integer := case when coalesce(p_step, 1) = 1 then 1 else 10 + p_step end;
  v_id  uuid;
  b     text := btrim(coalesce(p_body, ''));
  v     text := nullif(upper(left(btrim(coalesce(p_variant, '')), 20)), '');
  sl    text := nullif(lower(btrim(coalesce(p_slot, ''))), '');
  sh    time;
  rp    text;
  k     integer;
  reopen boolean := false;
  codes text;
  iv    public.interests;
  pid   uuid;
  iid   uuid;
begin
  select * into c from public.campaign_control where id = 1;
  select * into l from public.leads where leads.id = p_lead_id;
  if not found then return jsonb_build_object('status', 'refused', 'reason', 'no such card'); end if;
  if coalesce(p_step, 1) not between 1 and 5 then return jsonb_build_object('status', 'refused', 'reason', 'step is 1 to 5'); end if;
  if l.stage in ('dnc', 'dead', 'closed_no_contact', 'closed_won', 'under_contract') then
    -- a card the laptop closed only because its phones were dead comes back for the next phone (0080)
    if coalesce(p_step, 1) = 1 and l.stage in ('dead', 'closed_no_contact') then
      rp := public.dead_reopen_problem(p_lead_id, num);
      if rp is not null then return jsonb_build_object('status', 'refused', 'reason', rp); end if;
      reopen := true;
    else
      return jsonb_build_object('status', 'refused', 'reason', 'card is closed (' || l.stage::text || ')');
    end if;
  end if;
  if coalesce(p_step, 1) = 1 and (reopen or l.stage not in ('postcard_mailed', 'opener_queued')
       or exists (select 1 from public.planned_openers po where po.wpie_owner_id = l.wpie_owner_id and po.attempt between 1 and 9
                    and po.send_status = any(public.opener_live_statuses()))
       or exists (select 1 from public.messages m where m.lead_id = p_lead_id and m.direction = 'out' and m.is_opener and m.provider_sid is not null)) then
    -- the next phone on the card (0079): allowed when every earlier first text bounced or reached a wrong number
    if not reopen then
      rp := public.next_phone_problem(p_lead_id, num);
      if rp is not null then
        return jsonb_build_object('status', 'refused', 'reason', 'already texted or talking (' || l.stage::text || '): ' || rp);
      end if;
    end if;
    select coalesce(max(po.attempt), 1) + 1 into att from public.planned_openers po
     where po.wpie_owner_id = l.wpie_owner_id and po.attempt between 1 and 9;
    if att > 9 then return jsonb_build_object('status', 'refused', 'reason', 'nine first texts already: this card needs a skip trace'); end if;
  elsif coalesce(p_step, 1) > 1 then
    -- a follow-up belongs to the first text that reached this phone (attempt = that first text's attempt * 10 + step)
    select po.attempt into k from public.planned_openers po
     where po.wpie_owner_id = l.wpie_owner_id and po.attempt between 1 and 9 and right(regexp_replace(po.phone, '\D', '', 'g'), 10) = num
       and po.send_status = 'delivered' order by po.attempt desc limit 1;
    att := coalesce(k, 1) * 10 + p_step;
  end if;
  if not exists (select 1 from public.contacts ct where ct.lead_id = p_lead_id and ct.kind = 'phone' and ct.value_normalized = num
                  and ct.status = 'ok' and not ct.dnc_app and not ct.suppressed and not ct.dnc_vendor and ct.dnc_scrub <> 'dnc') then
    return jsonb_build_object('status', 'refused', 'reason', 'that phone is not a usable phone on this card');
  end if;
  if exists (select 1 from public.suppressed_phones s where s.phone10 = num) then
    return jsonb_build_object('status', 'refused', 'reason', 'this phone opted out');
  end if;
  -- the person the text is for (0083): a do-not-contact or deceased person's number is never texted, on any card
  rp := public.phone_person_block(num);
  if rp is not null then return jsonb_build_object('status', 'refused', 'reason', rp); end if;
  if p_interest_id is not null then
    select * into iv from public.interests i where i.id = p_interest_id and i.lead_id = p_lead_id;
    if not found then return jsonb_build_object('status', 'refused', 'reason', 'no such person on this card (interest_id)'); end if;
    if iv.status <> 'active' or (select pe.status from public.people pe where pe.id = iv.person_id) <> 'active' then
      return jsonb_build_object('status', 'refused', 'reason', 'that person is closed on this card (' || iv.status || ')');
    end if;
    if not exists (select 1 from public.contacts ct where ct.lead_id = p_lead_id and ct.value_normalized = num and ct.person_id = iv.person_id) then
      return jsonb_build_object('status', 'refused', 'reason', 'that phone is not that person''s on this card (add it to them with add_prospects)');
    end if;
    pid := iv.person_id; iid := iv.id;
  else
    select i.person_id, i.id into pid, iid from public.contacts ct join public.interests i on i.person_id = ct.person_id and i.lead_id = p_lead_id
      join public.people pe on pe.id = i.person_id
     where ct.lead_id = p_lead_id and ct.value_normalized = num and i.status = 'active' and pe.status = 'active'
     order by array_position(array['personal_representative', 'special_administrator', 'owner_of_record', 'co_owner', 'trustee', 'heir', 'spouse', 'occupant', 'other'], i.role)
     limit 1;
    if pid is null and exists (select 1 from public.contacts ct where ct.lead_id = p_lead_id and ct.value_normalized = num and ct.person_id is not null) then
      return jsonb_build_object('status', 'refused', 'reason', 'everyone this phone belongs to on this card is closed (deceased, do not contact or not the contact)');
    end if;
  end if;
  if exists (select 1 from public.twilio_inbound ti where ti.from10 = num) then
    return jsonb_build_object('status', 'refused', 'reason', 'they already texted back: replies go to the reply agent and the team');
  end if;
  if b = '' or position('STOP' in b) = 0 then return jsonb_build_object('status', 'refused', 'reason', 'the text needs a STOP line'); end if;
  if position('$' in b) > 0 then return jsonb_build_object('status', 'refused', 'reason', 'no prices or $ in a text'); end if;
  if length(b) > 320 then return jsonb_build_object('status', 'refused', 'reason', 'over 320 characters'); end if;
  if exists (select 1 from unnest(c.banned_words) w where w <> '' and position(lower(w) in lower(b)) > 0) then
    return jsonb_build_object('status', 'refused', 'reason', 'names the business');
  end if;
  if exists (select 1 from public.planned_openers po where po.lead_id = p_lead_id and po.step = coalesce(p_step, 1)
              and po.send_status in ('planned', 'would_send', 'sending')) then
    return jsonb_build_object('status', 'refused', 'reason', 'a text for this step is already waiting: withdraw it first');
  end if;
  if sl is not null and sl not in ('am', 'pm') then return jsonb_build_object('status', 'refused', 'reason', 'slot is am or pm'); end if;
  tz := public.agent_tz(coalesce(l.mailing_state, 'WI'));
  t := greatest(p_now, coalesce(p_send_after, p_now));
  -- the time-of-day test (Colin 2026-10-26: "200 daily in morning and 200 at 5", "9 is fine"): am goes from 9 AM, pm from 5 PM,
  -- their time; an am text queued after noon waits for the next morning
  if sl is not null then
    sh := case sl when 'am' then time '09:00' else time '17:00' end;
    if sl = 'am' and (t at time zone tz)::time >= time '12:00' then
      t := (((t at time zone tz)::date + 1) + sh) at time zone tz;
    else
      t := greatest(t, (((t at time zone tz)::date) + sh) at time zone tz);
    end if;
  end if;
  for i in 0..8 loop
    d := ((t at time zone tz)::date) + i;
    if c.no_sundays and extract(isodow from d) = 7 then continue; end if;
    ws := (d + c.window_start) at time zone tz;
    we := (d + c.window_end) at time zone tz;
    if we > t then t := greatest(t, ws); exit; end if;
  end loop;
  insert into public.planned_openers (plan_date, wpie_owner_id, attempt, lead_id, lane, template_lane, variant, send_slot, per_hour, phone, body,
         segments, scheduled_at, owner_name, property_address, decision, decided_by_name, decided_at, decision_note,
         send_status, window_start_utc, window_end_utc, governing_state, dnc_state, body_sha256, plan_created_at, step)
  values ((t at time zone c.timezone)::date, l.wpie_owner_id, att, l.id, 'agent', coalesce(nullif(left(btrim(coalesce(p_template, '')), 40), ''), 'agent'),
          coalesce(v, '-'), sl, case when sl = 'am' then 270 else 100 end, '+1' || num, b, case when length(b) <= 160 then 1 else 2 end, t, l.owner_name, l.property_address,
          'approved', 'Muse (' || coalesce(p_agent, 'agent') || ')', p_now, 'written and queued by the sender agent',
          'planned', ws, we, upper(coalesce(l.mailing_state, 'WI')), 'unknown', encode(sha256(convert_to(b, 'UTF8')), 'hex'), p_now,
          coalesce(p_step, 1))
  -- the laptop's copy of the same text, handed over to the agent, is taken over by the agent's wording
  on conflict (plan_date, wpie_owner_id, attempt) do update set
    lane = 'agent', template_lane = excluded.template_lane, variant = excluded.variant, send_slot = excluded.send_slot, phone = excluded.phone, body = excluded.body,
    segments = excluded.segments, scheduled_at = excluded.scheduled_at, decision = 'approved', decided_by_name = excluded.decided_by_name,
    decided_at = excluded.decided_at, decision_note = excluded.decision_note, send_status = 'planned', send_reason = null,
    send_updated_at = p_now, window_start_utc = excluded.window_start_utc, window_end_utc = excluded.window_end_utc,
    governing_state = excluded.governing_state, body_sha256 = excluded.body_sha256, per_hour = excluded.per_hour, step = excluded.step,
    claim_mode = null, claimed_at = null, provider_sid = null, error_code = null
    where planned_openers.send_status = 'withdrawn' and planned_openers.send_reason = 'handed to the sender agent'
  returning planned_openers.id into v_id;
  if v_id is null then return jsonb_build_object('status', 'refused', 'reason', 'this card already has that text planned for that day'); end if;
  if iid is not null then update public.planned_openers set interest_id = iid where id = v_id; end if;
  if reopen then
    select string_agg(distinct po.error_code, ', ') into codes from public.planned_openers po
     where po.wpie_owner_id = l.wpie_owner_id and po.step = 1 and po.error_code is not null;
    update public.leads set stage = 'opener_queued', belt = null, belt_step = 0, next_stop_at = null, next_stop_who = null,
           dead_reason = null, reopened_at = p_now,
           reopened_reason = 'delivery-failure cascade: every first text bounced' || coalesce(' (' || codes || ')', '') || '; next phone ' || num,
           notes = concat_ws(' | ', notes, to_char(p_now at time zone 'America/Chicago', 'YYYY-MM-DD') || ' reopened by Muse (' || coalesce(p_agent, 'agent')
                   || '): closed as ' || l.stage::text || ' only because every first text bounced' || coalesce(' (' || codes || ')', '') || '; texting the next phone ' || num)
     where id = p_lead_id;
    update public.lead_stage_events set source = 'agent: delivery-failure reopen'
     where id = (select max(e.id) from public.lead_stage_events e where e.lead_id = p_lead_id and e.to_stage = 'opener_queued');
    insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
    values (p_lead_id, 'reopened', l.belt, null, null, jsonb_build_object('from_stage', l.stage::text, 'why', 'every first text bounced', 'codes', codes, 'next_phone', num), p_now,
            'Muse (' || coalesce(p_agent, 'agent') || ')');
  end if;
  return jsonb_build_object('status', 'queued', 'text_id', v_id, 'goes_after', t, 'window_ends', we, 'variant', coalesce(v, '-'), 'slot', sl,
    'next_phone', coalesce(p_step, 1) = 1 and att > 1, 'reopened', reopen,
    'interest_id', iid, 'person', (select pe.name from public.people pe where pe.id = pid));
end $function$;

-- the people on a card, for the agent: role, status, their address, their phones (with the global facts) and their other cards
create or replace function public.card_interests(p_lead uuid) returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'interest_id', i.id, 'person_id', pe.id, 'name', pe.name, 'kind', pe.kind, 'role', i.role,
      'status', case when pe.status <> 'active' then pe.status else i.status end, 'status_reason', coalesce(i.status_reason, pe.status_reason),
      'mailing', jsonb_strip_nulls(jsonb_build_object('street', pe.mailing_street, 'city', pe.mailing_city, 'state', pe.mailing_state, 'zip', pe.mailing_zip)),
      'notes', i.notes,
      'phones', (select jsonb_agg(jsonb_build_object('phone', c.value_normalized, 'type', c.line_type,
                    'textable', c.status::text = 'ok' and not c.dnc_app and not c.suppressed and not c.dnc_vendor and c.dnc_scrub <> 'dnc'
                                and public.agent_phone_ok(c.value_normalized, c.line_type) and public.phone_person_block(c.value_normalized) is null,
                    'status', c.status, 'shared_with', (select jsonb_agg(distinct p2.name) from public.contacts c2 join public.people p2 on p2.id = c2.person_id
                                                          where c2.lead_id = i.lead_id and c2.value_normalized = c.value_normalized and c2.person_id <> pe.id))
                  order by c.created_at)
                   from public.contacts c where c.lead_id = i.lead_id and c.person_id = pe.id and c.kind = 'phone'),
      'other_cards', (select jsonb_agg(jsonb_build_object('lead_id', l2.id, 'address', l2.property_address, 'role', i2.role, 'stage', l2.stage))
                        from public.interests i2 join public.leads l2 on l2.id = i2.lead_id where i2.person_id = pe.id and i2.lead_id <> i.lead_id))
    order by (i.status = 'active' and pe.status = 'active') desc,
             array_position(array['personal_representative', 'special_administrator', 'owner_of_record', 'co_owner', 'trustee', 'heir', 'spouse', 'occupant', 'other'], i.role)), '[]'::jsonb)
    from public.interests i join public.people pe on pe.id = i.person_id where i.lead_id = p_lead
$$;

create or replace function public.agent_find(p jsonb) returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(public.agent_card(x.id)), '[]'::jsonb) from (
    select l.id from public.leads l
     where (coalesce(p->>'lead_id', '') = '' or l.id::text = p->>'lead_id')
       and (coalesce(p->>'address', '') = '' or l.property_address ilike '%' || (p->>'address') || '%'
            or public.addr_key(public.addr_main(l.property_address)) = public.addr_key(public.addr_main(p->>'address')))
       and (coalesce(p->>'name', '') = '' or l.owner_name ilike '%' || (p->>'name') || '%'
            or exists (select 1 from public.interests i join public.people pe on pe.id = i.person_id where i.lead_id = l.id and pe.name ilike '%' || (p->>'name') || '%'))
       and (coalesce(p->>'phone', '') = '' or exists (select 1 from public.contacts c where c.lead_id = l.id
              and c.value_normalized = right(regexp_replace(p->>'phone', '\D', '', 'g'), 10)))
       and (not coalesce((p->>'only_agent')::boolean, false) or l.wpie_owner_id < 0)
     order by l.updated_at desc limit least(coalesce((p->>'limit')::int, 20), 100)) x
$$;

-- the card carries its people
do $$
declare d text := pg_get_functiondef('public.agent_card(uuid)'::regprocedure);
begin
  if position('card_interests' in d) = 0 then
    d := replace(d, '''links'', public.card_links(l.id),', '''people'', public.card_interests(l.id),' || chr(10) || '    ''links'', public.card_links(l.id),');
    if position('card_interests' in d) = 0 then raise exception 'agent_card: could not add people'; end if;
    execute d;
  end if;
end $$;

revoke all on function public.agent_mark_person(uuid, text, uuid, text, text, text), public.card_after_person_change(uuid, text),
  public.phone_person_block(text), public.card_interests(uuid),
  public.agent_queue_text(uuid, text, text, integer, timestamptz, text, timestamptz, text, text, text, uuid) from public, anon, authenticated;
grant execute on function public.agent_mark_person(uuid, text, uuid, text, text, text), public.card_after_person_change(uuid, text),
  public.phone_person_block(text), public.card_interests(uuid),
  public.agent_queue_text(uuid, text, text, integer, timestamptz, text, timestamptz, text, text, text, uuid) to service_role;
grant execute on function public.card_interests(uuid) to authenticated;
