-- What is due (Colin 2026-10-26: "will it know when it's time to follow up with some guy in 30 days ... we're
-- waiting for a contract signature from this guy"). The card already carries the why (named_event, next_step,
-- notes); nothing listed the when. agent_due_today lists every card whose date has come, with the reason it was
-- waiting, and the contracts out for signature. agent_card now shows the card's contracts.

create or replace function public.card_contracts(p_lead uuid) returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('contract_id', c.id, 'form', c.form, 'status', c.status, 'sent_at', c.created_at,
           'signed_at', c.signed_at, 'voided_at', c.voided_at, 'days_out', (extract(epoch from now() - c.created_at) / 86400)::int,
           'signers', (select jsonb_agg(jsonb_build_object('name', s.name, 'phone', s.phone, 'opened_at', s.opened_at, 'signed_at', s.signed_at,
                        'expires_at', s.expires_at) order by s.position) from public.contract_signers s where s.contract_id = c.id))
           order by c.created_at desc), '[]'::jsonb)
    from public.contracts c where c.lead_id = p_lead
$$;

create or replace function public.agent_due_today(p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public as $$
  with due as (
    -- a dated check-back ("not now, until Dec 1"; a hold with a date; estate / family / elderly waits)
    select l.id, 'check_back' as what, coalesce(l.named_date, l.next_action_at) as due_at,
           coalesce(nullif(l.named_event, ''), nullif(l.next_action, ''), 'check back') as why
      from public.leads l
     where l.stage not in ('dnc', 'dead', 'closed_no_contact', 'closed_won')
       and ((l.stage = 'follow_up' and l.next_action_at <= p_now)
            or (l.belt in ('not_now_dated', 'hold_not_now', 'estate_waiting', 'needs_family', 'elderly', 'not_now_condition') and l.named_date <= p_now))
    union all
    -- a booked call or visit, today or past
    select l.id, case when l.belt = 'visit_booked' or l.named_event = 'visit' then 'booked_visit' else 'booked_call' end,
           coalesce(l.named_date, l.next_stop_at), coalesce(nullif(l.next_stop_say, ''), 'booked')
      from public.leads l
     where l.belt in ('call_booked', 'visit_booked') and coalesce(l.named_date, l.next_stop_at) <= p_now + interval '12 hours'
    union all
    -- any other stop on a warm card whose time has come (a call the team owes, a text the agent owes)
    select l.id, case when l.next_stop_who in ('thalia_call', 'colin_call', 'colin_visit') then 'call_due' else 'text_due' end,
           l.next_stop_at, coalesce(nullif(l.next_stop_say, ''), l.belt)
      from public.leads l
     where l.belt not in ('cold_texts', 'dead', 'dnc', 'call_booked', 'visit_booked', 'not_now_dated', 'hold_not_now', 'estate_waiting', 'needs_family', 'elderly', 'not_now_condition')
       and l.stage not in ('dnc', 'dead', 'closed_no_contact', 'closed_won') and l.next_stop_at <= p_now
    union all
    -- a contract out for signature
    select c.lead_id, 'contract_waiting', c.created_at,
           'contract sent ' || to_char(c.created_at at time zone 'America/Chicago', 'Mon DD') || ', not signed'
           || coalesce(' (' || (select string_agg(s.name, ', ') from public.contract_signers s where s.contract_id = c.id and s.signed_at is null) || ' still to sign)', '')
      from public.contracts c
     where c.status = 'sent' and c.voided_at is null)
  select coalesce(jsonb_agg(public.agent_card(d.id) || jsonb_build_object('what', d.what, 'due_at', d.due_at, 'why', d.why,
           'days_late', greatest(0, (extract(epoch from p_now - d.due_at) / 86400)::int)) order by d.due_at), '[]'::jsonb)
    from (select distinct on (id, what) id, what, due_at, why from due order by id, what, due_at) d
$$;

-- agent_card with the contracts
create or replace function public.agent_card(p_lead uuid) returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'lead_id', l.id, 'owner_name', l.owner_name, 'owner_type', l.owner_type,
    'address', l.property_address, 'city', l.municipality, 'county', l.county, 'zip', l.property_zip,
    'property', jsonb_build_object('type', l.property_type, 'units', l.units, 'parcel', l.parcel_id, 'lane', l.lane, 'score', l.score),
    'mailing', jsonb_build_object('street', l.mailing_street, 'city', l.mailing_city, 'state', l.mailing_state, 'zip', l.mailing_zip),
    'mailing_state', l.mailing_state,
    'stage', l.stage, 'belt', l.belt, 'next_step', l.next_stop_say, 'next_step_at', l.next_stop_at,
    'check_back_at', l.next_action_at, 'named_date', l.named_date, 'named_event', l.named_event,
    'elderly_or_ill', l.elderly_or_ill, 'grief', l.grief, 'notes', l.notes,
    'source', coalesce(l.source, case when l.wpie_owner_id > 0 then 'laptop' end),
    'reasons', l.reasons_to_sell,
    'reason_details', (select jsonb_agg(jsonb_build_object('kind', r.kind, 'detail', r.detail, 'date', r.event_date, 'amount', r.amount, 'source', r.source))
                         from public.prospect_reasons r where r.lead_id = l.id),
    'phones', (select jsonb_agg(jsonb_build_object('phone', c.value_normalized, 'type', c.line_type, 'name', c.person_name,
                      'textable', c.status = 'ok' and not c.dnc_app and not c.suppressed and not c.dnc_vendor and c.dnc_scrub <> 'dnc'
                                  and public.agent_phone_ok(c.value_normalized, c.line_type),
                      'also_on', (select jsonb_agg(jsonb_build_object('lead_id', c2.lead_id, 'owner_name', l2.owner_name, 'address', l2.property_address))
                                    from public.contacts c2 join public.leads l2 on l2.id = c2.lead_id
                                   where c2.value_normalized = c.value_normalized and c2.lead_id <> l.id)))
                 from public.contacts c where c.lead_id = l.id and c.kind = 'phone'),
    'links', public.card_links(l.id),
    'contracts', public.card_contracts(l.id),
    'conversation', (select jsonb_agg(x order by x->>'at') from (
        select jsonb_build_object('at', m.sent_at, 'who', case when m.direction = 'out' then 'us' else 'them' end,
                 'phone', case when m.direction = 'out' then m.to_number else m.from_number end,
                 'our_number', case when m.direction = 'out' then m.from_number else m.to_number end, 'text', m.body, 'status', m.status) x
          from public.messages m where m.lead_id = l.id and m.channel = 'sms'
        union all
        select jsonb_build_object('at', t.received_at, 'who', 'them', 'phone', t.from10, 'our_number', t.to_number, 'text', t.body,
                 'stop', t.is_opt_out)
          from public.twilio_inbound t where t.lead_id = l.id
           and not exists (select 1 from public.messages m2 where m2.lead_id = l.id and m2.direction = 'in' and m2.provider_sid = t.sid)) q),
    'calls', (select jsonb_agg(jsonb_build_object('at', m.sent_at, 'outcome', m.status, 'note', m.body) order by m.sent_at)
                from public.messages m where m.lead_id = l.id and m.channel = 'call'),
    'call_facts', l.call_facts,
    'what_we_know', coalesce((select jsonb_object_agg(k, v) from (
                 select distinct on (e.key) e.key as k, e.value as v
                   from public.reply_drafts d, jsonb_each(d.facts) e
                  where d.lead_id = l.id and d.facts is not null and jsonb_typeof(d.facts) = 'object'
                  order by e.key, d.inbound_at desc) f), '{}'::jsonb),
    'replied', exists (select 1 from public.twilio_inbound t where t.lead_id = l.id),
    'waiting', (select jsonb_agg(jsonb_build_object('text_id', p.id, 'step', p.step, 'goes_after', p.scheduled_at, 'status', p.send_status))
                  from public.planned_openers p where p.lead_id = l.id and p.send_status in ('planned', 'would_send', 'sending')))
  from public.leads l where l.id = p_lead
$$;

revoke all on function public.card_contracts(uuid), public.agent_due_today(timestamptz), public.agent_card(uuid) from public, anon, authenticated;
grant execute on function public.card_contracts(uuid), public.agent_due_today(timestamptz), public.agent_card(uuid) to service_role;
