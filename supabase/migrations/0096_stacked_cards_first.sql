-- Stacked cards first (Muse 2026-10-28: "When a new signal gets stacked onto a card, does anything re-rank it in the
-- ready queue? If not, please make stacked cards sort ahead of unstacked ones - moving them up is the point of stacking").
-- It did not: new cards were listed oldest first, follow-ups by due day. Now:
--   * leads.stacked_at is set whenever a card's reasons to sell grow (add_prospects stacking a reason, the laptop's sync, a
--     records match), by a trigger, so every path counts;
--   * ready_to_text lists cards with two or more reasons first (new cards and follow-ups alike): most reasons, then the
--     latest stacked, then the usual order; each card carries reasons_count and stacked_at.

alter table public.leads add column if not exists stacked_at timestamptz;

create or replace function public.leads_stacked_at() returns trigger language plpgsql as $$
begin
  if cardinality(coalesce(new.reasons_to_sell, '{}')) > cardinality(coalesce(old.reasons_to_sell, '{}'))
     and not (coalesce(new.reasons_to_sell, '{}') <@ coalesce(old.reasons_to_sell, '{}')) then
    new.stacked_at := now();
  end if;
  return new;
end $$;
drop trigger if exists leads_stacked_at on public.leads;
create trigger leads_stacked_at before update of reasons_to_sell on public.leads for each row execute function public.leads_stacked_at();

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
       and not exists (select 1 from public.messages m where m.lead_id = l.id and m.direction = 'in')
       -- a call either way ends the texting (the packet: a call from the card stops the follow-ups)
       and not exists (select 1 from public.messages m where m.lead_id = l.id and m.channel = 'call')
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
