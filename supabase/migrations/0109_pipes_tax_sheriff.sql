-- Pipes, Muse's updated spec (2026-10-28, Colin): Milwaukee's delinquent real-estate tax accounts and Milwaukee County's
-- sheriff sales (MCLIO Foreclosed_Parcels, future sales included) as staged signals, with WPIE's 14-day rule.
--   mke.delqtax          the city's Delinquent Real Estate Tax Accounts file (monthly), published from WPIE's own
--                        collection (mke.city.delinquent_tax: one row per tax key per levy year). One signal per parcel;
--                        tax_years = its distinct unpaid levy years (installments are not years), so the 2+ year rule
--                        reads the file's own depth, not the row's presence.
--   mkco.sheriff_sales   one signal per CASE NUMBER (never the date). Qualifies only while scheduled 14+ days out. A
--                        scheduled sale inside 14 days or already past blocks the parcel outright (a past sale is
--                        missing data, not a live listing); a sale sold in the last year blocks too. When an adjournment
--                        moves the date the sale counts as new again, so it can come back into the window.
-- MPROP's TAX_DELQ / BI_VIOL / RAZE_STATUS are NOT signals: on 2026-10-28 they were still constants on all 159,950
-- rows ('99999', 'XXXX', '9'). The laptop records their distinct values in each run's counts and says so if that changes.

insert into public.pipe_sources (source, name, county, url, cadence, grade, note) values
  ('mke.delqtax', 'City of Milwaukee delinquent real estate tax accounts', 'Milwaukee',
   'https://data.milwaukee.gov/dataset/f376a61a-b279-4ff5-b6da-776a3df14ca0/resource/8f1367e1-6f8f-44cc-8ed6-2eecd8267ec7/download/delqreweb.xlsx',
   'monthly', 'current', 'Published from WPIE''s collection (mke.city.delinquent_tax). One signal per tax key; tax_years = distinct unpaid levy years.'),
  ('mkco.sheriff_sales', 'Milwaukee County sheriff sales (MCLIO Foreclosed_Parcels)', 'Milwaukee',
   'https://services2.arcgis.com/s1wgJQKbKJihhhaT/arcgis/rest/services/Foreclosed_Parcels/FeatureServer/25',
   'daily', 'current', 'One signal per case number. The 14-day rule: qualifies only while scheduled 14+ days out.')
on conflict (source) do nothing;

alter table public.pipe_queue add column if not exists signal_marks text[] not null default '{}';

create or replace function public.pipe_screen(p_county text, p_parcel_id text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  s public.pipe_settings; p public.pipe_parcels; v_cards uuid[]; v_live uuid[]; v_main public.leads;
  v_fails text[]; v_sigs bigint[]; v_sig_kinds text[]; v_qualifying integer; v_tax_short integer; v_pairs integer; v_card_reasons boolean;
  v_map jsonb := null; v_conflicts jsonb := '[]'; v_why text[] := '{}'; v_missing text[] := '{}'; v_facts jsonb; v_gates jsonb;
  v_item public.pipe_queue; v_last public.pipe_queue; v_seen bigint[]; v_kind text; v_state text; v_new_signals boolean; v_owner_news boolean;
  c record; v_card_words text[]; v_shared integer; v_ambiguous uuid[] := '{}'; v_marks text[]; v_seen_marks text[];
  v_today date := (now() at time zone 'America/Chicago')::date;
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
  if exists (select 1 from public.pipe_signals g where g.id = any(v_sigs) and g.kind = 'sheriff_sale'
              and coalesce(g.detail->>'status', 'scheduled') = 'scheduled' and g.signal_date < v_today + 14) then
    v_fails := v_fails || 'sheriff_sale_inside_14_days_or_past'::text;
  end if;
  if exists (select 1 from public.pipe_signals g where g.id = any(v_sigs) and g.kind = 'sheriff_sale'
              and g.detail->>'status' = 'sold' and g.signal_date > v_today - 365) then
    v_fails := v_fails || 'sheriff_sale_sold'::text;
  end if;
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
  select coalesce(array_agg(g.id::text || case when g.kind = 'sheriff_sale' then ':' || coalesce(g.signal_date::text, '') else '' end), '{}')
    into v_marks from public.pipe_signals g where g.id = any(v_sigs);
  select coalesce(array_agg(distinct x), '{}') into v_seen_marks from public.pipe_queue q, unnest(q.signal_marks) x where q.county = p.county and q.parcel_id = p.parcel_id;
  v_new_signals := exists (select 1 from public.pipe_signals g where g.id = any(v_sigs) and g.active and g.kind not in ('permit', 'bankruptcy')
                             and not (g.id = any(v_seen) and (g.kind <> 'sheriff_sale' or (g.id::text || ':' || coalesce(g.signal_date::text, '')) = any(v_seen_marks))));
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
      insert into public.pipe_queue (county, parcel_id, address, kind, state, lead_id, lead_ids, why, signal_ids, signal_marks, facts, conflicts, missing, gates)
      values (p.county, p.parcel_id, p.situs_address, v_kind, v_state, v_main.id, v_cards, v_why, v_sigs, v_marks, v_facts, v_conflicts, v_missing, v_gates)
      returning * into v_item;
    else
      update public.pipe_queue q set kind = case when q.kind = 're_screen' then q.kind else v_kind end,
             state = case when q.state in ('open', 'held_buffer') then v_state else q.state end,
             lead_id = v_main.id, lead_ids = v_cards, why = (select array_agg(distinct w) from unnest(q.why || v_why) w),
             signal_ids = v_sigs, signal_marks = v_marks, facts = v_facts, conflicts = v_conflicts, missing = v_missing, gates = v_gates, updated_at = now()
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

