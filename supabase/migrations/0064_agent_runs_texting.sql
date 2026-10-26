-- Muse runs all the texting (Colin 2026-10-26: "MUSE effective immediately is taking over all texting"). With
-- agent_runs_texting on:
--   * the reply agent still reads every reply, blocks removals, marks wrong numbers, moves the card and flags hot
--     replies, but it no longer queues an answer or asks the team for one ("Needs you"); the sender agent answers
--     through replies_waiting / send_reply;
--   * the belts' automatic nudge texts are skipped (the agent writes its own);
--   * the laptop's follow-up texts are handed to the agent like its first texts.
-- And the agent sees the whole picture for each card (Colin: "muse needs context about the property and person and
-- their entire message chat"): property, owner and mailing, reasons, every text both ways, calls, what the reply
-- agent learned, the card's stage and next step.

alter table public.campaign_control add column if not exists agent_runs_texting boolean not null default false;

create or replace function public.hand_opener_to_agent() returns trigger
language plpgsql security definer set search_path = public as $$
declare c public.campaign_control;
begin
  if coalesce(new.lane, '') = 'agent' or new.send_status <> 'planned' then return new; end if;
  select * into c from public.campaign_control where id = 1;
  if (new.step = 1 and c.agent_writes_openers) or (new.step > 1 and c.agent_runs_texting) then
    new.send_status := 'withdrawn';
    new.send_reason := 'handed to the sender agent';
  end if;
  return new;
end $$;

create or replace function public.agent_card(p_lead uuid) returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'lead_id', l.id, 'owner_name', l.owner_name, 'owner_type', l.owner_type,
    'address', l.property_address, 'city', l.municipality, 'county', l.county, 'zip', l.property_zip,
    'property', jsonb_build_object('type', l.property_type, 'units', l.units, 'parcel', l.parcel_id, 'lane', l.lane, 'score', l.score),
    'mailing', jsonb_build_object('street', l.mailing_street, 'city', l.mailing_city, 'state', l.mailing_state, 'zip', l.mailing_zip),
    'mailing_state', l.mailing_state,
    'stage', l.stage, 'belt', l.belt, 'next_step', l.next_stop_say, 'next_step_at', l.next_stop_at,
    'named_date', l.named_date, 'named_event', l.named_event,
    'elderly_or_ill', l.elderly_or_ill, 'grief', l.grief, 'notes', l.notes,
    'source', coalesce(l.source, case when l.wpie_owner_id > 0 then 'laptop' end),
    'reasons', l.reasons_to_sell,
    'reason_details', (select jsonb_agg(jsonb_build_object('kind', r.kind, 'detail', r.detail, 'date', r.event_date, 'amount', r.amount, 'source', r.source))
                         from public.prospect_reasons r where r.lead_id = l.id),
    'phones', (select jsonb_agg(jsonb_build_object('phone', c.value_normalized, 'type', c.line_type, 'name', c.person_name,
                      'textable', c.status = 'ok' and not c.dnc_app and not c.suppressed and not c.dnc_vendor and c.dnc_scrub <> 'dnc'
                                  and public.agent_phone_ok(c.value_normalized, c.line_type)))
                 from public.contacts c where c.lead_id = l.id and c.kind = 'phone'),
    -- every text both ways, oldest first, like a phone's thread
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

create or replace function public.agent_ready_to_text(p_limit integer, p_followups boolean, p_all boolean, p_now timestamptz default now())
returns jsonb language sql stable security definer set search_path = public as $$
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
     order by 5 limit greatest(1, least(p_limit, 300)))
  select jsonb_build_object(
    'new_cards', (select coalesce(jsonb_agg(public.agent_card(id) || jsonb_build_object('next_step', step, 'laptop_text', laptop_text,
                    'laptop_phone', laptop_phone)), '[]'::jsonb) from new_cards),
    'followups_due', (select coalesce(jsonb_agg(public.agent_card(id) || jsonb_build_object('next_step', step, 'due_since', due,
                    'laptop_text', laptop_text, 'laptop_phone', laptop_phone)), '[]'::jsonb) from follow))
