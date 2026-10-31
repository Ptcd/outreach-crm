-- 0153: the anchor's opening discount per value band (Colin 2026-10-31: "I deserve the deep wholesaler discount if we're
-- doing the wholesaler work"; no 15% buying mode). offer_settings.bands entries may carry "off" (e.g. 0.35 under $120K,
-- 0.30 above, Rick's 2026 offer formula); offer_shoot uses it, else lao_discount, and returns the discount it used.

-- offer_shoot: from 0149_exit_anchor_number.sql
create or replace function public.offer_shoot(p_lead_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.offer_settings; l public.leads; pv public.property_values; pk public.deal_packages;
        value numeric; value_basis text; sqft integer; sqft_basis text; units integer; beds integer;
        cond text[]; happened text[]; tier text; tier_basis text; per_ft numeric; repairs numeric; pct numeric;
        mao numeric; lao numeric; num numeric; band jsonb; layout text; their text; off numeric;
begin
  if not public.is_team() then raise exception 'only the team'; end if;
  select * into s from public.offer_settings where id = 1;
  select * into l from public.leads where id = p_lead_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card', 'mode', s.mode); end if;
  select * into pk from public.deal_packages d where d.lead_id = p_lead_id
     and d.status in ('waiting_value', 'waiting_number', 'go_walk', 'number_ready', 'counter', 'agreed') order by created_at desc limit 1;
  if l.wpie_property_id is not null then select * into pv from public.property_values where wpie_property_id = l.wpie_property_id; end if;

  if pk.arv is not null and pk.arv > 0 then value := pk.arv; value_basis := 'the package''s value (' || coalesce(pk.valued_by, 'Muse') || ')';
  elsif pv.est_market_value is not null and pv.est_market_value > 0 then value := pv.est_market_value; value_basis := 'the county''s estimated market value';
  elsif pv.assessed_total is not null and pv.assessed_total > 0 then value := round(pv.assessed_total / 0.95); value_basis := 'assessed value (' || pv.assessed_total::text || ') adjusted';
  end if;
  their := nullif(l.call_facts->'price'->'value'->>'number', '');
  if value is null then
    return jsonb_build_object('ok', false, 'mode', s.mode, 'their_number', their,
      'reason', 'no value on file for this card: ask for their number, or book Colin');
  end if;

  units := greatest(coalesce(l.units, 1), 1);
  layout := coalesce(l.call_facts->'layout'->'value'->>'text', '');
  beds := nullif(substring(layout from '(\d+)\s*(?:-\s*)?(?:bed|br\b|bd\b|bdrm)'), '')::integer;
  if pv.building_sqft is not null and pv.building_sqft > 0 then sqft := pv.building_sqft; sqft_basis := 'county records';
  elsif beds is not null then sqft := (case when beds <= 1 then 750 when beds = 2 then 950 when beds = 3 then 1250 when beds = 4 then 1600 else 2000 end) * units;
       sqft_basis := beds::text || ' bedrooms, as they said';
  else sqft := s.default_sqft * units; sqft_basis := 'assumed'; end if;

  select coalesce(array_agg(x), '{}') into cond from jsonb_array_elements_text(coalesce(l.call_facts->'condition'->'value'->'choices', '[]'::jsonb)) x;
  select coalesce(array_agg(x), '{}') into happened from jsonb_array_elements_text(coalesce(l.call_facts->'happened'->'value'->'choices', '[]'::jsonb)) x;
  if cond && array['roof', 'foundation', 'electrical', 'plumbing', 'water'] or happened && array['fire', 'foundation', 'code', 'leak'] then
    tier := 'heavy'; tier_basis := 'roof, structure, systems or damage, as they said';
  elsif cond && array['furnace', 'water_heater', 'windows', 'kitchen_baths', 'yard'] then
    tier := 'medium'; tier_basis := 'mechanicals, windows, kitchen or baths, as they said';
  elsif cond && array['cosmetic', 'perfect'] then
    tier := 'light'; tier_basis := 'cosmetic only, as they said';
  else tier := 'medium'; tier_basis := 'assumed (condition not asked yet)'; end if;
  per_ft := case tier when 'heavy' then s.repair_heavy when 'light' then s.repair_light else s.repair_medium end;
  repairs := round(per_ft * sqft);

  pct := null; off := null;
  for band in select * from jsonb_array_elements(s.bands) loop
    if band->>'upto' is null or value <= (band->>'upto')::numeric then
      pct := (band->>'pct')::numeric; off := nullif(band->>'off', '')::numeric; exit;
    end if;
  end loop;
  pct := coalesce(pct, 0.70);
  -- a band may carry its own opening discount (Colin 2026-10-31: the deep wholesaler discount always, deeper on
  -- cheap houses, Rick's 2026 numbers); the single lao_discount is the fallback
  off := coalesce(off, s.lao_discount);
  mao := (value - repairs) * pct;
  lao := mao * (1 - off);
  num := floor(lao / greatest(s.round_to, 1)) * greatest(s.round_to, 1);
  if num < s.min_number then
    return jsonb_build_object('ok', false, 'mode', s.mode, 'their_number', their, 'value', value, 'value_basis', value_basis,
      'repairs', repairs, 'tier', tier, 'mao', round(mao), 'lao', round(lao),
      'reason', 'too thin to say a number (' || round(lao)::text || '): book Colin instead');
  end if;
  return jsonb_build_object('ok', true, 'mode', s.mode, 'their_number', their,
    'value', value, 'value_basis', value_basis, 'sqft', sqft, 'sqft_basis', sqft_basis, 'units', units,
    'tier', tier, 'tier_basis', tier_basis, 'per_ft', per_ft, 'repairs', repairs, 'pct', pct,
    'mao', round(mao), 'lao', round(lao), 'number', num, 'off', off,
    'say', 'I can''t give you a firm number on a place we haven''t seen. Rough, and going off what you''ve told me and what the county shows, we''d be somewhere around $' || to_char(num, 'FM999,999,999') || '. Is that even in the conversation?');
end $$;
