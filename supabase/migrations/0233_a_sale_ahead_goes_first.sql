-- 0233: a sale ahead goes first, by itself.
--
-- Colin 2026-11-14, after he had to say "call these four today" and "text em too": "This should be an automatic thing
-- though we shouldn't have had to make this decision, always we should have people with foreclosure sales coming soon
-- and with equity up top of the list ... The program should automatically give him new calls to do and his followups
-- at the correct time."
--
--   1. card_sale_dates: one sale date per card. The laptop's record when it has one (it follows adjournments), else
--      the date written in the card's reasons (the agents' cards have no laptop record).
--   2. Power hour: a card whose sale is 14 or more days out, and not thin or underwater, is on its caller's list
--      with no task, right behind sellers who called or wrote; known equity first, then the soonest sale. It stays
--      until someone is reached. A sale inside 14 days, or past, is never dialed from a list (the 14-day rule was
--      only words in a task title). A follow-up that is due now comes before the caller's list cards: it sat
--      behind some 190 hand-loaded cards and was never reached.
--   3. Texts: a sale ahead is the first of the day's first texts; the 14-day block reads every card's sale date.
--   4. An agent cannot park a card with a sale ahead on a hold.

create or replace function public.sale_date_in(p_reason text)
returns date language plpgsql stable set search_path = public as $$
declare s text;
begin
  if p_reason is null or p_reason !~* 'sheriff sale' then return null; end if;
  s := substring(p_reason from '(?i)sheriff sale[^0-9]{0,6}(\d{4}-\d{2}-\d{2})');
  if s is not null then return s::date; end if;
  s := substring(p_reason from '(?i)sheriff sale (?:[a-z]{3},? )?([a-z]{3} \d{1,2}, \d{4})');
  if s is not null then return to_date(s, 'Mon DD, YYYY'); end if;
  return null;
exception when others then return null;
end $$;

create or replace view public.card_sale_dates as
select l.id as lead_id, coalesce(f.sale_date, p.sale_date) as sale_date,
       coalesce(f.equity, e.equity_grade, 'unknown') as equity
  from public.leads l
  left join public.text_fitness f on f.wpie_owner_id = l.wpie_owner_id and l.wpie_owner_id > 0
  left join public.equity_inputs e on e.lead_id = l.id
  left join lateral (select max(public.sale_date_in(x)) as sale_date from unnest(l.reasons_to_sell) x where x ~* 'sheriff sale') p on true
 where coalesce(f.sale_date, p.sale_date) is not null;
revoke all on public.card_sale_dates from anon, authenticated;

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
     where m.channel = 'call' and coalesce(m.status, '') not in ('no_answer', 'voicemail', 'inbound_missed', 'missed', 'busy', 'failed', 'canceled', 'blocked')),
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

