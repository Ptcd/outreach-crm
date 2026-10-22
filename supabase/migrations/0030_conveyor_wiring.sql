-- Wiring every existing entry point into belt_event (0029), the conveyor's own SQL, and the health
-- checks. The reply agent's code (functions/_shared/reply*.ts) is not touched: it is hooked by triggers
-- on the rows it writes (reply_drafts, tasks, hot_alerts) and on what the laptop syncs (reply_threads).

-- ------------------------------------------------------------------ a) an inbound text, decided
create or replace function public.belt_on_reply_draft() returns trigger
language plpgsql security definer set search_path = public as $$
declare pl jsonb;
begin
  if new.lead_id is null or new.kind = 'belt' or new.is_test then return new; end if;
  pl := jsonb_build_object('key', 'draft:' || new.id::text, 'intent', new.intent, 'kind', new.kind, 'outcome', new.outcome,
          'removal', new.kind = 'removal', 'said', left(coalesce(new.inbound_body, ''), 300), 'at', new.inbound_at,
          'facts', coalesce(new.facts, '{}'::jsonb), 'callback_slot', new.facts->>'callback_slot');
  perform public.belt_event(new.lead_id, 'inbound_text', pl, 'reply agent', coalesce(new.created_at, now()));
  return new;
end $$;
drop trigger if exists belt_on_reply_draft on public.reply_drafts;
create trigger belt_on_reply_draft after insert on public.reply_drafts
  for each row execute function public.belt_on_reply_draft();

-- the facts the drafter read arrive a moment later (reply_set_facts): a nurture or a slot moves the card
create or replace function public.belt_on_reply_facts() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.lead_id is null or new.kind = 'belt' or new.is_test or new.facts is null or new.facts is not distinct from old.facts then return new; end if;
  if coalesce((new.facts->>'nurture')::boolean, false) or nullif(new.facts->>'callback_slot', '') is not null then
    perform public.belt_event(new.lead_id, 'inbound_text', jsonb_build_object('key', 'facts:' || new.id::text, 'intent', new.intent, 'kind', new.kind,
      'outcome', new.outcome, 'said', left(coalesce(new.inbound_body, ''), 300), 'at', new.inbound_at, 'facts', new.facts,
      'callback_slot', new.facts->>'callback_slot'), 'reply agent', now());
  end if;
  return new;
end $$;
drop trigger if exists belt_on_reply_facts on public.reply_drafts;
create trigger belt_on_reply_facts after update of facts on public.reply_drafts
  for each row execute function public.belt_on_reply_facts();

-- a belt draft Colin tapped (sent / dry) or skipped: the next stop
create or replace function public.belt_on_draft_status() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.kind <> 'belt' or new.lead_id is null or new.status is not distinct from old.status then return new; end if;
  if new.status in ('sent', 'dry_sent') then
    update public.tasks set done_at = coalesce(done_at, now()), note = coalesce(note, '') || ' [text went]'
     where source = 'belt' and source_key = new.belt_stop_key and done_at is null;
    perform public.belt_event(new.lead_id, case when new.draft_source = 'belt_auto' then 'auto_text_sent' else 'draft_sent' end,
      jsonb_build_object('key', 'sent:' || new.id::text, 'draft_id', new.id, 'template', new.outcome, 'dry', new.status = 'dry_sent'),
      coalesce(new.decided_by, 'conveyor'), now());
  elsif new.status = 'skipped' then
    update public.tasks set done_at = coalesce(done_at, now()), note = coalesce(note, '') || ' [skipped]'
     where source = 'belt' and source_key = new.belt_stop_key and done_at is null;
    perform public.belt_event(new.lead_id, 'draft_skipped', jsonb_build_object('key', 'skip:' || new.id::text, 'draft_id', new.id), coalesce(new.decided_by, 'conveyor'), now());
  end if;
  return new;
end $$;
drop trigger if exists belt_on_draft_status on public.reply_drafts;
create trigger belt_on_draft_status after update of status on public.reply_drafts
  for each row execute function public.belt_on_draft_status();

-- ------------------------------------------------------------------ b) the laptop's thread (synced)
create or replace function public.belt_on_reply_thread() returns trigger
language plpgsql security definer set search_path = public as $$
declare pl jsonb;
begin
  if new.lead_id is null then return new; end if;
  if tg_op = 'UPDATE' and new.agent_stage is not distinct from old.agent_stage and new.outcome is not distinct from old.outcome
     and new.callback_slot is not distinct from old.callback_slot and new.last_inbound_at is not distinct from old.last_inbound_at
     and new.human_owned is not distinct from old.human_owned then return new; end if;
  if new.human_owned and (tg_op = 'INSERT' or not old.human_owned) then
    perform public.belt_event(new.lead_id, 'human_text', jsonb_build_object('key', 'thread_human:' || new.phone10 || ':' || coalesce(new.last_inbound_at::text, '')), 'laptop', now());
  end if;
  if new.last_inbound_at is null then return new; end if;
  pl := jsonb_build_object('key', 'thread:' || new.phone10 || ':' || new.last_inbound_at::text || ':' || coalesce(new.outcome, '') || ':' || coalesce(new.agent_stage, ''),
          'intent', new.intent, 'kind', 'thread', 'agent_stage', new.agent_stage, 'thread_outcome', new.outcome,
          'callback_slot', new.callback_slot, 'said', left(coalesce(new.last_inbound, ''), 300), 'at', new.last_inbound_at,
          'facts', coalesce(new.facts, '{}'::jsonb),
          'outcome', case new.outcome when 'close_dnc' then 'dnc' when 'close_wrong_number' then 'wrong_number' when 'close_not_interested' then 'not_interested' else null end,
          'removal', new.outcome = 'close_dnc');
  perform public.belt_event(new.lead_id, 'inbound_text', pl, 'laptop', now());
  return new;
end $$;
drop trigger if exists belt_on_reply_thread on public.reply_threads;
create trigger belt_on_reply_thread after insert or update on public.reply_threads
  for each row execute function public.belt_on_reply_thread();

