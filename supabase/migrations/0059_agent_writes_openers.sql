-- The sender agent writes every first text (Colin 2026-10-26: "today actually"). The laptop still picks WHO gets a
-- first text (it runs the prospect rules: motivation, house or duplex, area, vacation homes, listings); with
-- agent_writes_openers on, each first text it plans is handed to the sender agent instead of being sent, and the
-- agent writes the words (and runs the A/B test). Follow-ups to the laptop's own cards stay with the laptop.

alter table public.campaign_control add column if not exists agent_writes_openers boolean not null default false;

-- a laptop first text arriving while the switch is on is handed over, not sent
create or replace function public.hand_opener_to_agent() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.step = 1 and coalesce(new.lane, '') <> 'agent' and new.send_status = 'planned'
     and (select agent_writes_openers from public.campaign_control where id = 1) then
    new.send_status := 'withdrawn';
    new.send_reason := 'handed to the sender agent';
  end if;
  return new;
end $$;
drop trigger if exists hand_opener_to_agent on public.planned_openers;
create trigger hand_opener_to_agent before insert on public.planned_openers
  for each row execute function public.hand_opener_to_agent();

-- the agent's list now includes the laptop's handed-over picks, with the laptop's own wording as a reference
create or replace function public.agent_ready_to_text(p_limit integer, p_followups boolean, p_all boolean, p_now timestamptz default now())
returns jsonb language sql stable security definer set search_path = public as $$
  with handed as (
    select distinct on (p.lead_id) p.lead_id, p.body as laptop_text, p.plan_date
      from public.planned_openers p
     where p.step = 1 and p.lane <> 'agent' and p.send_reason = 'handed to the sender agent'
       and p.plan_date >= ((p_now at time zone 'America/Chicago')::date - 7)
     order by p.lead_id, p.plan_date desc),
  new_cards as (
    select l.id, 1 as step, h.laptop_text, coalesce(h.plan_date, l.created_at::date) as since from public.leads l
      left join handed h on h.lead_id = l.id
     where l.stage in ('opener_queued', 'postcard_mailed')
       and (l.wpie_owner_id < 0 or h.lead_id is not null or (p_all and false))
       and not exists (select 1 from public.planned_openers po where po.lead_id = l.id
                        and po.send_status in ('planned', 'would_send', 'sending', 'sent', 'delivered'))
       and not exists (select 1 from public.messages m where m.lead_id = l.id and m.direction = 'out' and m.channel = 'sms')
       and exists (select 1 from public.contacts c where c.lead_id = l.id and c.kind = 'phone' and c.status = 'ok' and not c.dnc_app
                    and not c.suppressed and not c.dnc_vendor and c.dnc_scrub <> 'dnc' and public.agent_phone_ok(c.value_normalized, c.line_type))
     order by since, l.created_at limit greatest(1, least(p_limit, 300))),
  sent as (
    select m.lead_id, min(m.sent_at) first_at, max(m.sent_at) last_at, count(*) n from public.messages m
     where m.direction = 'out' and m.channel = 'sms' and m.provider_sid is not null group by 1),
  follow as (
    select l.id, (s.n + 1)::int as step,
           s.first_at + (case s.n + 1 when 2 then 2 when 3 then 9 when 4 then 16 else 23 end) * interval '1 day' as due
      from public.leads l join sent s on s.lead_id = l.id
     where p_followups and l.stage = 'opener_sent' and l.wpie_owner_id < 0 and s.n < 5
       and not exists (select 1 from public.twilio_inbound t where t.lead_id = l.id)
       and not exists (select 1 from public.planned_openers po where po.lead_id = l.id and po.send_status in ('planned', 'would_send', 'sending'))
       and s.last_at < p_now - interval '3 days'
       and s.first_at + (case s.n + 1 when 2 then 2 when 3 then 9 when 4 then 16 else 23 end) * interval '1 day' <= p_now
     order by 3 limit greatest(1, least(p_limit, 300)))
  select jsonb_build_object(
    'new_cards', (select coalesce(jsonb_agg(public.agent_card(id) || jsonb_build_object('next_step', step, 'laptop_text', laptop_text)), '[]'::jsonb) from new_cards),
    'followups_due', (select coalesce(jsonb_agg(public.agent_card(id) || jsonb_build_object('next_step', step, 'due_since', due)), '[]'::jsonb) from follow))
$$;

-- the agent's card shows who it is talking to (person, trust, llc, estate) so the first text can be worded for them
create or replace function public.agent_card(p_lead uuid) returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'lead_id', l.id, 'owner_name', l.owner_name, 'owner_type', l.owner_type, 'address', l.property_address, 'city', l.municipality,
    'county', l.county, 'zip', l.property_zip, 'mailing_state', l.mailing_state, 'stage', l.stage,
    'source', coalesce(l.source, case when l.wpie_owner_id > 0 then 'laptop' end),
    'reasons', l.reasons_to_sell,
    'reason_details', (select jsonb_agg(jsonb_build_object('kind', r.kind, 'detail', r.detail, 'date', r.event_date, 'amount', r.amount, 'source', r.source))
                         from public.prospect_reasons r where r.lead_id = l.id),
    'phones', (select jsonb_agg(jsonb_build_object('phone', c.value_normalized, 'type', c.line_type, 'name', c.person_name,
                      'textable', c.status = 'ok' and not c.dnc_app and not c.suppressed and not c.dnc_vendor and c.dnc_scrub <> 'dnc'
                                  and public.agent_phone_ok(c.value_normalized, c.line_type)))
                 from public.contacts c where c.lead_id = l.id and c.kind = 'phone'),
    'texts_sent', (select jsonb_agg(jsonb_build_object('at', m.sent_at, 'to', m.to_number, 'body', m.body, 'status', m.status) order by m.sent_at)
                     from public.messages m where m.lead_id = l.id and m.direction = 'out' and m.channel = 'sms'),
    'replied', exists (select 1 from public.twilio_inbound t where t.lead_id = l.id),
    'waiting', (select jsonb_agg(jsonb_build_object('text_id', p.id, 'step', p.step, 'goes_after', p.scheduled_at, 'status', p.send_status))
                  from public.planned_openers p where p.lead_id = l.id and p.send_status in ('planned', 'would_send', 'sending')))
  from public.leads l where l.id = p_lead
$$;

-- the switch: Colin's, in the app
create or replace function public.set_agent_writes_openers(p_on boolean) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_owner() then raise exception 'only Colin can hand the first texts to the agent'; end if;
  update public.campaign_control set agent_writes_openers = p_on where id = 1;
  return p_on;
end $$;
revoke all on function public.set_agent_writes_openers(boolean) from public, anon;
grant execute on function public.set_agent_writes_openers(boolean) to authenticated;

revoke all on function public.agent_ready_to_text(integer, boolean, boolean, timestamptz), public.agent_card(uuid) from public, anon, authenticated;
grant execute on function public.agent_ready_to_text(integer, boolean, boolean, timestamptz), public.agent_card(uuid) to service_role;
