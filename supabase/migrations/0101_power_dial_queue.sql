-- Power hour (Colin 2026-10-28: "theres no rapid click through to bang out 60 or 80 of the needed calls in our ui").
-- Thalia's 4-6 PM block is cold calls only (Rick's best hours), 50+ dials. power_dial_queue lists who to dial next:
--   1. her call-list stops due today (the laptop's day list and the belt's caller stops), then
--   2. the texted-but-silent cards: first text at least 3 days old, nobody wrote back from any phone, no conversation
--      on the phone yet,
-- each with the one number to dial (the phone their texts went to, else the owner's own, mobile first) and the
-- context the card needs on screen. The packet's rules are the filter: at most 3 dials a week per card and never two
-- within 2 days, never a stop / do-not-contact / closed / held card (listed properties are dropped on the laptop before they become cards), never an older, ill or grieving owner (their
-- calls are mornings, at their pace), never a card someone is on now, and only inside 9 AM - 8 PM their time.
-- A dial that did not reach anyone no longer ends the follow-up texts (follow-ups stop when a call REACHED them):
-- "call first, text the no-answers" (Rick), so the due list (0093/0096) counts only reached calls.

create or replace function public.power_dial_queue(p_limit integer default 80, p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public as $$
  with me as (select public.is_team() as ok),
  dialed as (
    select m.lead_id, count(*) filter (where m.sent_at > p_now - interval '7 days') as dials_7d, max(m.sent_at) as last_dial
      from public.messages m where m.channel = 'call' group by m.lead_id),
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
  due_tasks as (
    select distinct on (t.lead_id) t.lead_id, t.id as task_id, t.title, t.due_at from public.tasks t
     where t.done_at is null and t.kind = 'call' and t.lead_id is not null and t.due_at <= p_now + interval '12 hours'
       and t.owner in ('thalia', 'adil')
     order by t.lead_id, t.due_at),
  pool as (
    select l.*, dt.task_id, dt.title as task_title, ft.phone as thread_phone, ft.sent_at as first_text_at,
           coalesce(tx.n, 0) as texts_sent, tx.last_at as last_text_at, coalesce(d.dials_7d, 0) as dials_7d, d.last_dial,
           case when dt.task_id is not null then 0 else 1 end as src
      from public.leads l
      left join due_tasks dt on dt.lead_id = l.id
      left join first_text ft on ft.lead_id = l.id
      left join texts tx on tx.lead_id = l.id
      left join dialed d on d.lead_id = l.id
     where (select ok from me)
       and (dt.task_id is not null or (l.stage = 'opener_sent' and ft.sent_at < p_now - interval '3 days'))
       and l.stage not in ('dnc', 'dead', 'closed_no_contact', 'closed_won', 'under_contract', 'walkthrough_booked', 'offer')
       and not coalesce(l.elderly_or_ill, false) and not coalesce(l.grief, false)
       and l.human_takeover_at is null
       and (l.named_date is null or l.named_date <= p_now)
       and coalesce(d.dials_7d, 0) < 3
       and (d.last_dial is null or d.last_dial < p_now - interval '2 days')
       and (dt.task_id is not null or l.id not in (select lead_id from reached))
       and not exists (select 1 from public.twilio_inbound ti where ti.lead_id = l.id)
       and not exists (select 1 from public.messages mi where mi.lead_id = l.id and mi.direction = 'in' and mi.channel = 'sms')
       and extract(hour from (p_now at time zone public.agent_tz(coalesce(l.mailing_state, 'WI')))) between 9 and 19),
  pick as (
    select p.*, ph.value_normalized as phone, ph.line_type, ph.person_name as phone_person,
           (select count(*) from public.contacts c2 where c2.lead_id = p.id and c2.kind = 'phone' and c2.status = 'ok' and not c2.suppressed) - 1 as other_phones
      from pool p
      cross join lateral (
        select c.value_normalized, c.line_type, c.person_name from public.contacts c
         where c.lead_id = p.id and c.kind = 'phone' and c.status = 'ok' and c.value_normalized ~ '^[0-9]{10}$'
           and not c.suppressed and not coalesce(c.dnc_app, false) and not coalesce(c.dnc_vendor, false) and coalesce(c.dnc_scrub, '') <> 'dnc'
           and not exists (select 1 from public.suppressed_phones s where s.phone10 = c.value_normalized)
           and public.phone_person_block(c.value_normalized) is null
         order by (c.value_normalized = p.thread_phone) desc,
                  (c.person_id is not null and exists (select 1 from public.interests i where i.lead_id = p.id and i.person_id = c.person_id
                     and i.role in ('owner_of_record', 'co_owner', 'personal_representative', 'trustee') and i.status = 'active')) desc,
                  (c.line_type = 'mobile') desc, c.created_at
         limit 1) ph
     order by p.src, cardinality(p.reasons_to_sell) desc, p.first_text_at nulls last, p.id
     limit greatest(1, least(coalesce(p_limit, 80), 200)))
  select coalesce(jsonb_agg(jsonb_build_object(
      'lead_id', id, 'task_id', task_id, 'source', case when src = 0 then 'call_list' else 'texted_silent' end, 'why', task_title,
      'owner_name', owner_name, 'address', property_address, 'municipality', municipality, 'mailing_state', mailing_state,
      'reasons', reasons_to_sell, 'lane', lane, 'stage', stage,
      'texts_sent', texts_sent, 'first_text_at', first_text_at, 'last_text_at', last_text_at,
      'dials_7d', dials_7d, 'last_dial', last_dial,
      'phone', phone, 'line_type', line_type, 'phone_person', phone_person, 'other_phones', greatest(other_phones, 0))
      order by src, cardinality(reasons_to_sell) desc, first_text_at nulls last, id), '[]'::jsonb)
    from pick
$$;
revoke all on function public.power_dial_queue(integer, timestamptz) from public, anon;
grant execute on function public.power_dial_queue(integer, timestamptz) to authenticated, service_role;

-- the follow-up due list: only a call that reached them ends the texting
CREATE OR REPLACE FUNCTION public.agent_ready_to_text(p_limit integer, p_followups boolean, p_all boolean, p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with handed as (
    select distinct on (p.lead_id, p.step) p.lead_id, p.step, p.body as laptop_text, right(p.phone, 10) as laptop_phone, p.plan_date
      from public.planned_openers p
     where p.lane <> 'agent' and p.send_reason = 'handed to the sender agent' and p.send_status = 'withdrawn'
       and p.plan_date >= ((p_now at time zone 'America/Chicago')::date - 7)
     order by p.lead_id, p.step, p.plan_date desc),
  new_cards as (
    select l.id, 1 as step, h.laptop_text, h.laptop_phone, coalesce(h.plan_date, l.created_at::date) as since,
           cardinality(l.reasons_to_sell) as nreasons, l.stacked_at from public.leads l
      left join handed h on h.lead_id = l.id and h.step = 1
     where l.stage in ('opener_queued', 'postcard_mailed')
       and (l.wpie_owner_id < 0 or h.lead_id is not null)
       and not exists (select 1 from public.planned_openers po where po.lead_id = l.id and po.step = 1
                        and po.send_status in ('planned', 'would_send', 'sending', 'sent', 'delivered'))
       and not exists (select 1 from public.messages m where m.lead_id = l.id and m.direction = 'out' and m.channel = 'sms')
       and exists (select 1 from public.contacts c where c.lead_id = l.id and c.kind = 'phone' and c.status = 'ok' and not c.dnc_app
                    and not c.suppressed and not c.dnc_vendor and c.dnc_scrub <> 'dnc' and public.agent_phone_ok(c.value_normalized, c.line_type))
     -- stacked cards first (Muse 2026-10-28: "moving them up is the point of stacking"): most reasons, then the
     -- latest stacked, then the oldest waiting
     order by (cardinality(l.reasons_to_sell) > 1) desc, cardinality(l.reasons_to_sell) desc, l.stacked_at desc nulls last, since, l.created_at
     limit greatest(1, least(p_limit, 300))),
  first_text as (
    -- the latest first text that was not a bounce: the phone this thread runs on
    select distinct on (m.lead_id) m.lead_id, right(regexp_replace(m.to_number, '\D', '', 'g'), 10) as phone, m.sent_at as first_at
      from public.messages m join public.leads l on l.id = m.lead_id
     where p_followups and l.stage = 'opener_sent' and m.direction = 'out' and m.channel = 'sms' and m.is_opener
       and m.provider_sid is not null and coalesce(m.status, '') not in ('undelivered', 'failed')
     order by m.lead_id, m.sent_at desc),
  thread as (
    select f.lead_id, f.phone, f.first_at, count(m.*)::int as n, max(m.sent_at) as last_at
      from first_text f join public.messages m on m.lead_id = f.lead_id and m.direction = 'out' and m.channel = 'sms'
       and m.provider_sid is not null and right(regexp_replace(m.to_number, '\D', '', 'g'), 10) = f.phone and m.sent_at >= f.first_at
     group by 1, 2, 3),
  due as (
    select t.lead_id, t.phone, t.n + 1 as step, t.last_at,
           (t.first_at at time zone 'America/Chicago')::date + (case t.n + 1 when 2 then 2 when 3 then 9 when 4 then 16 else 23 end) as due_day
      from thread t where t.n between 1 and 4),
  follow as (
    select d.lead_id as id, d.step, d.phone,
           case when extract(isodow from d.due_day) = 7 then d.due_day + 1 else d.due_day end as due_day,
           h.laptop_text, h.laptop_phone, cardinality(l.reasons_to_sell) as nreasons, l.stacked_at
      from due d join public.leads l on l.id = d.lead_id
      left join handed h on h.lead_id = d.lead_id and h.step = d.step
     where (case when extract(isodow from d.due_day) = 7 then d.due_day + 1 else d.due_day end) <= (p_now at time zone 'America/Chicago')::date
       and d.last_at < p_now - interval '1 day'
       and not coalesce(l.elderly_or_ill, false) and not coalesce(l.grief, false) and l.human_takeover_at is null
       -- they wrote back, from any phone on the card (or a phone that belongs to it)
       and not exists (select 1 from public.twilio_inbound ti where ti.lead_id = l.id
                         or ti.from10 in (select c.value_normalized from public.contacts c where c.lead_id = l.id and c.kind = 'phone'))
       and not exists (select 1 from public.messages m where m.lead_id = l.id and m.direction = 'in' and m.channel = 'sms')
       -- a call that REACHED them ends the texting; a dial nobody answered does not (call first, text the no-answers)
       and not exists (select 1 from public.messages m where m.lead_id = l.id and m.channel = 'call'
                         and coalesce(m.status, '') not in ('no_answer', 'voicemail', 'inbound_missed', 'missed', 'busy', 'failed', 'canceled', 'blocked'))
       and not exists (select 1 from public.suppressed_phones s where s.phone10 = d.phone)
       and exists (select 1 from public.contacts c where c.lead_id = l.id and c.kind = 'phone' and c.value_normalized = d.phone and c.status = 'ok'
                    and not c.dnc_app and not c.suppressed and not c.dnc_vendor and c.dnc_scrub <> 'dnc')
       and public.phone_person_block(d.phone) is null
       and not exists (select 1 from public.planned_openers po where po.lead_id = l.id and po.send_status in ('planned', 'would_send', 'sending'))),
  shown as (select * from follow order by (nreasons > 1) desc, nreasons desc, stacked_at desc nulls last, due_day, id limit greatest(1, least(p_limit, 300)))
  select jsonb_build_object(
    'new_cards', (select coalesce(jsonb_agg(public.agent_card(id) || jsonb_build_object('next_step', step, 'laptop_text', laptop_text,
                    'laptop_phone', laptop_phone, 'reasons_count', nreasons, 'stacked_at', stacked_at)
                    order by (nreasons > 1) desc, nreasons desc, stacked_at desc nulls last, since), '[]'::jsonb) from new_cards),
    'followups_due', (select coalesce(jsonb_agg(public.agent_card(id) || jsonb_build_object('next_step', step, 'due_since', due_day,
                    'phone', phone, 'laptop_text', laptop_text, 'laptop_phone', laptop_phone, 'reasons_count', nreasons, 'stacked_at', stacked_at)
                    order by (nreasons > 1) desc, nreasons desc, stacked_at desc nulls last, due_day), '[]'::jsonb) from shown),
    'followups_due_total', (select count(*) from follow),
    'followups_due_by_step', (select coalesce(jsonb_object_agg(step, n), '{}'::jsonb) from (select step, count(*) n from follow group by step) x))
$function$;
