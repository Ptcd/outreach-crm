-- 0312: the cards only a call can reach go on the call lists, and a wrong number is not a reach.
--
-- Colin 2026-11-23, on the live cards nothing would touch: "put the 443 on call list and the 272". Those were cards
-- the text pool refuses because no number on them can take a text (landlines) or their phone is shared with another
-- owner; nothing ever put them on a call list. Each working morning power_lists_morning now gives each caller up to
-- campaign_control.power_list_callonly (20) of them, one in every fourth place of the ranked list (slot 4, 8, 12 ...),
-- so they are dialed without pushing the strongest cards down. Any tier; the records gate and the holds as for the
-- ranked list; fewer than six dials ever (a card dialed six times with nobody answering is done by this route),
-- fewer than three this week, none today, nobody reached in two weeks. An earlier day's call-only task whose card
-- no longer qualifies is closed as power_hour_dropped, like the ranked ones (0311).
--
-- A wrong number is not a reach. The same day the six "reached, no follow-up" cards were all a caller logging a
-- wrong or disconnected number: that log marks the phone bad, but every "reached" test counted it as a person
-- reached, so the card left the texted-and-silent queue for good, its texting ended and the ranked list skipped it
-- for two weeks. 263 live cards were out for that alone, 236 with numbers nobody had tried. text_pool,
-- power_dial_queue, power_list_by_need and agent_store_cards now leave wrong_number out of "reached", as they
-- already left out no answer and voicemail; the bad phone itself stays bad. (And see the end: a wrong number parked the card.)

alter table public.campaign_control add column if not exists power_list_callonly integer not null default 20;
comment on column public.campaign_control.power_list_callonly is 'Cards only a call can reach given to each caller each morning, one in every fourth place (0312).';

