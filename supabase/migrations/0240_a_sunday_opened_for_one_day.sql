-- 0240: a Sunday is opened one day at a time.
--
-- Colin 2026-11-15, a Sunday: "Tyler is working and say we turn the switch off" ... "Yes start sending". No texts on
-- Sunday is our own rule (campaign_control.no_sundays); Wisconsin allows texts 8 AM to 9 PM every day. Until now the
-- only way to text on a Sunday was to turn the rule off by hand and remember to turn it back on.
--
--   sunday_open(day, by, why)  opens that one Sunday. campaign_control.sunday_open_day holds it.
--   text_day_tick              keeps no_sundays in step with it: off on the Sunday that was opened, on every other
--                              day, so the rule closes itself by the first tick of Monday and the next Sunday is shut
--                              unless it is opened too. Everything that reads no_sundays (the list, the queue door,
--                              the sender) is unchanged.
--   card_record_block          on a Sunday, a card with a number in a state that bars or limits Sunday texts
--                              (Louisiana, Mississippi, Pennsylvania, Rhode Island, South Dakota, Utah; Texas, which
--                              allows them only from noon, is held the whole day) is 'state_bars_sunday': not listed,
--                              not queued, and it goes on Monday. The states are the laptop's (wpie/compliance).
--   A caller who is off on Sundays (caller_off_weekly) still gets no texts on their cards: nothing here changes that.

alter table public.campaign_control add column if not exists sunday_open_day date;
alter table public.campaign_control add column if not exists sunday_open_by text;
alter table public.campaign_control add column if not exists sunday_open_why text;

create or replace function public.sunday_closed_area_codes() returns text[]
language sql immutable as $$
  select array[
    -- LA
    '225', '318', '337', '504', '985',
    -- MS
    '228', '601', '662', '769',
    -- PA
    '215', '223', '267', '272', '412', '445', '484', '570', '582', '610', '717', '724', '814', '835', '878',
    -- RI
    '401',
    -- SD
    '605',
    -- TX (Sunday from noon only: held the whole day)
    '210', '214', '254', '281', '325', '346', '361', '409', '430', '432', '469', '512', '682', '713', '726', '737', '806',
    '817', '830', '832', '903', '915', '936', '940', '945', '956', '972', '979',
    -- UT
    '385', '435', '801']
$$;

