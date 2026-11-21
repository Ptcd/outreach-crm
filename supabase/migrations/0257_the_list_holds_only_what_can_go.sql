-- 0257: the day's list holds only texts that can go.
--
-- Muse, desk 324 and 326, 2026-11-20: the day closed at 285 of 400 on Thursday and looked stuck at 182 on Friday, and
-- Muse's own afternoon texts were refused as "already planned". The post blamed the server's own writing of the day
-- (the backstop). The records say otherwise: the server wrote and sent 280, 282 and 270 texts on Nov 18, 19 and 20,
-- 9 AM to 6:10 PM. What was lost each day was about 110 of the 400 places on the list, given to the SAME cards every
-- day since Nov 12, each written and then refused at the moment of sending:
--   about 60 first texts to a phone two different owners share (phone_shared: 84 cards, 363 times),
--   35 third texts refused as "text 2 not delivered" when text 2 WAS delivered (202 times),
--   about 10 follow-ups whose first text never got a delivery receipt (opener_not_delivered),
--   a few whose owner said STOP on another number.
-- The list did not know the send check's rules, so it offered those cards again the next morning.
--
-- 1. The 35 third texts were a real fault. Muse's cards are made on a negative owner id and re-keyed to the real
--    owner when the laptop ties them (docs/PHONES_WANTED.md). The texts already sent kept the old id, and the send
--    check looks for text 2 by owner id. Now a card's planned texts follow its owner id (a trigger), and the 133 rows
--    left behind are put right, so those owners get their third text.
-- 2. The pool (text_pool) blocks what the send check will refuse: a first text never picks a shared phone (the next
--    phone on the card, else the card reads phone_shared); an owner who opted out on another number reads
--    owner_opted_out; a follow-up on a shared phone, or whose earlier text was not delivered, reads the send check's
--    own reason. The daily report then counts them under "why the rest is not ready" instead of losing them silently.
-- 3. A text the send check refused no longer keeps its place on the day's list: the hourly top-up gives the place to
--    a card that can be texted.
-- The send check itself (claim_next_opener) is unchanged. Nothing here sends more than the cap or loosens a rule.

-- the send check's own test for a number two different owners share (as in claim_next_opener, 0083 and 0235)
create or replace function public.phone_is_shared(p_phone10 text) returns boolean
language sql stable security definer set search_path = public as $fn$
  select (select count(distinct ct.lead_id) from public.contacts ct where ct.value_normalized = p_phone10) > 1
     and (select count(distinct coalesce(ct.person_id::text, ct.lead_id::text)) from public.contacts ct where ct.value_normalized = p_phone10) > 1
     and (select count(distinct upper(regexp_replace(coalesce(ll.owner_name, ''), '[^A-Za-z0-9]', '', 'g')))
            from public.contacts ct join public.leads ll on ll.id = ct.lead_id where ct.value_normalized = p_phone10) > 1
$fn$;
revoke all on function public.phone_is_shared(text) from public, anon;
grant execute on function public.phone_is_shared(text) to authenticated, service_role;

-- the owner opted out on any of their numbers, on any of their cards (the send check's owner_opted_out_on_another_phone)
create or replace function public.owner_opted_out(p_wpie_owner_id bigint) returns boolean
language sql stable security definer set search_path = public as $fn$
  select p_wpie_owner_id is not null and exists (
    select 1 from public.contacts ct join public.leads ll on ll.id = ct.lead_id
     where ll.wpie_owner_id = p_wpie_owner_id and ct.kind = 'phone' and ct.value_normalized is not null
       and (ct.suppressed or exists (select 1 from public.suppressed_phones s where s.phone10 = ct.value_normalized)))
$fn$;
revoke all on function public.owner_opted_out(bigint) from public, anon;
grant execute on function public.owner_opted_out(bigint) to authenticated, service_role;

-- why the send check would refuse a follow-up on this phone, or null: the phone is shared, the first text on it has no
-- delivery receipt, or (text 3) text 2 has none. The same three tests as claim_next_opener, by the card.
create or replace function public.followup_send_block(p_lead_id uuid, p_phone10 text, p_step integer) returns text
language sql stable security definer set search_path = public as $fn$
  select case
    when public.phone_is_shared(p_phone10) then 'phone_shared'
    when not exists (select 1 from public.planned_openers p where p.lead_id = p_lead_id and p.step = 1 and p.send_status = 'delivered'
                        and right(regexp_replace(p.phone, '\D', '', 'g'), 10) = p_phone10)
     and not exists (select 1 from public.messages m where m.lead_id = p_lead_id and m.is_opener and m.direction = 'out' and m.status = 'delivered'
                        and right(regexp_replace(m.to_number, '\D', '', 'g'), 10) = p_phone10) then 'opener_not_delivered'
    when p_step = 3 and not exists (select 1 from public.planned_openers p where p.lead_id = p_lead_id and p.step = 2 and p.send_status = 'delivered'
                        and right(regexp_replace(p.phone, '\D', '', 'g'), 10) = p_phone10) then 'text_2_not_delivered'
  end
$fn$;
revoke all on function public.followup_send_block(uuid, text, integer) from public, anon;
grant execute on function public.followup_send_block(uuid, text, integer) to authenticated, service_role;

-- ---------------------------------------------------------------- a card's texts follow its owner id
create or replace function public.planned_openers_follow_owner() returns trigger
language plpgsql security definer set search_path = public as $fn$
begin
  if new.wpie_owner_id is distinct from old.wpie_owner_id and new.wpie_owner_id is not null then
    update public.planned_openers po set wpie_owner_id = new.wpie_owner_id
     where po.lead_id = new.id and po.wpie_owner_id is distinct from new.wpie_owner_id
       and not exists (select 1 from public.planned_openers q where q.plan_date = po.plan_date and q.attempt = po.attempt
                          and q.wpie_owner_id = new.wpie_owner_id);
  end if;
  return null;
end $fn$;
drop trigger if exists leads_planned_openers_follow_owner on public.leads;
create trigger leads_planned_openers_follow_owner after update of wpie_owner_id on public.leads
  for each row execute function public.planned_openers_follow_owner();

-- the rows left behind by earlier re-keys (133 rows on 77 cards on 2026-11-20)
update public.planned_openers po set wpie_owner_id = l.wpie_owner_id
  from public.leads l
 where l.id = po.lead_id and l.wpie_owner_id is not null and po.wpie_owner_id is distinct from l.wpie_owner_id
   and not exists (select 1 from public.planned_openers q where q.plan_date = po.plan_date and q.attempt = po.attempt
                      and q.wpie_owner_id = l.wpie_owner_id);

-- ---------------------------------------------------------------- the pool and the build (recreated from live, two changes each)
CREATE OR REPLACE FUNCTION public.text_pool(p_now timestamp with time zone DEFAULT now())
 RETURNS TABLE(lead_id uuid, kind text, step integer, phone text, tier text, need_why text, due_day date, block text, ord bigint)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
  with d as (select (p_now at time zone 'America/Chicago')::date as day),
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
                    case when public.owner_opted_out(l.wpie_owner_id) then 'owner_opted_out' end) as block
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
                    public.followup_send_block(x.lead_id, x.phone, x.step)) as block   -- 0257
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
$fn$;