CREATE OR REPLACE FUNCTION public.text_pool(p_now timestamp with time zone DEFAULT now())
 RETURNS TABLE(lead_id uuid, kind text, step integer, phone text, tier text, need_why text, due_day date, block text, ord bigint)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with d as (select (p_now at time zone 'America/Chicago')::date as day),
  firsts as (
    select l.id, l.stacked_at, l.created_at, ph.phone,
           coalesce(f.tier, m.tier) as tier, coalesce(f.equity, e.equity_grade) as equity, sd.sale_date,
           coalesce(sd.sale_date >= d.day + 14, false) as sale_ahead,
           coalesce(f.need_why, m.family_list) as need_why,
           coalesce(case when ph.phone is null then 'no_textable_phone' end,
                    public.card_hold_block(l.id, p_now), public.card_record_block(l.id, d.day)) as block
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
         order by (lower(coalesce(c.line_type, '')) in ('mobile', 'wireless', 'cell', 'cellular')) desc, c.created_at, c.value_normalized
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
           coalesce(public.card_hold_block(x.lead_id, p_now), public.card_record_block(x.lead_id, d.day)) as block
      from d, (select u.*, case when extract(isodow from u.raw_day) = 7 then u.raw_day + 1 else u.raw_day end as due_day from due u) x
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
                         and coalesce(m.status, '') not in ('no_answer', 'voicemail', 'inbound_missed', 'missed', 'busy', 'failed', 'canceled', 'blocked'))
       and not exists (select 1 from public.suppressed_phones s where s.phone10 = x.phone)
       and exists (select 1 from public.contacts c where c.lead_id = l.id and c.kind = 'phone' and c.value_normalized = x.phone and c.status = 'ok'
                    and not c.dnc_app and not c.suppressed and not c.dnc_vendor and c.dnc_scrub <> 'dnc')
       and public.phone_person_block(x.phone) is null
       and not exists (select 1 from public.planned_openers po where po.lead_id = l.id and po.send_status in ('planned', 'would_send', 'sending'))),
  -- the owner's next number: the texted number was someone else's (0079), or every first text to the card bounced
  -- on a dead number and nobody was reached (0225), and another usable mobile is on the card
  next_numbers as (
    select l.id, ph.value_normalized as phone, l.updated_at, coalesce(f.tier, m.tier) as tier, coalesce(f.need_why, m.family_list) as need_why,
           coalesce(public.card_hold_block(l.id, p_now), public.card_record_block(l.id, d.day)) as block
      from d, public.leads l
      left join public.text_fitness f on f.wpie_owner_id = l.wpie_owner_id and l.wpie_owner_id > 0
      left join public.lead_motivation m on m.lead_id = l.id
      cross join lateral (
        select c.value_normalized from public.contacts c
         where c.lead_id = l.id and c.kind = 'phone' and c.status = 'ok' and not c.dnc_app and not c.suppressed and not c.dnc_vendor
           and c.dnc_scrub <> 'dnc' and public.agent_phone_ok(c.value_normalized, c.line_type)
           and public.phone_person_block(c.value_normalized) is null
           and public.next_phone_problem(l.id, c.value_normalized) is null
         order by c.created_at, c.value_normalized limit 1) ph
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

CREATE OR REPLACE FUNCTION public.card_record_block(p_lead_id uuid, p_day date)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case
    when not coalesce((select cc.day_rules_on from public.campaign_control cc where cc.id = 1), true) then null
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

CREATE OR REPLACE FUNCTION public.agent_mark_card(p_lead_id uuid, p_mark text, p_reason text, p_date timestamp with time zone, p_phone text, p_agent text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  l    public.leads;
  who  text := 'Muse (' || coalesce(p_agent, 'agent') || ')';
  d    text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10);
  why  text := nullif(btrim(coalesce(p_reason, '')), '');
  phones text[];
  prev text;
  pbelt text;
  pstep integer;
  kept text[];
  gone text[];
  part text;
  ph   text;
  res  jsonb;
  dt   timestamptz := p_date;
begin
  -- a check-back date the agent picks: never in the past, never more than a year out, never a Sunday (10 AM their
  -- time on the next Monday instead); a hold with no date comes back in 45 days
  if dt is not null then
    if dt > now() + interval '366 days' then return jsonb_build_object('ok', false, 'reason', 'a check-back more than a year out is a dead card: mark dead, or pick a date inside a year'); end if;
    if extract(isodow from dt at time zone 'America/Chicago') = 7 then dt := dt + interval '1 day'; end if;
  elsif p_mark = 'held' then
    dt := now() + interval '45 days';
  end if;
  select * into l from public.leads where id = p_lead_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card'); end if;
  if l.stage = 'dnc' and p_mark not in ('note', 'note_delete') then return jsonb_build_object('ok', false, 'reason', 'this card is do-not-contact: it stays that way'); end if;
  -- a card with a sheriff sale 14 or more days out is called and texted now; it is never parked (0233)
  if p_mark = 'held' and exists (select 1 from public.card_sale_dates s where s.lead_id = p_lead_id
                                  and s.sale_date >= (now() at time zone 'America/Chicago')::date + 14) then
    return jsonb_build_object('ok', false, 'reason', 'a sheriff sale is ahead on this card: it is called and texted now and cannot be held (if the date is wrong, correct the reason on the card)');
  end if;
  case p_mark
    when 'note' then
      if why is null then return jsonb_build_object('ok', false, 'reason', 'a note needs words'); end if;
      update public.leads set notes = concat_ws(' | ', notes, 'Muse: ' || why), updated_at = now() where id = p_lead_id;
      return jsonb_build_object('ok', true, 'mark', 'note');
    when 'note_delete' then
      -- Muse's own notes only (a team member's note is theirs): every Muse note holding these words goes; what went is
      -- kept in the card's history (belt_events), never lost
      if why is null or length(why) < 8 then return jsonb_build_object('ok', false, 'reason', 'note_delete needs at least 8 characters of the note to remove (reason)'); end if;
      kept := '{}'; gone := '{}';
      foreach part in array string_to_array(coalesce(l.notes, ''), ' | ') loop
        if part ~ '^Muse( \([a-z_]+\))?: ' and position(lower(why) in lower(part)) > 0 then gone := gone || part;
        elsif part <> '' then kept := kept || part; end if;
      end loop;
      if coalesce(array_length(gone, 1), 0) = 0 then
        return jsonb_build_object('ok', false, 'reason', 'no note by Muse on this card holds those words (team notes cannot be deleted from here)');
      end if;
      update public.leads set notes = nullif(array_to_string(kept, ' | '), ''), updated_at = now() where id = p_lead_id;
      insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
      values (p_lead_id, 'note_deleted', l.belt, l.belt, l.belt_step, jsonb_build_object('removed', to_jsonb(gone)), now(), who);
      return jsonb_build_object('ok', true, 'mark', 'note_delete', 'removed', to_jsonb(gone));
    when 'release' then
      -- a hold (or a not-now) whose blocker cleared: off the hold belt, back to the stage the card had before it was
      -- held; a texting thread picks up its follow-ups again
      if l.belt not in ('hold_not_now', 'not_now_condition', 'not_now_dated') and l.stage <> 'follow_up' then
        return jsonb_build_object('ok', false, 'reason', 'this card is not held (belt ' || coalesce(l.belt, 'none') || ', stage ' || l.stage::text || ')');
      end if;
      if why is null then return jsonb_build_object('ok', false, 'reason', 'release needs what cleared (reason)'); end if;
      select e.from_stage::text into prev from public.lead_stage_events e
       where e.lead_id = p_lead_id and e.to_stage = 'follow_up' and e.from_stage is not null and e.from_stage <> 'follow_up'
       order by e.at desc limit 1;
      perform set_config('wpie.in_belt_event', '1', true);
      update public.leads set belt = null, belt_step = 0, next_stop_at = null, next_stop_who = null, next_stop_say = null,
             named_event = null, named_date = null,
             stage = case when stage = 'follow_up' then coalesce(prev, 'opener_sent')::public.lead_stage else stage end,
             next_action = 'Released: ' || left(why, 120), next_action_at = now(), updated_at = now()
       where id = p_lead_id;
      perform set_config('wpie.in_belt_event', '', true);
      insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
      values (p_lead_id, 'released', l.belt, null, 0, jsonb_build_object('reason', why, 'back_to_stage', coalesce(prev, 'opener_sent')), now(), who);
      res := jsonb_build_object('ok', true, 'released', true);
      -- the hold's own stop is over, and a card that was on a belt before the hold goes back to it (0230). Before, a
      -- released card kept its hold task, and one that had already replied was left on no belt with no next stop.
      update public.tasks set done_at = now(), note = coalesce(note, '') || ' [released: ' || left(why, 80) || ']'
       where lead_id = p_lead_id and source = 'belt' and done_at is null;
      select bb.belt, bb.step into pbelt, pstep from public.belt_before_hold(p_lead_id) bb;
      if pbelt is not null then
        perform set_config('wpie.in_belt_event', '1', true);
        res := res || jsonb_build_object('back_on', public.belt_enter(p_lead_id, pbelt, pstep, 'released',
                 jsonb_build_object('reason', why, 'note', 'back on the follow-ups it was on before the hold'), who, now()));
        perform set_config('wpie.in_belt_event', '', true);
      end if;
    when 'dead' then
      update public.leads set stage = 'dead', dead_reason = coalesce(why, 'not interested (texting agent)') where id = p_lead_id;
      res := public.belt_event(p_lead_id, 'move', jsonb_build_object('belt', 'dead', 'reason', coalesce(why, 'not interested (texting agent)')), who);
    when 'dnc' then
      select array_agg(distinct c.value_normalized) into phones from public.contacts c
       where c.lead_id = p_lead_id and c.kind = 'phone' and c.value_normalized ~ '^[0-9]{10}$';
      phones := coalesce(phones, '{}');
      if d ~ '^[0-9]{10}$' and not d = any(phones) then phones := array_append(phones, d); end if;
      insert into public.suppressed_phones (phone10, reason, source) select distinct p, 'dnc_agent', 'agent' from unnest(phones) p on conflict (phone10) do nothing;
      update public.contacts set suppressed = true, dnc_app = true where value_normalized = any(phones);
      update public.leads set stage = 'dnc', dead_reason = coalesce(why, 'asked not to be contacted') where id = p_lead_id;
      res := public.belt_event(p_lead_id, 'move', jsonb_build_object('belt', 'dnc', 'reason', coalesce(why, 'asked not to be contacted')), who);
    when 'not_now' then
      if dt is not null then
        if dt < now() then return jsonb_build_object('ok', false, 'reason', 'the check-back date cannot be in the past'); end if;
        update public.leads set stage = 'follow_up', next_action = 'Check back', next_action_at = dt where id = p_lead_id;
        res := public.belt_event(p_lead_id, 'named_date', jsonb_strip_nulls(jsonb_build_object('named_date', dt, 'named_event', why, 'reason', why)), who);
      else
        if why is null then return jsonb_build_object('ok', false, 'reason', 'not now needs a date, or the thing that has to change (reason)'); end if;
        update public.leads set stage = 'follow_up', named_event = left(why, 200), next_action = 'Check back', next_action_at = coalesce(next_action_at, now() + interval '30 days') where id = p_lead_id;
        res := public.belt_event(p_lead_id, 'move', jsonb_build_object('belt', 'not_now_condition', 'reason', why), who);
      end if;
    when 'hot' then
      if why is null then return jsonb_build_object('ok', false, 'reason', 'hot needs the reason in their words: Colin reads it on his phone'); end if;
      update public.leads set stage = case when stage in ('colin_call', 'walk_decision', 'walkthrough_booked', 'offer', 'under_contract', 'closed_won') then stage else 'colin_call' end,
             hot_at = coalesce(hot_at, now()) where id = p_lead_id;
      res := public.belt_event(p_lead_id, 'hot_reply', jsonb_strip_nulls(jsonb_build_object('reason', why, 'key', 'agent_hot:' || p_lead_id::text || ':' || to_char(now(), 'YYYYMMDDHH24MI'))), who);
      select c.value_normalized into ph from public.contacts c where c.lead_id = p_lead_id and c.kind = 'phone'
        and (d = '' or c.value_normalized = d) and c.status = 'ok' order by (c.value_normalized = d) desc, c.created_at limit 1;
      perform public.hot_record('agent:' || p_lead_id::text || ':' || to_char(now(), 'YYYYMMDDHH24MI'), p_lead_id, coalesce(ph, d, ''),
        split_part(l.owner_name, ' ', 1), l.property_address, 'Muse: ' || why, false, now());
    when 'held' then
      if why is null then return jsonb_build_object('ok', false, 'reason', 'held needs the blocker (reason)'); end if;
      update public.leads set named_event = left(why, 200), next_action = 'Waiting on: ' || left(why, 120), named_date = dt where id = p_lead_id;
      res := public.belt_event(p_lead_id, 'move', jsonb_strip_nulls(jsonb_build_object('belt', 'hold_not_now', 'reason', why, 'named_date', dt)), who);
    when 'wrong_number' then
      if d !~ '^[0-9]{10}$' then return jsonb_build_object('ok', false, 'reason', 'wrong_number needs the phone'); end if;
      update public.contacts set status = 'bad', note = concat_ws('; ', note, 'wrong number (texting agent)') where lead_id = p_lead_id and value_normalized = d;
      if not exists (select 1 from public.contacts c where c.lead_id = p_lead_id and c.kind = 'phone' and c.status = 'ok' and not c.suppressed and not c.dnc_app) then
        update public.leads set stage = 'data_fix' where id = p_lead_id and stage in ('postcard_mailed', 'opener_queued', 'opener_sent', 'reply_received');
      end if;
      res := jsonb_build_object('ok', true, 'phone_marked_bad', d);
    when 'elderly', 'grief' then
      res := public.belt_event(p_lead_id, 'flag', jsonb_strip_nulls(jsonb_build_object(case p_mark when 'elderly' then 'elderly_or_ill' else 'grief' end, true, 'reason', why)), who);
    else
      return jsonb_build_object('ok', false, 'reason', 'mark is one of: dead, dnc, not_now, hot, held, release, wrong_number, elderly, grief, note, note_delete');
  end case;
  if why is not null and p_mark <> 'note' then
    update public.leads set notes = concat_ws(' | ', notes, 'Muse (' || p_mark || '): ' || why), updated_at = now() where id = p_lead_id;
  end if;
  return coalesce(res, '{}'::jsonb) || jsonb_build_object('mark', p_mark,
    'card', (select jsonb_build_object('stage', x.stage, 'belt', x.belt, 'next_step_at', x.next_stop_at) from public.leads x where x.id = p_lead_id));
end $function$;
