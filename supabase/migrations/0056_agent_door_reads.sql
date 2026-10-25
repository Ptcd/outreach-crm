-- The agent door, part 2: what the agents read (cards, what is ready to text, today's queue, results, status) and
-- the sender agent's pause / resume. A pause Colin or the team made can only be lifted in the app.

create or replace function public.agent_phone_ok(p_phone10 text, p_line_type text) returns boolean language sql stable as $$
  select coalesce(lower(p_line_type), 'mobile') not in ('landline')
     and not exists (select 1 from public.suppressed_phones s where s.phone10 = p_phone10)
$$;

create or replace function public.agent_card(p_lead uuid) returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'lead_id', l.id, 'owner_name', l.owner_name, 'address', l.property_address, 'city', l.municipality, 'county', l.county,
    'zip', l.property_zip, 'mailing_state', l.mailing_state, 'stage', l.stage,
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

create or replace function public.agent_find(p jsonb) returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(public.agent_card(x.id)), '[]'::jsonb) from (
    select l.id from public.leads l
     where (coalesce(p->>'lead_id', '') = '' or l.id::text = p->>'lead_id')
       and (coalesce(p->>'address', '') = '' or l.property_address ilike '%' || (p->>'address') || '%')
       and (coalesce(p->>'name', '') = '' or l.owner_name ilike '%' || (p->>'name') || '%')
       and (coalesce(p->>'phone', '') = '' or exists (select 1 from public.contacts c where c.lead_id = l.id
              and c.value_normalized = right(regexp_replace(p->>'phone', '\D', '', 'g'), 10)))
       and (not coalesce((p->>'only_agent')::boolean, false) or l.wpie_owner_id < 0)
     order by l.updated_at desc limit least(coalesce((p->>'limit')::int, 20), 100)) x
$$;

create or replace function public.agent_counts() returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'agent_cards', (select count(*) from public.leads where wpie_owner_id < 0),
    'by_stage', (select coalesce(jsonb_object_agg(st, n), '{}') from (select stage::text st, count(*) n from public.leads where wpie_owner_id < 0 group by 1) a),
    'by_source', (select coalesce(jsonb_object_agg(src, n), '{}') from (select coalesce(source, 'muse') src, count(*) n from public.leads where wpie_owner_id < 0 group by 1) b))
$$;

create or replace function public.agent_status(p_now timestamptz default now()) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare c public.campaign_control; today date;
begin
  select * into c from public.campaign_control where id = 1;
  today := (p_now at time zone c.timezone)::date;
  return jsonb_build_object(
    'sending_switch_on', c.sending_enabled, 'paused', c.paused, 'pause_reason', c.pause_reason,
    'no_sundays', c.no_sundays, 'window', to_char(c.window_start, 'HH24:MI') || '-' || to_char(c.window_end, 'HH24:MI') || ' recipient local',
    'daily_limit', c.daily_cap, 'today', today, 'sunday_today', extract(isodow from p_now at time zone c.timezone) = 7,
    'sent_today', (select count(*) from public.planned_openers p where p.claim_mode = 'live' and p.send_status = any(public.opener_live_statuses())
                     and (p.claimed_at at time zone c.timezone)::date = today),
    'today_by_status', (select coalesce(jsonb_object_agg(s, n), '{}') from (select send_status s, count(*) n from public.planned_openers
                          where plan_date = today group by 1) a),
    'today_agent_by_status', (select coalesce(jsonb_object_agg(s, n), '{}') from (select send_status s, count(*) n from public.planned_openers
                          where plan_date = today and lane = 'agent' group by 1) b),
    'replies_today', (select count(*) from public.twilio_inbound t where (t.received_at at time zone c.timezone)::date = today and not t.is_opt_out),
    'stops_today', (select count(*) from public.twilio_inbound t where (t.received_at at time zone c.timezone)::date = today and t.is_opt_out));
end $$;