$$;

-- replies the agent should answer: their latest text has no answer from us after it
create or replace function public.agent_replies_waiting(p_days integer default 7) returns jsonb
language sql stable security definer set search_path = public as $$
  with last_in as (
    select distinct on (t.from10) t.from10, t.lead_id, t.sid, t.body, t.received_at, t.to_number
      from public.twilio_inbound t
     where t.received_at > now() - make_interval(days => greatest(1, least(p_days, 30))) and t.lead_id is not null
     order by t.from10, t.received_at desc)
  select coalesce(jsonb_agg(public.agent_card(li.lead_id) || jsonb_build_object(
           'reply_to', jsonb_build_object('phone', li.from10, 'our_number', li.to_number, 'text', li.body, 'at', li.received_at),
           'reply_agent_read', (select jsonb_build_object('intent', d.intent, 'outcome', d.outcome, 'suggested_reply', d.body, 'note', d.note)
                                  from public.reply_drafts d where d.inbound_sid = li.sid),
           'hot', exists (select 1 from public.hot_alerts h where h.lead_id = li.lead_id and h.created_at > now() - interval '3 days'))
         order by li.received_at), '[]'::jsonb)
    from last_in li join public.leads l on l.id = li.lead_id
   where l.stage not in ('dnc', 'dead', 'closed_no_contact', 'closed_won')
     and not exists (select 1 from public.suppressed_phones s where s.phone10 = li.from10)
     and not exists (select 1 from public.messages m where m.direction = 'out' and m.channel = 'sms' and m.sent_at > li.received_at
                      and right(regexp_replace(coalesce(m.to_number, ''), '\D', '', 'g'), 10) = li.from10)
     and not exists (select 1 from public.reply_drafts d where d.phone10 = li.from10 and d.inbound_at >= li.received_at
                      and d.status in ('queued', 'sending', 'sent'))
$$;

-- the agent's answer becomes a one-off draft on that thread (kind team, so it is not read as their text), sent by
-- agent-mcp through the same gate as an approved reply: wording, opted out, newer text from them, quiet hours
create or replace function public.agent_start_reply(p_lead_id uuid, p_phone text, p_agent text) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  l public.leads;
  p text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10);
  li public.twilio_inbound;
  id uuid;
begin
  select * into l from public.leads where leads.id = p_lead_id;
  if not found then raise exception 'no such card'; end if;
  if l.stage = 'dnc' then raise exception 'this card is closed (do not contact)'; end if;
  if exists (select 1 from public.suppressed_phones s where s.phone10 = p) then raise exception 'this phone opted out'; end if;
  select * into li from public.twilio_inbound t where t.from10 = p and t.lead_id = p_lead_id order by t.received_at desc limit 1;
  if not found then raise exception 'they have not texted us from that phone: a first text or follow-up goes through queue_texts'; end if;
  insert into public.reply_drafts (phone10, our_number, lead_id, inbound_body, inbound_at, intent, kind, outcome, note, draft_source, status, notified_at)
  values (p, li.to_number, p_lead_id, li.body, now(), 'agent_reply', 'team', 'open', 'written by the sender agent (' || coalesce(p_agent, 'agent') || ')',
          'agent', 'awaiting_approval', now())
  returning reply_drafts.id into id;
  return id;
end $$;

revoke all on function public.agent_replies_waiting(integer), public.agent_start_reply(uuid, text, text) from public, anon, authenticated;
grant execute on function public.agent_replies_waiting(integer), public.agent_start_reply(uuid, text, text) to service_role;
revoke all on function public.agent_ready_to_text(integer, boolean, boolean, timestamptz), public.agent_card(uuid) from public, anon, authenticated;
grant execute on function public.agent_ready_to_text(integer, boolean, boolean, timestamptz), public.agent_card(uuid) to service_role;

