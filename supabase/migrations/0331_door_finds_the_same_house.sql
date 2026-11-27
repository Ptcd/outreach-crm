-- 0331 (2026-11-27). Colin, after the 58 duplicate houses were merged (0330): "Yes, fix it" (the loader).
-- agent_add_prospect matched a load to a card by the address exactly as spelled (0298 made it ignore the ZIP). So an
-- agent's "1329 Tompkins Dr Unit E" made a second card beside the laptop's "1329 TOMPKINS DR", "N2441 Timothy Ln"
-- beside "N2441 TIMOTHY LA", and a load that carried the parcel number was never compared on it. 37 of the 59 extra
-- cards came from one load on 2026-11-23, and the second card went to the other caller as often as not.
--
-- Now, when the exact match finds nothing, same_house_card looks for the same house:
--   by parcel: the same parcel number in the same county (a county prefix on one side is fine), units not in
--     conflict, and the same street or the same owner;
--   by address: the same street in the same town with the unit taken off, units not in conflict (one side may have
--     none), parcels not in conflict, and the same owner (two name words shared, or the shorter name inside the longer;
--     one shared word is enough when the two addresses agree on the unit as well).
-- Two different units, or two different parcels, are two homes: no match. A different owner at an address with no
-- unit on one side is no match either (a condo building the laptop holds with no unit numbers).
-- And a card closed as a duplicate stands for the card that was kept, on every route, so a load never lands on a
-- dead card. The result says how it matched ('match': same_house, kept_card).

-- the two things a lookup starts from: the house number, and the end of the parcel number
create index if not exists leads_house_number_idx on public.leads (upper(split_part(btrim(property_address), ' ', 1)));
create index if not exists leads_parcel_tail_idx on public.leads (right(regexp_replace(upper(parcel_id), '[^0-9A-Z]', '', 'g'), 6));

create or replace function public.addr_parts(p text)
 returns text[]
 language plpgsql
 immutable
as $function$
declare
  k text := coalesce(public.addr_key(split_part(public.addr_main(coalesce(p, '')), ',', 1)), '');
  m text[];
  pair text[];
begin
  if k = '' then return array[null, null]::text[]; end if;
  k := ' ' || k || ' ';
  foreach pair slice 1 in array array[['LA','LN'],['WA','WAY'],['MOUNT','MT'],['TRAIL','TRL'],['PK','PKWY'],['APARTMENT','APT'],
      ['SUITE','STE'],['NUMBER','NO']] loop
    k := replace(k, ' ' || pair[1] || ' ', ' ' || pair[2] || ' ');
  end loop;
  k := regexp_replace(k, ' \d{5}( \d{4})? $', ' ');
  k := regexp_replace(k, '\m(\d+)(ST|ND|RD|TH)\M', '\1', 'g');
  -- a named unit, a bare "LOWER"/"UPPER", then a bare trailing number or letter ("... DR 111", "... ST A", "... DR W")
  m := regexp_match(k, '^ (.+) (?:UNIT|APT|STE|NO|LOT) ([0-9]+ ?[A-Z]?|[A-Z] ?[0-9]*) $');
  if m is null then m := regexp_match(k, '^ (.+ .+) (LOWER|UPPER) $'); end if;
  if m is null then m := regexp_match(k, '^ (.+? .+?) ([0-9]+ ?[A-Z]?|[A-Z]) $'); end if;
  if m is null then return array[btrim(k), null]::text[]; end if;
  -- a bare N, S, E or W after the street is a direction ("3403 W WOODWARD DR W"), not a unit
  if m[2] in ('N', 'S', 'E', 'W') and k !~ ' (UNIT|APT|STE|NO|LOT) [NSEW] $' then return array[btrim(m[1]), null]::text[]; end if;
  return array[btrim(m[1]), replace(m[2], ' ', '')]::text[];
end $function$;

create or replace function public.parcel_same(a text, b text)
 returns boolean
 language sql
 immutable
as $function$
  select case when x = '' or y = '' then false
              when x = y then true
              when length(x) >= 8 and length(y) > length(x) then right(y, length(x)) = x
              when length(y) >= 8 and length(x) > length(y) then right(x, length(y)) = y
              else false end
    from (select regexp_replace(upper(coalesce(a, '')), '[^0-9A-Z]', '', 'g') as x,
                 regexp_replace(upper(coalesce(b, '')), '[^0-9A-Z]', '', 'g') as y) s
$function$;

create or replace function public.owner_words(p text)
 returns text[]
 language sql
 immutable
