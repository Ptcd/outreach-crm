-- Pipes: the screen looks a parcel's signals up by parcel id and by address as two indexed lookups. With 18,500
-- signals staged (1b), the single OR condition scanned every signal for each of 160,000 parcels and the first 1b
-- screen ran past ten minutes (2026-10-28). Same rules, same results.

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
   where g.id in (select x.id from public.pipe_signals x where x.county = p.county and x.parcel_id = p.parcel_id
                  union all
                  select x.id from public.pipe_signals x where x.county = p.county and x.parcel_id is null and p.addr_key is not null and x.addr_key = p.addr_key);
  v_card_reasons := exists (select 1 from public.leads l where l.id = any(v_live) and l.reasons_to_sell <> '{}');

  v_fails := public.pipe_static_fails(p, s);
  if v_qualifying = 0 and not v_card_reasons then
    v_fails := v_fails || case when v_tax_short > 0 then 'tax_under_2_years' when v_pairs > 0 then 'dor_needs_a_pair' else 'no_distress' end;
  end if;
  if exists (select 1 from public.pipe_signals g where g.id = any(v_sigs) and g.kind = 'bankruptcy' and g.active) then v_fails := v_fails || 'bankruptcy_active'::text; end if;
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
    with p as (select x.county, x.parcel_id, x.addr_key, x.owner_changed_on, x.gate_at from public.pipe_parcels x where x.source = p_source and x.gone_on is null),
    cand as (
      select p.county, p.parcel_id from p join public.leads l on l.parcel_id = p.parcel_id and lower(l.county) = lower(p.county)
      union
      select p.county, p.parcel_id from p join public.leads l on l.parcel_id is null and lower(l.county) = lower(p.county)
                                                             and public.addr_key(public.addr_main(l.property_address)) = p.addr_key
      union
      select p.county, p.parcel_id from p join public.pipe_signals g on g.county = p.county and g.parcel_id = p.parcel_id
       where g.active and g.kind <> 'permit'
      union
      select p.county, p.parcel_id from p join public.pipe_signals g on g.county = p.county and g.parcel_id is null and g.addr_key = p.addr_key
       where g.active and g.kind <> 'permit'
      union
      select p.county, p.parcel_id from p where p.owner_changed_on is not null and (p.gate_at is null or p.owner_changed_on >= (p.gate_at at time zone 'America/Chicago')::date)
      union
      select p.county, p.parcel_id from p join public.pipe_queue q on q.county = p.county and q.parcel_id = p.parcel_id
       where q.state in ('open', 'claimed', 'held_buffer', 'held'))
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

create or replace function public.pipe_signal_counts(p_source text) returns jsonb
language sql stable security definer set search_path = public as $$
  with byp as (select distinct lower(county) county, parcel_id from public.leads where parcel_id is not null),
  bya as (select distinct lower(county) county, public.addr_key(public.addr_main(property_address)) ak from public.leads where parcel_id is null),
  g as (
    select g.id, g.active, g.county, coalesce(pp.parcel_id, pa.parcel_id) staged_parcel, coalesce(pp.addr_key, pa.addr_key) staged_addr
      from public.pipe_signals g
      left join public.pipe_parcels pp on pp.county = g.county and pp.parcel_id = g.parcel_id and pp.gone_on is null
      left join lateral (select x.parcel_id, x.addr_key from public.pipe_parcels x
                          where g.parcel_id is null and x.county = g.county and x.addr_key = g.addr_key and x.gone_on is null limit 1) pa on true
     where g.source = p_source)
  select jsonb_build_object('signals', count(*), 'active', count(*) filter (where active),
    'on_a_staged_parcel', count(*) filter (where staged_parcel is not null),
    'unmatched', count(*) filter (where staged_parcel is null),
    'active_on_a_card', count(*) filter (where active and staged_parcel is not null and (
        exists (select 1 from byp where byp.county = lower(g.county) and byp.parcel_id = g.staged_parcel)
        or exists (select 1 from bya where bya.county = lower(g.county) and bya.ak = g.staged_addr))))
  from g
$$;