-- ------------------------------------------------------------------ c) a hot reply: speed to lead stays as it is
create or replace function public.belt_on_hot() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.lead_id is null or new.is_test then return new; end if;
  perform public.belt_event(new.lead_id, 'hot_reply', jsonb_build_object('key', 'hot:' || new.inbound_sid, 'said', left(new.body, 300)), 'reply agent', new.created_at);
  return new;
end $$;
drop trigger if exists belt_on_hot on public.hot_alerts;
create trigger belt_on_hot after insert on public.hot_alerts
  for each row execute function public.belt_on_hot();

-- ------------------------------------------------------------------ d) tasks: nurture (+30), after-STOP interest, Done
create or replace function public.belt_on_task_insert() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.lead_id is null or new.source in ('belt', 'call_list') then return new; end if;
  if new.source = 'nurture' then
    perform public.belt_event(new.lead_id, 'inbound_text', jsonb_build_object('key', 'nurture:' || new.id::text, 'intent', 'not_interested', 'kind', 'routine',
      'outcome', 'open', 'facts', jsonb_build_object('nurture', true, 'condition', left(coalesce(new.quote, ''), 200)), 'said', left(coalesce(new.quote, ''), 300)), 'reply agent', now());
    -- the belt's own draft at +30 replaces this task: close it so Colin is not asked twice
    update public.tasks set done_at = now(), note = coalesce(note, '') || ' [the belt took this: a draft text goes to Colin for a tap in 30 days]' where id = new.id;
  elsif new.source = 'after_stop' then
    -- interest after a STOP: the task is the stop (a person may call; never a text); the card stays DNC
    insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
    values (new.lead_id, 'after_stop_interest', 'dnc', 'dnc', 0, jsonb_build_object('key', 'after_stop:' || new.id::text, 'task_id', new.id, 'said', left(coalesce(new.quote, ''), 300)), now(), 'reply agent');
    update public.leads set next_stop_at = new.due_at, next_stop_who = 'colin_call', next_stop_say = 'They wrote back after STOP: a call is fine, never a text', next_action = 'Colin calls (after STOP)', next_action_at = new.due_at where id = new.lead_id;
  end if;
  return new;
end $$;
drop trigger if exists belt_on_task_insert on public.tasks;
create trigger belt_on_task_insert after insert on public.tasks
  for each row execute function public.belt_on_task_insert();

-- a plain Done on a stop (no outcome button): the next stop on the ladder, not counted against them
create or replace function public.belt_on_task_done() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.done_at is null or old.done_at is not null or new.lead_id is null then return new; end if;
  if coalesce(current_setting('wpie.task_outcome', true), '') = '1' or public.belt_in_event() then return new; end if;
  if new.source in ('belt', 'call_list', 'after_stop') then
    perform public.belt_event(new.lead_id, 'stop_done', jsonb_build_object('outcome', 'done', 'task_id', new.id, 'source', new.source), null, now());
  end if;
  return new;
end $$;
drop trigger if exists belt_on_task_done on public.tasks;
create trigger belt_on_task_done after update of done_at on public.tasks
  for each row execute function public.belt_on_task_done();

-- ------------------------------------------------------------------ e) a person's own text or call, and a STOP by text
create or replace function public.belt_on_message() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.lead_id is null then return new; end if;
  if new.direction = 'in' and new.is_opt_out then
    perform public.belt_event(new.lead_id, 'stop', jsonb_build_object('key', 'stopmsg:' || new.id::text, 'said', left(coalesce(new.body, ''), 300)), 'text', new.sent_at);
  elsif new.direction = 'out' and (new.channel = 'email' or (new.channel = 'sms' and (new.created_by is not null or coalesce(new.status, '') like 'human%' or coalesce(new.status, '') like 'sent by %'))) then
    -- an email from the app (log_email), a text a person sent: nothing automatic follows it
    perform public.belt_event(new.lead_id, 'human_text', jsonb_build_object('key', 'human:' || new.id::text, 'channel', new.channel::text), null, new.sent_at);
  end if;
  return new;
end $$;
drop trigger if exists belt_on_message on public.messages;
create trigger belt_on_message after insert on public.messages
  for each row execute function public.belt_on_message();

-- ------------------------------------------------------------------ f) a stage written outside the belt
create or replace function public.belt_leads_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare changed text[] := '{}';
begin
  if public.belt_in_event() then return new; end if;
  if new.stage is distinct from old.stage then changed := array_append(changed, 'stage'); end if;
  if new.next_action is distinct from old.next_action then changed := array_append(changed, 'next_action'); end if;
  if new.next_action_at is distinct from old.next_action_at then changed := array_append(changed, 'next_action_at'); end if;
  if new.belt is distinct from old.belt or new.belt_step is distinct from old.belt_step then changed := array_append(changed, 'belt'); end if;
  if new.next_stop_at is distinct from old.next_stop_at or new.next_stop_who is distinct from old.next_stop_who then changed := array_append(changed, 'next_stop'); end if;
  if cardinality(changed) > 0 and auth.uid() is not null then
    insert into public.belt_direct_writes (lead_id, by, changed) values (new.id, public.belt_actor(null), changed);
  end if;
  return new;
end $$;
drop trigger if exists belt_leads_guard on public.leads;
create trigger belt_leads_guard before update of stage, next_action, next_action_at, belt, belt_step, next_stop_at, next_stop_who on public.leads
  for each row execute function public.belt_leads_guard();

create or replace function public.belt_leads_stage_follow() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.belt_in_event() or new.stage is not distinct from old.stage then return new; end if;
  perform public.belt_event(new.id, 'stage_changed', jsonb_build_object('from', old.stage::text, 'to', new.stage::text), null, now());
  return new;
end $$;
drop trigger if exists belt_leads_stage_follow on public.leads;
create trigger belt_leads_stage_follow after update of stage on public.leads
  for each row execute function public.belt_leads_stage_follow();

