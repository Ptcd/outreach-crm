-- 0314: square feet, bedrooms, baths and basement are not needed to make a card; an agent can put them on one later.
--
-- Colin 2026-11-23: "A card can't be built until it has sq ft, beds, baths and basement from an assessor record. make
-- this not a requirement to make a card and ill make a grok bot to research this and inject it card by card later".
-- No code in the app ever required them: the requirement was the agents' own "Stage D gate", written in the Research
-- Board's documents (job 15 and the foreclosure, probate, eviction, money judgment and divorce methods). Those
-- documents are changed by the desk through research_doc_write the same day (versions kept), not here.
--
-- What the code lacked was a way to fill them in afterwards: cards_missing_facts listed the cards and said "the door
-- has no tool that writes them", and property_values is keyed on the laptop's parcel id, which an agent-made card often
-- does not have. card_facts holds what an agent read for a card, field by field with where and when; card_facts_set
-- writes it. The county assessor's record (property_values, pushed by the laptop) is never written over: a field the
-- assessor has is kept and the agent is told so. cards_missing_facts now counts both.

create table if not exists public.card_facts (
  lead_id uuid primary key references public.leads(id) on delete cascade,
  building_sqft integer,
  bedrooms integer,
  baths_full integer,
  baths_half integer,
  basement text,
  year_built integer,
  sources jsonb not null default '{}'::jsonb,     -- field -> {source, date, by, at}
  updated_by text,
  updated_at timestamptz not null default now()
);
alter table public.card_facts enable row level security;
revoke all on public.card_facts from anon, authenticated;
grant select, insert, update on public.card_facts to service_role;
comment on table public.card_facts is 'House facts an agent read for a card (0314); the assessor record in property_values wins where it has one.';

create or replace function public.agent_card_facts_set(p jsonb, p_agent text) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare
  lid uuid; l public.leads; pv public.property_values; src text := btrim(coalesce(p->>'source', '')); d text := nullif(btrim(coalesce(p->>'date', '')), '');
  f text; v text; n numeric; wrote text[] := '{}'; kept text[] := '{}'; bad text[] := '{}'; srcs jsonb := '{}'::jsonb;
  vals jsonb := '{}'::jsonb;
  fields text[] := array['sqft', 'beds', 'baths_full', 'baths_half', 'basement', 'year_built'];
begin
  begin lid := nullif(btrim(coalesce(p->>'lead_id', '')), '')::uuid; exception when others then lid := null; end;
  if lid is null then return jsonb_build_object('ok', false, 'reason', 'lead_id: the card'); end if;
  select * into l from public.leads where id = lid;
  if l.id is null then return jsonb_build_object('ok', false, 'reason', 'no such card'); end if;
  if length(src) < 4 then
    return jsonb_build_object('ok', false, 'reason', 'source: where you read it (the county assessor record, a listing site, the seller), so a caller can trust it');
  end if;
  if d is not null and d !~ '^\d{4}-\d{2}-\d{2}$' then return jsonb_build_object('ok', false, 'reason', 'date: YYYY-MM-DD, the day the source showed it'); end if;
  if not (p ?| fields) then return jsonb_build_object('ok', false, 'reason', 'send at least one of: ' || array_to_string(fields, ', ')); end if;
  select * into pv from public.property_values where wpie_property_id = l.wpie_property_id;

  foreach f in array fields loop
    continue when not (p ? f) or jsonb_typeof(p->f) = 'null';
    v := btrim(p->>f);
    if f = 'basement' then
      if v = '' or length(v) > 60 then bad := bad || 'basement (a short statement: full, partial, none, crawl space, slab, finished)'; continue; end if;
      if pv.basement is not null then kept := kept || 'basement'; continue; end if;
      vals := vals || jsonb_build_object('basement', v);
    else
      begin n := v::numeric; exception when others then n := null; end;
      if n is null or n <> trunc(n)
         or (f = 'sqft' and not n between 300 and 15000) or (f = 'beds' and not n between 0 and 15)
         or (f = 'baths_full' and not n between 0 and 10) or (f = 'baths_half' and not n between 0 and 6)
         or (f = 'year_built' and not n between 1800 and extract(year from now()) + 1) then
        bad := bad || f; continue;
      end if;
      if (f = 'sqft' and pv.building_sqft is not null) or (f = 'beds' and pv.bedrooms is not null) or (f = 'baths_full' and pv.baths_full is not null)
         or (f = 'baths_half' and pv.baths_half is not null) or (f = 'year_built' and pv.year_built is not null) then
        kept := kept || f; continue;
      end if;
      vals := vals || jsonb_build_object(f, n::int);
    end if;
    wrote := wrote || f;
    srcs := srcs || jsonb_build_object(f, jsonb_build_object('source', left(src, 200), 'date', d, 'by', p_agent, 'at', now()));
  end loop;
  if cardinality(bad) > 0 then
    return jsonb_build_object('ok', false, 'reason', 'not a believable value, nothing written: ' || array_to_string(bad, ', ')
      || ' (whole numbers; sqft 300-15000, beds 0-15, baths_full 0-10, baths_half 0-6, year_built 1800-now)');
  end if;
  if cardinality(wrote) > 0 then
    insert into public.card_facts (lead_id, building_sqft, bedrooms, baths_full, baths_half, basement, year_built, sources, updated_by, updated_at)
    values (lid, (vals->>'sqft')::int, (vals->>'beds')::int, (vals->>'baths_full')::int, (vals->>'baths_half')::int, vals->>'basement',
            (vals->>'year_built')::int, srcs, p_agent, now())
    on conflict (lead_id) do update set
      building_sqft = coalesce((vals->>'sqft')::int, card_facts.building_sqft), bedrooms = coalesce((vals->>'beds')::int, card_facts.bedrooms),
      baths_full = coalesce((vals->>'baths_full')::int, card_facts.baths_full), baths_half = coalesce((vals->>'baths_half')::int, card_facts.baths_half),
      basement = coalesce(vals->>'basement', card_facts.basement), year_built = coalesce((vals->>'year_built')::int, card_facts.year_built),
      sources = card_facts.sources || srcs, updated_by = p_agent, updated_at = now();
  end if;
  return jsonb_build_object('ok', true, 'lead_id', lid, 'written', to_jsonb(wrote), 'kept_assessor', to_jsonb(kept),
    'note', case when cardinality(kept) > 0 then 'the county assessor record already has ' || array_to_string(kept, ', ') || '; it stays' else '' end);
