-- 0313: a number the phone company says is not in service is marked bad by itself, and a recorded call is not a reach.
--
-- Colin 2026-11-23, asked for a free way to find bad numbers: "Yes if it works". Calls are recorded from the moment
-- they are answered (pm-phone, record-from-answer-dual), and a carrier that answers a dead number to play its message
-- ("the number you have dialed is not in service") is a completed call of 15-30 seconds, so the message is in the
-- recording, and call-notes writes its words to call_transcripts. When the seller's side of an outbound call is that
-- message, the dialed number is marked bad on every card that holds it (the same as a text bounce on a dead number,
-- 0071), and a card left with no number to try goes to data_fix (0312's rule). A voicemail greeting ("is not
-- available", "leave a message") is not that message and changes nothing.
--
-- And the second leak the same reading found: call_notes_save writes the call onto the card as a message with status
-- call_notes (inbound_call_notes), and every "reached" test counted that as a person reached. With voicemails now
-- recorded, each one would have taken its card out of the texted-and-silent queue, ended its texts and kept it off the
-- ranked list for two weeks. The caller's own logged outcome is what says someone was reached; the notes are not.

create or replace function public.words_say_not_in_service(p_words text) returns boolean
language sql immutable set search_path = public as $fn$
  -- the seller's side of the call ("Seller: ..." lines from call-notes); all of it when the lines carry no label
  with w as (
    select lower(coalesce(nullif(array_to_string(array(
             select regexp_replace(x, '^\s*seller:\s*', '', 'i') from regexp_split_to_table(coalesce(p_words, ''), E'\n') x
              where x ~* '^\s*seller:'), ' '), ''), coalesce(p_words, ''))) as t)
  select t ~ '(not|no longer) in service|not a working number|non-?working number|has been disconnected|is disconnected|(cannot|could not|can ?not) be completed as dialed|check the number and (dial|try) again|number you (have )?(dialed|reached|called) (is|has) (not|been)'
     and t !~ '\m(leave|record) (a|your) (message|name)\M'
    from w
$fn$;

create or replace function public.call_transcript_not_in_service() returns trigger
language plpgsql security definer set search_path = public as $fn$
declare r public.call_recordings; lid uuid;
begin
  select * into r from public.call_recordings where call_sid = new.call_sid;
  if not found or r.direction <> 'out' or coalesce(r.phone10, '') !~ '^[0-9]{10}$' then return new; end if;
  if not public.words_say_not_in_service(new.words) then return new; end if;
  update public.contacts set status = 'bad',
         note = concat_ws('; ', note, 'not in service (the phone company said so on a call, ' || to_char(now() at time zone 'America/Chicago', 'YYYY-MM-DD') || ')')
   where kind = 'phone' and value_normalized = r.phone10 and status = 'ok';
  -- a card with no number left to try is a re-trace (0312), whatever stage a dial had left it in
  for lid in select distinct c.lead_id from public.contacts c where c.kind = 'phone' and c.value_normalized = r.phone10 loop
    update public.leads set stage = 'data_fix'
     where id = lid and stage::text in ('postcard_mailed', 'opener_queued', 'opener_sent', 'reply_received', 'follow_up')
       and not public.card_has_live_phone(lid);
  end loop;
  -- no message of its own: a call message would count in the dial rules and close the caller's list task; the call's
  -- own notes say what was heard, and the phone's note says why it is bad
  return new;
end $fn$;

drop trigger if exists call_transcripts_not_in_service on public.call_transcripts;
create trigger call_transcripts_not_in_service after insert or update of words on public.call_transcripts
  for each row execute function public.call_transcript_not_in_service();

-- ---------------------------------------------------------------- a recorded call is not a reach (recreated from live)
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
                         and coalesce(m.status, '') not in ('no_answer', 'voicemail', 'inbound_missed', 'missed', 'busy', 'failed', 'canceled', 'blocked', 'wrong_number', 'call_notes', 'inbound_call_notes'))
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
        'call_reached', exists (select 1 from public.messages m where m.lead_id = l.id and m.channel = 'call' and coalesce(m.status, '') not in ('no_answer', 'voicemail', 'inbound_missed', 'missed', 'busy', 'failed', 'canceled', 'blocked', 'wrong_number', 'call_notes', 'inbound_call_notes')),
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
     where m.channel = 'call' and coalesce(m.status, '') not in ('no_answer', 'voicemail', 'inbound_missed', 'missed', 'busy', 'failed', 'canceled', 'blocked', 'wrong_number', 'call_notes', 'inbound_call_notes')),
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
                          and coalesce(mm.status, '') not in ('no_answer', 'voicemail', 'inbound_missed', 'missed', 'busy', 'failed', 'canceled', 'blocked', 'wrong_number', 'call_notes', 'inbound_call_notes')
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

CREATE OR REPLACE FUNCTION public.power_lists_morning(p_now timestamp with time zone DEFAULT now(), p_force boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
                            and coalesce(mm.status, '') not in ('no_answer', 'voicemail', 'inbound_missed', 'missed', 'busy', 'failed', 'canceled', 'blocked', 'wrong_number', 'call_notes', 'inbound_call_notes')
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
end $function$;
