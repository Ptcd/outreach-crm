-- 0154: the quick number in Power hour, on line-item repairs (Colin 2026-10-31: "this needs to be something done quickly
-- during power hour", "also needs to factor in repairs somehow"; "less questions = more likely to get to the point of an
-- offer"). Four taps on the call (roof, furnace/AC, kitchen and baths, anything big) set the repair lines; everything the
-- seller was not asked counts as needing work (Rick: when unsure, assume heavy), unless the house is under 5 years old.
-- A base refresh is always on, so the repairs bring the house to the condition of the sold comps behind the value.
-- Water, foundation, fire or a code order means no number: Colin walks it first. The buffer is on the repairs (20%
-- while unseen). The answers live on the card's call_facts (quick_roof, quick_hvac, quick_kb, quick_big); the older
-- condition chips from the call script still count when no quick answer is given. Dollar figures are placeholders from
-- the investors' videos until Colin gives his own job costs; all of them are in offer_settings.rehab, editable.

alter table public.offer_settings add column if not exists rehab jsonb not null default '{
  "base_per_ft": 12,
  "roof_small": 12000, "roof_big": 16000, "roof_big_over_sqft": 1500,
  "hvac": 8000,
  "kitchen_pct": 0.08, "kitchen_min": 10000,
  "bath": 7000,
  "new_house_years": 5,
  "unseen_buffer": 0.20
}'::jsonb;