as $function$
  select coalesce(array_agg(distinct w), '{}')
    from regexp_split_to_table(upper(regexp_replace(coalesce(p, ''), '[^A-Za-z]+', ' ', 'g')), ' ') w
   where length(w) >= 3
     and w <> all (array['TRUST','REVOCABLE','IRREVOCABLE','REVOC','LIVING','ESTATE','TRUSTEE','JOINT','FAMILY','SURVIVORSHIP','MARITAL',
                         'PROPERTIES','PROPERTY','HOLDINGS','INVESTMENTS','REALTY','HOMES','GROUP','RENTALS','BANK','CREDIT','UNION',
                         'MORTGAGE','ASSOCIATION','NATIONAL','FEDERAL','HOUSING','AUTHORITY','WISCONSIN','CITY','COUNTY','VILLAGE',
                         'TOWN','AVAILABLE','UNKNOWN','CURRENT','OWNER','RESIDENT','HEIRS','DECEASED','THE','AND','LLC','INC','EST','TRS','DBA',
                         'MRS','III','VAN','VON','DER','DEL','LOS','NOT','FOR','ETAL','DEBTOR'])
$function$;

create or replace function public.owner_same(a text, b text)
 returns boolean
 language sql
 immutable
as $function$
  select n >= 2 or (n >= 1 and n = least(cardinality(x), cardinality(y)))
    from (select public.owner_words(a) as x, public.owner_words(b) as y) s,
         lateral (select count(*) as n from unnest(s.x) w where w = any (s.y)) c
$function$;

-- one name word shared: enough only when the two addresses agree on the unit too (Chimere and Laron Cooper at one house)
create or replace function public.owner_kin(a text, b text)
 returns boolean
 language sql
 immutable
as $function$
  select public.owner_words(a) && public.owner_words(b)
$function$;

create or replace function public.same_house_card(p_address text, p_muni text, p_county text, p_parcel text, p_owner text, p_exclude uuid default null)
 returns uuid
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare
  parts text[] := public.addr_parts(p_address);
  st   text := parts[1];
  un   text := parts[2];
  hn   text := split_part(coalesce(parts[1], ''), ' ', 1);
  mk   text := public.muni_key(p_muni);
  cty  text := lower(btrim(coalesce(p_county, '')));
  pk   text := nullif(regexp_replace(upper(coalesce(p_parcel, '')), '[^0-9A-Z]', '', 'g'), '');
  r    record;
  lp   text[];
  one_parcel boolean;
  other_parcel boolean;
  one_street boolean;
  name_ok boolean;
begin
  if st is null then return null; end if;
  for r in
    select l.id, l.property_address, l.municipality, l.county, l.parcel_id, l.owner_name
      from public.leads l
     where l.id is distinct from p_exclude
       and ((hn <> '' and upper(split_part(btrim(l.property_address), ' ', 1)) = hn)
            or (pk is not null and cty <> '' and right(regexp_replace(upper(l.parcel_id), '[^0-9A-Z]', '', 'g'), 6) = right(pk, 6)
                and lower(btrim(coalesce(l.county, ''))) = cty and public.parcel_same(l.parcel_id, p_parcel)))
     order by (l.stage not in ('dead', 'dnc')) desc, (l.wpie_owner_id > 0) desc, l.created_at
  loop
    lp := public.addr_parts(r.property_address);
    if un is not null and lp[2] is not null and un <> lp[2] then continue; end if;   -- two units: two homes
    one_parcel := pk is not null and cty <> '' and r.parcel_id is not null and lower(btrim(coalesce(r.county, ''))) = cty
                  and public.parcel_same(r.parcel_id, p_parcel);
    other_parcel := pk is not null and nullif(regexp_replace(upper(coalesce(r.parcel_id, '')), '[^0-9A-Z]', '', 'g'), '') is not null
                    and not public.parcel_same(r.parcel_id, p_parcel);
    one_street := lp[1] = st and mk <> '' and public.muni_key(r.municipality) = mk
                  and (cty = '' or coalesce(btrim(r.county), '') = '' or lower(btrim(r.county)) = cty);
    name_ok := public.owner_same(r.owner_name, p_owner)
               or (un is not distinct from lp[2] and public.owner_kin(r.owner_name, p_owner));
    if one_parcel and (lp[1] = st or name_ok) then return r.id; end if;
    if one_street and not other_parcel and name_ok then return r.id; end if;
  end loop;
  return null;
end $function$;

revoke all on function public.same_house_card(text, text, text, text, text, uuid) from public, anon, authenticated;
grant execute on function public.same_house_card(text, text, text, text, text, uuid) to service_role;

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
  ex2    public.leads;
  v_match text;
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
  w      record;
