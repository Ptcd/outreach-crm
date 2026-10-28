-- Pipes phase 1b (Muse's spec 2026-10-28): Milwaukee vacant buildings and permit work data as staged SIGNALS.
--   mke.vacant   the city's registered vacant buildings (Accela extract, daily), published from WPIE's own daily
--                collection (mke.city.vacant_buildings) so the city's server is asked once. Parcel = MPROP tax key.
--   mke.permits  Residential and Commercial Permit Work Data, the monthly file (address only: matched by address).
-- data.milwaukee.gov's robots.txt disallows /api/, so nothing here uses the CKAN API: the files are the dataset
-- pages' own download links, as WPIE's collectors already fetch them.
-- A signal is never deleted. active = still on its source's list today; a vacancy that left the list stays on the
-- parcel as history (a stack is history, not a state) but no longer qualifies a parcel or opens an item.
-- A permit is context, not distress (Colin's list: foreclosure, probate, vacant, code, tax, sheriff sale, bankruptcy,
-- lien): it rides along on an item and never opens one.

insert into public.pipe_sources (source, name, county, url, cadence, grade, note) values
  ('mke.vacant', 'City of Milwaukee registered vacant buildings (DNS Accela)', 'Milwaukee',
   'https://data.milwaukee.gov/dataset/a9d52246-c06e-4ec2-a58e-a53ea0a72ded/resource/46dca88b-fec0-48f1-bda6-7296249ea61f/download/accelavacantbuilding.csv',
   'daily', 'current', 'Published from WPIE''s daily collection (mke.city.vacant_buildings). Each registration is its own record: parcel:date opened.'),
  ('mke.permits', 'City of Milwaukee residential and commercial permit work data', 'Milwaukee',
   'https://data.milwaukee.gov/dataset/9bada2e0-fad5-4545-8674-1b2c8c4e9f2f/resource/828e9630-d7cb-42e4-960e-964eae916397/download/buildingpermits.csv',
   'monthly', 'current', 'Issued permits since 2021, address only. Context on an item, never distress.')
on conflict (source) do nothing;

-- a batch of signals for one source (jsonb array: source_record_id, kind, county, parcel_id, address, municipality,
-- signal_date, tax_years, pairs_only, active, detail). New rows are inserted; known rows refreshed (last_seen, active,
-- detail); nothing is removed.
create or replace function public.pipe_upsert_signals(p_source text, p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare n_new integer; n_all integer;
begin
  if not exists (select 1 from public.pipe_sources where source = p_source) then raise exception 'unknown pipe source %', p_source; end if;
  select count(*) into n_new from jsonb_array_elements(p_rows) x
   where not exists (select 1 from public.pipe_signals g where g.source = p_source and g.source_record_id = x->>'source_record_id');
  insert into public.pipe_signals as g (source, source_record_id, kind, county, parcel_id, address, addr_key, municipality, signal_date,
         tax_years, pairs_only, active, detail, fetched_at, first_seen, last_seen)
  select p_source, x->>'source_record_id', x->>'kind', x->>'county', nullif(x->>'parcel_id', ''), x->>'address',
         public.addr_key(public.addr_main(x->>'address')), x->>'municipality', (x->>'signal_date')::date,
         (x->>'tax_years')::integer, coalesce((x->>'pairs_only')::boolean, false), coalesce((x->>'active')::boolean, true),
         coalesce(x->'detail', '{}'), now(), current_date, current_date
    from jsonb_array_elements(p_rows) x
  on conflict (source, source_record_id) do update set
         kind = excluded.kind, parcel_id = coalesce(excluded.parcel_id, g.parcel_id), address = excluded.address, addr_key = excluded.addr_key,
         municipality = excluded.municipality, signal_date = excluded.signal_date, tax_years = excluded.tax_years,
         pairs_only = excluded.pairs_only, active = excluded.active, detail = excluded.detail, fetched_at = now(), last_seen = current_date;
  get diagnostics n_all = row_count;
  return jsonb_build_object('rows', n_all, 'new', n_new);
end $$;

-- the source's list today: anything of this source not on it is no longer active (kept, as history)
create or replace function public.pipe_signals_listed(p_source text, p_listed text[]) returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  update public.pipe_signals set active = false where source = p_source and active and not (source_record_id = any(p_listed));
  get diagnostics n = row_count;
  return n;
end $$;

-- how the staged signals of a source sit on parcels and cards (for the run report)
create or replace function public.pipe_signal_counts(p_source text) returns jsonb
language sql stable security definer set search_path = public as $$
  with g as (
    select g.*, (select x.parcel_id from public.pipe_parcels x where x.county = g.county and x.gone_on is null
                  and (x.parcel_id = g.parcel_id or (g.parcel_id is null and x.addr_key = g.addr_key)) limit 1) staged_parcel
      from public.pipe_signals g where g.source = p_source)
  select jsonb_build_object('signals', count(*), 'active', count(*) filter (where active),
    'on_a_staged_parcel', count(*) filter (where staged_parcel is not null),
    'unmatched', count(*) filter (where staged_parcel is null),
    'active_on_a_card', count(*) filter (where active and exists (select 1 from public.leads l where lower(l.county) = lower(g.county)
        and (l.parcel_id = g.staged_parcel or (l.parcel_id is null and public.addr_key(public.addr_main(l.property_address)) = g.addr_key)))))
  from g
$$;

create or replace function public.pipe_screen(p_county text, p_parcel_id text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  s public.pipe_settings; p public.pipe_parcels; v_cards uuid[]; v_live uuid[]; v_main public.leads;
  v_fails text[]; v_sigs bigint[]; v_sig_kinds text[]; v_qualifying integer; v_tax_short integer; v_pairs integer; v_card_reasons boolean;
  v_map jsonb := null; v_conflicts jsonb := '[]'; v_why text[] := '{}'; v_missing text[] := '{}'; v_facts jsonb; v_gates jsonb;
  v_item public.pipe_queue; v_last public.pipe_queue; v_seen bigint[]; v_kind text; v_state text; v_new_signals boolean; v_owner_news boolean;
  c record; v_card_words text[]; v_shared integer; v_ambiguous uuid[] := '{}';
begin
  select * into s from public.pipe_settings where id = 1;
  select * into p from public.pipe_parcels x where x.county = p_county and x.parcel_id = p_parcel_id and x.gone_on is null
   order by (select grade from public.pipe_sources where source = x.source) = 'current' desc, x.vintage desc limit 1;
  if p.parcel_id is null then return jsonb_build_object('error', 'no staged parcel ' || p_county || ' ' || p_parcel_id); end if;

  v_cards := public.pipe_card_ids(p);
  select coalesce(array_agg(l.id), '{}') into v_live from public.leads l where l.id = any(v_cards) and l.stage not in ('dead', 'dnc', 'closed_no_contact');
  select * into v_main from public.leads l where l.id = coalesce(v_live[1], v_cards[1]);
  select count(*) into v_shared from public.pipe_parcels x where x.county = p.county and x.addr_key = p.addr_key and x.gone_on is null and x.source = p.source;
  if v_shared > 1 then
    select coalesce(array_agg(l.id), '{}') into v_ambiguous from public.leads l where l.id = any(v_cards) and l.parcel_id is null;
  end if;

  -- signals on this parcel (by parcel id, or by address when the source printed no parcel)
  select coalesce(array_agg(g.id order by g.id), '{}'), coalesce(array_agg(distinct g.kind), '{}'),
         count(*) filter (where g.active and not g.pairs_only and g.kind not in ('bankruptcy', 'permit') and (g.kind <> 'tax_delinquent' or coalesce(g.tax_years, 0) >= 2)),
         count(*) filter (where g.active and g.kind = 'tax_delinquent' and coalesce(g.tax_years, 0) < 2),
         count(*) filter (where g.active and g.pairs_only)
    into v_sigs, v_sig_kinds, v_qualifying, v_tax_short, v_pairs
    from public.pipe_signals g
   where g.county = p.county and (g.parcel_id = p.parcel_id or (g.parcel_id is null and g.addr_key is not null and g.addr_key = p.addr_key));
  v_card_reasons := exists (select 1 from public.leads l where l.id = any(v_live) and l.reasons_to_sell <> '{}');

  v_fails := public.pipe_static_fails(p, s);
  if v_qualifying = 0 and not v_card_reasons then
    v_fails := v_fails || case when v_tax_short > 0 then 'tax_under_2_years' when v_pairs > 0 then 'dor_needs_a_pair' else 'no_distress' end;
  end if;
  if exists (select 1 from public.pipe_signals g where g.county = p.county and g.kind = 'bankruptcy' and g.active
              and (g.parcel_id = p.parcel_id or (g.parcel_id is null and g.addr_key = p.addr_key))) then v_fails := v_fails || 'bankruptcy_active'::text; end if;
  if exists (select 1 from public.leads l where l.id = any(v_cards) and l.stage in ('dead', 'dnc', 'closed_no_contact')) then v_fails := v_fails || 'card_dead_or_dnc'::text; end if;
  if v_main.id is not null and exists (select 1 from public.interests i where i.lead_id = v_main.id and i.role = 'owner_of_record' and i.status = 'deceased')
     and not exists (select 1 from public.interests i where i.lead_id = v_main.id and i.status = 'active'
                       and i.role in ('owner_of_record', 'co_owner', 'personal_representative', 'special_administrator', 'heir', 'trustee', 'spouse'))
  then v_fails := v_fails || 'deceased_no_representative'::text; end if;

  -- the map last: it is only read for a parcel that passed everything else
  if cardinality(v_fails) = 0 then
    v_map := public.pipe_map_verdict(p.county, p.municipality, p.lat, p.lon);
    if v_map->>'verdict' = 'excluded' then v_fails := v_fails || 'map_excluded'::text;
    elsif v_map->>'verdict' = 'no_map' then v_fails := v_fails || 'map_not_loaded'::text;
    elsif v_map->>'verdict' = 'no_point' then v_fails := v_fails || 'map_no_point'::text; end if;
  end if;

  -- the card's owner against the pipe's: no shared name word on a live card = a conflict, kept, both sides stamped
  if cardinality(p.owner_names) > 0 then
    for c in select l.id, l.owner_name from public.leads l where l.id = any(v_live) and not (l.id = any(v_ambiguous)) loop
      select coalesce(array_agg(distinct z.w), '{}') into v_card_words from (
        select unnest(public.pipe_name_words(c.owner_name)) w
        union select unnest(public.pipe_name_words(pe.name)) from public.interests i join public.people pe on pe.id = i.person_id
         where i.lead_id = c.id and i.status = 'active' and i.role in ('owner_of_record', 'co_owner', 'trustee')) z;
      if cardinality(v_card_words) > 0 and not (v_card_words && public.pipe_name_words(array_to_string(p.owner_names, ' '))) then
        insert into public.pipe_conflicts (lead_id, county, parcel_id, field, card_value, card_basis, pipe_value, pipe_source, pipe_date)
        values (c.id, p.county, p.parcel_id, 'owner', c.owner_name, 'the card', array_to_string(p.owner_names, ' & '), p.source, p.vintage)
        on conflict (lead_id, field, pipe_value) do nothing;
      end if;
    end loop;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'lead_id', x.lead_id, 'field', x.field, 'card', x.card_value, 'card_basis', x.card_basis,
           'pipe', x.pipe_value, 'pipe_source', x.pipe_source, 'pipe_date', x.pipe_date, 'since', x.created_at) order by x.id), '[]')
    into v_conflicts from public.pipe_conflicts x where x.lead_id = any(v_live) and x.closed_at is null and x.parcel_id = p.parcel_id;

  v_gates := jsonb_build_object('pass', cardinality(v_fails) = 0 and coalesce(v_map->>'verdict', 'ok') = 'ok', 'fails', to_jsonb(v_fails), 'map', v_map,
                                'signals', cardinality(v_sigs), 'qualifying_signals', v_qualifying, 'card_reasons', v_card_reasons,
                                'cards', to_jsonb(v_cards), 'cards_by_shared_address', to_jsonb(v_ambiguous), 'at', now());
  update public.pipe_parcels x set gate = v_gates, gate_at = now() where x.county = p.county and x.parcel_id = p.parcel_id and x.source = p.source;

  -- what is new since the last item for this parcel: signals on no earlier item, an owner change it did not carry
  select * into v_item from public.pipe_queue q where q.county = p.county and q.parcel_id = p.parcel_id and q.state in ('open', 'claimed', 'held_buffer', 'held');
  select * into v_last from public.pipe_queue q where q.county = p.county and q.parcel_id = p.parcel_id order by q.created_at desc limit 1;
  select coalesce(array_agg(distinct x), '{}') into v_seen from public.pipe_queue q, unnest(q.signal_ids) x where q.county = p.county and q.parcel_id = p.parcel_id;
  v_new_signals := exists (select 1 from public.pipe_signals g where g.id = any(v_sigs) and not (g.id = any(v_seen)) and g.active and g.kind not in ('permit', 'bankruptcy'));
  v_owner_news := p.owner_changed_on is not null and (v_last.id is null or (v_last.facts->'owner'->>'changed_on') is distinct from p.owner_changed_on::text);

  if cardinality(v_live) > 0 and p.owner_changed_on is not null and (v_owner_news or v_item.id is not null) then v_why := v_why || 'owner_changed'::text; end if;
  if jsonb_array_length(v_conflicts) > 0 then v_why := v_why || 'owner_conflict'::text; end if;
  if cardinality(v_sigs) > 0 then v_why := v_why || 'signal'::text; end if;

  if cardinality(v_live) > 0 and (v_owner_news or jsonb_array_length(v_conflicts) > 0 or v_item.kind = 're_screen') then
    v_kind := 're_screen'; v_state := 'open';                   -- a card to look at again, whatever the gates say now
  elsif cardinality(v_fails) = 0 and (v_new_signals or v_item.id is not null) then
    v_kind := case when cardinality(v_live) > 0 then 'stack' else 'new' end;
    v_state := case when v_map->>'verdict' = 'held_buffer' then 'held_buffer' else 'open' end;
  else
    v_kind := null;
  end if;

  v_missing := array_remove(array[
    case when not exists (select 1 from public.contacts ct where ct.lead_id = any(v_live)) then 'phones' end,
    case when p.owner_changed_on is not null or (select grade from public.pipe_sources where source = p.source) <> 'current' or jsonb_array_length(v_conflicts) > 0
         then 'current_ownership_confirmation' end,
    case when p.use_class = 'residential' then 'unit_count_evidence' end,
    case when cardinality(v_ambiguous) > 0 then 'which_parcel: the card''s address is ' || v_shared || ' staged parcels' end,
    case when v_sig_kinds && array['foreclosure', 'probate', 'sheriff_sale', 'bankruptcy', 'lis_pendens', 'judgment'] then 'case_detail_read' end
  ], null);
  v_facts := public.pipe_facts(p);

  if v_kind is not null then
    if v_item.id is null then
      insert into public.pipe_queue (county, parcel_id, address, kind, state, lead_id, lead_ids, why, signal_ids, facts, conflicts, missing, gates)
      values (p.county, p.parcel_id, p.situs_address, v_kind, v_state, v_main.id, v_cards, v_why, v_sigs, v_facts, v_conflicts, v_missing, v_gates)
      returning * into v_item;
    else
      update public.pipe_queue q set kind = case when q.kind = 're_screen' then q.kind else v_kind end,
             state = case when q.state in ('open', 'held_buffer') then v_state else q.state end,
             lead_id = v_main.id, lead_ids = v_cards, why = (select array_agg(distinct w) from unnest(q.why || v_why) w),
             signal_ids = v_sigs, facts = v_facts, conflicts = v_conflicts, missing = v_missing, gates = v_gates, updated_at = now()
       where q.id = v_item.id returning * into v_item;
    end if;
  elsif v_item.id is not null then
    if v_item.state in ('open', 'held_buffer') then
      -- nobody has it and it no longer qualifies: closed by the pipe, with why
      update public.pipe_queue q set state = 'killed', outcome = 'gate_failed', outcome_note = array_to_string(v_fails, ', '), closed_by = 'pipe',
             closed_at = now(), gates = v_gates, facts = v_facts, updated_at = now() where q.id = v_item.id returning * into v_item;
    else
      update public.pipe_queue q set gates = v_gates, facts = v_facts, conflicts = v_conflicts, missing = v_missing, updated_at = now()
       where q.id = v_item.id returning * into v_item;
    end if;
  end if;
  return v_gates || jsonb_build_object('item', v_item.id, 'item_state', v_item.state, 'item_kind', v_item.kind);
