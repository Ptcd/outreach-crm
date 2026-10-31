-- 0149: the exit anchor. Colin 2026-10-30, after Adil: "we're losing opportunities and having doors closed because
-- we're just asking questions to strangers like everyone else then saying we'll call you back"; the purpose "is for
-- people that don't give us a number or are trying to get off the phone fast". A seller who has refused a number twice,
-- said "make me an offer", or is leaving, hears ONE low, non-firm figure so they say their own number (Rick's go-for-no).
-- Everyone else still hears no number: Colin gives his at the house (0114). The figure is Rick's arithmetic on what the
-- county says the place is worth and what the seller said about its condition, never a caller's guess. Ships OFF:
-- offer_settings.mode is 'off' until Colin turns it on in Settings ('exit_only'; 'live' shows it on every call).

-- what the county knows about each card's parcel (the laptop pushes it: tools/push_property_values.py)
create table if not exists public.property_values (
  wpie_property_id integer primary key,
  est_market_value numeric,          -- DOR estimated fair market value (assessed / the municipality's ratio)
  assessed_total numeric,
  assessed_land numeric,
  assessed_improvements numeric,
  building_sqft integer,
  year_built integer,
  property_class text,
  last_sale_price numeric,
  last_sale_date date,
  as_of date,
  updated_at timestamptz not null default now()
);
alter table public.property_values enable row level security;
drop policy if exists property_values_team_read on public.property_values;
create policy property_values_team_read on public.property_values for select to authenticated using (public.is_team());
grant select on public.property_values to authenticated;

create table if not exists public.offer_settings (
  id integer primary key default 1 check (id = 1),
  mode text not null default 'off' check (mode in ('off', 'exit_only', 'live')),
  -- Rick: ARV minus repairs times 70% under $120K ARV; 75 to 80% above (savvy buyers 70-75, newer cash buyers 80-85)
  bands jsonb not null default '[{"upto": 120000, "pct": 0.70}, {"upto": 250000, "pct": 0.75}, {"upto": null, "pct": 0.80}]'::jsonb,
  repair_light numeric not null default 15,      -- $ per square foot: cosmetic only
  repair_medium numeric not null default 30,     -- mechanicals, windows, kitchen and baths
  repair_heavy numeric not null default 50,      -- roof, foundation, electrical, plumbing, water damage, fire, code
  lao_discount numeric not null default 0.15,    -- the anchor sits 15% under MAO (Rick: 15 to 20)
  default_sqft integer not null default 1200,    -- when the county has no size and the seller named no bedrooms
  min_number numeric not null default 15000,     -- under this the math is too thin to say out loud
  round_to integer not null default 1000,
  updated_at timestamptz not null default now(),
  updated_by text
);
insert into public.offer_settings (id) values (1) on conflict (id) do nothing;
alter table public.offer_settings enable row level security;
drop policy if exists offer_settings_team_read on public.offer_settings;
create policy offer_settings_team_read on public.offer_settings for select to authenticated using (public.is_team());
grant select on public.offer_settings to authenticated;

create or replace function public.offer_settings_set(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_owner() then raise exception 'only Colin sets the offer rules'; end if;
  if p ? 'mode' and p->>'mode' not in ('off', 'exit_only', 'live') then return jsonb_build_object('ok', false, 'reason', 'mode is off, exit_only or live'); end if;
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
    updated_at = now(), updated_by = coalesce(auth.jwt() ->> 'email', 'colin')
   where id = 1;
  return jsonb_build_object('ok', true, 'mode', (select mode from public.offer_settings where id = 1));
end $$;
revoke all on function public.offer_settings_set(jsonb) from public, anon;
grant execute on function public.offer_settings_set(jsonb) to authenticated, service_role;

-- The arithmetic, in one place. Value: an open package's value (Muse or Colin) first, else the county's estimated
-- market value, else assessed / 0.95. Size: the county's square feet, else the bedrooms the seller named, else the
-- default (times units for a multi). Repairs: the worst thing the seller said about the place sets the tier.
create or replace function public.offer_shoot(p_lead_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.offer_settings; l public.leads; pv public.property_values; pk public.deal_packages;
        value numeric; value_basis text; sqft integer; sqft_basis text; units integer; beds integer;
        cond text[]; happened text[]; tier text; tier_basis text; per_ft numeric; repairs numeric; pct numeric;
        mao numeric; lao numeric; num numeric; band jsonb; layout text; their text;
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

  pct := null;
  for band in select * from jsonb_array_elements(s.bands) loop
    if band->>'upto' is null or value <= (band->>'upto')::numeric then pct := (band->>'pct')::numeric; exit; end if;
  end loop;
  pct := coalesce(pct, 0.70);
  mao := (value - repairs) * pct;
  lao := mao * (1 - s.lao_discount);
  num := floor(lao / greatest(s.round_to, 1)) * greatest(s.round_to, 1);
  if num < s.min_number then
    return jsonb_build_object('ok', false, 'mode', s.mode, 'their_number', their, 'value', value, 'value_basis', value_basis,
      'repairs', repairs, 'tier', tier, 'mao', round(mao), 'lao', round(lao),
      'reason', 'too thin to say a number (' || round(lao)::text || '): book Colin instead');
  end if;
  return jsonb_build_object('ok', true, 'mode', s.mode, 'their_number', their,
    'value', value, 'value_basis', value_basis, 'sqft', sqft, 'sqft_basis', sqft_basis, 'units', units,
    'tier', tier, 'tier_basis', tier_basis, 'per_ft', per_ft, 'repairs', repairs, 'pct', pct,
    'mao', round(mao), 'lao', round(lao), 'number', num,
    'say', 'I can''t give you a firm number on a place we haven''t seen. Rough, and going off what you''ve told me and what the county shows, we''d be somewhere around $' || to_char(num, 'FM999,999,999') || '. Is that even in the conversation?');
end $$;
revoke all on function public.offer_shoot(uuid) from public, anon;
grant execute on function public.offer_shoot(uuid) to authenticated, service_role;

-- The caller said it: what they said back. Kept on the card (call_facts.our_number), in the notes, and carried onto
-- the package when it is sent. The only number a caller ever says is the one this function was handed by offer_shoot.
create or replace function public.offer_said(p_lead_id uuid, p_number numeric, p_reaction text, p_counter numeric default null, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.offer_settings; who text; shot jsonb;
begin
  if not public.is_team() then raise exception 'only the team'; end if;
  select * into s from public.offer_settings where id = 1;
  if s.mode = 'off' then return jsonb_build_object('ok', false, 'reason', 'the anchor is off: no number on the phone'); end if;
  if p_reaction not in ('gave_number', 'open', 'no', 'later') then return jsonb_build_object('ok', false, 'reason', 'reaction is gave_number, open, no or later'); end if;
  if p_reaction = 'gave_number' and (p_counter is null or p_counter <= 0) then return jsonb_build_object('ok', false, 'reason', 'write the number they said'); end if;
  shot := public.offer_shoot(p_lead_id);
  if not coalesce((shot->>'ok')::boolean, false) or (shot->>'number')::numeric is distinct from p_number then
    return jsonb_build_object('ok', false, 'reason', 'the only number you say is the one on the card' || coalesce(': ' || (shot->>'number'), ''));
  end if;
  select display_name into who from public.team_members where lower(email) = lower(auth.jwt() ->> 'email');
  update public.leads set
    call_facts = coalesce(call_facts, '{}'::jsonb) || jsonb_build_object('our_number', jsonb_build_object(
        'value', jsonb_build_object('number', p_number, 'choices', jsonb_build_array(p_reaction), 'counter', p_counter, 'text', nullif(btrim(coalesce(p_note, '')), '')),
        'at', now(), 'by', who)),
    notes = concat_ws(' | ', notes, to_char(now() at time zone 'America/Chicago', 'YYYY-MM-DD') || ' anchor said by ' || coalesce(who, 'the team')
            || ': around ' || p_number::text || ', they ' || case p_reaction when 'gave_number' then 'said ' || p_counter::text when 'open' then 'stayed open'
               when 'no' then 'said no' else 'said later' end || coalesce(' (' || nullif(btrim(p_note), '') || ')', ''))
   where id = p_lead_id;
  -- their counter is their number: the script's "Their number" fills in, so the package carries it
  if p_reaction = 'gave_number' then
    update public.leads set call_facts = call_facts || jsonb_build_object('price', jsonb_build_object('value', jsonb_build_object('number', p_counter::text),
      'at', now(), 'by', who)) where id = p_lead_id and nullif(call_facts->'price'->'value'->>'number', '') is null;
  end if;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.offer_said(uuid, numeric, text, numeric, text) from public, anon;
grant execute on function public.offer_said(uuid, numeric, text, numeric, text) to authenticated, service_role;

-- Colin's own non-firm number on a package, back on (0114 had closed it): he types it from his desk and the caller
-- reads exactly that on the callback (package_delivered already refuses any other figure).
create or replace function public.package_price(p_id uuid, p_number numeric, p_note text, p_grade text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d public.deal_packages;
begin
  if not public.is_owner() then raise exception 'only Colin sets the number'; end if;
  select * into d from public.deal_packages where id = p_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such package'); end if;
  if d.status not in ('waiting_value', 'waiting_number', 'counter', 'number_ready', 'go_walk') then return jsonb_build_object('ok', false, 'reason', 'this package is ' || d.status); end if;
  if p_number is null or p_number <= 0 then return jsonb_build_object('ok', false, 'reason', 'the number is in dollars'); end if;
  update public.deal_packages set our_number = p_number, number_note = nullif(btrim(coalesce(p_note, '')), ''), grade = coalesce(nullif(p_grade, ''), grade),
         priced_at = now(), status = 'number_ready', ready_pinged_at = null where id = p_id;
  update public.tasks set note = 'Callback: Colin''s number is ready, non-firm (package ' || left(p_id::text, 8) || ')'
   where lead_id = d.lead_id and kind = 'callback' and done_at is null;
  update public.leads set notes = concat_ws(' | ', notes, to_char(now() at time zone 'America/Chicago', 'YYYY-MM-DD') || ' Colin set a non-firm number for the callback')
   where id = d.lead_id;
  return jsonb_build_object('ok', true);
end $$;


-- package_submit: from 0116_package_caller.sql, carries the anchor
create or replace function public.package_submit(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid; login public.team_person := public.wpie_person();
        -- who is on the phone: the shared login is Colin's, so the app sends the person picked on this phone
        -- (a caller with a login of their own is always themself)
        who public.team_person := case
          when p->>'caller' in ('thalia', 'adil', 'colin') and (login is null or login = 'colin') then (p->>'caller')::public.team_person
          else login end; lid uuid := nullif(p->>'lead_id', '')::uuid; cb timestamptz := nullif(p->>'callback_at', '')::timestamptz;
        walk boolean := coalesce((p->>'walk_booked_on_call')::boolean, false); l public.leads;
begin
  if not public.is_team() then raise exception 'only the team sends packages'; end if;
  select * into l from public.leads where id = lid;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card'); end if;
  if coalesce(btrim(p->>'need'), '') = '' and coalesce(p->'condition', '{}'::jsonb) = '{}'::jsonb then
    return jsonb_build_object('ok', false, 'reason', 'a package needs their reason or the condition, in their words');
  end if;
  if cb is null and not walk then return jsonb_build_object('ok', false, 'reason', 'set the callback time you promised (or say the walk is booked)'); end if;
  if exists (select 1 from public.deal_packages d where d.lead_id = lid and d.status in ('waiting_value', 'waiting_number', 'go_walk', 'number_ready', 'counter', 'agreed')) then
    return jsonb_build_object('ok', false, 'reason', 'this card already has an open package');
  end if;
  insert into public.deal_packages (lead_id, interest_id, source, hot, need, condition, timeline, their_number, their_basis, on_title, owed,
         occupancy, photos, other_buyers, concerns, motivation, callback_at, walk_booked_on_call, created_by)
  values (lid, nullif(p->>'interest_id', '')::uuid, coalesce(nullif(p->>'source', ''), public.lead_source_kind(lid)), coalesce((p->>'hot')::boolean, false),
          nullif(btrim(p->>'need'), ''), coalesce(p->'condition', '{}'::jsonb), nullif(btrim(p->>'timeline'), ''), nullif(btrim(p->>'their_number'), ''),
          nullif(btrim(p->>'their_basis'), ''), nullif(btrim(p->>'on_title'), ''), nullif(btrim(p->>'owed'), ''), nullif(btrim(p->>'occupancy'), ''),
          nullif(btrim(p->>'photos'), ''), nullif(btrim(p->>'other_buyers'), ''), nullif(btrim(p->>'concerns'), ''), nullif(btrim(p->>'motivation'), ''),
          cb, walk, who)
  returning id into v_id;
  if cb is not null then
    insert into public.tasks (lead_id, due_at, kind, owner, note)
    values (lid, cb, 'callback', coalesce(who, 'thalia'), 'Callback promised: waiting on Colin (walk it or pass) (package ' || left(v_id::text, 8) || ')');
  end if;
  update public.leads set next_action = case when walk then 'Package with Colin: walk booked on the call' else 'Package with Colin: callback ' || to_char(cb at time zone 'America/Chicago', 'Dy Mon DD HH12:MI AM') end,
         next_action_at = coalesce(cb, next_action_at),
         notes = concat_ws(' | ', notes, to_char(now() at time zone 'America/Chicago', 'YYYY-MM-DD') || ' package sent to Colin by ' || coalesce(who::text, 'the team')
                 || coalesce(': ' || nullif(btrim(p->>'motivation'), ''), ''))
   where id = lid;
  -- the anchor said on the first call (0149) and what they said back, so Colin sees it with the package
  if l.call_facts ? 'our_number' then
    update public.deal_packages set said_number = nullif(l.call_facts->'our_number'->'value'->>'number', '')::numeric,
           number_note = 'non-firm anchor said on the first call, they ' || coalesce(l.call_facts->'our_number'->'value'->'choices'->>0, '?')
             || coalesce(' ' || nullif(l.call_facts->'our_number'->'value'->>'counter', ''), '')
     where id = v_id;
  end if;
  return jsonb_build_object('ok', true, 'package_id', v_id);
end $$;