create or replace function public.power_lists_morning(p_now timestamptz default now(), p_force boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare
  c public.campaign_control;
  d date := (p_now at time zone 'America/Chicago')::date;
  hr integer := extract(hour from (p_now at time zone 'America/Chicago'))::int;
  base timestamptz := (d + time '06:00') at time zone 'America/Chicago';
  who public.team_person; r jsonb; out jsonb := '{}'::jsonb; q record; tid uuid; k integer; n_co integer; n_co_drop integer;
begin
  if not (public.is_owner() or auth.uid() is null) then raise exception 'only Colin or the desk ranks the call lists'; end if;
  select * into c from public.campaign_control where id = 1;
  if not coalesce(c.power_list_daily, true) and not p_force then return jsonb_build_object('day', d, 'ran', false, 'why', 'switched off'); end if;
  if extract(isodow from d) = 7 and not p_force then return jsonb_build_object('day', d, 'ran', false, 'why', 'Sunday: calls rest'); end if;
  if hr < 5 and not p_force then return jsonb_build_object('day', d, 'ran', false, 'why', 'before 5 AM Central'); end if;

  -- 0312: the cards no text can reach (asked once, for both callers: the pool is the slow part)
  drop table if exists _callonly_pool;
  create temp table _callonly_pool on commit drop as
    select p.lead_id, min(p.block) filter (where p.block in ('no_textable_phone', 'phone_shared')) as why
      from public.text_pool(p_now) p group by p.lead_id
     having bool_and(p.block is not null) and bool_or(p.block in ('no_textable_phone', 'phone_shared'));

  foreach who in array array['thalia', 'adil']::public.team_person[] loop
    if exists (select 1 from public.power_list_runs pr where pr.day = d and pr.person = who) and not p_force then
      out := out || jsonb_build_object(who::text, 'already ranked today');
      continue;
    elsif public.caller_is_off(who, d) then
      out := out || jsonb_build_object(who::text, 'off today');
      continue;
    end if;
    r := public.power_list_by_need(who, d, greatest(1, coalesce(c.power_list_top, 120)), false);

    -- the call-only cards for this caller, one in every fourth place of the ranked list
    drop table if exists _co;
    create temp table _co on commit drop as
    with cand as (
      select l.id as lead_id, cp.why, coalesce(f.tier, m.tier, 'D') as tier, l.stacked_at,
             (select count(*) from public.messages mm where mm.lead_id = l.id and mm.channel = 'call' and coalesce(mm.status, '') not like 'inbound%') as dials
        from _callonly_pool cp join public.leads l on l.id = cp.lead_id
        left join public.text_fitness f on f.wpie_owner_id = l.wpie_owner_id and l.wpie_owner_id > 0
        left join public.lead_motivation m on m.lead_id = l.id
       where public.card_caller(l.id) = who
         and not public.card_is_closed(l.stage) and l.stage::text not in ('under_contract', 'data_fix')
         and l.owner_name not ilike 'TEST %'
         and exists (select 1 from public.contacts ct where ct.lead_id = l.id and ct.kind = 'phone' and ct.status = 'ok' and not ct.dnc_app
                        and not ct.suppressed and not ct.dnc_vendor and ct.dnc_scrub <> 'dnc'
                        and not exists (select 1 from public.suppressed_phones s where s.phone10 = ct.value_normalized)
                        and public.phone_person_block(ct.value_normalized) is null)
         and (select count(*) from public.messages mm where mm.lead_id = l.id and mm.channel = 'call' and coalesce(mm.status, '') not like 'inbound%'
                and mm.sent_at > p_now - interval '7 days') < 3
         and not exists (select 1 from public.messages mm where mm.lead_id = l.id and mm.channel = 'call' and coalesce(mm.status, '') not like 'inbound%'
                            and (mm.sent_at at time zone 'America/Chicago')::date = d)
         and not exists (select 1 from public.messages mm where mm.lead_id = l.id and mm.channel = 'call' and mm.sent_at > p_now - interval '14 days'
                            and coalesce(mm.status, '') not in ('no_answer', 'voicemail', 'inbound_missed', 'missed', 'busy', 'failed', 'canceled', 'blocked', 'wrong_number')
                            and coalesce(mm.status, '') not like 'inbound%')
         -- already on today's ranked list
         and not exists (select 1 from public.tasks t where t.lead_id = l.id and t.done_at is null and t.owner = who and t.source = 'power_hour'
                            and t.due_at >= base and t.due_at < base + make_interval(secs => greatest(1, coalesce(c.power_list_top, 120)) + 1))),
    ok as (select cand.* from cand where cand.dials < 6
              and coalesce(public.card_hold_block(cand.lead_id, p_now), public.card_record_block(cand.lead_id, d)) is null)
    select ok.*, row_number() over (order by case ok.tier when 'A' then 1 when 'B' then 2 when 'C' then 3 else 4 end, ok.dials, ok.stacked_at desc nulls last, ok.lead_id) as k
      from ok;

    n_co := 0;
    for q in select * from _co where _co.k <= greatest(0, coalesce(c.power_list_callonly, 20)) order by _co.k loop
      tid := null;
      select t.id into tid from public.tasks t
       where t.lead_id = q.lead_id and t.done_at is null and t.owner = who and t.source in ('power_hour', 'power_hour_reserve')
       order by t.due_at limit 1;
      if tid is not null then
        update public.tasks set due_at = base + make_interval(secs => 4 * q.k - 0.5), source = 'power_hour', updated_at = now() where id = tid;
      else
        insert into public.tasks (lead_id, due_at, kind, owner, source, source_key, title, note)
        values (q.lead_id, base + make_interval(secs => 4 * q.k - 0.5), 'call', who, 'power_hour', 'callonly:' || d::text || ':' || q.lead_id::text,
                case q.why when 'phone_shared' then 'Call only: the phone is shared with another owner' else 'Call only: no number on it takes a text' end,
                'Only a call can reach this card (' || case q.why when 'phone_shared' then 'its phone is shared with another owner, so it is not texted'
                  else 'no number on it can take a text' end || '). Tier ' || q.tier || ', dialed ' || q.dials || ' times before.')
        on conflict (source_key) do update set due_at = excluded.due_at, done_at = null, owner = excluded.owner, updated_at = now();
      end if;
      n_co := n_co + 1;
    end loop;
    -- an earlier day's call-only task whose card no longer qualifies leaves the list
    update public.tasks t set done_at = now(), source = 'power_hour_dropped', updated_at = now(),
           note = coalesce(t.note || ' ', '') || 'Off the call-only list on ' || to_char(d, 'Dy Mon FMDD') || '.'
     where t.done_at is null and t.owner = who and t.source = 'power_hour' and t.source_key like 'callonly:%'
       and t.source_key not like 'callonly:' || d::text || ':%'
       and not exists (select 1 from _co where _co.lead_id = t.lead_id and _co.k <= greatest(0, coalesce(c.power_list_callonly, 20)));
    get diagnostics n_co_drop = row_count;

    r := (r - 'top') || jsonb_build_object('call_only', n_co, 'call_only_waiting', (select count(*) from _co), 'call_only_dropped', n_co_drop);
    insert into public.power_list_runs (day, person, at, result) values (d, who, p_now, r)
    on conflict (day, person) do update set at = excluded.at, result = excluded.result;
    out := out || jsonb_build_object(who::text, r);
  end loop;
  return jsonb_build_object('day', d, 'ran', true, 'lists', out);
end $fn$;
revoke all on function public.power_lists_morning(timestamptz, boolean) from public, anon, authenticated;
grant execute on function public.power_lists_morning(timestamptz, boolean) to service_role;

-- ---------------------------------------------------------------- a wrong number is not a reach (recreated from live)
CREATE OR REPLACE FUNCTION public.text_pool(p_now timestamp with time zone DEFAULT now())
 RETURNS TABLE(lead_id uuid, kind text, step integer, phone text, tier text, need_why text, due_day date, block text, ord bigint)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with d as (select (p_now at time zone 'America/Chicago')::date as day),
  -- 0272: threads that speak in the name of a caller who is off today
  off_name as (select n.lead_id from d, public.text_name_off(d.day) n),
  firsts as (
    select l.id, l.stacked_at, l.created_at, ph.phone,
           coalesce(f.tier, m.tier) as tier, coalesce(f.equity, e.equity_grade) as equity, sd.sale_date,
           coalesce(sd.sale_date >= d.day + 14, false) as sale_ahead,
           coalesce(f.need_why, m.family_list) as need_why,
           coalesce(case when ph.phone is null and exists (select 1 from public.contacts c2 where c2.lead_id = l.id and c2.kind = 'phone' and c2.status = 'ok'
                                                              and public.phone_is_shared(c2.value_normalized)) then 'phone_shared'
                         when ph.phone is null then 'no_textable_phone' end,
                    public.card_hold_block(l.id, p_now), public.card_record_block(l.id, d.day),
                    -- 0257: the owner said STOP on another number of theirs; the send check refuses every card of theirs
                    case when public.owner_opted_out(l.wpie_owner_id) then 'owner_opted_out' end,
                    (select 'name_off_today' from off_name o where o.lead_id = l.id limit 1)) as block
      from d, public.leads l
      left join public.text_fitness f on f.wpie_owner_id = l.wpie_owner_id and l.wpie_owner_id > 0
      left join public.lead_motivation m on m.lead_id = l.id
      left join public.equity_inputs e on e.lead_id = l.id
      left join public.card_sale_dates sd on sd.lead_id = l.id
      left join lateral (
        select c.value_normalized as phone from public.contacts c
         where c.lead_id = l.id and c.kind = 'phone' and c.status = 'ok' and not c.dnc_app and not c.suppressed and not c.dnc_vendor
           and c.dnc_scrub <> 'dnc' and public.agent_phone_ok(c.value_normalized, c.line_type)
           and not exists (select 1 from public.suppressed_phones s where s.phone10 = c.value_normalized)
           and not exists (select 1 from public.twilio_inbound ti where ti.from10 = c.value_normalized)
           and public.phone_person_block(c.value_normalized) is null
           and not public.phone_is_shared(c.value_normalized)   -- 0257: the send check refuses it (phone_shared)
         -- 0301: among the numbers a card has, one whose block belongs to a wireless carrier goes first
         order by (lower(coalesce(c.line_type, '')) in ('mobile', 'wireless', 'cell', 'cellular')) desc, coalesce(c.block_rank, 1), c.created_at, c.value_normalized
         limit 1) ph on true
     where l.stage in ('opener_queued', 'postcard_mailed')
       and not exists (select 1 from public.planned_openers po where po.lead_id = l.id and po.step = 1
                        and po.send_status in ('planned', 'would_send', 'sending', 'sent', 'delivered'))
       and not exists (select 1 from public.messages mm where mm.lead_id = l.id and mm.direction = 'out' and mm.channel = 'sms')),
  first_text as (
    -- the latest first text that was not a bounce: the phone this thread runs on
    select distinct on (m.lead_id) m.lead_id, right(regexp_replace(m.to_number, '\D', '', 'g'), 10) as phone, m.sent_at as first_at
      from public.messages m join public.leads l on l.id = m.lead_id
     where l.stage = 'opener_sent' and m.direction = 'out' and m.channel = 'sms' and m.is_opener
       and m.provider_sid is not null and coalesce(m.status, '') not in ('undelivered', 'failed')
     order by m.lead_id, m.sent_at desc),
  thread as (
    select f.lead_id, f.phone, f.first_at, count(m.*)::int as n, max(m.sent_at) as last_at
      from first_text f join public.messages m on m.lead_id = f.lead_id and m.direction = 'out' and m.channel = 'sms'
       and m.provider_sid is not null and right(regexp_replace(m.to_number, '\D', '', 'g'), 10) = f.phone and m.sent_at >= f.first_at
     group by 1, 2, 3),
  due as (
    select t.lead_id, t.phone, t.n + 1 as step, t.last_at,
           (t.first_at at time zone 'America/Chicago')::date + (case t.n + 1 when 2 then 2 when 3 then 9 when 4 then 16 else 23 end) as raw_day
      from thread t where t.n between 1 and 4),
  follow as (
    select x.lead_id as id, x.step, x.phone, x.due_day, fm.tier, fm.need_why,
           coalesce(public.card_hold_block(x.lead_id, p_now), public.card_record_block(x.lead_id, d.day),
                    public.followup_send_block(x.lead_id, x.phone, x.step),   -- 0257
                    (select 'name_off_today' from off_name o where o.lead_id = x.lead_id limit 1)) as block
      from d, (select u.*, case when extract(isodow from u.raw_day) = 7 and coalesce((select cc.no_sundays from public.campaign_control cc where cc.id = 1), true) then u.raw_day + 1 else u.raw_day end as due_day from due u) x
      join public.leads l on l.id = x.lead_id
      left join lateral (select coalesce(f.tier, m.tier) as tier, coalesce(f.need_why, m.family_list) as need_why
                           from (select 1) one
                           left join public.text_fitness f on f.wpie_owner_id = l.wpie_owner_id and l.wpie_owner_id > 0
                           left join public.lead_motivation m on m.lead_id = l.id) fm on true
     where x.due_day <= d.day and x.last_at < p_now - interval '1 day'
       -- they wrote back, from any phone on the card (or a phone that belongs to it)
       and not exists (select 1 from public.twilio_inbound ti where ti.lead_id = l.id
                         or ti.from10 in (select c.value_normalized from public.contacts c where c.lead_id = l.id and c.kind = 'phone'))
       and not exists (select 1 from public.messages m where m.lead_id = l.id and m.direction = 'in' and m.channel = 'sms')
       -- a call that REACHED them ends the texting; a dial nobody answered does not
       and not exists (select 1 from public.messages m where m.lead_id = l.id and m.channel = 'call'
                         and coalesce(m.status, '') not in ('no_answer', 'voicemail', 'inbound_missed', 'missed', 'busy', 'failed', 'canceled', 'blocked', 'wrong_number'))
       and not exists (select 1 from public.suppressed_phones s where s.phone10 = x.phone)
       and exists (select 1 from public.contacts c where c.lead_id = l.id and c.kind = 'phone' and c.value_normalized = x.phone and c.status = 'ok'
                    and not c.dnc_app and not c.suppressed and not c.dnc_vendor and c.dnc_scrub <> 'dnc')
       and public.phone_person_block(x.phone) is null
       and not exists (select 1 from public.planned_openers po where po.lead_id = l.id and po.send_status in ('planned', 'would_send', 'sending'))),
  -- the owner's next number: the texted number was someone else's (0079), or every first text to the card bounced
  -- on a dead number and nobody was reached (0225), and another usable mobile is on the card
  next_numbers as (
    select l.id, ph.value_normalized as phone, l.updated_at, coalesce(f.tier, m.tier) as tier, coalesce(f.need_why, m.family_list) as need_why,
           coalesce(public.card_hold_block(l.id, p_now), public.card_record_block(l.id, d.day),
                    (select 'name_off_today' from off_name o where o.lead_id = l.id limit 1)) as block
      from d, public.leads l
      left join public.text_fitness f on f.wpie_owner_id = l.wpie_owner_id and l.wpie_owner_id > 0
      left join public.lead_motivation m on m.lead_id = l.id
      cross join lateral (
        select c.value_normalized from public.contacts c
         where c.lead_id = l.id and c.kind = 'phone' and c.status = 'ok' and not c.dnc_app and not c.suppressed and not c.dnc_vendor
           and c.dnc_scrub <> 'dnc' and public.agent_phone_ok(c.value_normalized, c.line_type)
           and public.phone_person_block(c.value_normalized) is null
           and public.next_phone_problem(l.id, c.value_normalized) is null
           and not public.phone_is_shared(c.value_normalized)   -- 0257
         order by coalesce(c.block_rank, 1), c.created_at, c.value_normalized limit 1) ph      -- 0301
     where (l.stage = 'data_fix'
            or (l.stage = 'opener_sent'
                and exists (select 1 from public.planned_openers b where b.lead_id = l.id and b.step = 1 and b.send_status in ('undelivered', 'failed'))
                and not exists (select 1 from public.planned_openers g where g.lead_id = l.id and g.send_status in ('sending', 'sent', 'delivered', 'uncertain'))))
       and not exists (select 1 from public.planned_openers po where po.lead_id = l.id and po.send_status in ('planned', 'would_send', 'sending')))
  select f.id, 'first', 1, f.phone, f.tier, f.need_why, null::date, f.block,
         -- a sale ahead is the first text of the day, soonest sale first (0233)
         row_number() over (order by (f.block is null) desc, f.sale_ahead desc, case when f.sale_ahead then f.sale_date end nulls last,
                                     case f.tier when 'A' then 1 when 'B' then 2 when 'C' then 3 when 'D' then 4 else 5 end,
                                     f.sale_date nulls last, (coalesce(f.equity, '') in ('clear', 'likely')) desc,
                                     f.stacked_at desc nulls last, f.created_at desc, f.id)
    from firsts f
  union all
  select w.id, 'followup', w.step, w.phone, w.tier, w.need_why, w.due_day, w.block,
         row_number() over (order by (w.block is null) desc, w.step, w.due_day, w.id)
    from follow w
  union all
  select n.id, 'next_number', 1, n.phone, n.tier, n.need_why, null::date, n.block,
         row_number() over (order by (n.block is null) desc,
                                     case n.tier when 'A' then 1 when 'B' then 2 when 'C' then 3 when 'D' then 4 else 5 end, n.updated_at, n.id)
    from next_numbers n
$function$;

CREATE OR REPLACE FUNCTION public.agent_store_cards(p_after_updated timestamp with time zone DEFAULT NULL::timestamp with time zone, p_after_id uuid DEFAULT NULL::uuid, p_since timestamp with time zone DEFAULT NULL::timestamp with time zone, p_limit integer DEFAULT 200, p_county text DEFAULT NULL::text, p_stage text[] DEFAULT NULL::text[], p_live_only boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with page as (
    select l.*, coalesce(l.updated_at, l.created_at) as u from public.leads l
     where (p_after_updated is null or (coalesce(l.updated_at, l.created_at), l.id) > (p_after_updated, coalesce(p_after_id, '00000000-0000-0000-0000-000000000000'::uuid)))
       and (p_since is null or coalesce(l.updated_at, l.created_at) >= p_since)
       and (p_county is null or lower(coalesce(l.county, '')) = lower(p_county))
       and (p_stage is null or l.stage::text = any(p_stage))
       and (not p_live_only or l.stage not in ('dead', 'dnc', 'closed_no_contact', 'closed_won'))
     order by coalesce(l.updated_at, l.created_at), l.id
     limit greatest(1, least(coalesce(p_limit, 200), 500))),
  rows as (
    select l.u, l.id, jsonb_build_object(
      'lead_id', l.id, 'owner_name', l.owner_name, 'owner_type', l.owner_type,
      'address', l.property_address, 'city', l.municipality, 'county', l.county, 'zip', l.property_zip,
      'property', jsonb_build_object('type', l.property_type, 'units', l.units, 'parcel', l.parcel_id, 'lane', l.lane, 'score', l.score,
                                     'wpie_property_id', l.wpie_property_id, 'laptop_card', l.wpie_owner_id > 0),
      'stage', l.stage, 'stage_changed_at', l.stage_changed_at, 'dead_reason', l.dead_reason,
      'card_owner', (select tm.display_name from public.team_members tm where tm.person = l.locked_to), 'card_owner_key', l.locked_to,
      'held', jsonb_build_object('parked_at', l.parked_at, 'parked_why', l.parked_why, 'rest_until', l.rest_until,
                                 'human_takeover_at', l.human_takeover_at, 'elderly_or_ill', l.elderly_or_ill, 'grief', l.grief,
                                 'caller_texting', public.caller_texting(l.id)),
      'belt', jsonb_build_object('belt', l.belt, 'step', l.belt_step, 'next_stop_at', l.next_stop_at, 'who', l.next_stop_who, 'say', l.next_stop_say),
      'check_back_at', l.next_action_at, 'named_date', l.named_date, 'named_event', l.named_event, 'say_next', l.say_next,
      'reasons', l.reasons_to_sell,
      'reason_details', (select jsonb_agg(jsonb_build_object('kind', r.kind, 'detail', r.detail, 'date', r.event_date, 'amount', r.amount, 'source', r.source))
                           from public.prospect_reasons r where r.lead_id = l.id),
      'motivation', (select jsonb_build_object('tier', lm.tier, 'families', lm.families, 'family_list', lm.family_list, 'lines', lm.lines,
                                               'amplifiers', lm.amplifiers, 'tax_years', lm.tax_years, 'tax_owed', lm.tax_owed, 'as_of', lm.as_of)
                       from public.lead_motivation lm where lm.lead_id = l.id),
      'equity', (select jsonb_build_object('grade', e.equity_grade, 'line', e.equity_line, 'estimated', e.estimated,
                                           'value_used', e.value_used, 'value_source', e.value_source, 'assessed_total', e.assessed_total, 'est_market_value', e.est_market_value,
                                           'last_sale_date', e.last_sale_date, 'last_sale_price', e.last_sale_price, 'sale_source', e.sale_source,
                                           'tenure_from', e.tenure_from, 'tenure_source', e.tenure_source,
                                           'tax_years_behind', e.tax_years_behind, 'tax_owed', e.tax_owed, 'judgment_amount', e.judgment_amount, 'in_rem_amount', e.in_rem_amount,
                                           'mortgage_balance_est', e.mortgage_balance_est, 'assumed_loan_balance_est', e.assumed_loan_balance_est, 'mortgage_source', e.mortgage_source,
                                           'debt_total', e.debt_total, 'equity', e.equity, 'equity_share', e.equity_share, 'basis', e.basis, 'caveats', e.caveats, 'pushed_at', e.pushed_at)
                   from public.equity_inputs e where e.lead_id = l.id),
      'people', public.card_interests(l.id),
      'phones', (select coalesce(jsonb_agg(jsonb_build_object('phone', c.value_normalized, 'type', c.line_type, 'name', c.person_name, 'status', c.status,
                        'textable', c.status = 'ok' and not c.dnc_app and not c.suppressed and not c.dnc_vendor and c.dnc_scrub <> 'dnc' and public.agent_phone_ok(c.value_normalized, c.line_type),
                        'opted_out', exists (select 1 from public.suppressed_phones s where s.phone10 = c.value_normalized),
                        'blocked', public.phone_person_block(c.value_normalized),
                        'texts_sent', (select count(*) from public.messages m where m.lead_id = l.id and m.direction = 'out' and m.channel = 'sms'
                                         and m.provider_sid is not null and right(regexp_replace(coalesce(m.to_number, ''), '\D', '', 'g'), 10) = c.value_normalized),
                        'last_sent_at', (select max(m.sent_at) from public.messages m where m.lead_id = l.id and m.direction = 'out' and m.channel = 'sms'
                                           and m.provider_sid is not null and right(regexp_replace(coalesce(m.to_number, ''), '\D', '', 'g'), 10) = c.value_normalized),
                        'replies', (select count(*) from public.twilio_inbound t where t.lead_id = l.id and t.from10 = c.value_normalized))
                      order by c.created_at), '[]'::jsonb)
                   from public.contacts c where c.lead_id = l.id and c.kind = 'phone'),
      'cadence', jsonb_build_object(
        'texts_sent', (select count(*) from public.messages m where m.lead_id = l.id and m.direction = 'out' and m.channel = 'sms' and m.provider_sid is not null),
        'last_out_at', (select max(m.sent_at) from public.messages m where m.lead_id = l.id and m.direction = 'out' and m.channel = 'sms' and m.provider_sid is not null),
        'last_in_at', greatest((select max(t.received_at) from public.twilio_inbound t where t.lead_id = l.id),
                               (select max(m.sent_at) from public.messages m where m.lead_id = l.id and m.direction = 'in' and m.channel = 'sms')),
        'replied', exists (select 1 from public.twilio_inbound t where t.lead_id = l.id)
                   or exists (select 1 from public.messages m where m.lead_id = l.id and m.direction = 'in' and m.channel = 'sms'),
        'call_reached', exists (select 1 from public.messages m where m.lead_id = l.id and m.channel = 'call' and coalesce(m.status, '') not in ('no_answer', 'voicemail', 'inbound_missed', 'missed', 'busy', 'failed', 'canceled', 'blocked', 'wrong_number')),
        'planned', (select count(*) from public.planned_openers po where po.lead_id = l.id and po.send_status in ('planned', 'would_send', 'sending'))),
      'created_at', l.created_at, 'updated_at', l.u) as card
      from page l)
  select jsonb_build_object(
    'cards', coalesce((select jsonb_agg(r.card order by r.u, r.id) from rows r), '[]'::jsonb),
    'page', (select count(*) from rows),
    'next_after', (select jsonb_build_object('updated_at', r.u, 'id', r.id) from rows r order by r.u desc, r.id desc limit 1),
    'store_counts', case when p_after_updated is null then (
        select jsonb_build_object('cards', count(*), 'live', count(*) filter (where l.stage not in ('dead', 'dnc', 'closed_no_contact', 'closed_won')),
                                  'agent_loaded', count(*) filter (where l.wpie_owner_id < 0),
                                  'by_stage', (select coalesce(jsonb_object_agg(st, n), '{}'::jsonb) from (select stage::text st, count(*) n from public.leads group by 1) a),
                                  'with_equity_row', (select count(*) from public.equity_inputs),
                                  'with_sale_date', (select count(*) from public.equity_inputs e where e.last_sale_date is not null),
                                  'with_sale_price', (select count(*) from public.equity_inputs e where e.last_sale_price is not null))
          from public.leads l) end)
$function$;

CREATE OR REPLACE FUNCTION public.power_dial_queue(p_limit integer DEFAULT 80, p_now timestamp with time zone DEFAULT now(), p_test boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with me as (select public.is_team() as ok),
  today as (select (p_now at time zone 'America/Chicago')::date as d),
  -- the phones a person's status blocks (phone_person_block, 0084), computed once for the whole queue instead of once
  -- per contact per card: as a per-row call it stopped using the index and the queue took minutes (2026-10-29)
  blocked as (
    select distinct c.value_normalized as ph from public.contacts c join public.people pe on pe.id = c.person_id
     where pe.status = 'do_not_contact'
        or (pe.status = 'deceased' and not exists (select 1 from public.contacts c2 join public.people p2 on p2.id = c2.person_id
                                                    where c2.value_normalized = c.value_normalized and p2.status = 'active'))),
  dialed as (
    select m.lead_id, count(*) filter (where m.sent_at > p_now - interval '7 days') as dials_7d, count(*) as dials_total, max(m.sent_at) as last_dial,
           count(*) filter (where (m.sent_at at time zone 'America/Chicago')::date = (p_now at time zone 'America/Chicago')::date) as dials_today
      -- our dials only: a logged call is stored as 'in' with its outcome; their own calls to us are 'inbound...'
      from public.messages m where m.channel = 'call' and coalesce(m.status, '') not like 'inbound%' group by m.lead_id),
  reached as (
    select distinct m.lead_id from public.messages m
     where m.channel = 'call' and coalesce(m.status, '') not in ('no_answer', 'voicemail', 'inbound_missed', 'missed', 'busy', 'failed', 'canceled', 'blocked', 'wrong_number')),
  first_text as (
    select distinct on (m.lead_id) m.lead_id, right(regexp_replace(m.to_number, '\D', '', 'g'), 10) as phone, m.sent_at
      from public.messages m
     where m.direction = 'out' and m.channel = 'sms' and m.is_opener and m.provider_sid is not null and coalesce(m.status, '') not in ('undelivered', 'failed')
     order by m.lead_id, m.sent_at),
  texts as (
    select m.lead_id, count(*) as n, max(m.sent_at) as last_at from public.messages m
     where m.direction = 'out' and m.channel = 'sms' and m.provider_sid is not null group by m.lead_id),
  -- a seller who called us and nobody picked up, not called back since (the same rule as Today's Missed calls box)
  missed as (
    select distinct on (ic.lead_id) ic.lead_id, ic.from10 as missed_phone, ic.created_at as missed_at, ic.voicemail,
           nullif(substring(m.body from 'Voicemail: "(.*)"'), '') as vm_words
      from public.inbound_calls ic left join public.messages m on m.id = ic.message_id
     where ic.lead_id is not null and ic.created_at > p_now - interval '48 hours'
       and (ic.status in ('missed', 'blocked', 'no_answer', 'busy', 'failed') or ic.voicemail)
       -- a caller whose number is on the stop list ("erase my number") is never a callback, on any of the card's numbers
       and not exists (select 1 from public.suppressed_phones s where s.phone10 = ic.from10)
       -- the voicemail was read (0118): an upset caller, a stop, the wrong person or someone who isn't a seller is never a
       -- callback; a voicemail not read yet waits up to 10 minutes so nobody calls a caller who was angry
       and coalesce(ic.vm_verdict, '') not in ('stop', 'wrong_person', 'upset', 'not_seller')
       and not (ic.voicemail and ic.vm_verdict is null and ic.created_at > p_now - interval '10 minutes')
       and not exists (select 1 from public.messages o where o.lead_id = ic.lead_id and o.channel = 'call' and o.sent_at > ic.created_at
                         and coalesce(o.status, '') not like 'inbound%')
     order by ic.lead_id, ic.created_at desc),
  due_tasks as (
    select distinct on (t.lead_id) t.lead_id, t.id as task_id, t.title, t.due_at, t.source as task_source, t.kind as task_kind, t.note as task_note, t.quote as reply_words,
           nullif(t.phone10, '') as reply_phone, t.created_at as task_at,
           -- a follow-up a conversation set (the belt's call, the caller's own, a check-in) that is due now (0233)
           bool_or(coalesce(t.source, '') in ('belt', 'mine', 'checkin') and t.due_at <= p_now) over (partition by t.lead_id) as followup_due
      from public.tasks t
     where t.done_at is null and t.lead_id is not null
       and ((t.kind = 'call' and t.due_at <= p_now + interval '12 hours')
         -- a callback promised to a seller comes up from 15 minutes before its time (0124)
         or (t.kind = 'callback' and t.due_at <= p_now + interval '15 minutes'))
       and t.owner in ('thalia', 'adil')
       -- a callback promised by one caller is that caller's (Colin 2026-10-30): on a caller's own login only their own come up
       and (t.kind <> 'callback' or public.wpie_person() not in ('thalia', 'adil') or t.owner = public.wpie_person())
       -- a power-hour set is loaded per caller (Colin 2026-11-03: "50 in each and then followups"): only its caller sees it
       and (coalesce(t.source, '') not in ('power_hour', 'power_hour_after') or public.wpie_person() not in ('thalia', 'adil') or t.owner = public.wpie_person())
     order by t.lead_id, (t.kind = 'callback') desc, (t.source = 'call_next') desc, t.due_at),
  pool as (
    select l.*, dt.task_id, dt.title as task_title, dt.reply_words, dt.task_at, dt.due_at as task_due, (dt.task_source = 'call_next') as replied,
           mc.missed_at, mc.voicemail as missed_voicemail, mc.vm_words, mc.missed_phone,
           coalesce(mc.missed_phone, dt.reply_phone, ft.phone) as thread_phone, ft.sent_at as first_text_at,
           coalesce(tx.n, 0) as texts_sent, tx.last_at as last_text_at, coalesce(d.dials_7d, 0) as dials_7d, coalesce(d.dials_total, 0) as dials_total, d.last_dial, coalesce(d.dials_today, 0) as dials_today,
           dt.task_source, case when mc.lead_id is not null then -3 when dt.task_kind = 'callback' then -2 when dt.task_source = 'call_next' then -1
                when dt.task_id is not null then 0 else 1 end as src, dt.task_note,
           -- a sheriff sale 14 or more days out, on a card that is not thin or underwater (0233): first on the list
           sl.sale_date, sl.equity as sale_equity, coalesce(sl.sale_date >= (select d from today) + 14 and sl.equity not in ('thin', 'underwater'), false) as sale_ahead,
           coalesce(dt.followup_due, false) as followup_due
      from public.leads l
      left join missed mc on mc.lead_id = l.id
      left join due_tasks dt on dt.lead_id = l.id
      left join first_text ft on ft.lead_id = l.id
      left join texts tx on tx.lead_id = l.id
      left join dialed d on d.lead_id = l.id
      left join public.card_sale_dates sl on sl.lead_id = l.id
     where (select ok from me)
       and not (coalesce(l.locked_to = any ((select public.caller_blind_locks())::public.team_person[]), false) or (l.locked_to is distinct from (select public.wpie_person()) and coalesce(l.assigned_to = any ((select public.caller_blind_to())::public.team_person[]), false)))
       -- a card on another caller's screen right now is theirs (two callers in Power hour, 0120)
       -- a card locked to the other caller, or with the other caller's open callback, is not mine to dial (0148)
       and (public.wpie_person() not in ('thalia', 'adil') or l.locked_to is null or l.locked_to = public.wpie_person())
       and not exists (select 1 from public.tasks cb where cb.lead_id = l.id and cb.kind = 'callback' and cb.done_at is null
                         and public.wpie_person() in ('thalia', 'adil') and cb.owner <> public.wpie_person())
       and not exists (select 1 from public.power_claims pc where pc.lead_id = l.id and pc.until > p_now
                         and pc.person is distinct from public.wpie_person())
       -- a walkthrough runs on TEST cards only, and the real queue never shows them
       and (l.owner_name ilike 'TEST %') = coalesce(p_test, false)
       -- a seller who called us comes first, whatever the card's stage or dial count (Colin 2026-10-28: "should
       -- automatically be top of the list to call"); only a dead or do-not-contact card is left out
       and (((mc.lead_id is not null or dt.task_kind = 'callback') and l.stage not in ('dnc', 'dead', 'closed_no_contact')) or (
           (dt.task_id is not null or (l.stage = 'opener_sent' and ft.sent_at < p_now - interval '3 days')
            or (coalesce(p_test, false) and l.stage = 'opener_sent')   -- a TEST card needs no task and no texts
            -- a sale ahead needs no task either (0233): it is on the list by itself until someone is reached
            or (coalesce(sl.sale_date >= (select d from today) + 14 and sl.equity not in ('thin', 'underwater'), false) and l.stage in ('opener_queued', 'postcard_mailed', 'opener_sent', 'data_fix', 'follow_up')
                and l.id not in (select lead_id from reached)))
       -- the 14-day rule (0233): a sale inside two weeks, or already past, is never dialed from a list; a follow-up a
       -- conversation set still comes up
       and (sl.sale_date is null or sl.sale_date >= (select d from today) + 14
            or coalesce(dt.task_source, '') in ('call_next', 'belt', 'mine', 'checkin'))
       and l.stage not in ('dnc', 'dead', 'closed_no_contact', 'closed_won', 'under_contract', 'walkthrough_booked', 'offer')
       and not coalesce(l.elderly_or_ill, false) and not coalesce(l.grief, false)
       -- a caller's due follow-up call (the belt's) still comes up when a caller took the text thread (0163)
       -- a dial placed over 12 hours ago and never logged no longer hides the card from its list (0231)
       and (l.human_takeover_at is null or l.human_takeover_at < p_now - interval '12 hours' or dt.task_source in ('belt', 'mine'))
       and (l.named_date is null or l.named_date <= p_now)
        and (l.parked_at is null or (l.rest_until is not null and l.rest_until <= p_now))   -- parked (0182) or rested by the caller (0186) until it wakes
       -- four numbers a sitting (Thalia 2026-11-04, Colin: 'do what thalia asked for'): after four dials on a card in a day the
       -- card leaves today's queue and comes back the next day at its next untried number; a seller who called us, or a
       -- promised callback, is never capped
       and (mc.lead_id is not null or dt.task_kind = 'callback' or coalesce(d.dials_today, 0) < 4)
       -- someone who just texted back with a bit of interest (Muse's call_next) is called next, whatever the dial rules say
       -- and a seller who texted back gets the follow-up call the belt set for them (Colin 2026-11-03: "behind them any followups needed")
       and (dt.task_source in ('call_next', 'belt', 'mine', 'power_hour', 'power_hour_after') or coalesce(sl.sale_date >= (select d from today) + 14 and sl.equity not in ('thin', 'underwater'), false) or (
            coalesce(d.dials_7d, 0) < 3
        and (d.last_dial is null or d.last_dial < p_now - interval '2 days')
        and (dt.task_id is not null or l.id not in (select lead_id from reached))
        and not exists (select 1 from public.twilio_inbound ti where ti.lead_id = l.id)
        and not exists (select 1 from public.messages mi where mi.lead_id = l.id and mi.direction = 'in' and mi.channel = 'sms')))))
       and extract(hour from (p_now at time zone public.agent_tz(coalesce(l.mailing_state, 'WI')))) between 9 and 19),
  pick as (
    select p.*,
           -- the order of the list (0233): a seller who called, a promised callback, a reply; then a sale ahead; then a
           -- follow-up that is due; then the caller's list; then texted-and-silent cards
           case when p.src < 0 then p.src when p.sale_ahead then 0 when p.followup_due then 1 else 2 + p.src end as prio,
           -- need first (0189): the motivation tier from the laptop's records, A..D; a card with no row is D
           coalesce((select case m.tier when 'A' then 0 when 'B' then 1 when 'C' then 2 else 3 end
                       from public.lead_motivation m where m.lead_id = p.id), 3) as need_rank,
           ph.value_normalized as phone, ph.line_type, ph.person_name as phone_person,
           (select count(*) from public.contacts c2 where c2.lead_id = p.id and c2.kind = 'phone' and c2.status = 'ok' and not c2.suppressed
              and not exists (select 1 from public.messages m where m.lead_id = p.id and m.channel = 'call' and coalesce(m.status, '') not like 'inbound%'
                              and right(regexp_replace(coalesce(m.to_number, ''), '\D', '', 'g'), 10) = c2.value_normalized and (m.sent_at at time zone 'America/Chicago')::date = (p_now at time zone 'America/Chicago')::date)) - 1 as other_phones
      from pool p
      cross join lateral (
        select c.value_normalized, c.line_type, c.person_name from public.contacts c
         where c.lead_id = p.id and c.kind = 'phone' and c.status = 'ok' and c.value_normalized ~ '^[0-9]{10}$'
           and not c.suppressed and not coalesce(c.dnc_app, false)
           and (c.value_normalized = p.missed_phone or (not coalesce(c.dnc_vendor, false) and coalesce(c.dnc_scrub, '') <> 'dnc'))
           and not exists (select 1 from public.suppressed_phones s where s.phone10 = c.value_normalized)
           and not exists (select 1 from blocked b where b.ph = c.value_normalized)
           -- a number already dialed today is not offered again today (0184), except to call a seller back
           and (p.src <= -2 or (true and not exists (select 1 from public.messages m where m.lead_id = p.id and m.channel = 'call' and coalesce(m.status, '') not like 'inbound%'
                              and right(regexp_replace(coalesce(m.to_number, ''), '\D', '', 'g'), 10) = c.value_normalized and (m.sent_at at time zone 'America/Chicago')::date = (p_now at time zone 'America/Chicago')::date)))
         order by (c.value_normalized = p.thread_phone) desc,
                  (c.person_id is not null and exists (select 1 from public.interests i where i.lead_id = p.id and i.person_id = c.person_id
                     and i.role in ('owner_of_record', 'co_owner', 'personal_representative', 'trustee') and i.status = 'active')) desc,
                  (c.line_type = 'mobile') desc, c.created_at
         limit 1) ph
     order by prio, p.missed_at desc nulls last, (p.sale_ahead and p.sale_equity in ('clear', 'likely')) desc,
              case when p.sale_ahead then p.sale_date end nulls last, (coalesce(p.task_source, '') = 'power_hour') desc,
              case when p.task_source = 'power_hour' then p.task_due end nulls last, p.task_at nulls last, need_rank, cardinality(p.reasons_to_sell) desc, p.dials_total, p.first_text_at nulls last, p.id
     limit greatest(1, least(coalesce(p_limit, 80), 200)))
  select coalesce(jsonb_agg(jsonb_build_object(
      'lead_id', id, 'task_id', task_id, 'source', case when src = -3 then 'missed_call' when src = -2 then 'callback' when src = -1 then 'replied'
        when task_source = 'checkin' then 'checkin' when src = 0 or sale_ahead then 'call_list' else 'texted_silent' end,
      'why', case when sale_ahead then 'Sheriff sale ' || to_char(sale_date, 'Mon FMDD') || ': last call day ' || to_char(sale_date - 14, 'Mon FMDD')
                  else task_title end,
      'sale_date', sale_date,
      'missed_at', missed_at, 'voicemail', missed_voicemail, 'voicemail_words', vm_words,
      'reply', reply_words, 'task_note', task_note,
      -- the card's latest package: what Colin decided, so the caller says the right thing (0124)
      'package', (select jsonb_build_object('id', d.id, 'status', d.status, 'colin_call', d.colin_call, 'colin_asks', d.colin_asks,
                    'caller_answers', d.caller_answers, 'callback_at', d.callback_at, 'number_note', d.number_note,
                    'our_number', d.our_number, 'their_number', d.their_number)
                    from public.deal_packages d where d.lead_id = pick.id order by d.created_at desc limit 1),
      'owner_name', owner_name, 'address', property_address, 'municipality', municipality, 'mailing_state', mailing_state,
      'reasons', reasons_to_sell, 'lane', lane, 'stage', stage,
      'texts_sent', texts_sent, 'first_text_at', first_text_at, 'last_text_at', last_text_at,
      'dials_7d', dials_7d, 'dials_total', dials_total, 'last_dial', last_dial, 'dials_today', dials_today,
      'phone', phone, 'line_type', line_type, 'phone_person', phone_person, 'other_phones', greatest(other_phones, 0),
      'say_next', say_next, 'next_plain', public.next_plain(belt, next_stop_at, next_stop_who, next_stop_say, named_date, named_event, public.wpie_person()))
      order by prio, missed_at desc nulls last, (sale_ahead and sale_equity in ('clear', 'likely')) desc,
        case when sale_ahead then sale_date end nulls last, (coalesce(task_source, '') = 'power_hour') desc,
        case when task_source = 'power_hour' then task_due end nulls last, task_at nulls last, need_rank, cardinality(reasons_to_sell) desc, dials_total, first_text_at nulls last, id), '[]'::jsonb)
    from pick
$function$;

CREATE OR REPLACE FUNCTION public.power_list_by_need(p_person team_person, p_day date DEFAULT NULL::date, p_top integer DEFAULT 120, p_dry boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  d date := coalesce(p_day, (now() at time zone 'America/Chicago')::date);
  -- 6 AM: before the laptop's own call list (due 7 AM), because the queue takes a card's earliest open task and a
  -- card whose earliest task is not a list task falls out of the list's place in the order
  base timestamptz := (coalesce(p_day, (now() at time zone 'America/Chicago')::date) + time '06:00') at time zone 'America/Chicago';
  r record; tid uuid; n_new integer := 0; n_moved integer := 0; n_behind integer := 0; n_dropped integer := 0; top jsonb; by_tier jsonb;
begin
  if not (public.is_owner() or auth.uid() is null) then raise exception 'only Colin or the desk ranks a caller''s list'; end if;
  if not public.is_caller_person(p_person) then return jsonb_build_object('ok', false, 'reason', 'a list is a caller''s: thalia or adil'); end if;
  drop table if exists _need;
  create temp table _need on commit drop as
  with c as (
    select l.id as lead_id, l.owner_name, l.property_address, l.municipality, l.stacked_at,
           coalesce(f.tier, m.tier) as tier, coalesce(m.families, 0) as families, coalesce(m.family_list, f.need_why) as family_list,
           coalesce(m.tax_years, 0) as tax_years, sd.sale_date, coalesce(sd.sale_date >= d + 14, false) as sale_ahead,
           coalesce(f.equity, sd.equity) as equity
      from public.leads l
      left join public.text_fitness f on f.wpie_owner_id = l.wpie_owner_id and l.wpie_owner_id > 0
      left join public.lead_motivation m on m.lead_id = l.id
      left join public.card_sale_dates sd on sd.lead_id = l.id
     where public.card_caller(l.id) = p_person
       and not public.card_is_closed(l.stage) and l.stage::text not in ('under_contract', 'data_fix')
       and coalesce(f.tier, m.tier) in ('A', 'B', 'C')
       -- a phone that may be dialed
       and exists (select 1 from public.contacts ct where ct.lead_id = l.id and ct.kind = 'phone' and ct.status = 'ok' and not ct.dnc_app
                      and not ct.suppressed and not ct.dnc_vendor and ct.dnc_scrub <> 'dnc'
                      and not exists (select 1 from public.suppressed_phones s where s.phone10 = ct.value_normalized)
                      and public.phone_person_block(ct.value_normalized) is null)
       -- fewer than three dials this week, and nobody reached in the last two weeks (that card is on its follow-up)
       and (select count(*) from public.messages mm where mm.lead_id = l.id and mm.channel = 'call' and coalesce(mm.status, '') not like 'inbound%'
              and mm.sent_at > now() - interval '7 days') < 3
       -- 0265: not a card already dialed on the day the list is for. A list built in the morning has none; a list
       -- topped up in the afternoon must not hand back the cards the caller just tried.
       and not exists (select 1 from public.messages mm where mm.lead_id = l.id and mm.channel = 'call' and coalesce(mm.status, '') not like 'inbound%'
                          and (mm.sent_at at time zone 'America/Chicago')::date = d)
       and not exists (select 1 from public.messages mm where mm.lead_id = l.id and mm.channel = 'call' and mm.sent_at > now() - interval '14 days'
                          and coalesce(mm.status, '') not in ('no_answer', 'voicemail', 'inbound_missed', 'missed', 'busy', 'failed', 'canceled', 'blocked', 'wrong_number')
                          and coalesce(mm.status, '') not like 'inbound%')
  ), ok as (
    -- the records and the holds, asked only of the cards that got this far (the two checks are the slow part)
    select c.* from c where coalesce(public.card_hold_block(c.lead_id, now()), public.card_record_block(c.lead_id, d)) is null
  )
  select ok.*, row_number() over (order by ok.sale_ahead desc, case when ok.sale_ahead then ok.sale_date end nulls last,
           case ok.tier when 'A' then 1 when 'B' then 2 else 3 end,
           case when ok.family_list ~* 'foreclos|sheriff|lis pendens' then 1 when ok.family_list ~* 'probate|estate|inherit' then 2
                when ok.family_list ~* 'court|judgment|warrant|debt' then 3 when ok.tax_years >= 2 then 4
                when ok.family_list ~* 'condition|vacant|raze|code|fire' then 5 else 6 end,
           ok.tax_years desc, (coalesce(ok.equity, '') in ('clear', 'likely')) desc, ok.stacked_at desc nulls last, ok.lead_id) as rk
    from ok;

  select coalesce(jsonb_object_agg(x.tier, x.n), '{}'::jsonb) into by_tier
    from (select tier, count(*) n from _need where rk <= p_top group by 1) x;
  select coalesce(jsonb_agg(jsonb_build_object('rank', rk, 'owner', owner_name, 'address', property_address, 'town', municipality, 'tier', tier,
           'why', family_list, 'sale_date', sale_date) order by rk), '[]'::jsonb) into top from _need where rk <= 15;
  if p_dry then
    return jsonb_build_object('ok', true, 'dry_run', true, 'person', p_person, 'day', d, 'can_be_called', (select count(*) from _need),
      'on_the_list', least(p_top, (select count(*) from _need)), 'by_tier', by_tier, 'sale_ahead', (select count(*) from _need where rk <= p_top and sale_ahead), 'top', top);
  end if;

  for r in select * from _need where rk <= p_top order by rk loop
    select t.id into tid from public.tasks t
     where t.lead_id = r.lead_id and t.done_at is null and t.owner = p_person and t.source in ('power_hour', 'power_hour_reserve')
     order by t.due_at limit 1;
    if tid is not null then
      update public.tasks set due_at = base + make_interval(secs => r.rk), source = 'power_hour', updated_at = now() where id = tid;
      n_moved := n_moved + 1;
    else
      insert into public.tasks (lead_id, due_at, kind, owner, source, source_key, title, note)
      values (r.lead_id, base + make_interval(secs => r.rk), 'call', p_person, 'power_hour', 'need:' || d::text || ':' || r.lead_id::text,
              left('Need first: ' || coalesce(r.family_list, 'tier ' || r.tier) || coalesce(', sale ' || to_char(r.sale_date, 'Mon FMDD'), ''), 120),
              'Ranked ' || r.rk || ' of the list for ' || to_char(d, 'Dy Mon FMDD') || ' by need: tier ' || r.tier
                || coalesce(' (' || r.family_list || ')', '') || coalesce('; sheriff sale ' || to_char(r.sale_date, 'Mon FMDD'), '') || '.')
      on conflict (source_key) do update set due_at = excluded.due_at, done_at = null, owner = excluded.owner, updated_at = now();
      n_new := n_new + 1;
    end if;
  end loop;
  -- 0311: a ranked task from an earlier day whose card did not make this list is closed (marked power_hour_dropped,
  -- not a call made): the card was dialed out for the week, reached, held or blocked by the records since, and an old
  -- ranking must not keep it on the list. Only the ranking's own tasks (need:...); an agent's or a caller's are untouched.
  update public.tasks t set done_at = now(), source = 'power_hour_dropped', updated_at = now(),
         note = coalesce(t.note || ' ', '') || 'Off the ranked list on ' || to_char(d, 'Dy Mon FMDD') || '.'
   where t.done_at is null and t.owner = p_person and t.source = 'power_hour' and t.source_key like 'need:%'
     and t.source_key not like 'need:' || d::text || ':%'
     and not exists (select 1 from _need n where n.lead_id = t.lead_id and n.rk <= p_top);
  get diagnostics n_dropped = row_count;
  -- the rest of the caller's list goes behind the ranked cards, in the order it was in
  with rest as (
    select t.id, row_number() over (order by t.due_at, t.id) as rn from public.tasks t
     where t.done_at is null and t.owner = p_person and t.source in ('power_hour', 'power_hour_reserve')
       and not exists (select 1 from _need n where n.lead_id = t.lead_id and n.rk <= p_top))
  update public.tasks t set due_at = base + make_interval(secs => p_top + 600 + rest.rn::int), updated_at = now() from rest where rest.id = t.id;
  get diagnostics n_behind = row_count;
  return jsonb_build_object('ok', true, 'person', p_person, 'day', d, 'can_be_called', (select count(*) from _need),
    'on_the_list', least(p_top, (select count(*) from _need)), 'new_tasks', n_new, 'retimed', n_moved, 'moved_behind', n_behind, 'dropped', n_dropped,
    'by_tier', by_tier, 'sale_ahead', (select count(*) from _need where rk <= p_top and sale_ahead), 'top', top);
end $function$;


-- ---------------------------------------------------------------- a wrong number is one number, not the card
-- The same reading found where those cards went: a logged wrong number (log_call, the belt, the reply agent's
-- decision) moved the whole card to data_fix, the stage for a card with no number left, even when it had other
-- numbers. 243 of the 263 cards out on a wrong number alone were in data_fix, 217 of them with a number nobody had
-- ruled out. Now the card goes to data_fix only when no number on it is left to try (card_has_live_phone, the test
-- agent_mark_card already used), and those cards go back: to opener_sent if a text went out, else opener_queued.
create or replace function public.card_has_live_phone(p_lead_id uuid) returns boolean
language sql stable security definer set search_path = public as $fn$
  select exists (select 1 from public.contacts ct where ct.lead_id = p_lead_id and ct.kind = 'phone' and ct.status = 'ok'
                   and not ct.suppressed and not ct.dnc_app and not ct.dnc_vendor and ct.dnc_scrub <> 'dnc'
                   and not exists (select 1 from public.suppressed_phones s where s.phone10 = ct.value_normalized)
                   and public.phone_person_block(ct.value_normalized) is null)
$fn$;
revoke all on function public.card_has_live_phone(uuid) from public, anon;
grant execute on function public.card_has_live_phone(uuid) to authenticated, service_role;

CREATE OR REPLACE FUNCTION public.log_call(p_lead_id uuid, p_phone text, p_outcome text, p_note text DEFAULT NULL::text, p_when timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare who text; d text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10); l public.leads;
  phones text[]; label text; named_day date; follow_at timestamptz; tz text; disconnected boolean := p_outcome = 'disconnected';
begin
  perform public.card_guard(p_lead_id);   -- 0250: a card is its caller's
  if not public.is_team() then raise exception 'team only'; end if;
  -- a disconnected number (Colin 2026-10-28: "add an option on dialer for disconnected number") is logged the wrong-number
  -- way, so the belt, the call lock and the lists all treat it as they do today: that number is marked bad, the card
  -- stays open, and the owner's next number gets a first text (ready_to_text next_numbers). The card says which.
  if disconnected then p_outcome := 'wrong_number'; end if;
  if p_outcome not in ('interested', 'not_now', 'not_interested', 'wrong_number', 'dnc', 'no_answer', 'reached_no_decision') then
    return jsonb_build_object('ok', false, 'reason', 'pick an outcome');
  end if;
  select * into l from public.leads where id = p_lead_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such lead'); end if;
  tz := public.belt_tz(l.mailing_state);
  if p_outcome = 'not_now' and p_when is not null then
    named_day := (p_when at time zone tz)::date;
    follow_at := public.not_now_followup_at(named_day, l.mailing_state, now());
    if follow_at is null then
      return jsonb_build_object('ok', false, 'reason', 'the check-back date cannot be before today');
    end if;
  end if;
  select display_name into who from public.team_members where lower(email) = lower(auth.jwt() ->> 'email');
  if p_outcome in ('interested', 'reached_no_decision', 'not_now') then perform public.lock_card_to(p_lead_id, public.wpie_person(), 'reached on a call'); end if;
  label := case p_outcome when 'interested' then 'Interested' when 'not_now' then 'Not now' when 'not_interested' then 'Not interested'
                          when 'wrong_number' then case when disconnected then 'Disconnected number' else 'Wrong number' end when 'no_answer' then 'No answer'
                          when 'reached_no_decision' then 'Reached, no decision' else 'Do not contact' end;
  if p_outcome = 'not_now' and p_when is not null then
    update public.leads set named_date = follow_at where id = p_lead_id;
    label := label || ' until ' || to_char(named_day, 'Mon DD');
  end if;
  insert into public.messages (lead_id, direction, channel, body, from_number, sent_at, seen_at, status)
  values (p_lead_id, 'in', 'call', format('Call (%s)%s: %s%s', coalesce(who, 'team'),
            case when d ~ '^[0-9]{10}$' then ' from ' || d else '' end, label,
            coalesce(E'\n' || nullif(btrim(coalesce(p_note, '')), ''), '')),
          case when d ~ '^[0-9]{10}$' then '+1' || d end, now(), now(), p_outcome);
  update public.leads set call_facts = jsonb_set(call_facts, '{last_call}', jsonb_build_object('value', p_outcome, 'at', now(), 'by', who))
   where id = p_lead_id;

  if p_outcome in ('interested', 'reached_no_decision') then
    update public.leads set stage = case when stage in ('walkthrough_booked', 'offer', 'under_contract', 'closed_won') then stage else 'colin_call' end
     where id = p_lead_id;
  elsif p_outcome = 'no_answer' then
    null;
  elsif p_outcome = 'not_now' then
    update public.leads set stage = 'follow_up', next_action = coalesce(next_action, 'Check back'),
           next_action_at = coalesce(follow_at, next_action_at, now() + interval '30 days') where id = p_lead_id;
  elsif p_outcome = 'not_interested' then
    update public.leads set stage = 'dead', dead_reason = coalesce(nullif(btrim(coalesce(p_note, '')), ''), 'Not interested (call)') where id = p_lead_id;
  elsif p_outcome = 'wrong_number' then
    if d ~ '^[0-9]{10}$' then
      update public.contacts set status = 'bad',
             note = case when disconnected then concat_ws('; ', note, 'disconnected (call ' || to_char(now() at time zone 'America/Chicago', 'YYYY-MM-DD') || ')') else note end
       where lead_id = p_lead_id and value_normalized = d;
    end if;
    -- 0312: only when no number on the card is left to try; a card with other numbers stays where it was
    update public.leads set stage = 'data_fix' where id = p_lead_id and not public.card_has_live_phone(p_lead_id);
  else
    select array_agg(distinct c.value_normalized) into phones from public.contacts c
     where c.lead_id = p_lead_id and c.kind = 'phone' and c.value_normalized ~ '^[0-9]{10}$';
    phones := coalesce(phones, '{}');
    if d ~ '^[0-9]{10}$' and not d = any(phones) then phones := array_append(phones, d); end if;
    insert into public.suppressed_phones (phone10, reason, source)
      select distinct p, 'dnc_call', 'app' from unnest(phones) p on conflict (phone10) do nothing;
    update public.contacts set suppressed = true, dnc_app = true where value_normalized = any(phones);
    update public.leads set stage = 'dnc' where id = p_lead_id;
  end if;
  return jsonb_build_object('ok', true, 'outcome', p_outcome, 'until', follow_at, 'named_day', named_day);
end $function$;

CREATE OR REPLACE FUNCTION public.belt_event(p_lead_id uuid, p_event text, p_payload jsonb DEFAULT '{}'::jsonb, p_by text DEFAULT NULL::text, p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare l public.leads; pl jsonb := coalesce(p_payload, '{}'::jsonb); prev text; who text; o text; b text; st integer;
  res jsonb; slot timestamptz; r public.belt_rules; nd timestamptz; prior integer; reason text; maxs integer;
begin
  perform public.card_guard(p_lead_id);   -- 0250: a card is its caller's
  select * into l from public.leads where id = p_lead_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such lead'); end if;
  if p_event !~ '^[a-z_]{3,40}$' then return jsonb_build_object('ok', false, 'reason', 'bad event'); end if;
  prev := current_setting('wpie.in_belt_event', true);
  perform set_config('wpie.in_belt_event', '1', true);
  who := public.belt_actor(p_by);
  -- an outside event the card already took (a synced text, a WPIE record): once
  if pl ? 'key' and exists (select 1 from public.belt_events e where e.lead_id = p_lead_id and e.payload->>'key' = pl->>'key') then
    perform set_config('wpie.in_belt_event', coalesce(prev, ''), true);
    return jsonb_build_object('ok', true, 'belt', l.belt, 'step', l.belt_step, 'duplicate', true);
  end if;
  if pl ? 'said' and nullif(btrim(pl->>'said'), '') is not null then
    update public.leads set belt_reference = left(btrim(pl->>'said'), 300) where id = p_lead_id;
  end if;
  if pl ? 'named_date' and nullif(pl->>'named_date', '') is not null then
    begin nd := (pl->>'named_date')::timestamptz; exception when others then nd := null; end;
    if nd is not null then update public.leads set named_date = nd, named_event = coalesce(nullif(pl->>'named_event', ''), named_event) where id = p_lead_id; end if;
  elsif pl ? 'named_event' and nullif(pl->>'named_event', '') is not null then
    update public.leads set named_event = left(pl->>'named_event', 200) where id = p_lead_id;
  end if;
  select * into l from public.leads where id = p_lead_id;

  case p_event
  -- ---------------------------------------------------------------- the end of the line
  when 'stop', 'dnc' then
    res := public.belt_enter(p_lead_id, 'dnc', 0, p_event, pl, who, p_now);
  when 'flag' then
    update public.leads set elderly_or_ill = coalesce((pl->>'elderly_or_ill')::boolean, elderly_or_ill),
                            grief = coalesce((pl->>'grief')::boolean, grief) where id = p_lead_id;
    select * into l from public.leads where id = p_lead_id;
    if (l.elderly_or_ill or l.grief) and l.belt not in ('dead', 'dnc') then
      -- every pending agent text is cancelled; Colin only, by phone, at their pace
      res := public.belt_enter(p_lead_id, 'elderly', 1, 'flag', pl, who, p_now);
    else
      insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by) values (p_lead_id, 'flag', l.belt, l.belt, l.belt_step, pl, p_now, who);
      res := jsonb_build_object('ok', true, 'belt', l.belt, 'step', l.belt_step, 'next_stop_at', l.next_stop_at);
    end if;
  when 'move' then
    b := pl->>'belt';
    if b is null or not exists (select 1 from public.belt_rules where belt = b) then
      res := jsonb_build_object('ok', false, 'reason', 'pick a belt');
    else
      res := public.belt_enter(p_lead_id, b, coalesce((pl->>'step')::integer, 1), 'move', pl, who, p_now);
    end if;
  -- ---------------------------------------------------------------- they wrote
  when 'inbound_text' then
    update public.leads set unanswered_count = 0 where id = p_lead_id;
    perform public.belt_cancel_pending(p_lead_id, 'they texted', p_now);
    o := coalesce(pl->>'outcome', ''); b := coalesce(pl->>'intent', '');
    if coalesce((pl->>'removal')::boolean, false) or o = 'dnc' or b in ('opt_out', 'hostile') then
      res := public.belt_enter(p_lead_id, 'dnc', 0, 'inbound_text', pl, who, p_now);
    elsif coalesce(pl->>'kind', '') = 'after_close' then
      insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by) values (p_lead_id, 'inbound_text', l.belt, l.belt, l.belt_step, pl || '{"note":"after the thread was closed: nothing moves"}', p_now, who);
      res := jsonb_build_object('ok', true, 'belt', l.belt, 'step', l.belt_step, 'next_stop_at', l.next_stop_at);
    elsif o = 'wrong_number' or b = 'wrong_number' then
      update public.leads set belt = null, belt_step = 0, next_stop_at = null, next_stop_who = null, next_stop_say = null,
             stage = case when stage in ('dnc', 'closed_won', 'under_contract') or public.card_has_live_phone(p_lead_id) then stage else 'data_fix' end where id = p_lead_id;  -- 0312
      insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by) values (p_lead_id, 'inbound_text', l.belt, null, 0, pl, p_now, who);
      res := jsonb_build_object('ok', true, 'belt', null, 'reason', 'wrong number: WPIE re-plans the next mobile');
    elsif o = 'not_interested' or (o <> 'open' and b in ('sold', 'signed_other', 'my_home', 'tenant', 'manager', 'middleman', 'burned', 'annoyed', 'joke_number')) then
      res := public.belt_enter(p_lead_id, 'dead', 0, 'inbound_text', pl || jsonb_build_object('reason', coalesce(nullif(b, ''), o)), who, p_now);
    elsif b = 'not_interested' and position('own anything else' in coalesce(pl->>'reply', '')) > 0 then
      -- a no that got the one exit question (outcome open): the card is dead now, not "replied, went quiet"
      -- (2026-10-24: belt nudges were drafted to six people who had said no). An answer to the exit question that
      -- names another property arrives as a new text and moves the card again.
      res := public.belt_enter(p_lead_id, 'dead', 0, 'inbound_text', pl || jsonb_build_object('reason', 'not interested (exit question asked)'), who, p_now);
    -- 0279: a seller who texts that it is listed is still a lead (Colin 2026-11-22: "We can still buy listed stuff"):
    -- no branch of its own, so the text moves the card like any other reply (replied, the caller's call)
    elsif l.belt = 'not_now_dated' and l.named_date is not null and l.named_date > p_now
          and not (coalesce((pl->>'interest')::boolean, false) or b in ('interested', 'wants_call', 'price_first', 'number_only', 'worth', 'terms')
                   or coalesce(pl->>'agent_stage', '') = 'book' or coalesce(pl->>'thread_outcome', '') = 'handoff'
                   or coalesce(pl->>'callback_slot', pl->'facts'->>'callback_slot', '') <> '') then
      -- they gave a date and this text is not interest (0229: "I will", "thanks", "who are you?", another "not yet"): the
      -- date stands. Before, any such text restarted the follow-ups or sent the card dormant, and the caller's call on
      -- the date was lost (Jeri Weger, 2026-11-13: check back in February, then "I will" put a call on for next week).
      res := public.belt_enter(p_lead_id, 'not_now_dated', 1, 'inbound_text',
               pl || '{"note":"the date they gave stands: this text does not restart the follow-ups"}'::jsonb, who, p_now);
    elsif coalesce((pl->'facts'->>'nurture')::boolean, false) then
      update public.leads set named_event = coalesce(nullif(left(pl->'facts'->>'condition', 200), ''), nullif(left(pl->>'said', 200), ''), named_event) where id = p_lead_id;
      res := public.belt_enter(p_lead_id, 'not_now_condition', 1, 'inbound_text', pl, who, p_now);
    elsif b = 'not_now' then
      res := public.belt_enter(p_lead_id, 'dormant', 1, 'inbound_text', pl, who, p_now);
    elsif b in ('who_is_this', 'bot_question') then
      -- a question about us, answered plainly: no nudge at all (Rick: texting a ghost only shows your cards)
      res := public.belt_enter(p_lead_id, 'dormant', 1, 'inbound_text', pl || '{"note":"no nudge: asked who we are"}', who, p_now);
    else
      slot := null;
      if coalesce(pl->>'callback_slot', pl->'facts'->>'callback_slot', '') <> '' then
        begin slot := (coalesce(pl->>'callback_slot', pl->'facts'->>'callback_slot'))::timestamptz; exception when others then slot := null; end;
      end if;
      if slot is not null and slot > p_now then
        update public.leads set named_date = slot, named_event = 'call' where id = p_lead_id;
        res := public.belt_enter(p_lead_id, 'call_booked', 1, 'inbound_text', pl, who, p_now);
      elsif coalesce((pl->>'interest')::boolean, false) or b in ('interested', 'wants_call', 'price_first', 'number_only', 'worth', 'terms')
            or coalesce(pl->>'agent_stage', '') = 'book' or coalesce(pl->>'thread_outcome', '') = 'handoff' then
        res := public.belt_enter(p_lead_id, 'yes_unbooked', 1, 'inbound_text', pl, who, p_now);
      elsif l.belt = 'yes_unbooked' then
        -- 0244: they said yes and nobody has reached them: a text that is not a no keeps the caller's call on, now
        res := public.belt_enter(p_lead_id, 'yes_unbooked', 1, 'inbound_text',
                 pl || '{"note":"said yes and not reached yet: the call stays on"}'::jsonb, who, p_now);
        update public.tasks set notified_at = null
         where lead_id = p_lead_id and source = 'belt' and kind = 'call' and done_at is null
           and notified_at is not null and notified_at < p_now - interval '30 minutes';
      else
        select count(*) into prior from public.twilio_inbound t where t.lead_id = p_lead_id and t.received_at < coalesce((pl->>'at')::timestamptz, p_now);
        res := public.belt_enter(p_lead_id, case when prior > 0 or coalesce(pl->>'agent_stage', '') = 'qualify' or l.belt = 'questions_quiet' then 'questions_quiet' else 'replied_quiet' end,
                 1, 'inbound_text', pl, who, p_now);
      end if;
    end if;
  when 'hot_reply' then
    update public.leads set unanswered_count = 0 where id = p_lead_id;
    res := public.belt_enter(p_lead_id, 'yes_unbooked', 1, 'hot_reply', pl, who, p_now);
  when 'human_text' then
    -- a person wrote in the thread: the pending automatic text is off; the card keeps its belt and step
    update public.reply_drafts set status = 'superseded', note = coalesce(note, '') || ' | a person texted', updated_at = p_now
     where lead_id = p_lead_id and kind = 'belt' and status in ('queued', 'awaiting_approval', 'would_send');
    insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by) values (p_lead_id, 'human_text', l.belt, l.belt, l.belt_step, pl, p_now, who);
    if l.next_stop_who in ('auto_text', 'draft_text') and l.belt is not null then
      res := public.belt_enter(p_lead_id, l.belt, l.belt_step + 1, 'human_text', pl - 'key', who, p_now);
    else
      res := jsonb_build_object('ok', true, 'belt', l.belt, 'step', l.belt_step, 'next_stop_at', l.next_stop_at);
    end if;
  -- ---------------------------------------------------------------- a call was logged
  when 'call_logged' then
    o := coalesce(pl->>'outcome', '');
    if o = 'dnc' then res := public.belt_enter(p_lead_id, 'dnc', 0, 'call_logged', pl, who, p_now);
    elsif o = 'not_interested' then res := public.belt_enter(p_lead_id, 'dead', 0, 'call_logged', pl || jsonb_build_object('reason', coalesce(nullif(pl->>'note', ''), 'Not interested (call)')), who, p_now);
    elsif o = 'wrong_number' then
      update public.leads set belt = null, belt_step = 0, next_stop_at = null, next_stop_who = null, next_stop_say = null,
             stage = case when stage in ('dnc', 'closed_won', 'under_contract') or public.card_has_live_phone(p_lead_id) then stage else 'data_fix' end where id = p_lead_id;  -- 0312
      insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by) values (p_lead_id, 'call_logged', l.belt, null, 0, pl, p_now, who);
      res := jsonb_build_object('ok', true, 'belt', null);
    elsif o = 'not_now' then
      if l.named_date is not null and l.named_date > p_now then res := public.belt_enter(p_lead_id, 'not_now_dated', 1, 'call_logged', pl, who, p_now);
      else res := public.belt_enter(p_lead_id, 'not_now_condition', 1, 'call_logged', pl, who, p_now); end if;
    elsif o = 'interested' then
      if (l.stage in ('walkthrough_booked', 'offer', 'under_contract', 'closed_won') and l.belt in ('visit_booked', 'offer_out'))
         or (l.belt = 'call_booked' and l.next_stop_at > p_now) then
        res := jsonb_build_object('ok', true, 'belt', l.belt, 'step', l.belt_step, 'next_stop_at', l.next_stop_at);
        insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by) values (p_lead_id, 'call_logged', l.belt, l.belt, l.belt_step, pl, p_now, who);
      else res := public.belt_enter(p_lead_id, 'yes_unbooked', 1, 'call_logged', pl, who, p_now); end if;
    elsif o = 'reached_no_decision' then
      if l.belt = 'call_booked' and l.next_stop_at > p_now then
        res := jsonb_build_object('ok', true, 'belt', l.belt, 'step', l.belt_step, 'next_stop_at', l.next_stop_at);
        insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by) values (p_lead_id, 'call_logged', l.belt, l.belt, l.belt_step, pl, p_now, who);
      else res := public.belt_enter(p_lead_id, 'after_call_quiet', 1, 'call_logged', pl, who, p_now); end if;
    elsif o = 'no_answer' then
      res := public.belt_route_no_answer(p_lead_id, pl, who, p_now, p_event);
    else
      res := jsonb_build_object('ok', false, 'reason', 'unknown call outcome ' || o);
    end if;
  when 'next_step' then
    begin slot := (pl->>'at')::timestamptz; exception when others then slot := null; end;
    if slot is null then res := jsonb_build_object('ok', false, 'reason', 'a day and time');
    else
      update public.leads set named_date = slot, named_event = case when pl->>'kind' = 'walk' then 'visit' else 'call' end where id = p_lead_id;
      res := public.belt_enter(p_lead_id, case when pl->>'kind' = 'walk' then 'visit_booked' else 'call_booked' end, 1, 'next_step', pl, who, p_now);
    end if;
  when 'verdict_no' then
    reason := coalesce(pl->>'reason', '');
    if reason in ('dnc', 'removed') then res := public.belt_enter(p_lead_id, 'dnc', 0, 'verdict_no', pl, who, p_now);
    elsif reason in ('listed', 'signed_other', 'market_firm') then res := public.belt_enter(p_lead_id, 'too_high_or_listed', 0, 'verdict_no', pl, who, p_now);
    elsif reason = 'elderly_no_family' then res := public.belt_enter(p_lead_id, 'elderly', 1, 'verdict_no', pl, who, p_now);
    elsif reason = 'estate_no_signer' then res := public.belt_enter(p_lead_id, 'estate_waiting', 1, 'verdict_no', pl, who, p_now);
    elsif reason = 'spouse' then res := public.belt_enter(p_lead_id, 'needs_family', 1, 'verdict_no', pl, who, p_now);
    else res := public.belt_enter(p_lead_id, 'dead', 0, 'verdict_no', pl || jsonb_build_object('reason', coalesce(nullif(reason, ''), 'the card said do not book')), who, p_now); end if;
  -- ---------------------------------------------------------------- a stop was logged
  when 'stop_done' then
    o := coalesce(pl->>'outcome', 'done');
    if o = 'dnc' then res := public.belt_enter(p_lead_id, 'dnc', 0, 'stop_done', pl, who, p_now);
    elsif o = 'no' then res := public.belt_enter(p_lead_id, 'dead', 0, 'stop_done', pl || jsonb_build_object('reason', coalesce(nullif(pl->>'note', ''), 'said no on the call')), who, p_now);
    elsif o = 'wrong_number' then res := public.belt_event(p_lead_id, 'call_logged', pl, who, p_now);
    elsif o = 'booked' then
      begin slot := (pl->>'at')::timestamptz; exception when others then slot := null; end;
      if slot is null then res := jsonb_build_object('ok', false, 'reason', 'a day and time');
      else res := public.belt_event(p_lead_id, 'next_step', jsonb_build_object('kind', coalesce(pl->>'kind', 'callback'), 'at', slot), who, p_now); end if;
    elsif o = 'not_now' then
      if nd is not null and nd > p_now then res := public.belt_enter(p_lead_id, 'not_now_dated', 1, 'stop_done', pl, who, p_now);
      elsif nullif(pl->>'named_event', '') is not null then res := public.belt_enter(p_lead_id, 'not_now_condition', 1, 'stop_done', pl, who, p_now);
      else res := public.belt_enter(p_lead_id, 'dormant', 1, 'stop_done', pl, who, p_now); end if;
    elsif o in ('family', 'elderly', 'estate', 'hold', 'too_high', 'listed', 'offer_out') then
      b := case o when 'family' then 'needs_family' when 'elderly' then 'elderly' when 'estate' then 'estate_waiting' when 'hold' then 'hold_not_now'
                  when 'offer_out' then 'offer_out' else 'too_high_or_listed' end;
      if o = 'elderly' then update public.leads set elderly_or_ill = true where id = p_lead_id; end if;
      res := public.belt_enter(p_lead_id, b, 1, 'stop_done', pl, who, p_now);
    elsif o in ('reached', 'reached_no_decision') then
      update public.leads set unanswered_count = 0 where id = p_lead_id;
      if l.belt = 'cold_texts' then res := public.belt_enter(p_lead_id, 'yes_unbooked', 1, 'stop_done', pl, who, p_now);
      elsif l.belt = 'visit_booked' and l.belt_step = 2 then res := public.belt_enter(p_lead_id, 'after_visit_quiet', 1, 'stop_done', pl, who, p_now);
      else res := public.belt_enter(p_lead_id, 'after_call_quiet', 1, 'stop_done', pl, who, p_now); end if;
    elsif o in ('no_answer', 'voicemail') then
      res := public.belt_route_no_answer(p_lead_id, pl, who, p_now, p_event);
    elsif o = 'sent' then      -- a draft stop went out: next stop, counts as a touch with no reply yet
      update public.leads set unanswered_count = unanswered_count + 1 where id = p_lead_id and belt is not null;
      res := public.belt_enter(p_lead_id, coalesce(l.belt, 'dormant'), l.belt_step + 1, 'stop_done', pl, who, p_now);
      if l.belt = 'dormant' then update public.leads set dormant_round = least(dormant_round + 1, 3) where id = p_lead_id; end if;
    else                       -- 'done' / 'skipped': the next stop on the ladder, not counted against them
      if l.belt is null then res := jsonb_build_object('ok', true, 'belt', null);
      else res := public.belt_enter(p_lead_id, l.belt, l.belt_step + 1, 'stop_done', pl, who, p_now); end if;
      if l.belt = 'dormant' and o = 'skipped' then update public.leads set dormant_round = least(dormant_round + 1, 3) where id = p_lead_id; end if;
    end if;
  when 'auto_text_sent' then
    update public.leads set unanswered_count = unanswered_count + 1 where id = p_lead_id;
    if l.belt is null then res := jsonb_build_object('ok', true, 'belt', null);
    else res := public.belt_enter(p_lead_id, l.belt, l.belt_step + 1, 'auto_text_sent', pl, who, p_now); end if;
  when 'draft_sent' then
    res := public.belt_event(p_lead_id, 'stop_done', pl || '{"outcome":"sent"}', who, p_now);
  when 'draft_skipped' then
    res := public.belt_event(p_lead_id, 'stop_done', pl || '{"outcome":"skipped"}', who, p_now);
  when 'stop_missed' then
    -- a text stop that never went counts as unanswered; a call stop is re-slid once, then counts
    if l.next_stop_who in ('auto_text', 'draft_text') then
      update public.leads set unanswered_count = unanswered_count + 1 where id = p_lead_id;
      res := public.belt_enter(p_lead_id, l.belt, l.belt_step + 1, 'stop_missed', pl, who, p_now);
    elsif coalesce((pl->>'again')::boolean, false) then
      update public.leads set unanswered_count = unanswered_count + 1 where id = p_lead_id;
      res := public.belt_enter(p_lead_id, l.belt, l.belt_step + 1, 'stop_missed', pl, who, p_now);
    else
      res := public.belt_enter(p_lead_id, l.belt, l.belt_step, 'stop_missed', pl || '{"reslid":true}', who, p_now);
    end if;
  -- ---------------------------------------------------------------- the laptop
  when 'cold_text' then
    st := coalesce((pl->>'step')::integer, 1);
    if l.belt is null or l.belt = 'cold_texts' then
      update public.leads set belt = 'cold_texts', belt_step = st, belt_round = greatest(belt_round, 1),
             belt_entered_at = coalesce(belt_entered_at, p_now),
             next_stop_at = nullif(pl->>'next_at', '')::timestamptz,
             next_stop_who = case when nullif(pl->>'next_at', '') is null then null when st >= 5 then 'thalia_call' else 'auto_text' end,
             next_stop_say = case when st >= 5 then 'Never answered five texts; one call from the daily list' else format('Text %s goes on its own (WPIE)', st + 1) end,
             next_action = case when nullif(pl->>'next_at', '') is null then next_action else 'Cold texts (WPIE)' end,
             next_action_at = coalesce(nullif(pl->>'next_at', '')::timestamptz, next_action_at)
       where id = p_lead_id;
      insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by) values (p_lead_id, 'cold_text', l.belt, 'cold_texts', st, pl, p_now, who);
    else
      insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by) values (p_lead_id, 'cold_text', l.belt, l.belt, l.belt_step, pl || '{"ignored":"already past cold texts"}', p_now, who);
    end if;
    select * into l from public.leads where id = p_lead_id;
    res := jsonb_build_object('ok', true, 'belt', l.belt, 'step', l.belt_step, 'next_stop_at', l.next_stop_at);
  when 'wpie_event' then
    -- a new public record on a resting card: one call from Colin that references the earlier conversation, never the record
    if l.belt in ('dormant', 'too_high_or_listed', 'hold_not_now') or (l.belt = 'dead' and l.belt_entered_at < p_now - interval '90 days'
         and coalesce(l.dead_reason, '') not in ('Not interested (call)', 'not_interested', 'no_contact', 'said no on the call')) then
      update public.leads set belt_reference = coalesce(belt_reference, 'we spoke before') where id = p_lead_id;
      res := public.belt_enter(p_lead_id, 'after_call_quiet', 1, 'wpie_event',
               pl || jsonb_build_object('say', 'Re-entry: we spoke before about the place; checking in as I said I would. Never mention the record.'), who, p_now);
      update public.leads set next_stop_say = 'We spoke before about ' || public.belt_street(property_address) || '; checking in as I said I would (never mention the record)' where id = p_lead_id;
      update public.tasks set note = 'Re-entry after a new public record. Say: we spoke before about ' || public.belt_street(l.property_address) || '; checking in as I said I would. Never mention the record itself.'
       where lead_id = p_lead_id and source = 'belt' and done_at is null;
    else
      insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by) values (p_lead_id, 'wpie_event', l.belt, l.belt, l.belt_step, pl || '{"note":"card is live or closed: no re-entry"}', p_now, who);
      res := jsonb_build_object('ok', true, 'belt', l.belt, 'step', l.belt_step, 'next_stop_at', l.next_stop_at);
    end if;
  when 'named_date' then
    if l.belt in ('not_now_dated', 'elderly', 'estate_waiting', 'hold_not_now', 'needs_family') then
      res := public.belt_enter(p_lead_id, l.belt, 1, 'named_date', pl, who, p_now);
    elsif nd is not null then res := public.belt_enter(p_lead_id, 'not_now_dated', 1, 'named_date', pl, who, p_now);
    else res := jsonb_build_object('ok', false, 'reason', 'a date'); end if;
  when 'stage_changed' then
    -- a stage written outside the belt (a legacy path): keep the belt honest
    b := pl->>'to';
    if b = 'dnc' then res := public.belt_enter(p_lead_id, 'dnc', 0, 'stage_changed', pl, who, p_now);
    elsif b = 'dead' then res := public.belt_enter(p_lead_id, 'dead', 0, 'stage_changed', pl, who, p_now);
    elsif b = 'closed_no_contact' then res := public.belt_enter(p_lead_id, 'dead', 0, 'stage_changed', pl || '{"reason":"no_contact"}', who, p_now);
    elsif b = 'walkthrough_booked' and l.belt is distinct from 'visit_booked' then res := public.belt_enter(p_lead_id, 'visit_booked', 1, 'stage_changed', pl, who, p_now);
    elsif b = 'colin_call' and l.belt not in ('call_booked', 'call_missed', 'yes_unbooked') then res := public.belt_enter(p_lead_id, 'yes_unbooked', 1, 'stage_changed', pl, who, p_now);
    elsif b = 'offer' and l.belt is distinct from 'offer_out' then res := public.belt_enter(p_lead_id, 'offer_out', 1, 'stage_changed', pl, who, p_now);
    elsif b = 'follow_up' and l.belt is null then res := public.belt_enter(p_lead_id, 'not_now_condition', 1, 'stage_changed', pl, who, p_now);
    elsif b in ('reply_received', 'ai_qualifying', 'handoff') and l.belt is null then
      res := public.belt_enter(p_lead_id, case b when 'handoff' then 'yes_unbooked' when 'ai_qualifying' then 'questions_quiet' else 'replied_quiet' end, 1, 'stage_changed', pl, who, p_now);
    else
      insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by) values (p_lead_id, 'stage_changed', l.belt, l.belt, l.belt_step, pl, p_now, who);
      res := jsonb_build_object('ok', true, 'belt', l.belt, 'step', l.belt_step, 'next_stop_at', l.next_stop_at);
    end if;
  else
    res := jsonb_build_object('ok', false, 'reason', 'unknown event ' || p_event);
  end case;
  perform set_config('wpie.in_belt_event', coalesce(prev, ''), true);
  return res;