-- the reply agent stops queuing answers when the sender agent runs the texting
create or replace function public.reply_record_decision(p_sid text, p_intent text, p_kind text, p_removal boolean, p_outcome text, p_body text, p_draft_source text, p_note text, p_rules_version text, p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  t public.twilio_inbound;
  c public.campaign_control;
  st text;
  did uuid;
  owner_phones text[];
  oid bigint;
begin
  select * into t from public.twilio_inbound where sid = p_sid;
  if not found then return jsonb_build_object('ok', false, 'reason', 'unknown_inbound'); end if;
  select * into c from public.campaign_control where id = 1;
  update public.reply_drafts set status = 'superseded', updated_at = p_now
   where phone10 = t.from10 and status in ('awaiting_approval', 'would_send', 'queued') and inbound_at < t.received_at;

  st := case
    -- the sender agent answers (agent_runs_texting): read, recorded, nothing queued and nothing for the team to approve
    when c.agent_runs_texting then 'no_reply'
    when p_body is null or btrim(p_body) = '' then case when p_kind = 'candidate' then 'awaiting_approval' else 'no_reply' end
    when p_kind = 'candidate' then 'awaiting_approval'
    when c.routine_enabled then 'queued'
    else 'would_send' end;
  insert into public.reply_drafts (inbound_sid, phone10, our_number, lead_id, inbound_body, inbound_at, intent, kind, outcome,
                                   note, body, draft_source, status, send_after, rules_version, created_at, updated_at)
  values (t.sid, t.from10, t.to_number, t.lead_id, t.body, t.received_at, p_intent, p_kind, p_outcome, p_note,
          nullif(btrim(coalesce(p_body, '')), ''), p_draft_source, st,
          case when st = 'queued' then public.auto_reply_at(p_now) else null end,
          p_rules_version, p_now, p_now)
  on conflict (inbound_sid) do nothing
  returning id into did;
  if did is null then return jsonb_build_object('ok', false, 'reason', 'already_decided'); end if;

  oid := (select l.wpie_owner_id from public.leads l where l.id = t.lead_id);
  if p_removal then
    select coalesce(array_agg(distinct ct.value_normalized), '{}') into owner_phones
      from public.contacts ct join public.leads l on l.id = ct.lead_id
     where ct.kind = 'phone' and ct.value_normalized is not null and (ct.value_normalized = t.from10 or l.wpie_owner_id = oid);
    owner_phones := array_append(owner_phones, t.from10);
    insert into public.suppressed_phones (phone10, reason, source)
      select distinct p, case when p = t.from10 then 'removal_reply' else 'removal_reply_other_phone' end, 'reply_agent'
        from unnest(owner_phones) p where p ~ '^[0-9]{10}$'
    on conflict (phone10) do nothing;
    update public.contacts set suppressed = true where value_normalized = any(owner_phones);
    update public.leads set stage = 'dnc' where id = t.lead_id;
  elsif p_outcome = 'wrong_number' then
    update public.contacts set status = 'bad', note = coalesce(note || '; ', '') || 'wrong number (reply agent)'
     where value_normalized = t.from10 and lead_id = t.lead_id;
    update public.leads set stage = 'data_fix' where id = t.lead_id and stage in ('postcard_mailed', 'opener_queued', 'opener_sent', 'reply_received');
  elsif p_outcome = 'not_interested' then
    update public.leads set stage = 'dead', dead_reason = coalesce(nullif(p_note, ''), 'not interested')
     where id = t.lead_id and stage in ('postcard_mailed', 'opener_queued', 'opener_sent', 'reply_received', 'ai_qualifying');
  else
    update public.leads set stage = case when p_kind = 'candidate' then 'reply_received'::public.lead_stage else 'ai_qualifying'::public.lead_stage end
     where id = t.lead_id and stage in ('postcard_mailed', 'opener_queued', 'opener_sent');
  end if;
  update public.leads set last_inbound_at = greatest(coalesce(last_inbound_at, t.received_at), t.received_at) where id = t.lead_id;
  return jsonb_build_object('ok', true, 'id', did, 'status', st);
end $function$;

-- the belts stop sending their own nudges when the sender agent runs the texting
create or replace function public.belt_claim_text(p_lead_id uuid, p_dry boolean DEFAULT true, p_force boolean DEFAULT false, p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare l public.leads; s public.belt_steps; t public.touch_templates; r public.belt_rules; stop_key text; ph text; ours text; txt text; tz text;
  did uuid; st text; slid timestamptz; since timestamptz; reason text;
begin
  select * into l from public.leads where id = p_lead_id for update;
  if not found or l.next_stop_who not in ('auto_text', 'draft_text') then return jsonb_build_object('outcome', 'refused', 'reason', 'not a text stop'); end if;
  select * into r from public.belt_rules where belt = l.belt;
  stop_key := format('belt:%s:%s:%s:%s', l.id, l.belt, l.belt_round, l.belt_step);
  -- the sender agent writes every text now (agent_runs_texting): the belt's own nudge is skipped, the stop moves on
  if (select agent_runs_texting from public.campaign_control where id = 1) then
    perform public.belt_event(l.id, 'stop_done', jsonb_build_object('outcome', 'skipped', 'reason', 'the texting agent writes the texts', 'key', 'textskip:' || stop_key), 'conveyor', p_now);
    return jsonb_build_object('outcome', 'skipped', 'reason', 'the texting agent writes the texts');
  end if;
  tz := public.belt_tz(l.mailing_state);
  select * into s from public.belt_steps where belt = l.belt and step = l.belt_step;
  if found then select * into t from public.touch_templates tt where tt.key = s.template_key; end if;
  -- never: dead, DNC, elderly / ill / grieving, a belt with no texts
  if l.belt in ('dead', 'dnc') or l.elderly_or_ill or l.grief or not coalesce(r.texts_ok, false) or s.belt is null or t.key is null then
    reason := case when l.belt in ('dead', 'dnc') then 'nothing to a dead or DNC card' when l.elderly_or_ill or l.grief then 'no texts to an elderly, ill or grieving owner'
                   when s.belt is null then 'no such step' when t.key is null then 'no template' else 'no texts on this belt' end;
    perform public.belt_event(l.id, 'stop_done', jsonb_build_object('outcome', 'skipped', 'reason', reason, 'key', 'textskip:' || stop_key), 'conveyor', p_now);
    return jsonb_build_object('outcome', 'skipped', 'reason', reason);
  end if;
  -- a morning-of reminder whose switch is off is skipped, never a draft: the slot itself must not wait on a tap
  if s.anchor = 'slot_morning' and not (t.enabled or p_force) then
    perform public.belt_event(l.id, 'stop_done', jsonb_build_object('outcome', 'skipped', 'reason', 'reminder switch is off', 'key', 'textskip:' || stop_key), 'conveyor', p_now);
    return jsonb_build_object('outcome', 'skipped', 'reason', 'reminder switch is off');
  end if;
  ph := public.belt_phone(l.id);
  if ph is null or exists (select 1 from public.suppressed_phones sp where sp.phone10 = ph) then
    reason := case when ph is null then 'no phone to text' else 'the phone opted out' end;
    perform public.belt_event(l.id, 'stop_done', jsonb_build_object('outcome', 'skipped', 'reason', reason, 'key', 'textskip:' || stop_key), 'conveyor', p_now);
    return jsonb_build_object('outcome', 'skipped', 'reason', reason);
  end if;
  -- their last text is still waiting for Colin's answer: no nudge on top of an unanswered question; try again in a day
  -- (2026-10-24: "as long as you think the system is smart enough to know the difference")
  if exists (select 1 from public.reply_drafts d where d.lead_id = l.id and d.kind in ('candidate', 'after_close')
               and d.status in ('awaiting_approval', 'queued') and not d.is_test) then
    slid := p_now + interval '24 hours';
    update public.leads set next_stop_at = slid, next_action_at = slid where id = l.id;
    update public.tasks set due_at = slid where source = 'belt' and source_key = stop_key and done_at is null;
    return jsonb_build_object('outcome', 'slid', 'to', slid, 'reason', 'their text is waiting for Colin');
  end if;
  -- they wrote, or a person did, since this stop was set: the stop is stale
  since := coalesce((select max(e.at) from public.belt_events e where e.lead_id = l.id and e.to_belt = l.belt and e.step = l.belt_step), l.belt_entered_at, p_now);
  if exists (select 1 from public.twilio_inbound i where i.lead_id = l.id and i.received_at > since)
     or exists (select 1 from public.messages m where m.lead_id = l.id and m.sent_at > since and ((m.direction = 'in') or (m.direction = 'out' and m.created_by is not null))) then
    perform public.belt_event(l.id, 'stop_done', jsonb_build_object('outcome', 'skipped', 'reason', 'they wrote since this stop was set', 'key', 'textskip:' || stop_key), 'conveyor', p_now);
    return jsonb_build_object('outcome', 'skipped', 'reason', 'they wrote since this stop was set');
  end if;
  -- 8am-8pm recipient local, never Sunday: slide, never earlier
  slid := public.belt_slide(p_now, tz, 'text', null);
  if slid > p_now + interval '5 minutes' then
    update public.leads set next_stop_at = slid, next_action_at = slid where id = l.id;
    update public.tasks set due_at = slid where source = 'belt' and source_key = stop_key and done_at is null;
    return jsonb_build_object('outcome', 'slid', 'to', slid);
  end if;
  txt := public.belt_render(t.wording, l);
  if l.belt = 'not_now_dated' and l.named_date is not null and l.named_date <= p_now and s.anchor = 'named' and s.delay_hours < 0 then
    perform public.belt_event(l.id, 'stop_done', jsonb_build_object('outcome', 'skipped', 'reason', 'the date has passed', 'key', 'textskip:' || stop_key), 'conveyor', p_now);
    return jsonb_build_object('outcome', 'skipped', 'reason', 'the date has passed');
  end if;
  ours := public.belt_our_number(l.id, ph);
  st := case when l.next_stop_who = 'auto_text' and t.auto and (t.enabled or p_force) then 'queued' else 'awaiting_approval' end;
  insert into public.reply_drafts (inbound_sid, phone10, our_number, lead_id, inbound_body, inbound_at, intent, kind, outcome, note, body,
                                   draft_source, status, send_after, rules_version, belt_stop_key, created_at, updated_at)
  values (null, ph, ours, l.id, null, p_now, 'belt', 'belt', t.key,
          format('belt stop: %s, stop %s of %s%s', r.label, l.belt_step, public.belt_max_step(l.belt),
                 case when st = 'awaiting_approval' and l.next_stop_who = 'auto_text' then ' (its switch is off: your tap sends it)' else '' end),
          txt, case when st = 'queued' then 'belt_auto' else 'belt_draft' end, st, null, null, stop_key, p_now, p_now)
  on conflict (belt_stop_key) where belt_stop_key is not null do nothing
  returning id into did;
  if did is null then
    select id, status into did, st from public.reply_drafts where belt_stop_key = stop_key;
    if st not in ('queued') then return jsonb_build_object('outcome', st, 'id', did, 'already', true); end if;
  end if;
  if st = 'awaiting_approval' then
    update public.tasks set note = 'Tap the draft on Approve: ' || left(txt, 160) || case when length(txt) > 160 then '...' else '' end,
           title = coalesce(title, 'Draft text')
     where source = 'belt' and source_key = stop_key and done_at is null;
    if not exists (select 1 from public.tasks where source = 'belt' and source_key = stop_key) then
      insert into public.tasks (lead_id, due_at, kind, owner, note, title, source, source_key, phone10, created_by)
      values (l.id, p_now, 'text', 'colin', 'Tap the draft on Approve: ' || left(txt, 160), format('%s: stop %s of %s (tap to send)', r.label, l.belt_step, public.belt_max_step(l.belt)), 'belt', stop_key, ph, null)
      on conflict (source_key) do update set done_at = null, note = excluded.note, due_at = excluded.due_at;
    end if;
    return jsonb_build_object('outcome', 'awaiting_approval', 'id', did, 'body', txt, 'to', '+1' || ph);
  end if;
  if p_dry then
    update public.reply_drafts set status = 'dry_sent', sent_body = txt, decided_by = 'conveyor', decided_at = p_now, updated_at = p_now,
           note = coalesce(note, '') || ' | would send (live sending is off)' where id = did;
    return jsonb_build_object('outcome', 'dry_sent', 'id', did, 'body', txt, 'to', '+1' || ph);
  end if;
  update public.reply_drafts set status = 'sending', sent_body = txt, decided_by = 'conveyor', decided_at = p_now, updated_at = p_now where id = did;
  return jsonb_build_object('outcome', 'send', 'id', did, 'to', '+1' || ph, 'from', ours, 'body', txt);
end $function$;

-- ------------------------------------------------------------------ "do we already have them?" (Colin 2026-10-26)
-- One address key for every card, the laptop's included: upper case, no punctuation, the first address of a
-- two-address card, and the common spellings evened out (STREET = ST, NORTH = N ...).
create or replace function public.addr_key(p text) returns text language plpgsql immutable as $$
declare
  k text := ' ' || upper(regexp_replace(split_part(coalesce(p, ''), ';', 1), '[^A-Za-z0-9 ]', ' ', 'g')) || ' ';
  pair text[];
begin
  k := regexp_replace(k, '\s+', ' ', 'g');
  foreach pair slice 1 in array array[['STREET','ST'],['AVENUE','AVE'],['AV','AVE'],['ROAD','RD'],['DRIVE','DR'],['LANE','LN'],
      ['COURT','CT'],['BOULEVARD','BLVD'],['BL','BLVD'],['PLACE','PL'],['CIRCLE','CIR'],['TERRACE','TER'],['PARKWAY','PKWY'],
      ['HIGHWAY','HWY'],['NORTH','N'],['SOUTH','S'],['EAST','E'],['WEST','W']] loop
    k := replace(k, ' ' || pair[1] || ' ', ' ' || pair[2] || ' ');
  end loop;
  return nullif(btrim(k), '');
end $$;
create index if not exists leads_addr_key_idx on public.leads (public.addr_key(property_address));

-- add_prospects, again: an address we already have (any card, the laptop's too) is not a new card. Its new phones
-- and reasons go onto that card, and the result says so (already_have, with the card's stage and whether it was
-- texted). A phone that is already on another card is not added twice.
create or replace function public.agent_add_prospect(p jsonb, p_agent text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  ak     text := public.addr_key(p->>'address');
  owner  text := btrim(coalesce(p->>'owner_name', ''));
  zip    text := left(coalesce(p->>'zip', ''), 5);
  lid    uuid;
  ex     public.leads;
  status text := 'created';
  ph     jsonb;
  r      jsonb;
  num    text;
  other  uuid;
  added  jsonb := '[]'::jsonb;
  skipped jsonb := '[]'::jsonb;
  reasons text[];
begin
  if ak is null then return jsonb_build_object('status', 'rejected', 'reason', 'no address'); end if;
  if owner = '' then return jsonb_build_object('status', 'rejected', 'reason', 'no owner name'); end if;
  select * into ex from public.leads l
   where public.addr_key(l.property_address) = ak
     and (zip = '' or coalesce(l.property_zip, '') = '' or left(l.property_zip, 5) = zip)
   order by (lower(l.owner_name) = lower(owner)) desc, (l.wpie_owner_id > 0) desc, l.created_at limit 1;
  select coalesce(array_agg(distinct coalesce(nullif(x->>'label', ''), x->>'kind')), '{}') into reasons
    from jsonb_array_elements(coalesce(p->'reasons', '[]'::jsonb)) x where coalesce(x->>'kind', '') <> '';
  if ex.id is null then
    insert into public.leads (wpie_owner_id, owner_name, owner_type, mailing_street, mailing_city, mailing_state, mailing_zip,
                              lane, county, municipality, property_address, property_zip, property_type, units,
                              reasons_to_sell, stage, source, notes)
    values (-nextval('public.agent_prospect_seq'), owner, nullif(p->>'owner_type', ''), nullif(p->>'mailing_street', ''),
            nullif(p->>'mailing_city', ''), nullif(p->>'mailing_state', ''), nullif(p->>'mailing_zip', ''),
            case when p->>'lane' = 'hold' then 'hold'::public.lead_lane else 'flip'::public.lead_lane end,
            nullif(p->>'county', ''), nullif(coalesce(p->>'city', p->>'municipality'), ''), btrim(p->>'address'),
            nullif(p->>'zip', ''), nullif(p->>'property_type', ''), nullif(p->>'units', '')::int,
            reasons, 'opener_queued', coalesce(nullif(p->>'source', ''), 'muse'), nullif(p->>'notes', ''))
    returning id into lid;
  else
    lid := ex.id;
    status := case when ex.wpie_owner_id < 0 then 'updated' else 'already_have' end;
    update public.leads set reasons_to_sell = (select array_agg(distinct x) from unnest(reasons_to_sell || reasons) x),
           notes = case when nullif(p->>'notes', '') is null then notes else concat_ws(' | ', notes, 'Muse: ' || (p->>'notes')) end,
           updated_at = now()
     where id = lid;
  end if;
  for ph in select * from jsonb_array_elements(coalesce(p->'phones', '[]'::jsonb)) loop
    num := right(regexp_replace(coalesce(case when jsonb_typeof(ph) = 'string' then ph #>> '{}' else ph->>'number' end, ''), '\D', '', 'g'), 10);
    other := null;
    select c.lead_id into other from public.contacts c where c.value_normalized = num and c.lead_id <> lid limit 1;
    if num !~ '^[2-9][0-9]{2}[2-9][0-9]{6}$' then
      skipped := skipped || jsonb_build_object('number', coalesce(ph->>'number', ph #>> '{}'), 'why', 'not a US phone number');
    elsif exists (select 1 from public.contacts c where c.lead_id = lid and c.value_normalized = num) then
      skipped := skipped || jsonb_build_object('number', num, 'why', 'already on this card');
    elsif other is not null then
      skipped := skipped || jsonb_build_object('number', num, 'why', 'already on another card', 'lead_id', other);
    else
      insert into public.contacts (lead_id, kind, value, value_normalized, person_name, line_type, source, confidence, note)
      values (lid, 'phone', num, num, nullif(ph->>'name', ''), nullif(lower(ph->>'type'), ''), 'muse:' || coalesce(p_agent, 'agent'),
              nullif(ph->>'confidence', '')::numeric, nullif(ph->>'note', ''));
      added := added || to_jsonb(num);
      if exists (select 1 from public.suppressed_phones s where s.phone10 = num) then
        skipped := skipped || jsonb_build_object('number', num, 'why', 'opted out before: kept on the card, never texted');
      end if;
    end if;
  end loop;
  for r in select * from jsonb_array_elements(coalesce(p->'reasons', '[]'::jsonb)) loop
    if coalesce(r->>'kind', '') = '' then continue; end if;
    insert into public.prospect_reasons (lead_id, kind, detail, event_date, amount, source, added_by)
    values (lid, r->>'kind', nullif(r->>'detail', ''), nullif(r->>'date', '')::date, nullif(r->>'amount', '')::numeric,
            nullif(r->>'source', ''), p_agent)
    on conflict do nothing;
  end loop;
  return jsonb_build_object('status', status, 'lead_id', lid, 'phones_added', added, 'phones_skipped', skipped,
    'existing', case when ex.id is null then null else jsonb_build_object('owner_name', ex.owner_name, 'stage', ex.stage,
      'source', coalesce(ex.source, case when ex.wpie_owner_id > 0 then 'laptop' end),
      'texted', exists (select 1 from public.messages m where m.lead_id = ex.id and m.direction = 'out' and m.channel = 'sms')) end);
end $$;
revoke all on function public.agent_add_prospect(jsonb, text) from public, anon, authenticated;
grant execute on function public.agent_add_prospect(jsonb, text) to service_role;