CREATE OR REPLACE FUNCTION public.text_day_build(p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
declare
  c       public.campaign_control;
  d       date := (p_now at time zone 'America/Chicago')::date;
  cap     integer;
  room    integer;
  n       integer;
  nxt     integer;
  added   jsonb := '{}'::jsonb;
  ph      record;
  left_out integer;
begin
  select * into c from public.campaign_control where id = 1;
  if coalesce(c.no_sundays, true) and extract(isodow from d) = 7 then
    return jsonb_build_object('day', d, 'built', false, 'why', 'Sunday: no texts');
  end if;
  -- a text carried over to a day its card's caller is off does not go (0238)
  perform public.caller_off_sweep(d);
  cap := coalesce(c.daily_cap, 400);
  drop table if exists _day_pool;
  create temp table _day_pool on commit drop as select * from public.text_pool(p_now) where block is null;

  delete from public.text_day t
   where t.day = d
     and not exists (select 1 from public.planned_openers po where po.lead_id = t.lead_id and po.step = t.step and po.plan_date = d and po.lane = 'agent'
                        and po.send_status not in ('withdrawn', 'skipped'))   -- a withdrawn text does not keep its row on the list (0237), nor one the send check refused (0257)
     and not exists (select 1 from _day_pool p where p.lead_id = t.lead_id and p.step = t.step);
  get diagnostics left_out = row_count;

  -- what the day has already spent: the list, and any text the agent queued for today that is not on it
  select count(*) into n from public.text_day t where t.day = d;
  room := cap - n - (select count(*) from public.planned_openers po
                      where po.plan_date = d and po.lane = 'agent' and po.send_status in ('planned', 'would_send', 'sending', 'sent', 'delivered', 'undelivered', 'failed', 'uncertain')
                        and not exists (select 1 from public.text_day t where t.day = d and t.lead_id = po.lead_id and t.step = po.step));
  select coalesce(max(t.ord), 0) into nxt from public.text_day t where t.day = d;

  for ph in
    select * from (values
      ('first_floor', 'first', array[1], greatest(0, coalesce(c.day_first_floor, 140) - (select count(*) from public.text_day t where t.day = d and t.kind = 'first')::int)),
      ('followups_2_3', 'followup', array[2, 3], 100000),
      ('next_numbers', 'next_number', array[1], 100000),
      ('followups_4_5', 'followup', array[4, 5], 100000),
      ('more_first', 'first', array[1], 100000)) as v(name, kind, steps, quota)
  loop
    exit when room <= 0;
    with pick as (
      select p.*, row_number() over (order by p.step, p.ord) as rn from _day_pool p
       where p.kind = ph.kind and p.step = any (ph.steps)
         and not exists (select 1 from public.text_day t where t.day = d and t.lead_id = p.lead_id)
       order by p.step, p.ord limit least(room, ph.quota))
    insert into public.text_day (day, lead_id, step, kind, phone, voice, tier, need_why, due_day, ord, listed_at)
    select d, k.lead_id, k.step, k.kind, k.phone, public.card_voice(k.lead_id), k.tier, k.need_why, k.due_day, nxt + k.rn, p_now from pick k
    on conflict (day, lead_id, step) do nothing;
    get diagnostics n = row_count;
    room := room - n;
    nxt := nxt + n;
    added := added || jsonb_build_object(ph.name, n);
  end loop;

  update public.campaign_control set day_last_build_at = p_now where id = 1;
  insert into public.text_day_runs (day, at, kind, summary)
  values (d, p_now, 'build', jsonb_build_object('added', added, 'left_the_list', left_out, 'room_left', greatest(room, 0), 'cap', cap,
          'listed', (select count(*) from public.text_day t where t.day = d)));
  return jsonb_build_object('day', d, 'built', true, 'cap', cap, 'added', added, 'left_the_list', left_out,
    'listed', (select count(*) from public.text_day t where t.day = d), 'room_left', greatest(room, 0));
end $fn$;
