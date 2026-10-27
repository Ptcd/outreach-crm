-- A follow-up is due once (Muse, 2026-10-27: "10 follow-ups were presented as due again even though their step-2 texts
-- were sent yesterday"). The laptop's follow-ups handed to the sender agent stay on the hand-over list for 7 days, and
-- ready_to_text listed a handed step even after the agent had sent it. Nothing was sent twice (the send check refuses a
-- step already sent), but the due list could not be trusted. Now a handed step that went out is not listed again.

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
    select l.id, 1 as step, h.laptop_text, h.laptop_phone, coalesce(h.plan_date, l.created_at::date) as since from public.leads l
      left join handed h on h.lead_id = l.id and h.step = 1
     where l.stage in ('opener_queued', 'postcard_mailed')
       and (l.wpie_owner_id < 0 or h.lead_id is not null)
       and not exists (select 1 from public.planned_openers po where po.lead_id = l.id and po.step = 1
                        and po.send_status in ('planned', 'would_send', 'sending', 'sent', 'delivered'))
       and not exists (select 1 from public.messages m where m.lead_id = l.id and m.direction = 'out' and m.channel = 'sms')
       and exists (select 1 from public.contacts c where c.lead_id = l.id and c.kind = 'phone' and c.status = 'ok' and not c.dnc_app
                    and not c.suppressed and not c.dnc_vendor and c.dnc_scrub <> 'dnc' and public.agent_phone_ok(c.value_normalized, c.line_type))
     order by since, l.created_at limit greatest(1, least(p_limit, 300))),
  sent as (
    select m.lead_id, min(m.sent_at) first_at, max(m.sent_at) last_at, count(*) n from public.messages m
     where m.direction = 'out' and m.channel = 'sms' and m.provider_sid is not null group by 1),
  follow as (
    -- the agent's own cards on the 1-3-10-17-24 days, and the laptop's follow-ups handed over
    select l.id, coalesce(h.step, (s.n + 1)::int) as step, h.laptop_text, h.laptop_phone,
           coalesce(h.plan_date::timestamptz, s.first_at + (case s.n + 1 when 2 then 2 when 3 then 9 when 4 then 16 else 23 end) * interval '1 day') as due
      from public.leads l join sent s on s.lead_id = l.id
      left join handed h on h.lead_id = l.id and h.step > 1
     where p_followups and l.stage = 'opener_sent' and s.n < 5
       and (h.lead_id is not null or (l.wpie_owner_id < 0
            and s.last_at < p_now - interval '3 days'
            and s.first_at + (case s.n + 1 when 2 then 2 when 3 then 9 when 4 then 16 else 23 end) * interval '1 day' <= p_now))
       and not exists (select 1 from public.twilio_inbound t where t.lead_id = l.id)
       and not exists (select 1 from public.planned_openers po where po.lead_id = l.id and po.send_status in ('planned', 'would_send', 'sending'))
       -- a laptop follow-up handed over stays on the hand-over list for a week: once that step went out, it is not due again (0083)
       and (h.lead_id is null or (s.n < h.step and not exists (select 1 from public.planned_openers po where po.lead_id = l.id and po.step = h.step
                                                                and po.send_status = any(public.opener_live_statuses()))))
     order by 5 limit greatest(1, least(p_limit, 300)))
  select jsonb_build_object(
    'new_cards', (select coalesce(jsonb_agg(public.agent_card(id) || jsonb_build_object('next_step', step, 'laptop_text', laptop_text,
                    'laptop_phone', laptop_phone)), '[]'::jsonb) from new_cards),
    'followups_due', (select coalesce(jsonb_agg(public.agent_card(id) || jsonb_build_object('next_step', step, 'due_since', due,
                    'laptop_text', laptop_text, 'laptop_phone', laptop_phone)), '[]'::jsonb) from follow))
$function$;
