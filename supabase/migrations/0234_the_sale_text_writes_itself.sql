-- 0234: the sale text writes itself.
--
-- Colin 2026-11-14: "Text em too, the text we use for people in foreclosure. This should be an automatic thing."
-- The wording he chose on 2026-11-07 for an owner with a sheriff sale ahead was typed by hand each time. The day's
-- list now hands it to the sender, filled in, on every first text to a card whose sale is 14 or more days out.

create or replace function public.sale_first_text(p_lead_id uuid, p_voice text, p_day date)
returns text language sql stable security definer set search_path = public as $$
  select 'Hi ' || public.text_first_name(l.owner_name) || ', ' || coalesce(nullif(btrim(p_voice), ''), 'Thalia') || ' here about '
         || initcap(btrim(l.property_address)) || '. I know a sale date may be coming up. If selling before then and walking away with something would help, I''d like to talk. Would you be open to that? Reply STOP to opt out.'
    from public.leads l join public.card_sale_dates s on s.lead_id = l.id
   where l.id = p_lead_id and s.sale_date >= p_day + 14 and coalesce(btrim(l.property_address), '') <> ''
$$;
revoke all on function public.sale_first_text(uuid, text, date) from public, anon;

CREATE OR REPLACE FUNCTION public.agent_ready_to_text(p_limit integer, p_followups boolean, p_all boolean, p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with d as (select (p_now at time zone 'America/Chicago')::date as day),
  handed as (
    select distinct on (p.lead_id, p.step) p.lead_id, p.step, p.body as laptop_text
      from public.planned_openers p
     where p.lane <> 'agent' and p.send_reason = 'handed to the sender agent' and p.send_status = 'withdrawn'
       and p.plan_date >= ((p_now at time zone 'America/Chicago')::date - 7)
     order by p.lead_id, p.step, p.plan_date desc),
  listed as (
    select t.lead_id, t.kind, t.step, t.phone, t.voice, t.tier, t.need_why, t.due_day, t.ord from public.text_day t, d
     where t.day = d.day
       -- written already: a text for this step to THIS phone (the owner's next number is step 1 again, on another phone)
       and not exists (select 1 from public.planned_openers po where po.lead_id = t.lead_id and po.step = t.step
                        and right(regexp_replace(po.phone, '\D', '', 'g'), 10) = t.phone
                        and po.send_status in ('planned', 'would_send', 'sending', 'sent', 'delivered'))),
  pool as (
    select p.lead_id, p.kind, p.step, p.phone, public.card_voice(p.lead_id) as voice, p.tier, p.need_why, p.due_day, p.ord::int as ord
      from public.text_pool(p_now) p
     where p.block is null and p.ord <= 300
       and not exists (select 1 from public.text_day t where t.day = (p_now at time zone 'America/Chicago')::date)),
  todo as (select * from listed union all select * from pool),
  shown as (
    select x.*, h.laptop_text, row_number() over (partition by x.kind order by x.ord) as rn from todo x
      left join handed h on h.lead_id = x.lead_id and h.step = x.step
     where x.kind <> 'followup' or p_followups)
  select jsonb_build_object(
    'new_cards', (select coalesce(jsonb_agg(public.agent_card(s.lead_id) || jsonb_build_object('next_step', 1, 'phone', s.phone, 'voice', s.voice,
                    'tier', s.tier, 'need', s.need_why, 'laptop_text', s.laptop_text, 'laptop_phone', s.phone,
           'sale_text', public.sale_first_text(s.lead_id, s.voice, (p_now at time zone 'America/Chicago')::date),
                    'reasons_count', cardinality(l.reasons_to_sell), 'stacked_at', l.stacked_at, 'laptop_card', l.wpie_owner_id > 0) order by s.ord), '[]'::jsonb)
                    from shown s join public.leads l on l.id = s.lead_id where s.kind = 'first' and s.rn <= greatest(1, least(p_limit, 300))),
    'followups_due', (select coalesce(jsonb_agg(public.agent_card(s.lead_id) || jsonb_build_object('next_step', s.step, 'due_since', s.due_day,
                    'phone', s.phone, 'voice', s.voice, 'tier', s.tier, 'need', s.need_why, 'laptop_text', s.laptop_text, 'laptop_phone', s.phone,
           'sale_text', public.sale_first_text(s.lead_id, s.voice, (p_now at time zone 'America/Chicago')::date),
                    'reasons_count', cardinality(l.reasons_to_sell), 'stacked_at', l.stacked_at) order by s.ord), '[]'::jsonb)
                    from shown s join public.leads l on l.id = s.lead_id where s.kind = 'followup' and s.rn <= greatest(1, least(p_limit, 300))),
    'next_numbers', (select coalesce(jsonb_agg(public.agent_card(s.lead_id) || jsonb_build_object('next_step', 1, 'phone', s.phone, 'voice', s.voice,
                    'why', 'the number we texted reached someone else; this is the owner''s next number',
                    'reasons_count', cardinality(l.reasons_to_sell)) order by s.ord), '[]'::jsonb)
                    from shown s join public.leads l on l.id = s.lead_id where s.kind = 'next_number' and s.rn <= greatest(1, least(p_limit, 300))),
    'followups_due_total', (select count(*) from todo where kind = 'followup'),
    'followups_due_by_step', (select coalesce(jsonb_object_agg(step, n), '{}'::jsonb) from (select step, count(*) n from todo where kind = 'followup' group by step) x),
    'the_day', jsonb_build_object(
       'day', (select day from d),
       'list_built', exists (select 1 from public.text_day t, d where t.day = d.day),
       'left_to_write', (select count(*) from todo),
       'left_by_kind', (select coalesce(jsonb_object_agg(k, n), '{}'::jsonb) from (
           select case when kind = 'followup' then 'step_' || step else kind end as k, count(*) n from todo group by 1) x),
       'how', 'This is today''s list, built by the server from the whole store, real need first. Write each text to the phone given, signed with the name in voice. One name per thread; a first text carries the STOP line, a follow-up does not. When a card carries sale_text, send exactly that text: it is the first text for an owner with a sheriff sale ahead (Colin 2026-11-14).'))
$function$;