create or replace function public.agent_ready_to_text(p_limit integer, p_followups boolean, p_all boolean, p_now timestamptz default now())
returns jsonb language sql stable security definer set search_path = public as $$
  with new_cards as (
    select l.id, 1 as step from public.leads l
     where l.stage in ('opener_queued', 'postcard_mailed') and (p_all or l.wpie_owner_id < 0)
       and not exists (select 1 from public.planned_openers po where po.lead_id = l.id
                        and po.send_status in ('planned', 'would_send', 'sending', 'sent', 'delivered'))
       and not exists (select 1 from public.messages m where m.lead_id = l.id and m.direction = 'out' and m.channel = 'sms')
       and exists (select 1 from public.contacts c where c.lead_id = l.id and c.kind = 'phone' and c.status = 'ok' and not c.dnc_app
                    and not c.suppressed and not c.dnc_vendor and c.dnc_scrub <> 'dnc' and public.agent_phone_ok(c.value_normalized, c.line_type))
     order by l.created_at limit greatest(1, least(p_limit, 300))),
  sent as (
    select m.lead_id, min(m.sent_at) first_at, max(m.sent_at) last_at, count(*) n from public.messages m
     where m.direction = 'out' and m.channel = 'sms' and m.provider_sid is not null group by 1),
  follow as (
    select l.id, (s.n + 1)::int as step,
           s.first_at + (case s.n + 1 when 2 then 2 when 3 then 9 when 4 then 16 else 23 end) * interval '1 day' as due
      from public.leads l join sent s on s.lead_id = l.id
     where p_followups and l.stage = 'opener_sent' and (p_all or l.wpie_owner_id < 0) and s.n < 5
       and not exists (select 1 from public.twilio_inbound t where t.lead_id = l.id)
       and not exists (select 1 from public.planned_openers po where po.lead_id = l.id and po.send_status in ('planned', 'would_send', 'sending'))
       and s.last_at < p_now - interval '3 days'
       and s.first_at + (case s.n + 1 when 2 then 2 when 3 then 9 when 4 then 16 else 23 end) * interval '1 day' <= p_now
     order by 3 limit greatest(1, least(p_limit, 300)))
  select jsonb_build_object(
    'new_cards', (select coalesce(jsonb_agg(public.agent_card(id) || jsonb_build_object('next_step', step)), '[]'::jsonb) from new_cards),
    'followups_due', (select coalesce(jsonb_agg(public.agent_card(id) || jsonb_build_object('next_step', step, 'due_since', due)), '[]'::jsonb) from follow))
$$;

create or replace function public.agent_queue_list(p_date date) returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('text_id', p.id, 'lead_id', p.lead_id, 'owner_name', p.owner_name, 'address', p.property_address,
          'phone', p.phone, 'step', p.step, 'from', case when p.lane = 'agent' then 'agent' else 'laptop' end, 'status', p.send_status,
          'reason', p.send_reason, 'goes_after', p.scheduled_at, 'body', p.body) order by p.scheduled_at), '[]'::jsonb)
    from public.planned_openers p
   where p.plan_date = coalesce(p_date, (now() at time zone (select timezone from public.campaign_control where id = 1))::date)
$$;

create or replace function public.agent_results(p_hours integer) returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'texts', (select coalesce(jsonb_agg(jsonb_build_object('text_id', p.id, 'lead_id', p.lead_id, 'owner_name', p.owner_name, 'phone', p.phone,
               'step', p.step, 'from', case when p.lane = 'agent' then 'agent' else 'laptop' end, 'status', p.send_status,
               'error_code', p.error_code, 'reason', p.send_reason, 'at', coalesce(p.sent_at, p.send_updated_at)) order by p.send_updated_at desc), '[]'::jsonb)
                from public.planned_openers p where p.send_updated_at > now() - make_interval(hours => p_hours)
                 and p.send_status <> 'planned'),
    'counts', (select coalesce(jsonb_object_agg(s, n), '{}') from (select send_status s, count(*) n from public.planned_openers
                where send_updated_at > now() - make_interval(hours => p_hours) group by 1) a),
    'replies', (select coalesce(jsonb_agg(jsonb_build_object('lead_id', t.lead_id, 'owner_name', l.owner_name, 'phone', t.from10,
                 'stop', t.is_opt_out, 'text', t.body, 'at', t.received_at) order by t.received_at desc), '[]'::jsonb)
                  from public.twilio_inbound t left join public.leads l on l.id = t.lead_id
                 where t.received_at > now() - make_interval(hours => p_hours)))
$$;

create or replace function public.agent_pause(p_reason text, p_agent text) returns jsonb language plpgsql security definer set search_path = public as $$
begin
  update public.campaign_control set paused = true, pause_reason = 'Muse (' || coalesce(p_agent, 'agent') || '): ' || left(coalesce(p_reason, ''), 200),
         paused_at = now() where id = 1;
  return jsonb_build_object('paused', true);
end $$;

create or replace function public.agent_resume(p_agent text) returns jsonb language plpgsql security definer set search_path = public as $$
declare c public.campaign_control;
begin
  select * into c from public.campaign_control where id = 1;
  if not c.paused then return jsonb_build_object('paused', false, 'note', 'sending was not paused'); end if;
  if coalesce(c.pause_reason, '') not like 'Muse (%' then
    return jsonb_build_object('paused', true, 'refused', 'Colin or the team paused sending (' || coalesce(c.pause_reason, 'no reason given') || '): only the app can lift it');
  end if;
  update public.campaign_control set paused = false, pause_reason = null, paused_at = null where id = 1;
  return jsonb_build_object('paused', false);
end $$;

revoke all on function public.agent_card(uuid), public.agent_find(jsonb), public.agent_counts(), public.agent_status(timestamptz),
  public.agent_ready_to_text(integer, boolean, boolean, timestamptz), public.agent_queue_list(date), public.agent_results(integer),
  public.agent_pause(text, text), public.agent_resume(text) from public, anon, authenticated;
grant execute on function public.agent_card(uuid), public.agent_find(jsonb), public.agent_counts(), public.agent_status(timestamptz),
  public.agent_ready_to_text(integer, boolean, boolean, timestamptz), public.agent_queue_list(date), public.agent_results(integer),
  public.agent_pause(text, text), public.agent_resume(text) to service_role;