end $$;

create or replace function public.pipe_screen_source(p_source text, p_limit integer default 5000) returns jsonb
language plpgsql security definer set search_path = public as $$
declare k record; n integer := 0; v jsonb; fails jsonb := '{}'; f text;
begin
  for k in
    with cand as (
      select p.county, p.parcel_id from public.pipe_parcels p
       where p.source = p_source and p.gone_on is null
         and (exists (select 1 from public.leads l where lower(l.county) = lower(p.county) and l.parcel_id = p.parcel_id)
              or exists (select 1 from public.leads l where lower(l.county) = lower(p.county) and p.addr_key is not null and l.parcel_id is null
                           and public.addr_key(public.addr_main(l.property_address)) = p.addr_key)
              or exists (select 1 from public.pipe_signals g where g.county = p.county and g.active and g.kind <> 'permit'
                           and (g.parcel_id = p.parcel_id or (g.parcel_id is null and g.addr_key = p.addr_key)))
              or (p.owner_changed_on is not null and (p.gate_at is null or p.owner_changed_on >= (p.gate_at at time zone 'America/Chicago')::date))
              or exists (select 1 from public.pipe_queue q where q.county = p.county and q.parcel_id = p.parcel_id and q.state in ('open', 'claimed', 'held_buffer', 'held'))))
    select * from cand order by county, parcel_id limit p_limit
  loop
    v := public.pipe_screen(k.county, k.parcel_id);
    n := n + 1;
    for f in select jsonb_array_elements_text(v->'fails') loop
      fails := jsonb_set(fails, array[f], to_jsonb(coalesce((fails->>f)::integer, 0) + 1));
    end loop;
  end loop;
  return jsonb_build_object('screened', n, 'fails', fails,
    'queue', (select coalesce(jsonb_object_agg(state || ':' || kind, c), '{}') from (select state, kind, count(*) c from public.pipe_queue group by 1, 2) q));
end $$;


do $$
declare f text;
begin
  foreach f in array array['pipe_upsert_signals(text, jsonb)', 'pipe_signals_listed(text, text[])', 'pipe_signal_counts(text)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;