begin
  -- 0307: a load that names the laptop's owner id needs no address of its own. The owner's card, else its
  -- phones_wanted row, says which house it is (Muse 2's batch 9, 2026-11-22: 102 numbers for owners with no card
  -- were refused 'no address' because the entries carried the owner id and the phones only). What the agent did
  -- send still wins.
  if ak is null and coalesce(p->>'wpie_owner_id', '') ~ '^[0-9]+$' then
    select l.property_address as address, l.property_zip as zip, l.municipality, l.county, null::text as parcel,
           null::text as owner_name, null::text as owner_type,
           null::text as mailing_street, null::text as mailing_city, null::text as mailing_state, null::text as mailing_zip
      into w from public.leads l
     where l.wpie_owner_id = (p->>'wpie_owner_id')::int and coalesce(btrim(l.property_address), '') <> ''
     order by l.created_at limit 1;
    if w.address is null then
      select pw.property_address as address, pw.property_zip as zip,
             regexp_replace(regexp_replace(initcap(pw.municipality), '^(City|Village) Of ', ''), '^Town Of ', 'Town of ') as municipality,
             pw.county, pw.parcel_id as parcel, pw.owner_name, pw.owner_type,
             pw.mailing_street, pw.mailing_city, pw.mailing_state, pw.mailing_zip
        into w from public.phones_wanted pw
       where pw.wpie_owner_id = (p->>'wpie_owner_id')::int and coalesce(btrim(pw.property_address), '') <> '';
    end if;
    if w.address is not null then
      p := jsonb_strip_nulls(jsonb_build_object('address', w.address, 'zip', w.zip, 'municipality', w.municipality,
             'county', w.county, 'parcel', w.parcel, 'owner_name', w.owner_name, 'owner_type', w.owner_type,
             'mailing_street', w.mailing_street, 'mailing_city', w.mailing_city, 'mailing_state', w.mailing_state,
             'mailing_zip', w.mailing_zip))
           || (select coalesce(jsonb_object_agg(k, v), '{}'::jsonb) from jsonb_each(p) e(k, v)
                where not (jsonb_typeof(v) = 'null' or (jsonb_typeof(v) = 'string' and btrim(v #>> '{}') = '')));
      ak := public.addr_key(p->>'address');
      akm := public.addr_key(public.addr_main(p->>'address'));
      zip := left(coalesce(p->>'zip', ''), 5);
      v_parcel := coalesce(nullif(left(btrim(coalesce(p->>'parcel', p->>'parcel_id')), 80), ''),
                           case when cardinality(public.notes_parcels(p->>'notes')) = 1 then (public.notes_parcels(p->>'notes'))[1] end);
    end if;
  end if;
  if ak is null then
    return jsonb_build_object('status', 'rejected', 'reason', case when coalesce(p->>'wpie_owner_id', '') ~ '^[0-9]+$'
      then 'no address: that owner id has no card and no phones_wanted row with an address; send the property address'
      else 'no address' end);
  end if;
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
  -- 0331: the same house under another spelling. 58 houses had two live cards on 2026-11-27 because "1329 Tompkins Dr"
  -- and "1329 Tompkins Dr Unit E" (same owner), "Timothy La" and "Timothy Ln", and one parcel written with and without
  -- its county prefix were each read as two houses.
  if ex.id is null then
    select * into ex from public.leads l
     where l.id = public.same_house_card(p->>'address', coalesce(p->>'city', p->>'municipality'), p->>'county', v_parcel, owner);
    if ex.id is not null then v_match := 'same_house'; end if;
  end if;
  -- a card closed as a duplicate stands for the card that was kept: the load goes there, not onto a dead card
  if ex.id is not null and ex.stage = 'dead' and coalesce(ex.dead_reason, '') ~ '^duplicate of card [0-9a-f-]{36}' then
    select * into ex2 from public.leads l where l.id = substring(ex.dead_reason from '^duplicate of card ([0-9a-f-]{36})')::uuid;
    if ex2.id is not null then ex := ex2; v_match := coalesce(v_match || ', ', '') || 'kept_card'; end if;
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
    'match', v_match,
    'parcel', coalesce(nullif(btrim(ex.parcel_id), ''), v_parcel),
    -- an agent card that already has a different parcel keeps it; the result says so
    'parcel_conflict', case when ex.wpie_owner_id < 0 and coalesce(btrim(ex.parcel_id), '') <> '' and v_parcel is not null
                             and regexp_replace(upper(ex.parcel_id), '[^0-9A-Z]', '', 'g') <> regexp_replace(upper(v_parcel), '[^0-9A-Z]', '', 'g')
                            then jsonb_build_object('card', ex.parcel_id, 'sent', v_parcel) end,
    'existing', case when ex.id is null then null else jsonb_build_object('owner_name', ex.owner_name, 'stage', ex.stage,
      'source', coalesce(ex.source, case when ex.wpie_owner_id > 0 then 'laptop' end),
      'texted', exists (select 1 from public.messages m where m.lead_id = ex.id and m.direction = 'out' and m.channel = 'sms')) end);
end $function$;