create or replace function public.sunday_open(p_day date, p_by text, p_why text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare today date := (now() at time zone 'America/Chicago')::date;
begin
  if p_day is null or extract(isodow from p_day) <> 7 then raise exception 'sunday_open: % is not a Sunday', p_day; end if;
  if p_day < today then raise exception 'sunday_open: % is past', p_day; end if;
  if coalesce(trim(p_by), '') = '' then raise exception 'sunday_open: say who opened it'; end if;
  update public.campaign_control
     set sunday_open_day = p_day, sunday_open_by = p_by, sunday_open_why = p_why,
         no_sundays = case when p_day = today then false else no_sundays end
   where id = 1;
  return jsonb_build_object('opened', p_day, 'by', p_by, 'texts_today', p_day = today);
end $$;
revoke all on function public.sunday_open(date, text, text) from public, anon, authenticated;

create or replace function public.sunday_close(p_by text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  update public.campaign_control set sunday_open_day = null, sunday_open_by = p_by, sunday_open_why = null, no_sundays = true where id = 1;
  return jsonb_build_object('closed', true, 'by', p_by);
end $$;
revoke all on function public.sunday_close(text) from public, anon, authenticated;

CREATE OR REPLACE FUNCTION public.card_record_block(p_lead_id uuid, p_day date)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case
    when not coalesce((select cc.day_rules_on from public.campaign_control cc where cc.id = 1), true) then null
    -- the card's caller is off that day (0237): nobody is there for the reply
    when public.caller_is_off(l.locked_to, p_day) then 'caller_off_today'
    -- a Sunday that was opened (0240): a number in a state that bars or limits Sunday texts waits for Monday
    when extract(isodow from p_day) = 7
         and exists (select 1 from public.contacts c where c.lead_id = l.id and c.kind = 'phone' and c.status = 'ok'
                      and left(c.value_normalized, 3) = any (public.sunday_closed_area_codes())) then 'state_bars_sunday'
    when l.wpie_owner_id > 0 and f.wpie_owner_id is null then 'no_record_verdict'
    when l.wpie_owner_id > 0 and f.as_of < p_day - 7 then 'record_verdict_stale'
    when l.wpie_owner_id > 0 and f.verdict <> 'ok'
         and not (f.verdict = 'probate_floor_30d' and f.not_before is not null and f.not_before <= p_day) then f.verdict
    -- any card's sale date, the agents' cards too (0233)
    when (select s.sale_date from public.card_sale_dates s where s.lead_id = l.id) < p_day + 14 then 'sheriff_sale_inside_14d'
    when not (coalesce(f.need, false) or coalesce(m.tax_years, 0) >= 2
              or coalesce(m.family_list, '') ~ '(estate|foreclosure|condition|legal_money)'
              or array_to_string(l.reasons_to_sell, ', ') ~* 'foreclos|sheriff|estate|inherit|probate|court debt|judgment|tax warrant|code|nuisance|vacan|raze|condemn')
      then 'want_not_need'
    when coalesce(f.equity, e.equity_grade) = 'thin' then 'equity_thin'
    when coalesce(f.equity, e.equity_grade) = 'underwater' then 'equity_underwater'
  end
  from public.leads l
  left join public.text_fitness f on f.wpie_owner_id = l.wpie_owner_id and l.wpie_owner_id > 0
  left join public.lead_motivation m on m.lead_id = l.id
  left join public.equity_inputs e on e.lead_id = l.id
  where l.id = p_lead_id
$function$;

CREATE OR REPLACE FUNCTION public.text_day_tick(p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c    public.campaign_control;
  d    date := (p_now at time zone 'America/Chicago')::date;
  t    time := (p_now at time zone 'America/Chicago')::time;
  out  jsonb := '{}'::jsonb;
  r    jsonb;
  low  boolean;
  txt  text;
begin
  select * into c from public.campaign_control where id = 1;
  -- a Sunday is opened one day at a time (0240): the rule is off on the Sunday that was opened and on every other day
  if coalesce(c.no_sundays, true) is distinct from (c.sunday_open_day is distinct from d) then
    update public.campaign_control set no_sundays = (sunday_open_day is distinct from d) where id = 1;
    select * into c from public.campaign_control where id = 1;
  end if;
  if coalesce(c.no_sundays, true) and extract(isodow from d) = 7 then return jsonb_build_object('day', d, 'why', 'Sunday'); end if;
  if t >= time '07:00' and t < time '18:30'
     and (c.day_last_build_at is null or (c.day_last_build_at at time zone 'America/Chicago')::date < d or c.day_last_build_at < p_now - interval '55 minutes') then
    out := out || jsonb_build_object('build', public.text_day_build(p_now));
  end if;
  -- the noon check is for a day people write; a day the server drips is half unwritten at noon by design (0236)
  if t >= time '12:00' and t < time '18:30' and c.day_noon_checked is distinct from d and not coalesce(c.day_backstop, false) then
    r := public.text_day_report(p_now);
    update public.campaign_control set day_noon_checked = d where id = 1;
    if (r ->> 'listed')::int >= 20 and (r ->> 'not_written')::int * 2 > (r ->> 'listed')::int then
      perform public.desk_post('desk', 'all', 'note', 'The day ' || d || ': at noon ' || (r ->> 'not_written') || ' of ' || (r ->> 'listed') || ' texts are not written',
        'The day''s list (text_day) has ' || (r ->> 'listed') || ' texts on it and ' || (r ->> 'not_written') || ' have not been written and queued yet. '
        || 'The list is in ready_to_text, need first. ' || case when coalesce(c.day_backstop, false) then 'The backstop is on and will write the rest in the settled wording.'
           else 'The backstop is off, so nothing goes out for those rows unless they are queued.' end);
      out := out || jsonb_build_object('noon', 'posted');
    end if;
  end if;
  if coalesce(c.day_backstop, false) and t >= c.day_backstop_after and t < time '18:30' then
    out := out || jsonb_build_object('backstop', public.text_day_backstop(p_now));
  end if;
  if t >= time '19:15' and c.day_reported is distinct from d then
    r := public.text_day_report(p_now);
    update public.campaign_control set day_reported = d where id = 1;
    insert into public.text_day_runs (day, at, kind, summary) values (d, p_now, 'report', r);
    low := (r ->> 'days_of_new_people')::numeric < 5;
    txt := 'Listed ' || (r ->> 'listed') || ' (cap ' || coalesce(r ->> 'cap', '?') || ', floor of new people ' || (r ->> 'floor') || '); not written ' || (r ->> 'not_written')
        || '; off the list ' || (r ->> 'off_list_today') || E'.\nBy kind: ' || (r -> 'by_kind')::text
        || E'\nReplies today ' || (r ->> 'replies_today') || ', STOPs ' || (r ->> 'stops_today') || ', hot ' || (r ->> 'hot_today')
        || E'.\nNew people still ready: ' || (r ->> 'first_ready') || ' by tier ' || (r -> 'first_ready_by_tier')::text || ', about ' || (r ->> 'days_of_new_people') || ' days at the floor.'
        || E'\nFollow-ups ready by step: ' || (r -> 'followups_ready_by_step')::text || '; next numbers ' || (r ->> 'next_numbers_ready')
        || E'.\nWhy the rest of the first-text store is not ready: ' || (r -> 'first_blocked')::text
        || E'\nFollow-ups held back: ' || (r -> 'followups_blocked')::text
        || E'\nRecord verdicts as of ' || coalesce(r ->> 'verdicts_as_of', 'never') || '.';
    perform public.desk_post('desk', 'all', 'report',
      'The day ' || d || case when low then ': NEW PEOPLE RUN OUT IN ' || (r ->> 'days_of_new_people') || ' DAYS' else ': report' end, left(txt, 11000));
    out := out || jsonb_build_object('report', 'posted', 'low_supply', low);
  end if;
  return out;
end $function$;