end $function$;

CREATE OR REPLACE FUNCTION public.reply_record_decision(p_sid text, p_intent text, p_kind text, p_removal boolean, p_outcome text, p_body text, p_draft_source text, p_note text, p_rules_version text, p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  t public.twilio_inbound;
  c public.campaign_control;
  st text;
  did uuid;
  owner_phones text[];
  oid bigint;
  who text;
  removal boolean := p_removal;
begin
  select * into t from public.twilio_inbound where sid = p_sid;
  if not found then return jsonb_build_object('ok', false, 'reason', 'unknown_inbound'); end if;
  select * into c from public.campaign_control where id = 1;
  update public.reply_drafts set status = 'superseded', updated_at = p_now
   where phone10 = t.from10 and status in ('awaiting_approval', 'would_send', 'queued') and inbound_at < t.received_at;

  who := public.caller_texting(t.lead_id);
  if who is not null then
    -- a caller has texted this card: the AI is off it for good (Colin 2026-11-07). Nothing is queued or sent by the
    -- reply agent; a suggested line is kept for the caller to see. A STOP is still law; a 'hostile' read is not.
    if removal and p_intent <> 'opt_out' then removal := false; end if;
  end if;
  st := case
    when who is not null then case when p_kind = 'candidate' or coalesce(btrim(p_body), '') <> '' then 'awaiting_approval' else 'no_reply' end
    -- the sender agent answers (agent_runs_texting): read, recorded, nothing queued and nothing for the team to approve
    when c.agent_runs_texting then 'no_reply'
    when p_body is null or btrim(p_body) = '' then case when p_kind = 'candidate' then 'awaiting_approval' else 'no_reply' end
    when p_kind = 'candidate' then 'awaiting_approval'
    when c.routine_enabled then 'queued'
    else 'would_send' end;
  insert into public.reply_drafts (inbound_sid, phone10, our_number, lead_id, inbound_body, inbound_at, intent, kind, outcome,
                                   note, body, draft_source, status, send_after, rules_version, created_at, updated_at)
  values (t.sid, t.from10, t.to_number, t.lead_id, t.body, t.received_at, p_intent, p_kind, p_outcome, p_note,
          nullif(btrim(coalesce(p_body, '')), ''), p_draft_source, st,
          case when st = 'queued' then public.auto_reply_at(p_now) else null end,
          p_rules_version, p_now, p_now)
  on conflict (inbound_sid) do nothing
  returning id into did;
  if did is null then return jsonb_build_object('ok', false, 'reason', 'already_decided'); end if;

  oid := (select l.wpie_owner_id from public.leads l where l.id = t.lead_id);
  if removal and p_outcome = 'wrong_number' then
    -- not the owner, asked to stop: this phone only; the card stays open for the owner's other numbers
    perform public.block_wrong_person_phone(t.lead_id, t.from10, 'reply_agent');
    update public.leads set stage = 'data_fix' where id = t.lead_id and stage in ('postcard_mailed', 'opener_queued', 'opener_sent', 'reply_received')
         and not public.card_has_live_phone(t.lead_id);   -- 0312: other numbers left to try
  elsif removal then
    select coalesce(array_agg(distinct ct.value_normalized), '{}') into owner_phones
      from public.contacts ct join public.leads l on l.id = ct.lead_id
     where ct.kind = 'phone' and ct.value_normalized is not null and (ct.value_normalized = t.from10 or l.wpie_owner_id = oid);
    owner_phones := array_append(owner_phones, t.from10);
    insert into public.suppressed_phones (phone10, reason, source)
      select distinct p, case when p = t.from10 then 'removal_reply' else 'removal_reply_other_phone' end, 'reply_agent'
        from unnest(owner_phones) p where p ~ '^[0-9]{10}$'
    on conflict (phone10) do nothing;
    update public.contacts set suppressed = true where value_normalized = any(owner_phones);
    update public.leads set stage = 'dnc' where id = t.lead_id;
  elsif p_outcome = 'wrong_number' then
    update public.contacts set status = 'bad', note = coalesce(note || '; ', '') || 'wrong number (reply agent)'
     where value_normalized = t.from10 and lead_id = t.lead_id;
    update public.leads set stage = 'data_fix' where id = t.lead_id and stage in ('postcard_mailed', 'opener_queued', 'opener_sent', 'reply_received')
         and not public.card_has_live_phone(t.lead_id);   -- 0312: other numbers left to try
  elsif who is not null and p_removal and not removal then
    null;   -- the caller decides what a hostile text means
  elsif p_outcome = 'not_interested' then
    update public.leads set stage = 'dead', dead_reason = coalesce(nullif(p_note, ''), 'not interested')
     where id = t.lead_id and stage in ('postcard_mailed', 'opener_queued', 'opener_sent', 'reply_received', 'ai_qualifying');
  else
    update public.leads set stage = case when p_kind = 'candidate' then 'reply_received'::public.lead_stage else 'ai_qualifying'::public.lead_stage end
     where id = t.lead_id and stage in ('postcard_mailed', 'opener_queued', 'opener_sent');
  end if;
  update public.leads set last_inbound_at = greatest(coalesce(last_inbound_at, t.received_at), t.received_at) where id = t.lead_id;
  return jsonb_build_object('ok', true, 'id', did, 'status', st);
end $function$;

-- the cards a wrong number parked with numbers left: back to where a card with numbers belongs
create table if not exists public.leads_before_0312 as select id, stage, stage_changed_at from public.leads where false;
with back as (
  select l.id, case when exists (select 1 from public.messages m where m.lead_id = l.id and m.channel = 'sms' and m.direction = 'out'
                                    and m.provider_sid is not null) then 'opener_sent' else 'opener_queued' end as to_stage
    from public.leads l
   where l.stage = 'data_fix' and public.card_has_live_phone(l.id)
     and exists (select 1 from public.messages m where m.lead_id = l.id and m.channel = 'call' and m.status = 'wrong_number')
     and not exists (select 1 from public.messages m where m.lead_id = l.id and m.channel = 'call'
                       and coalesce(m.status, '') not in ('no_answer', 'voicemail', 'inbound_missed', 'missed', 'busy', 'failed', 'canceled', 'blocked', 'wrong_number')
                       and coalesce(m.status, '') not like 'inbound%')
     and not exists (select 1 from public.messages m where m.lead_id = l.id and m.channel = 'sms' and m.direction = 'in')),
saved as (insert into public.leads_before_0312 (id, stage, stage_changed_at)
          select l.id, l.stage, l.stage_changed_at from public.leads l join back on back.id = l.id returning id)
update public.leads l set stage = back.to_stage::public.lead_stage from back where back.id = l.id;
