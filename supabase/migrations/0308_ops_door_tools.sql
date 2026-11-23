-- 0308: what the Pipe Keeper asked the desk for on 2026-11-23 (relayed by Colin; room 246, 248).
--  * card_fix: an agent corrects a card's owner type and owner name (28 cards owned by churches, lodges and companies
--    were typed as people; "Boca" for "Baca"). Parking a card is mark_card held, as before.
--  * court_rows_status rows carry the whole row and the card the case's house is on.
--  * court_row_parcel: the parcel for a row the laptop left ambiguous. The laptop honours it only when that parcel
--    is one of those it found under the name or at the address (wpie.collectors.wi_court_cases.chosen_hit).
--  * court_row_to_card: a matched case on a card that is the same house, as a reason and a note. The laptop's nightly
--    scoring does this for its own cards; an agent-made card never got it, and case numbers were going on as notes.
--  * cards_missing_facts: cards with no square feet, bedrooms, baths or basement on record.
-- Re-queueing needed no change: a deposit of a row that is not matched has always corrected it and put it back in line.

CREATE OR REPLACE FUNCTION public.agent_court_rows_status(p jsonb, p_agent text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  kind_ text := nullif(lower(btrim(coalesce(p->>'kind', ''))), ''); st text := nullif(lower(btrim(coalesce(p->>'state', ''))), '');
  co text := nullif(initcap(btrim(coalesce(p->>'county', ''))), ''); lim integer := least(greatest(coalesce(nullif(p->>'limit', '')::integer, 100), 1), 500);
  after_ timestamptz := nullif(p->>'after', '')::timestamptz;
begin
  return jsonb_build_object(
    'by_kind', coalesce((select jsonb_object_agg(k, c) from (
        select r.kind k, jsonb_build_object('rows', count(*), 'waiting', count(*) filter (where r.state = 'waiting'), 'matched', count(*) filter (where r.state = 'matched'),
                 'unmatched', count(*) filter (where r.state = 'unmatched'), 'ambiguous', count(*) filter (where r.state = 'ambiguous'),
                 'skipped', count(*) filter (where r.state = 'skipped'), 'properties_matched', count(distinct r.parcel_id) filter (where r.state = 'matched'),
                 'last_deposit', max(r.deposited_at), 'last_result', max(r.result_at)) c
          from public.court_rows r where (kind_ is null or r.kind = kind_) and (co is null or r.county = co) group by r.kind) z), '{}'::jsonb),
    'why_not_matched', coalesce((select jsonb_object_agg(w, n) from (
        select left(coalesce(r.result_note, 'no note'), 110) w, count(*) n from public.court_rows r
         where r.state in ('unmatched', 'ambiguous', 'skipped') and (kind_ is null or r.kind = kind_) and (co is null or r.county = co)
         group by 1 order by 2 desc limit 15) z), '{}'::jsonb),
    'by_county', coalesce((select jsonb_object_agg(c, j) from (
        select r.county c, jsonb_build_object('rows', count(*), 'waiting', count(*) filter (where r.state = 'waiting'), 'matched', count(*) filter (where r.state = 'matched')) j
          from public.court_rows r where (kind_ is null or r.kind = kind_) group by r.county) z), '{}'::jsonb),
    'rows', case when coalesce((p->>'rows')::boolean, false) then coalesce((
        select jsonb_agg(jsonb_build_object('kind', r.kind, 'county', r.county, 'case_number', r.case_number, 'state', r.state, 'note', r.result_note,
                 'parcel_id', r.parcel_id, 'owner_of_record', r.matched_owner, 'address', r.address, 'result_at', r.result_at, 'updated_at', r.updated_at)
                 -- 0308: the whole row, so a row the laptop could not tie can be checked and corrected
                 || jsonb_strip_nulls(jsonb_build_object('defendant', r.defendant, 'plaintiff', r.plaintiff, 'caption', r.caption, 'city', r.city, 'zip', r.zip,
                      'filed', r.filed, 'class_code', r.class_code, 'amount', r.amount, 'status', r.status_text, 'deposited_by', r.deposited_by,
                      'chosen_parcel', r.extra->>'chosen_parcel', 'on_card', (select l.id from public.leads l where l.wpie_property_id = r.wpie_property_id limit 1)))
                 order by r.updated_at)
          from (select * from public.court_rows q where (kind_ is null or q.kind = kind_) and (st is null or q.state = st) and (co is null or q.county = co)
                   and (after_ is null or q.updated_at > after_) order by q.updated_at limit lim) r), '[]'::jsonb) end,
    'how_it_works', 'Deposit with court_rows_deposit. Each night the laptop ties waiting rows to a parcel (an eviction by the property address, a money judgment by the debtor''s name inside the county) and writes matched, unmatched or ambiguous on the row. A matched row is a record on the property: it reaches a card through the ordinary pipeline, stacked with whatever else is on that property. You never load these rows as cards. To fix a row the laptop could not tie (unmatched, ambiguous, skipped): deposit it again with the corrected fields (same kind, county and case number) and it goes back in line; a matched row is settled. To settle an ambiguous row, name the parcel with court_row_parcel. To put a matched case on a card that is the same house, court_row_to_card.');
end $function$;

alter table public.leads add column if not exists owner_fixed jsonb;
comment on column public.leads.owner_fixed is 'An owner type or name corrected through the door (card_fix, 0308): {owner_type, owner_name, by, at}. The laptop''s push cannot write over it.';

create or replace function public.leads_keep_owner_fix() returns trigger language plpgsql as $function$
begin
  if new.owner_fixed is not null then
    new.owner_type := coalesce(new.owner_fixed->>'owner_type', new.owner_type);
    new.owner_name := coalesce(new.owner_fixed->>'owner_name', new.owner_name);
  end if;
  return new;
end $function$;
drop trigger if exists leads_keep_owner_fix on public.leads;
create trigger leads_keep_owner_fix before update of owner_name, owner_type, owner_fixed on public.leads
  for each row execute function public.leads_keep_owner_fix();

create or replace function public.agent_card_fix(p jsonb, p_agent text)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare
  l     public.leads;
  who   text := coalesce(nullif(btrim(p_agent), ''), 'agent');
  t     text := nullif(lower(btrim(coalesce(p->>'owner_type', ''))), '');
  n     text := nullif(btrim(regexp_replace(coalesce(p->>'owner_name', ''), '\s+', ' ', 'g')), '');
  why   text := nullif(btrim(coalesce(p->>'reason', '')), '');
  types text[] := array['individual', 'couple', 'trust', 'llc', 'corporation', 'partnership', 'estate', 'nonprofit', 'government', 'bank_lender', 'other'];
  kind_ text;
  said  text[] := '{}';
  pe    record;
begin
  if coalesce(p->>'lead_id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return jsonb_build_object('ok', false, 'reason', 'lead_id is a card id (find_prospects gives it)');
  end if;
  if t is null and n is null then return jsonb_build_object('ok', false, 'reason', 'give owner_type, owner_name or both'); end if;
  if why is null then return jsonb_build_object('ok', false, 'reason', 'say in reason where you read the right value (the county record, the state business record)'); end if;
  if t is not null and t <> all(types) then
    return jsonb_build_object('ok', false, 'reason', 'owner_type is one of ' || array_to_string(types, ', ') || ' (a church or a lodge is nonprofit)');
  end if;
  if n is not null and (length(n) < 2 or length(n) > 120) then return jsonb_build_object('ok', false, 'reason', 'owner_name is 2 to 120 characters'); end if;
  select * into l from public.leads where id = (p->>'lead_id')::uuid for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card'); end if;
  -- a card a seller signed is Colin's (0255): nothing on it changes from the door
  if l.locked_to::text = 'colin' then return jsonb_build_object('ok', false, 'reason', 'this card is Colin''s: post the correction on the desk'); end if;
  if t is not null and t is distinct from l.owner_type then
    said := said || ('owner type ' || coalesce(l.owner_type, 'none') || ' -> ' || t);
    kind_ := case when t = 'individual' then 'person' when t = 'couple' then 'household' else 'entity' end;
    for pe in select pp.id, pp.name from public.interests i join public.people pp on pp.id = i.person_id
               where i.lead_id = l.id and i.role = 'owner_of_record' and pp.kind is distinct from kind_ loop
      update public.people set kind = kind_, name_key = public.person_key(pe.name, kind_), updated_at = now() where id = pe.id;
    end loop;
    update public.leads set owner_type = t, updated_at = now() where id = l.id;
  end if;
  if n is not null and n is distinct from l.owner_name then
    said := said || ('owner name ' || coalesce(l.owner_name, 'none') || ' -> ' || n);
    -- the person on the card who carries the old name carries the new one
    for pe in select pp.id, pp.kind from public.interests i join public.people pp on pp.id = i.person_id
               where i.lead_id = l.id and i.role = 'owner_of_record'
                 and pp.name_key = public.person_key(l.owner_name, pp.kind) loop
      update public.people set name = n, name_key = public.person_key(n, pe.kind), updated_at = now() where id = pe.id;
    end loop;
    update public.contacts set person_name = n, updated_at = now()
     where lead_id = l.id and lower(btrim(coalesce(person_name, ''))) = lower(btrim(coalesce(l.owner_name, '')));
    update public.leads set owner_name = n, updated_at = now() where id = l.id;
  end if;
  if cardinality(said) = 0 then return jsonb_build_object('ok', true, 'changed', '[]'::jsonb, 'note', 'the card already says that'); end if;
  -- the fix is kept on the card: the laptop's push writes the county's owner name and type on every pass, and
  -- leads_keep_owner_fix puts the corrected ones back
  update public.leads set notes_log = concat_ws(' | ', nullif(notes_log, ''), who || ' (fix): ' || array_to_string(said, '; ') || '. ' || left(why, 300)),
         owner_fixed = coalesce(owner_fixed, '{}'::jsonb) || jsonb_strip_nulls(jsonb_build_object(
           'owner_type', case when t is not null and t is distinct from l.owner_type then t end,
           'owner_name', case when n is not null and n is distinct from l.owner_name then n end, 'by', who, 'at', now()))
   where id = l.id;
  return jsonb_build_object('ok', true, 'lead_id', l.id, 'changed', to_jsonb(said),
    'next', 'To park a card, mark_card held (with a date) or dead. A registered agent goes on with add_prospects as a person with role other and a note saying registered agent: an agent of record is not the decision maker.');
end $function$;

create or replace function public.agent_court_row_parcel(p jsonb, p_agent text)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare
  who   text := coalesce(nullif(btrim(p_agent), ''), 'agent');
  kind_ text := lower(btrim(coalesce(p->>'kind', '')));
  cn    text := upper(regexp_replace(coalesce(p->>'case_number', ''), '[^0-9A-Za-z]', '', 'g'));
  co    text := replace(initcap(btrim(regexp_replace(coalesce(p->>'county', ''), '\s+county$', '', 'i'))), ' Du ', ' du ');
  par   text := nullif(left(btrim(coalesce(p->>'parcel_id', p->>'parcel', '')), 80), '');
  why   text := nullif(btrim(coalesce(p->>'why', p->>'reason', '')), '');
  r     public.court_rows;
begin
  if par is null then return jsonb_build_object('ok', false, 'reason', 'parcel_id is the parcel you are naming'); end if;
  if why is null then return jsonb_build_object('ok', false, 'reason', 'say in why what on the court record settles it (the unit, the address on the filing)'); end if;
  select * into r from public.court_rows where kind = kind_ and county = co and case_number = cn for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such row: kind, county and case_number as you deposited them'); end if;
  if r.state = 'matched' then return jsonb_build_object('ok', false, 'reason', 'that row is tied already (parcel ' || coalesce(r.parcel_id, '?') || '): a tied row is settled'); end if;
  if r.state = 'waiting' then return jsonb_build_object('ok', false, 'reason', 'that row has not been judged yet: wait for the laptop''s pass'); end if;
  if r.state = 'skipped' then return jsonb_build_object('ok', false, 'reason', 'that row was skipped (' || coalesce(r.result_note, 'no note') || '): correct it with court_rows_deposit'); end if;
  update public.court_rows
     set extra = extra || jsonb_build_object('chosen_parcel', par, 'chosen_by', who, 'chosen_why', left(why, 200), 'chosen_at', now()),
         state = 'waiting', result_note = null, result_at = null, pulled_at = null, updated_at = now()
   where id = r.id;
  return jsonb_build_object('ok', true, 'state', 'waiting',
    'next', 'The laptop takes it on its next pass (ten minutes by day). The pick stands only when that parcel is one of those it found under that name, or at that address: then the row comes back matched. Otherwise it comes back as it was, and the fix is a corrected row (court_rows_deposit).');
end $function$;

create or replace function public.agent_court_row_to_card(p jsonb, p_agent text)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare
  who   text := coalesce(nullif(btrim(p_agent), ''), 'agent');
  kind_ text := lower(btrim(coalesce(p->>'kind', '')));
  cn    text := upper(regexp_replace(coalesce(p->>'case_number', ''), '[^0-9A-Za-z]', '', 'g'));
  co    text := replace(initcap(btrim(regexp_replace(coalesce(p->>'county', ''), '\s+county$', '', 'i'))), ' Du ', ' du ');
  r     public.court_rows;
  l     public.leads;
  why   text;
  line  text;
  same  boolean;
begin
  if coalesce(p->>'lead_id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return jsonb_build_object('ok', false, 'reason', 'lead_id is a card id (find_prospects gives it)');
  end if;
  why := case kind_ when 'foreclosure' then 'pre-foreclosure' when 'probate' then 'probate filed' when 'will' then 'probate filed'
                    when 'tax_warrant' then 'court debt (tax warrant / judgment)' when 'money_judgment' then 'court debt (tax warrant / judgment)'
                    when 'eviction' then 'landlord filed an eviction' when 'divorce' then 'divorce filed (never bring it up)' end;
  if why is null then
    return jsonb_build_object('ok', false, 'reason', 'kind is foreclosure, probate, will, tax_warrant, money_judgment, eviction or divorce (the banked-only kinds have no rule yet)');
  end if;
  select * into r from public.court_rows where kind = kind_ and county = co and case_number = cn;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such row: deposit it first with court_rows_deposit'); end if;
  if r.state <> 'matched' or (r.wpie_property_id is null and coalesce(r.parcel_id, '') = '') then
    return jsonb_build_object('ok', false, 'reason', 'the laptop has not tied that case to a house (state ' || r.state || '): a case goes on a card only once it is tied');
  end if;
  select * into l from public.leads where id = (p->>'lead_id')::uuid for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card'); end if;
  if l.locked_to::text = 'colin' then return jsonb_build_object('ok', false, 'reason', 'this card is Colin''s: post it on the desk'); end if;
  -- the same house: the laptop's property id, else the parcel inside the county (never the address)
  same := (l.wpie_property_id is not null and l.wpie_property_id = r.wpie_property_id)
       or (coalesce(l.parcel_id, '') <> '' and coalesce(r.parcel_id, '') <> ''
           and regexp_replace(upper(l.parcel_id), '[^0-9A-Z]', '', 'g') = regexp_replace(upper(r.parcel_id), '[^0-9A-Z]', '', 'g')
           and (coalesce(l.county, '') = '' or lower(btrim(l.county)) = lower(r.county)));
  if not same then
    return jsonb_build_object('ok', false, 'reason', 'that card is not the house this case is tied to (the case: parcel ' || coalesce(r.parcel_id, '?')
      || ', ' || r.county || '; the card: parcel ' || coalesce(nullif(l.parcel_id, ''), 'none on it') || '). A card with no parcel gets one from a "Parcel: ..." line in its notes.');
  end if;
  line := 'Court: ' || r.county || ' ' || r.case_number || ', ' || replace(kind_, '_', ' ') || coalesce(' filed ' || to_char(r.filed, 'YYYY-MM-DD'), '')
          || coalesce(', ' || nullif(btrim(r.status_text), ''), '') || ' (tied by the laptop: ' || coalesce(r.result_note, 'parcel ' || r.parcel_id) || ')';
  if position(r.case_number in coalesce(l.notes, '')) > 0 and why = any(coalesce(l.reasons_to_sell, '{}')) then
    return jsonb_build_object('ok', true, 'lead_id', l.id, 'already', true, 'note', 'that case and its reason are on the card already');
  end if;
  update public.leads
     set reasons_to_sell = coalesce((select array_agg(distinct x) from unnest(coalesce(reasons_to_sell, '{}') || array[why]) x), '{}'::text[]),
         stacked_at = case when why = any(coalesce(reasons_to_sell, '{}')) then stacked_at else now() end,
         notes = case when position(r.case_number in coalesce(notes, '')) > 0 then notes else concat_ws(' | ', notes, who || ': ' || line) end,
         updated_at = now()
   where id = l.id;
  return jsonb_build_object('ok', true, 'lead_id', l.id, 'reason_added', why, 'note', line);
end $function$;

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
      from public.leads l left join public.property_values v on v.wpie_property_id = l.wpie_property_id
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
    'how_it_works', 'Square feet, bedrooms, baths and basement come from the county assessor''s record, read by the laptop for the card''s parcel (the door has no tool that writes them). A card with has_laptop_record false has no parcel tied: put a "Parcel: ..." line in its notes and the laptop ties it within the hour. Cards a seller said yes on come first; page with after = the last created_at.')
$function$;

revoke all on function public.agent_card_fix(jsonb, text), public.agent_court_row_parcel(jsonb, text), public.agent_court_row_to_card(jsonb, text),
  public.agent_cards_missing_facts(jsonb, text) from public, anon, authenticated;
grant execute on function public.agent_card_fix(jsonb, text), public.agent_court_row_parcel(jsonb, text), public.agent_court_row_to_card(jsonb, text),
  public.agent_cards_missing_facts(jsonb, text) to service_role;
