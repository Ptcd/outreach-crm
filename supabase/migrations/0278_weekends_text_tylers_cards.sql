-- 0278: Saturdays and Sundays text only Tyler's cards. Colin 2026-11-22: "make Saturday and Sunday only text Tyler's
-- cards". Until now that held only because Thalia is marked off every weekend (caller_off_weekly, 0238); a card of
-- Colin's, a card with no caller, or a change to Thalia's days off would have let other cards through. Now it is a
-- rule of its own, in the one check every text passes (card_record_block: the day's pool, the list, the queue door
-- and the send check): on a Saturday or a Sunday a card whose caller (card_caller) is not the weekend caller is
-- 'weekend_other_caller'. The weekend caller is campaign_control.weekend_text_caller, 'adil' (Tyler); null turns the
-- rule off. A thread that began in another name on one of Tyler's cards is still Tyler's card and goes.

alter table public.campaign_control add column if not exists weekend_text_caller public.team_person default 'adil';
update public.campaign_control set weekend_text_caller = 'adil' where id = 1;

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
    -- 0278: on a Saturday or a Sunday only the weekend caller's cards are texted (Colin 2026-11-22)
    when extract(isodow from p_day) in (6, 7)
         and (select cc.weekend_text_caller from public.campaign_control cc where cc.id = 1) is not null
         and public.card_caller(l.id) is distinct from (select cc.weekend_text_caller from public.campaign_control cc where cc.id = 1)
      then 'weekend_other_caller'
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