create or replace function public.offer_settings_set(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_owner() then raise exception 'only Colin sets the offer rules'; end if;
  if p ? 'mode' and p->>'mode' not in ('off', 'exit_only', 'live') then return jsonb_build_object('ok', false, 'reason', 'mode is off, exit_only or live'); end if;
  if p ? 'rehab' and jsonb_typeof(p->'rehab') <> 'object' then return jsonb_build_object('ok', false, 'reason', 'rehab is an object of dollar figures'); end if;
  update public.offer_settings set
    mode = coalesce(p->>'mode', mode),
    bands = coalesce(p->'bands', bands),
    repair_light = coalesce((p->>'repair_light')::numeric, repair_light),
    repair_medium = coalesce((p->>'repair_medium')::numeric, repair_medium),
    repair_heavy = coalesce((p->>'repair_heavy')::numeric, repair_heavy),
    lao_discount = coalesce((p->>'lao_discount')::numeric, lao_discount),
    default_sqft = coalesce((p->>'default_sqft')::integer, default_sqft),
    min_number = coalesce((p->>'min_number')::numeric, min_number),
    round_to = coalesce((p->>'round_to')::integer, round_to),
    rehab = case when p ? 'rehab' then rehab || (p->'rehab') else rehab end,
    updated_at = now(), updated_by = coalesce(auth.jwt() ->> 'email', 'colin')
   where id = 1;
  return jsonb_build_object('ok', true, 'mode', (select mode from public.offer_settings where id = 1));
end $$;
revoke all on function public.offer_settings_set(jsonb) from public, anon;
grant execute on function public.offer_settings_set(jsonb) to authenticated, service_role;

create or replace function public.offer_shoot(p_lead_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.offer_settings; l public.leads; pv public.property_values; pk public.deal_packages; rh jsonb;
        value numeric; value_basis text; sqft integer; sqft_basis text; units integer; beds integer; baths integer;
        cond text[]; happened text[]; layout text; their text; f jsonb;
        q_roof text; q_hvac text; q_kb text; q_big text; newish boolean := false;
        lines jsonb := '[]'::jsonb; sub numeric := 0; amt numeric; buffer numeric; repairs numeric;
        pct numeric; off numeric; band jsonb; mao numeric; lao numeric; num numeric; asked integer := 0;
begin
  if not public.is_team() then raise exception 'only the team'; end if;
  select * into s from public.offer_settings where id = 1;
  rh := s.rehab;
  select * into l from public.leads where id = p_lead_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card', 'mode', s.mode); end if;
  f := coalesce(l.call_facts, '{}'::jsonb);
  select * into pk from public.deal_packages d where d.lead_id = p_lead_id
     and d.status in ('waiting_value', 'waiting_number', 'go_walk', 'number_ready', 'counter', 'agreed') order by created_at desc limit 1;
  if l.wpie_property_id is not null then select * into pv from public.property_values where wpie_property_id = l.wpie_property_id; end if;

  -- the value fixed up: the package's (Muse or Colin), else the county's estimate, else assessed adjusted
  if pk.arv is not null and pk.arv > 0 then value := pk.arv; value_basis := 'the package''s value (' || coalesce(pk.valued_by, 'Muse') || ')';
  elsif pv.est_market_value is not null and pv.est_market_value > 0 then value := pv.est_market_value; value_basis := 'the county''s estimated market value';
  elsif pv.assessed_total is not null and pv.assessed_total > 0 then value := round(pv.assessed_total / 0.95); value_basis := 'assessed value (' || pv.assessed_total::text || ') adjusted';
  end if;
  their := nullif(f->'price'->'value'->>'number', '');
  if value is null then
    return jsonb_build_object('ok', false, 'mode', s.mode, 'their_number', their, 'reason', 'no value on file for this card: ask for their number, or book Colin');
  end if;

  -- size: the county, else the bedrooms they named, else the default
  units := greatest(coalesce(l.units, 1), 1);
  layout := coalesce(f->'layout'->'value'->>'text', '');
  beds := nullif(substring(layout from '(\d+)\s*(?:-\s*)?(?:bed|br\b|bd\b|bdrm)'), '')::integer;
  baths := coalesce(nullif(substring(layout from '(\d+)\s*(?:-\s*)?(?:bath|ba\b)'), '')::integer, 1);
  if pv.building_sqft is not null and pv.building_sqft > 0 then sqft := pv.building_sqft; sqft_basis := 'county records';
  elsif beds is not null then sqft := (case when beds <= 1 then 750 when beds = 2 then 950 when beds = 3 then 1250 when beds = 4 then 1600 else 2000 end) * units;
       sqft_basis := beds::text || ' bedrooms, as they said';
  else sqft := s.default_sqft * units; sqft_basis := 'assumed'; end if;
  newish := pv.year_built is not null and pv.year_built >= extract(year from now())::integer - coalesce((rh->>'new_house_years')::integer, 5);

  -- the four quick answers, else the call script's condition chips, else unknown
  select coalesce(array_agg(x), '{}') into cond from jsonb_array_elements_text(coalesce(f->'condition'->'value'->'choices', '[]'::jsonb)) x;
  select coalesce(array_agg(x), '{}') into happened from jsonb_array_elements_text(coalesce(f->'happened'->'value'->'choices', '[]'::jsonb)) x;
  q_roof := f->'quick_roof'->'value'->'choices'->>0;
  q_hvac := f->'quick_hvac'->'value'->'choices'->>0;
  q_kb   := f->'quick_kb'->'value'->'choices'->>0;
  q_big  := f->'quick_big'->'value'->'choices'->>0;
  if q_roof is null then q_roof := case when 'roof' = any(cond) then 'old' when cond && array['cosmetic', 'perfect'] then 'new' end; end if;
  if q_hvac is null then q_hvac := case when 'furnace' = any(cond) then 'old' when cond && array['cosmetic', 'perfect'] then 'new' end; end if;
  if q_kb is null then q_kb := case when 'kitchen_baths' = any(cond) then 'original' when cond && array['cosmetic', 'perfect'] then 'updated' end; end if;
  if q_big is null then q_big := case when cond && array['foundation', 'water'] or happened && array['fire', 'foundation', 'code', 'leak'] then 'yes'
                                       when 'none' = any(happened) then 'no' end; end if;
  asked := (q_roof is not null)::int + (q_hvac is not null)::int + (q_kb is not null)::int + (q_big is not null)::int;

  if q_big = 'yes' then
    return jsonb_build_object('ok', false, 'mode', s.mode, 'their_number', their, 'value', value, 'value_basis', value_basis, 'walk_first', true,
      'reason', 'water, foundation, fire or a code order: no number on the phone, Colin walks it first');
  end if;

  -- the lines
  amt := round((rh->>'base_per_ft')::numeric * sqft);
  lines := lines || jsonb_build_object('item', 'Base refresh (paint, floors, fixtures)', 'amount', amt, 'why', sqft::text || ' sq ft, ' || sqft_basis); sub := sub + amt;
  if coalesce(q_roof, case when newish then 'new' else 'old' end) = 'old' then
    amt := case when sqft > (rh->>'roof_big_over_sqft')::integer then (rh->>'roof_big')::numeric else (rh->>'roof_small')::numeric end;
    lines := lines || jsonb_build_object('item', 'Roof', 'amount', amt, 'why', case when q_roof is null then 'not asked: counted' else 'old, as they said' end); sub := sub + amt;
  end if;
  if coalesce(q_hvac, case when newish then 'new' else 'old' end) = 'old' then
    amt := (rh->>'hvac')::numeric;
    lines := lines || jsonb_build_object('item', 'Furnace / AC', 'amount', amt, 'why', case when q_hvac is null then 'not asked: counted' else 'original, as they said' end); sub := sub + amt;
  end if;
  if coalesce(q_kb, case when newish then 'updated' else 'original' end) = 'original' then
    amt := greatest(round((rh->>'kitchen_pct')::numeric * value / units), (rh->>'kitchen_min')::numeric) * units;
    lines := lines || jsonb_build_object('item', 'Kitchen', 'amount', amt, 'why', case when q_kb is null then 'not asked: counted' else 'original, as they said' end); sub := sub + amt;
    amt := (rh->>'bath')::numeric * baths * units;
    lines := lines || jsonb_build_object('item', 'Bath' || case when baths * units > 1 then 's' else '' end, 'amount', amt, 'why', (baths * units)::text || ' bath' || case when baths * units > 1 then 's' else '' end); sub := sub + amt;
  end if;
  buffer := round(sub * coalesce((rh->>'unseen_buffer')::numeric, 0.20));
  lines := lines || jsonb_build_object('item', 'Buffer, unseen', 'amount', buffer, 'why', round(coalesce((rh->>'unseen_buffer')::numeric, 0.20) * 100)::text || '% of the lines');
  repairs := sub + buffer;

  -- Rick's math: (value - repairs) x the band's percent = the buyer's most; the anchor opens the band's discount under it
  pct := null; off := null;
  for band in select * from jsonb_array_elements(s.bands) loop
    if band->>'upto' is null or value <= (band->>'upto')::numeric then
      pct := (band->>'pct')::numeric; off := nullif(band->>'off', '')::numeric; exit;
    end if;
  end loop;
  pct := coalesce(pct, 0.70); off := coalesce(off, s.lao_discount);
  mao := (value - repairs) * pct;
  lao := mao * (1 - off);
  num := floor(lao / greatest(s.round_to, 1)) * greatest(s.round_to, 1);
  if num < s.min_number then
    return jsonb_build_object('ok', false, 'mode', s.mode, 'their_number', their, 'value', value, 'value_basis', value_basis,
      'repairs', repairs, 'lines', lines, 'mao', round(mao), 'lao', round(lao), 'asked', asked,
      'reason', 'too thin to say a number (' || round(lao)::text || '): book Colin instead');
  end if;
  return jsonb_build_object('ok', true, 'mode', s.mode, 'their_number', their,
    'value', value, 'value_basis', value_basis, 'sqft', sqft, 'sqft_basis', sqft_basis, 'units', units,
    'lines', lines, 'repairs', repairs, 'asked', asked,
    'tier', 'itemized', 'tier_basis', asked::text || ' of 4 quick answers given; the rest counted as needing work',
    'pct', pct, 'off', off, 'mao', round(mao), 'lao', round(lao), 'number', num,
    'say', 'I can''t give you a firm number on a place we haven''t seen. Rough, and going off what you''ve told me and what the county shows, we''d be somewhere around $' || to_char(num, 'FM999,999,999') || '. Is that even in the conversation?');
end $$;
revoke all on function public.offer_shoot(uuid) from public, anon;
grant execute on function public.offer_shoot(uuid) to authenticated, service_role;