end $fn$;
revoke all on function public.agent_card_facts_set(jsonb, text) from public, anon, authenticated;
grant execute on function public.agent_card_facts_set(jsonb, text) to service_role;

-- cards_missing_facts (0308) counts what an agent read too
create or replace function public.agent_cards_missing_facts(p jsonb, p_agent text)
 returns jsonb language sql stable security definer set search_path to 'public'
as $function$
  with want as (
    select coalesce((select array_agg(lower(x)) from jsonb_array_elements_text(case when jsonb_typeof(p->'missing') = 'array' then p->'missing' else '[]'::jsonb end) x),
                    array['sqft', 'beds', 'baths', 'basement']) w,
           least(greatest(coalesce(nullif(p->>'limit', '')::integer, 100), 1), 500) lim,
           nullif(p->>'after', '')::timestamptz after_,
           nullif(initcap(btrim(coalesce(p->>'county', ''))), '') co),
  c as (
    select l.id, l.property_address, l.municipality, l.county, l.property_zip, l.parcel_id, l.wpie_property_id, l.stage, l.belt, l.created_at, l.property_type,
           array_remove(array[case when v.building_sqft is null then 'sqft' end, case when v.bedrooms is null then 'beds' end,
                              case when v.baths_full is null then 'baths' end, case when v.basement is null then 'basement' end], null) miss,
           v.year_built, v.as_of
      from public.leads l
      left join lateral (
        -- 0314: the county assessor's record (the laptop) first, then what an agent read onto the card (card_facts)
        select coalesce(pv.building_sqft, cf.building_sqft) building_sqft, coalesce(pv.bedrooms, cf.bedrooms) bedrooms,
               coalesce(pv.baths_full, cf.baths_full) baths_full, coalesce(pv.basement, cf.basement) basement,
               coalesce(pv.year_built, cf.year_built) year_built, coalesce(pv.as_of, cf.updated_at::date) as_of
          from (select 1) one
          left join public.property_values pv on pv.wpie_property_id = l.wpie_property_id
          left join public.card_facts cf on cf.lead_id = l.id) v on true
     where l.stage not in ('dead', 'dnc') and coalesce(btrim(l.property_address), '') <> '')
  select jsonb_build_object(
    'counts', (select jsonb_build_object('cards', count(*), 'no_sqft', count(*) filter (where 'sqft' = any(miss)), 'no_beds', count(*) filter (where 'beds' = any(miss)),
                        'no_baths', count(*) filter (where 'baths' = any(miss)), 'no_basement', count(*) filter (where 'basement' = any(miss)),
                        'no_laptop_record', count(*) filter (where wpie_property_id is null)) from c),
    'cards', coalesce((select jsonb_agg(jsonb_build_object('lead_id', x.id, 'address', x.property_address, 'municipality', x.municipality, 'county', x.county,
                         'zip', x.property_zip, 'parcel', x.parcel_id, 'missing', to_jsonb(x.miss), 'has_laptop_record', x.wpie_property_id is not null,
                         'stage', x.stage, 'created_at', x.created_at) order by x.said_yes desc, x.created_at)
                 from (select c.*, (c.belt in ('yes_unbooked', 'call_booked', 'visit_booked', 'offer_out')) said_yes from c, want
                        where c.miss && want.w and (want.after_ is null or c.created_at > want.after_) and (want.co is null or c.county = want.co)
                        order by (c.belt in ('yes_unbooked', 'call_booked', 'visit_booked', 'offer_out')) desc, c.created_at limit (select lim from want)) x), '[]'::jsonb),
    'how_it_works', 'Square feet, bedrooms, baths and basement come from the county assessor''s record (read by the laptop for the card''s parcel) or from card_facts_set (what an agent read, with where). None of them is needed to make a card (Colin 2026-11-23); this list is the work of filling them in, card by card. A card with has_laptop_record false has no parcel tied: put a "Parcel: ..." line in its notes and the laptop ties it within the hour. Cards a seller said yes on come first; page with after = the last created_at.')
$function$;