-- ------------------------------------------------------------------ g) the call desk: log_call and call_answer go through the belt
create or replace function public.log_call(p_lead_id uuid, p_phone text, p_outcome text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare who text; d text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10); l public.leads;
  phones text[]; label text; res jsonb;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  if p_outcome not in ('interested', 'not_now', 'not_interested', 'wrong_number', 'dnc', 'no_answer', 'reached_no_decision') then
    return jsonb_build_object('ok', false, 'reason', 'pick an outcome');
  end if;
  select * into l from public.leads where id = p_lead_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such lead'); end if;
  select display_name into who from public.team_members where lower(email) = lower(auth.jwt() ->> 'email');
  label := case p_outcome when 'interested' then 'Interested' when 'not_now' then 'Not now' when 'not_interested' then 'Not interested'
                          when 'wrong_number' then 'Wrong number' when 'no_answer' then 'No answer' when 'reached_no_decision' then 'Reached, no decision yet'
                          else 'Do not contact' end;
  insert into public.messages (lead_id, direction, channel, body, from_number, sent_at, seen_at, status)
  values (p_lead_id, (case when p_outcome = 'no_answer' then 'out' else 'in' end)::public.msg_direction, 'call', format('Call (%s)%s: %s%s', coalesce(who, 'team'),
            case when d ~ '^[0-9]{10}$' then ' from ' || d else '' end, label,
            coalesce(E'\n' || nullif(btrim(coalesce(p_note, '')), ''), '')),
          case when d ~ '^[0-9]{10}$' then '+1' || d end, now(), now(), p_outcome);
  update public.leads set call_facts = jsonb_set(call_facts, '{last_call}', jsonb_build_object('value', p_outcome, 'at', now(), 'by', who))
   where id = p_lead_id;
  if p_outcome = 'wrong_number' and d ~ '^[0-9]{10}$' then
    update public.contacts set status = 'bad' where lead_id = p_lead_id and value_normalized = d;
  elsif p_outcome = 'dnc' then
    select array_agg(distinct c.value_normalized) into phones from public.contacts c
     where c.lead_id = p_lead_id and c.kind = 'phone' and c.value_normalized ~ '^[0-9]{10}$';
    phones := coalesce(phones, '{}');
    if d ~ '^[0-9]{10}$' and not d = any(phones) then phones := array_append(phones, d); end if;
    insert into public.suppressed_phones (phone10, reason, source)
      select distinct p, 'dnc_call', 'app' from unnest(phones) p
    on conflict (phone10) do nothing;
    update public.contacts set suppressed = true, dnc_app = true where value_normalized = any(phones);
  end if;
  -- the stop this call was, if it was one, is logged with it (the call's outcome is the outcome)
  perform set_config('wpie.task_outcome', '1', true);
  update public.tasks set done_at = now(), note = coalesce(note, '') || ' [logged: ' || label || ']'
   where lead_id = p_lead_id and source in ('belt', 'call_list', 'after_stop') and done_at is null and kind in ('call', 'visit')
     and due_at <= now() + interval '12 hours';
  perform set_config('wpie.task_outcome', '', true);
  res := public.belt_event(p_lead_id, 'call_logged', jsonb_build_object('outcome', p_outcome, 'note', p_note, 'phone', d, 'said', nullif(btrim(coalesce(p_note, '')), '')), who, now());
  return jsonb_build_object('ok', true, 'outcome', p_outcome, 'belt', res->>'belt', 'next_stop_at', res->>'next_stop_at');
end $$;

create or replace function public.call_answer(p_lead_id uuid, p_key text, p_value jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare who text; at timestamptz; kind text; res jsonb;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  if p_key !~ '^[a-z_]{2,40}$' then return jsonb_build_object('ok', false, 'reason', 'bad key'); end if;
  select display_name into who from public.team_members where lower(email) = lower(auth.jwt() ->> 'email');
  update public.leads
     set call_facts = case when p_value is null or p_value = 'null'::jsonb then call_facts - p_key
                           else jsonb_set(call_facts, array[p_key], jsonb_build_object('value', p_value, 'at', now(), 'by', who)) end
   where id = p_lead_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such lead'); end if;
  if p_key = 'next_step' and jsonb_typeof(p_value) = 'object' then
    kind := p_value->>'kind';
    at := nullif(p_value->>'at', '')::timestamptz;
    if kind in ('walk', 'callback') and at is not null then
      res := public.belt_event(p_lead_id, 'next_step', jsonb_build_object('kind', kind, 'at', at), who, now());
      return jsonb_build_object('ok', true, 'belt', res->>'belt', 'next_stop_at', res->>'next_stop_at');
    end if;
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- The card's "Don't book" with its reason (the booking verdict's close).
create or replace function public.verdict_no(p_lead_id uuid, p_reason text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare who text;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  select display_name into who from public.team_members where lower(email) = lower(auth.jwt() ->> 'email');
  return public.belt_event(p_lead_id, 'verdict_no', jsonb_build_object('reason', p_reason, 'note', p_note), who, now());
end $$;
revoke all on function public.verdict_no(uuid, text, text) from public, anon;
grant execute on function public.verdict_no(uuid, text, text) to authenticated;

-- Colin's push notification also covers a belt draft waiting for his tap (0025's thread, plus kind 'belt').
create or replace function public.notify_claim(p_kind text, p_now timestamptz default now(), p_limit integer default 20)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  out jsonb := '[]'::jsonb;
  d record;
begin
  if p_kind not in ('first', 'reminder') then raise exception 'unknown kind %', p_kind; end if;
  if public.in_quiet_hours(p_now) then return out; end if;
  for d in
    select r.* from public.reply_drafts r
     where r.kind in ('candidate', 'belt') and r.status = 'awaiting_approval'
       and ((p_kind = 'first' and r.notified_at is null)
         or (p_kind = 'reminder' and r.notified_at is not null and r.reminded_at is null and r.notified_at <= p_now - interval '2 hours'))
     order by r.inbound_at
     limit p_limit
     for update skip locked
  loop
    if p_kind = 'first' then
      update public.reply_drafts set notified_at = p_now where id = d.id;
    else
      update public.reply_drafts set reminded_at = p_now where id = d.id;
    end if;
    out := out || jsonb_build_object(
      'id', d.id, 'kind', p_kind, 'is_test', d.is_test, 'phone10', d.phone10,
      'inbound_body', coalesce(d.inbound_body, case when d.kind = 'belt' then '(a follow-up text waiting for your tap: ' || coalesce(d.note, 'belt stop') || ')' end),
      'inbound_at', d.inbound_at, 'intent', d.intent, 'note', d.note, 'body', d.body,
      'owner_name', case when d.is_test then (select c.test_owner_name from public.campaign_control c where c.id = 1)
                         else (select l.owner_name from public.leads l where l.id = d.lead_id) end,
      'property_address', case when d.is_test then (select c.test_property_address from public.campaign_control c where c.id = 1)
                               else (select l.property_address from public.leads l where l.id = d.lead_id) end,
      'thread', coalesce((select jsonb_agg(jsonb_build_object('who', z.who, 'body', z.body, 'at', z.at) order by z.at) from (
        select z0.*, row_number() over (partition by z0.who, btrim(z0.body), date_trunc('hour', z0.at) order by z0.at) as rn from (
          select 'them' as who, x.body, x.received_at as at from public.twilio_inbound x
           where x.from10 = d.phone10 and x.received_at <= d.inbound_at
          union all
          select 'us', s.sent_body, s.sent_at from public.reply_drafts s where s.phone10 = d.phone10 and s.status = 'sent'
          union all
          select case when m.direction = 'out' then 'us' else 'them' end, m.body, m.sent_at
            from public.messages m where m.lead_id = d.lead_id and m.channel = 'sms' and m.provider_sid is not null
              -- the same text again: a sent reply is also logged in messages, an inbound text is also synced
              and not exists (select 1 from public.reply_drafts s2 where s2.provider_sid = m.provider_sid)
              and not exists (select 1 from public.twilio_inbound x2 where x2.sid = m.provider_sid)
        ) z0 where z0.body is not null
        -- and anything else that is the same words from the same side within the same hour
        ) z where z.rn = 1), '[]'::jsonb));
  end loop;
  return out;
end $$;

-- ================================================================== the conveyor's SQL (service_role)
-- Due text stops: the lead rows whose next stop is a text and its time has come.
create or replace function public.belt_due_texts(p_now timestamptz default now(), p_limit integer default 50)
returns table (id uuid, belt text, belt_step smallint, next_stop_who text, next_stop_at timestamptz)
language sql stable security definer set search_path = public as $$
  select l.id, l.belt, l.belt_step, l.next_stop_who, l.next_stop_at from public.leads l
   where l.next_stop_who in ('auto_text', 'draft_text') and l.next_stop_at is not null and l.next_stop_at <= p_now
     and l.belt not in ('cold_texts', 'dead', 'dnc')
   order by l.next_stop_at limit p_limit
$$;

-- One text stop -> a reply_drafts row. Returns {outcome: send | dry_sent | awaiting_approval | slid | skipped, ...}.
--   send              status 'sending': the function calls Twilio, then reply_record_result
--   awaiting_approval the template is off (or a draft stop): Colin taps it on Approve; the stop's task says so
--   slid              outside 8am-8pm local or Sunday, or the phone is unknown: moved later
--   skipped           the card may not be texted (elderly / grief / dead / dnc / opted out / they wrote since): the next stop
create or replace function public.belt_claim_text(p_lead_id uuid, p_dry boolean default true, p_force boolean default false, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare l public.leads; s public.belt_steps; t public.touch_templates; r public.belt_rules; stop_key text; ph text; ours text; txt text; tz text;
  did uuid; st text; slid timestamptz; since timestamptz; reason text;
begin
  select * into l from public.leads where id = p_lead_id for update;
  if not found or l.next_stop_who not in ('auto_text', 'draft_text') then return jsonb_build_object('outcome', 'refused', 'reason', 'not a text stop'); end if;
  select * into r from public.belt_rules where belt = l.belt;
  stop_key := format('belt:%s:%s:%s:%s', l.id, l.belt, l.belt_round, l.belt_step);
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
end $$;

-- End of day: a stop due today and not logged. A text counts as unanswered; a call is re-slid once (tomorrow), then counts.
create or replace function public.belt_sweep_missed(p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare l record; n integer := 0; again boolean; out jsonb := '[]'::jsonb;
begin
  for l in
    select x.* from public.leads x
     where x.next_stop_at is not null and x.next_stop_at < p_now - interval '20 hours'
       and x.belt not in ('cold_texts', 'dead', 'dnc', 'too_high_or_listed')
       and (x.next_stop_who in ('thalia_call', 'colin_call', 'colin_visit')
            or (x.next_stop_who in ('auto_text', 'draft_text') and x.next_stop_at < p_now - interval '3 days'))
     order by x.next_stop_at limit 200
  loop
    again := exists (select 1 from public.belt_events e where e.lead_id = l.id and e.event = 'stop_missed' and e.to_belt = l.belt and e.step = l.belt_step);
    perform public.belt_event(l.id, 'stop_missed', jsonb_build_object('again', again, 'was_due', l.next_stop_at), 'conveyor', p_now);
    n := n + 1;
    out := out || jsonb_build_object('lead_id', l.id, 'belt', l.belt, 'step', l.belt_step, 'again', again);
  end loop;
  return jsonb_build_object('swept', n, 'rows', out);
end $$;

-- Cold texts: WPIE's ledger owns 1-3; the sync mirrors the step here (service_role).
create or replace function public.belt_mirror_cold(p_wpie_owner_id bigint, p_step integer, p_last_at timestamptz, p_next_at timestamptz)
returns jsonb language plpgsql security definer set search_path = public as $$
declare lid uuid;
begin
  select id into lid from public.leads where wpie_owner_id = p_wpie_owner_id;
  if lid is null then return jsonb_build_object('ok', false, 'reason', 'no lead'); end if;
  return public.belt_event(lid, 'cold_text', jsonb_build_object('step', p_step, 'last_at', p_last_at, 'next_at', p_next_at,
           'key', format('cold:%s:%s:%s', p_wpie_owner_id, p_step, coalesce(p_last_at::text, ''))), 'laptop', now());
end $$;

-- A new WPIE record on a parcel (service_role; the sync): re-entry for a resting card, never a live one.
create or replace function public.belt_wpie_event(p_wpie_owner_id bigint, p_kind text, p_detail text, p_key text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare lid uuid;
begin
  select id into lid from public.leads where wpie_owner_id = p_wpie_owner_id;
  if lid is null then return jsonb_build_object('ok', false, 'reason', 'no lead'); end if;
  return public.belt_event(lid, 'wpie_event', jsonb_build_object('kind', p_kind, 'detail', left(coalesce(p_detail, ''), 200), 'key', 'wpie:' || p_key), 'laptop', now());
end $$;

-- ================================================================== views for the pages
-- Every live card must have a next stop. Belts that rest by design (dead, dnc, too high / listed, dormant after
-- three rounds, cold texts between texts) are not debt.
create or replace view public.cards_no_stop with (security_invoker = true) as
  select l.id as lead_id, l.owner_name, l.property_address, l.stage, l.belt, l.belt_step, l.assigned_to, l.belt_entered_at,
         l.updated_at
    from public.leads l
   where l.next_stop_at is null
     and ((l.belt is not null and l.belt not in ('dead', 'dnc', 'too_high_or_listed', 'cold_texts')
           and not (l.belt = 'dormant' and l.dormant_round >= 3))
          or (l.belt is null and l.stage in ('reply_received', 'ai_qualifying', 'handoff', 'colin_call', 'walk_decision',
                                            'walkthrough_booked', 'offer', 'follow_up', 'human_owned')));

create or replace view public.belt_counts with (security_invoker = true) as
  select r.belt, r.label, count(l.id)::int as n,
         count(l.id) filter (where l.next_stop_at is not null and l.next_stop_at < now())::int as overdue,
         count(l.id) filter (where l.next_stop_at is null)::int as no_stop
    from public.belt_rules r left join public.leads l on l.belt = r.belt
   group by r.belt, r.label;

-- Stops per person per day: done on time, done late, still open and late (Central days).
create or replace view public.belt_stops_daily with (security_invoker = true) as
  select (coalesce(t.done_at, t.due_at) at time zone 'America/Chicago')::date as day, t.owner::text as person,
         count(*) filter (where t.done_at is not null and t.done_at <= t.due_at + interval '1 day')::int as done_on_time,
         count(*) filter (where t.done_at is not null and t.done_at > t.due_at + interval '1 day')::int as done_late,
         count(*) filter (where t.done_at is null and t.due_at < now() - interval '1 day')::int as open_late
    from public.tasks t where t.source in ('belt', 'call_list')
   group by 1, 2;

-- Replies per touch: each belt text that went, and whether the owner wrote back within 7 days.
create or replace view public.belt_touch_replies with (security_invoker = true) as
  select d.outcome as template_key, split_part(d.belt_stop_key, ':', 3) as belt, count(*)::int as sent,
         count(*) filter (where exists (select 1 from public.twilio_inbound i where i.from10 = d.phone10 and i.received_at > d.sent_at and i.received_at < d.sent_at + interval '7 days'))::int as replied,
         count(*) filter (where exists (select 1 from public.twilio_inbound i where i.from10 = d.phone10 and i.is_opt_out and i.received_at > d.sent_at and i.received_at < d.sent_at + interval '7 days'))::int as stops
    from public.reply_drafts d where d.kind = 'belt' and d.status = 'sent'
   group by 1, 2;

-- Revivals: a card on a quiet or resting belt whose owner wrote back (the belt it came from).
create or replace view public.belt_revivals with (security_invoker = true) as
  select date_trunc('week', e.at at time zone 'America/Chicago')::date as week_start, e.from_belt as belt, count(*)::int as revived
    from public.belt_events e
   where e.event in ('inbound_text', 'hot_reply') and e.from_belt is distinct from e.to_belt
     and e.from_belt in ('replied_quiet', 'questions_quiet', 'yes_unbooked', 'call_missed', 'visit_missed', 'after_call_quiet', 'after_visit_quiet',
                         'offer_out', 'not_now_dated', 'not_now_condition', 'needs_family', 'estate_waiting', 'hold_not_now', 'too_high_or_listed', 'dormant')
   group by 1, 2;

create or replace view public.belt_unanswered with (security_invoker = true) as
  select l.belt, l.unanswered_count, count(*)::int as n from public.leads l where l.belt is not null group by 1, 2;

grant select on public.cards_no_stop, public.belt_counts, public.belt_stops_daily, public.belt_touch_replies, public.belt_revivals, public.belt_unanswered to authenticated, service_role;

-- ================================================================== health
-- The invariants, written as one heartbeat row per conveyor run.
create or replace function public.belt_health_check(p_now timestamptz default now(), p_extra jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare c jsonb; fails text[] := '{}'; n_nostop int; n_unlogged int; n_failed int; n_stuck int; n_direct int; last_push timestamptz; hour_ct int;
  swing jsonb := '[]'::jsonb; prevc jsonb; cur jsonb; b record; canary record; ok boolean; summary text; counts jsonb;
begin
  select count(*) into n_nostop from public.cards_no_stop;
  select count(*) into n_unlogged from public.tasks t where t.source in ('belt', 'call_list') and t.done_at is null and t.due_at < p_now - interval '24 hours';
  select count(*) into n_failed from public.reply_drafts d where d.kind = 'belt' and d.status = 'failed' and d.updated_at > p_now - interval '24 hours';
  select count(*) into n_stuck from public.reply_drafts d where d.kind = 'belt' and ((d.status = 'queued' and d.created_at < p_now - interval '1 hour') or (d.status = 'sending' and d.updated_at < p_now - interval '10 minutes'));
  select count(*) into n_direct from public.belt_direct_writes w where w.at > p_now - interval '24 hours';
  select max(synced_at) into last_push from public.leads;
  hour_ct := extract(hour from p_now at time zone 'America/Chicago')::int;
  select coalesce(jsonb_object_agg(belt, n), '{}'::jsonb) into counts from public.belt_counts;
  select h.checks->'counts' into prevc from public.belt_health h where h.kind = 'run' and h.at <= p_now - interval '23 hours' and h.at > p_now - interval '26 hours' order by h.at desc limit 1;
  if prevc is not null then
    for b in select key, value::int as n from jsonb_each_text(counts) loop
      if coalesce((prevc->>b.key)::int, 0) >= 20 and abs(b.n - (prevc->>b.key)::int) > 0.25 * (prevc->>b.key)::int then
        swing := swing || jsonb_build_object('belt', b.key, 'was', (prevc->>b.key)::int, 'now', b.n);
      end if;
    end loop;
  end if;
  select h.ok, h.at into canary from public.belt_health h where h.kind = 'canary' order by h.at desc limit 1;
  if n_nostop > 0 then fails := array_append(fails, format('%s live card(s) have no next stop', n_nostop)); end if;
  if n_unlogged > 0 then fails := array_append(fails, format('%s stop(s) sit unlogged more than a day after they were due', n_unlogged)); end if;
  if n_failed > 0 then fails := array_append(fails, format('%s belt text(s) failed to send in the last day', n_failed)); end if;
  if n_stuck > 0 then fails := array_append(fails, format('%s belt text(s) stuck in the queue for over an hour', n_stuck)); end if;
  if n_direct > 0 then fails := array_append(fails, format('%s card(s) were moved outside the belt in the last day', n_direct)); end if;
  if jsonb_array_length(swing) > 0 then fails := array_append(fails, format('a belt gained or lost over a quarter of its cards in a day: %s', swing::text)); end if;
  if hour_ct between 8 and 20 and extract(isodow from p_now at time zone 'America/Chicago') < 7
     and (last_push is null or last_push < p_now - interval '2 hours') then
    fails := array_append(fails, 'the laptop has not pushed in over 2 hours');
  end if;
  if canary.at is null or canary.at < p_now - interval '26 hours' then fails := array_append(fails, 'the daily canary has not run');
  elsif not canary.ok then fails := array_append(fails, 'the daily canary FAILED: a belt is broken'); end if;
  ok := cardinality(fails) = 0;
  c := jsonb_build_object('no_stop', n_nostop, 'unlogged', n_unlogged, 'texts_failed', n_failed, 'texts_stuck', n_stuck, 'direct_writes', n_direct,
         'swings', swing, 'last_push_at', last_push, 'canary_ok', canary.ok, 'canary_at', canary.at, 'counts', counts, 'fails', to_jsonb(fails)) || coalesce(p_extra, '{}'::jsonb);
  summary := case when ok then format('All belts moving: %s cards on belts, %s stop(s) overdue',
                   (select coalesce(sum(n), 0) from public.belt_counts where belt not in ('dead', 'dnc')), (select coalesce(sum(overdue), 0) from public.belt_counts))
                  else array_to_string(fails, '; ') end;
  insert into public.belt_health (at, kind, ok, checks, summary) values (p_now, 'run', ok, c, summary);
  update public.campaign_control set belt_last_run_at = p_now where id = 1;
  delete from public.belt_health where at < p_now - interval '14 days';
  return jsonb_build_object('ok', ok, 'summary', summary, 'checks', c);
end $$;

-- The watchdog (its own pg_cron, SQL only, so it still runs when the conveyor function is down):
-- one text to Colin per issue per day through ops_alerts (sent by the reply agent's ops loop).
create or replace function public.belt_alert_once(p_key text, p_text text, p_now timestamptz)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  insert into public.belt_alerts_sent (key, day) values (p_key, (p_now at time zone 'America/Chicago')::date) on conflict do nothing;
  if not found then return false; end if;
  insert into public.ops_alerts (text, created_at) values ('Belt health: ' || p_text || ' (the Today page shows the strip)', p_now);
  return true;
end $$;

create or replace function public.belt_watch(p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare last_run timestamptz; n_nostop int; nostop_since timestamptz; n_over int; canary record; out jsonb := '[]'::jsonb;
begin
  select max(at) into last_run from public.belt_health where kind = 'run';
  if (last_run is null or last_run < p_now - interval '1 hour')
     and public.belt_alert_once('heartbeat', 'the conveyor has not run for over an hour; stops are not moving', p_now) then out := out || '"heartbeat"'::jsonb; end if;
  select count(*) into n_nostop from public.cards_no_stop;
  if n_nostop > 0 then
    select min(at) into nostop_since from public.belt_health where kind = 'run' and at > p_now - interval '2 hours' and (checks->>'no_stop')::int > 0;
    if nostop_since is not null and nostop_since < p_now - interval '1 hour'
       and public.belt_alert_once('no_stop', format('%s live card(s) have had no next stop for over an hour', n_nostop), p_now) then out := out || '"no_stop"'::jsonb; end if;
  end if;
  select count(*) into n_over from public.tasks t where t.source in ('belt', 'call_list') and t.done_at is null and t.due_at < p_now - interval '24 hours';
  if n_over > 10 and public.belt_alert_once('overdue', format('%s stops are more than a day overdue', n_over), p_now) then out := out || '"overdue"'::jsonb; end if;
  select h.ok, h.at into canary from public.belt_health h where h.kind = 'canary' order by h.at desc limit 1;
  if canary.at is not null and not canary.ok and canary.at > p_now - interval '26 hours'
     and public.belt_alert_once('canary', 'the daily test card FAILED to move through its belts: a belt is broken', p_now) then out := out || '"canary"'::jsonb; end if;
  return jsonb_build_object('alerted', out);
end $$;

-- ================================================================== the daily canary
-- A synthetic card walks yes_unbooked -> no answer -> an auto text (dry, switch forced) -> call booked ->
-- visit booked, each stop asserted, then the card is deleted. A failure is a broken belt.
create or replace function public.belt_canary_step(p_steps jsonb, p_name text, p_ok boolean, p_detail text)
returns jsonb language sql immutable as $$
  select p_steps || jsonb_build_object('step', p_name, 'ok', coalesce(p_ok, false), 'detail', left(coalesce(p_detail, ''), 300))
$$;

create or replace function public.belt_canary(p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare lid uuid; ph text; steps jsonb := '[]'::jsonb; res jsonb; l public.leads; tid uuid; ok boolean; why text;
  mon timestamptz := public.belt_slide(p_now + interval '1 day', 'America/Chicago', 'call', 10);
begin
  select coalesce(test_phones[1], '2627770909') into ph from public.campaign_control where id = 1;
  insert into public.leads (owner_name, property_address, municipality, mailing_state, lane, stage, notes)
  values ('BELT CANARY (test card)', '1234 N Test St, Milwaukee', 'Milwaukee', 'WI', 'flip', 'opener_sent', 'canary: deleted at the end of the test')
  returning id into lid;
  insert into public.contacts (lead_id, kind, value, value_normalized, line_type, source) values (lid, 'phone', ph, ph, 'mobile', 'canary');
  begin
    -- 1. interest -> said yes, not booked; Thalia's call now
    res := public.belt_event(lid, 'inbound_text', jsonb_build_object('intent', 'interested', 'kind', 'candidate', 'outcome', 'open', 'said', 'yes, call me', 'interest', true), 'canary', p_now);
    select * into l from public.leads where id = lid;
    steps := public.belt_canary_step(steps, 'yes_unbooked', l.belt = 'yes_unbooked' and l.belt_step = 1 and l.next_stop_who = 'thalia_call' and l.next_stop_at is not null,
               coalesce(l.belt, 'null') || '/' || l.belt_step || '/' || coalesce(l.next_stop_who, 'null'));
    select id into tid from public.tasks where lead_id = lid and source = 'belt' and done_at is null;
    steps := public.belt_canary_step(steps, 'thalia_task', tid is not null and (select owner from public.tasks where id = tid) = 'thalia', coalesce(tid::text, 'no task'));
    -- 2. no answer -> the auto text an hour later
    res := public.belt_event(lid, 'stop_done', jsonb_build_object('outcome', 'no_answer', 'task_id', tid), 'canary', p_now);
    select * into l from public.leads where id = lid;
    steps := public.belt_canary_step(steps, 'no_answer', l.belt = 'yes_unbooked' and l.belt_step = 2 and l.next_stop_who = 'auto_text' and l.unanswered_count = 1,
               coalesce(l.belt, 'null') || '/' || l.belt_step || '/' || coalesce(l.next_stop_who, 'null') || '/unanswered ' || l.unanswered_count);
    steps := public.belt_canary_step(steps, 'task_logged', (select done_at from public.tasks where id = tid) is not null, 'the stop task closed');
    -- 3. the text, dry, with the switch forced for the test: a dry_sent draft, then step 3 (a call at another band)
    res := public.belt_claim_text(lid, true, true, l.next_stop_at + interval '1 minute');
    steps := public.belt_canary_step(steps, 'dry_text', res->>'outcome' = 'dry_sent' and (res->>'body') like 'Colin here%' and (res->>'body') like '%STOP%' and (res->>'body') like '%N Test St%', coalesce(res::text, 'null'));
    select * into l from public.leads where id = lid;
    steps := public.belt_canary_step(steps, 'after_text', l.belt = 'yes_unbooked' and l.belt_step = 3 and l.next_stop_who = 'thalia_call' and l.unanswered_count = 2,
               coalesce(l.belt, 'null') || '/' || l.belt_step || '/' || coalesce(l.next_stop_who, 'null') || '/unanswered ' || l.unanswered_count);
    -- 4. a call back booked -> call_booked with the slot, the reminder the morning of
    res := public.belt_event(lid, 'next_step', jsonb_build_object('kind', 'callback', 'at', mon), 'canary', p_now);
    select * into l from public.leads where id = lid;
    steps := public.belt_canary_step(steps, 'call_booked', l.belt = 'call_booked' and l.named_date = mon and l.next_stop_who = 'auto_text' and l.next_stop_at < mon,
               coalesce(l.belt, 'null') || '/' || coalesce(l.next_stop_who, 'null') || '/' || coalesce(l.next_stop_at::text, 'null'));
    -- 5. the walk-through booked -> visit_booked, Colin visits at the slot
    res := public.belt_event(lid, 'next_step', jsonb_build_object('kind', 'walk', 'at', mon + interval '1 day'), 'canary', p_now);
    select * into l from public.leads where id = lid;
    steps := public.belt_canary_step(steps, 'visit_booked', l.belt = 'visit_booked' and l.stage = 'walkthrough_booked'
               and exists (select 1 from public.tasks t where t.lead_id = lid and t.source = 'belt' and t.done_at is null and t.kind = 'visit' and t.owner = 'colin'),
               coalesce(l.belt, 'null') || '/' || l.stage::text);
    -- 6. STOP is final: nothing moves a DNC card
    res := public.belt_event(lid, 'stop', '{}'::jsonb, 'canary', p_now);
    res := public.belt_event(lid, 'inbound_text', jsonb_build_object('intent', 'interested', 'interest', true), 'canary', p_now);
    select * into l from public.leads where id = lid;
    steps := public.belt_canary_step(steps, 'dnc_final', l.belt = 'dnc' and l.next_stop_at is null and not exists (select 1 from public.tasks t where t.lead_id = lid and t.done_at is null), coalesce(l.belt, 'null'));
  exception when others then
    steps := public.belt_canary_step(steps, 'error', false, sqlerrm);
  end;
  delete from public.reply_drafts where lead_id = lid;
  delete from public.leads where id = lid;
  ok := not exists (select 1 from jsonb_array_elements(steps) x where not (x->>'ok')::boolean);
  select x->>'step' || ': ' || (x->>'detail') into why from jsonb_array_elements(steps) x where not (x->>'ok')::boolean limit 1;
  insert into public.belt_health (at, kind, ok, checks, summary) values (p_now, 'canary', ok, jsonb_build_object('steps', steps), coalesce(why, 'canary passed: a test card moved through its belts and was deleted'));
  update public.campaign_control set belt_canary_date = (p_now at time zone 'America/Chicago')::date where id = 1;
  return jsonb_build_object('ok', ok, 'why', why, 'steps', steps);
end $$;

-- ================================================================== the one-off backfill
-- Every card with no belt lands on one from its stage, its call facts, its thread and its next action.
create or replace function public.belt_backfill(p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare l record; b text; st integer; counts jsonb := '{}'::jsonb; res jsonb; k text; n int; th record; pl jsonb;
begin
  for l in select * from public.leads where belt is null order by created_at loop
    b := null; st := 1; pl := jsonb_build_object('key', 'backfill:' || l.id::text, 'reason', 'backfill from stage ' || l.stage::text);
    select * into th from public.reply_threads r where r.lead_id = l.id order by r.last_inbound_at desc nulls last limit 1;
    case l.stage::text
      when 'dnc' then b := 'dnc';
      when 'dead' then b := 'dead';
      when 'closed_no_contact' then b := 'dead'; pl := pl || '{"reason":"no_contact"}';
      when 'opener_queued', 'opener_sent' then b := 'cold_texts';
      when 'reply_received' then b := 'replied_quiet';
      when 'ai_qualifying' then b := 'questions_quiet';
      when 'handoff' then b := 'yes_unbooked';
      when 'colin_call' then b := case when l.next_action_at is not null and l.next_action_at > p_now then 'call_booked' else 'yes_unbooked' end;
      when 'walk_decision' then b := 'after_visit_quiet';
      when 'walkthrough_booked' then b := case when l.next_action_at is not null and l.next_action_at > p_now then 'visit_booked' else 'visit_missed' end;
      when 'offer' then b := 'offer_out';
      when 'under_contract' then b := 'offer_out';
      when 'follow_up' then b := case when exists (select 1 from public.tasks t where t.lead_id = l.id and t.source = 'nurture') then 'not_now_condition'
                                      when l.next_action_at is not null and l.next_action_at > p_now + interval '3 days' then 'not_now_dated' else 'after_call_quiet' end;
      when 'human_owned' then b := 'after_call_quiet';
      else b := null;
    end case;
    if th.outcome = 'close_dnc' then b := 'dnc'; elsif th.outcome = 'close_not_interested' then b := 'dead'; elsif th.outcome = 'close_wrong_number' then b := null;
    elsif th.outcome = 'handoff' and b in ('replied_quiet', 'questions_quiet') then b := 'yes_unbooked'; end if;
    if l.hot_at is not null and b in ('replied_quiet', 'questions_quiet') and not exists (select 1 from public.messages m where m.lead_id = l.id and m.channel = 'call' and m.sent_at > l.hot_at) then b := 'yes_unbooked'; end if;
    if b is null then counts := counts || jsonb_build_object('(none: ' || l.stage::text || ')', coalesce((counts->>('(none: ' || l.stage::text || ')'))::int, 0) + 1); continue; end if;
    if b = 'cold_texts' then
      select coalesce(max(p.step), 1) into st from public.planned_openers p where p.wpie_owner_id = l.wpie_owner_id and p.send_status in ('sent', 'delivered', 'undelivered', 'failed', 'uncertain', 'sending');
      res := public.belt_event(l.id, 'cold_text', jsonb_build_object('step', st, 'key', 'backfill:' || l.id::text), 'backfill', p_now);
    elsif b in ('call_booked', 'visit_booked', 'not_now_dated') and l.next_action_at is not null then
      update public.leads set named_date = l.next_action_at, named_event = coalesce(l.next_action, case when b = 'visit_booked' then 'visit' else 'call' end) where id = l.id;
      res := public.belt_event(l.id, 'move', pl || jsonb_build_object('belt', b), 'backfill', p_now);
    else
      res := public.belt_event(l.id, 'move', pl || jsonb_build_object('belt', b), 'backfill', p_now);
    end if;
    k := coalesce(res->>'belt', 'none');
    counts := counts || jsonb_build_object(k, coalesce((counts->>k)::int, 0) + 1);
  end loop;
  select count(*) into n from public.leads where belt is not null;
  return jsonb_build_object('placed', counts, 'on_belts', n, 'no_stop', (select count(*) from public.cards_no_stop));
end $$;

revoke all on function public.belt_due_texts(timestamptz, integer), public.belt_claim_text(uuid, boolean, boolean, timestamptz), public.belt_sweep_missed(timestamptz),
  public.belt_mirror_cold(bigint, integer, timestamptz, timestamptz), public.belt_wpie_event(bigint, text, text, text), public.belt_health_check(timestamptz, jsonb),
  public.belt_watch(timestamptz), public.belt_canary(timestamptz), public.belt_backfill(timestamptz), public.belt_alert_once(text, text, timestamptz) from public, anon, authenticated;
grant execute on function public.belt_due_texts(timestamptz, integer), public.belt_claim_text(uuid, boolean, boolean, timestamptz), public.belt_sweep_missed(timestamptz),
  public.belt_mirror_cold(bigint, integer, timestamptz, timestamptz), public.belt_wpie_event(bigint, text, text, text), public.belt_health_check(timestamptz, jsonb),
  public.belt_watch(timestamptz), public.belt_canary(timestamptz), public.belt_backfill(timestamptz) to service_role;
grant select on public.belt_alerts_sent to authenticated;
create policy belt_alerts_sent_read on public.belt_alerts_sent for select to authenticated using (public.is_team());
