-- 0272: no text goes out in the name of a caller who is off that day. Colin 2026-11-21, a Saturday: "Texting should
-- only be sending to Tyler's cards on the weekend what the fuck?! Thalia works during the week".
--
-- Every text that day was on a card Tyler owns: Thalia has been off every Saturday and Sunday since 2026-11-14
-- (caller_off_weekly) and a card whose caller is off is not texted (0237). But 238 of the day's 500 were follow-ups
-- in threads that had started in Thalia's name before those cards became Tyler's on 2026-11-04. A thread keeps its
-- name (one name a thread, 0219), so they went out saying "this is Thalia" on a day she does not work, and 58 were
-- delivered before this was applied.
--
-- The rule: a thread that speaks as a caller who is off that day is not texted that day (block name_off_today), the
-- same as a card whose caller is off. It waits for a day that caller works. The list fills with other cards.
-- The sweep that withdraws a planned text when a caller is marked off now withdraws these too.

-- the cards whose thread speaks as a caller who is off that day (the name in our last text that carries one)
create or replace function public.text_name_off(p_day date) returns table (lead_id uuid, name text)
language sql stable security definer set search_path = public as $$
  with off as (select lower(split_part(tm.display_name, ' ', 1)) as nm from public.team_members tm
                where tm.person is not null and coalesce(tm.display_name, '') <> '' and public.caller_is_off(tm.person, p_day)
                  and coalesce((select cc.day_rules_on from public.campaign_control cc where cc.id = 1), true)),
  said as (select distinct on (m.lead_id) m.lead_id, public.text_speaker(m.body) as sp
             from public.messages m
            where exists (select 1 from off) and m.lead_id is not null and m.direction = 'out' and m.channel = 'sms' and m.provider_sid is not null
              and m.body ~* (select '(' || string_agg(nm, '|') || ')' from off)
              and public.text_speaker(m.body) is not null
            order by m.lead_id, m.sent_at desc nulls last)
  select s.lead_id, s.sp from said s where lower(s.sp) in (select nm from off)
     -- a later text in another name means the thread has moved on
     and not exists (select 1 from public.messages m2 where m2.lead_id = s.lead_id and m2.direction = 'out' and m2.channel = 'sms' and m2.provider_sid is not null
                        and public.text_speaker(m2.body) is not null and lower(public.text_speaker(m2.body)) not in (select nm from off)
                        and m2.sent_at > (select max(m3.sent_at) from public.messages m3 where m3.lead_id = s.lead_id and m3.direction = 'out' and m3.channel = 'sms'
                                             and m3.provider_sid is not null and lower(public.text_speaker(m3.body)) in (select nm from off)))
$$;
revoke all on function public.text_name_off(date) from public, anon, authenticated;
grant execute on function public.text_name_off(date) to service_role;

-- ---------------------------------------------------------------- the day's pool: a thread in an off caller's name is blocked for the day
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
           coalesce(public.card_hold_block(x.lead_id, p_now), public.card_record_block(x.lead_id, d.day),
                    public.followup_send_block(x.lead_id, x.phone, x.step),   -- 0257
                    (select 'name_off_today' from off_name o where o.lead_id = x.lead_id limit 1)) as block
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

-- ---------------------------------------------------------------- the sweep withdraws a planned text in an off caller's name
CREATE OR REPLACE FUNCTION public.caller_off_sweep(p_day date)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare n integer; m integer;
begin
  update public.planned_openers po set send_status = 'withdrawn', send_reason = 'the card''s caller is off that day', send_updated_at = now()
   where po.plan_date = p_day and po.send_status in ('planned', 'would_send') and po.claim_mode is null
     and exists (select 1 from public.leads l where l.id = po.lead_id and public.caller_is_off(l.locked_to, p_day));
  get diagnostics n = row_count;
  -- 0272: nor a text that speaks in the name of a caller who is off that day, whoever owns the card now
  update public.planned_openers po set send_status = 'withdrawn', send_reason = 'it goes out in the name of a caller who is off that day', send_updated_at = now()
   where po.plan_date = p_day and po.send_status in ('planned', 'would_send') and po.claim_mode is null
     and (exists (select 1 from public.text_name_off(p_day) o where o.lead_id = po.lead_id)
          or exists (select 1 from public.team_members tm where tm.person is not null and public.caller_is_off(tm.person, p_day)
                      and lower(public.text_speaker(po.body)) = lower(split_part(tm.display_name, ' ', 1))));
  get diagnostics m = row_count;
  return n + m;
end $function$;
