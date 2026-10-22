-- The conveyor's engine (see 0028 for the state, the cadence table and the texts).
--   belt_event(lead, event, payload)   the ONE door: every move of a card goes through here
--   belt_enter(...)                    puts a card on a belt at a step and schedules the next stop
--   belt_stop_done(task, outcome, ...) a person logged a stop (Today's outcome buttons)
--   triggers                           inbound texts (reply_drafts), the laptop's threads, hot replies,
--                                      nurture / after-STOP tasks, human texts, STOP, task Done, draft sent
-- Hard rules enforced here: nothing to dead or DNC; no text ever to an elderly, ill or grieving owner;
-- never before a named date; 8am-8pm recipient-local, never Sunday (slid later, never earlier);
-- at most three unanswered touches (four when they asked for the call); a channel change before a repeat.

-- ------------------------------------------------------------------ time helpers
-- Recipient time zone from the mailing state (every WPIE owner is in or near Wisconsin; Central otherwise).
create or replace function public.belt_tz(p_state text)
returns text language sql immutable as $$
  select case upper(coalesce(p_state, ''))
    when 'NY' then 'America/New_York' when 'FL' then 'America/New_York' when 'OH' then 'America/New_York'
    when 'MI' then 'America/Detroit'  when 'GA' then 'America/New_York' when 'PA' then 'America/New_York'
    when 'NC' then 'America/New_York' when 'VA' then 'America/New_York' when 'SC' then 'America/New_York'
    when 'IN' then 'America/Indiana/Indianapolis' when 'NJ' then 'America/New_York' when 'MA' then 'America/New_York'
    when 'CO' then 'America/Denver'   when 'AZ' then 'America/Phoenix'   when 'UT' then 'America/Denver'
    when 'NM' then 'America/Denver'   when 'MT' then 'America/Denver'    when 'ID' then 'America/Boise'
    when 'CA' then 'America/Los_Angeles' when 'WA' then 'America/Los_Angeles' when 'OR' then 'America/Los_Angeles'
    when 'NV' then 'America/Los_Angeles'
    else 'America/Chicago' end
$$;

-- Slide an instant to the next open moment for the recipient: 8am-8pm local (texts from 9am), never
-- Sunday, never earlier. p_hour fixes the local hour (a day-anchored stop); p_kind is 'text' or 'call'.
create or replace function public.belt_slide(p_at timestamptz, p_tz text, p_kind text, p_hour integer default null)
returns timestamptz language plpgsql immutable as $$
declare l timestamp; open_from time; d date;
begin
  l := p_at at time zone p_tz;
  open_from := case when p_kind = 'text' then time '09:00' else time '08:00' end;
  if p_hour is not null then l := l::date + make_time(p_hour, 0, 0); end if;
  for i in 1..8 loop
    d := l::date;
    if l::time < open_from then l := d + open_from;
    elsif l::time >= time '20:00' then l := d + 1 + open_from;
    end if;
    if extract(isodow from l) = 7 then
      l := (l::date + 1) + coalesce(case when p_hour is not null then make_time(p_hour, 0, 0) end, open_from);
      continue;
    end if;
    exit;
  end loop;
  return l at time zone p_tz;
end $$;

create or replace function public.belt_street(p_address text)
returns text language sql immutable as $$
  select coalesce(nullif(initcap(lower(btrim(split_part(coalesce(p_address, ''), ',', 1)))), ''), 'the property')
$$;

create or replace function public.belt_fmt_time(p_at timestamptz, p_tz text)
returns text language sql immutable as $$
  select case when p_at is null then 'the time we set'
              else ltrim(to_char(p_at at time zone p_tz, 'FMDy FMHH12:MI AM'), '0') end
$$;

-- Fill {street} {said} {time} {event} {condition} {name} in a say or a template.
create or replace function public.belt_render(p_text text, l public.leads)
returns text language sql stable as $$
  select regexp_replace(replace(replace(replace(replace(replace(replace(coalesce(p_text, ''),
           '{street}', public.belt_street(l.property_address)),
           '{said}', coalesce(nullif(left(btrim(l.belt_reference), 120), ''), 'what you mentioned')),
           '{time}', public.belt_fmt_time(l.named_date, public.belt_tz(l.mailing_state))),
           '{event}', coalesce(nullif(btrim(l.named_event), ''), 'what you mentioned')),
           '{condition}', coalesce(nullif(btrim(l.named_event), ''), 'what you mentioned')),
           '{name}', coalesce(nullif(btrim(l.named_event), ''), 'them')),
         '\s+', ' ', 'g')
$$;

-- The best mobile for a text: the phone that replied last, else the first usable phone.
create or replace function public.belt_phone(p_lead_id uuid)
returns text language sql stable as $$
  select coalesce(
    (select t.from10 from public.twilio_inbound t where t.lead_id = p_lead_id order by t.received_at desc limit 1),
    (select r.phone10 from public.reply_threads r where r.lead_id = p_lead_id order by r.last_inbound_at desc nulls last limit 1),
    (select c.value_normalized from public.contacts c
      where c.lead_id = p_lead_id and c.kind = 'phone' and c.status = 'ok' and not c.suppressed and not c.dnc_app
        and c.value_normalized ~ '^[0-9]{10}$'
      order by (coalesce(c.line_type, '') in ('mobile', 'wireless')) desc, c.created_at limit 1))
$$;

-- The number they texted (a reply goes out from it), else the first reply number.
create or replace function public.belt_our_number(p_lead_id uuid, p_phone10 text)
returns text language sql stable as $$
  select coalesce(
    (select t.to_number from public.twilio_inbound t where t.from10 = p_phone10 and t.to_number is not null order by t.received_at desc limit 1),
    (select m.from_number from public.messages m where m.lead_id = p_lead_id and m.direction = 'out' and m.channel = 'sms'
       and m.from_number like '+1%' order by m.sent_at desc limit 1),
    (select c.reply_numbers[1] from public.campaign_control c where c.id = 1))
$$;

create or replace function public.belt_stage(p_belt text)
returns public.lead_stage language sql stable as $$ select stage from public.belt_rules where belt = p_belt $$;

create or replace function public.belt_label(p_belt text)
returns text language sql stable as $$ select coalesce((select label from public.belt_rules where belt = p_belt), 'No belt') $$;

create or replace function public.belt_max_step(p_belt text)
returns integer language sql stable as $$ select coalesce(max(step), 0)::integer from public.belt_steps where belt = p_belt $$;

create or replace function public.belt_in_event()
returns boolean language sql stable as $$ select coalesce(current_setting('wpie.in_belt_event', true), '') = '1' $$;

create or replace function public.belt_actor(p_by text)
returns text language sql stable as $$
  select coalesce(nullif(btrim(coalesce(p_by, '')), ''),
                  (select display_name from public.team_members where lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))),
                  'system')
$$;

-- ------------------------------------------------------------------ the stop for a step
-- When the stop of (belt, step) falls for this lead, who takes it and what to say. Null when the step
-- does not exist or has already passed (a slot-morning reminder after 8:30, a slot in the past).
create or replace function public.belt_stop_for(l public.leads, p_belt text, p_step integer, p_now timestamptz)
returns table (at timestamptz, who text, say text, template_key text)
language plpgsql stable as $$
declare s public.belt_steps; tz text; base timestamptz; kind text; w text; hr integer; prev_hour integer;
begin
  select * into s from public.belt_steps b where b.belt = p_belt and b.step = p_step;
  if not found then return; end if;
  tz := public.belt_tz(l.mailing_state);
  kind := case when s.anchor = 'slot_morning' then 'reminder' when s.who in ('auto_text', 'draft_text') then 'text' else 'call' end;
  w := case when s.who = 'owner_call' then (case when l.assigned_to = 'colin' then 'colin_call' else 'thalia_call' end) else s.who end;
  hr := s.call_hour;
  if s.anchor = 'now' then base := p_now;
  elsif s.anchor = 'prev' then base := p_now + make_interval(mins => (s.delay_hours * 60)::integer);
  elsif s.anchor = 'slot' then
    base := l.named_date;
    if base is null then base := p_now; end if;
  elsif s.anchor = 'slot_morning' then
    if l.named_date is null then return; end if;
    base := ((l.named_date at time zone tz)::date + time '08:30') at time zone tz;
    if base <= p_now or base >= l.named_date then return; end if;   -- booked after 8:30 the same day: no reminder
  elsif s.anchor = 'named' then
    if l.named_date is not null then
      base := l.named_date + make_interval(mins => (s.delay_hours * 60)::integer);
      -- a bare day they named gets the call hour; a day with a time is honoured as said, never earlier
      if (l.named_date at time zone tz)::time = time '00:00' then
        if kind = 'call' then hr := coalesce(hr, 14); end if;
      else
        hr := null;
        if s.delay_hours >= 0 then base := greatest(base, l.named_date); end if;
      end if;
      if s.delay_hours < 0 and base <= p_now then return; end if;    -- the date is too near for a pre-date text
    else
      base := p_now + make_interval(mins => (coalesce(s.fallback_hours, s.delay_hours) * 60)::integer);
    end if;
  end if;
  -- never before the date they named
  if l.named_date is not null and s.anchor in ('prev', 'now') and p_belt in ('not_now_dated', 'elderly', 'estate_waiting', 'hold_not_now')
     and base < l.named_date then base := l.named_date; end if;
  -- a call at a different hour band than the last call stop
  if kind = 'call' and s.other_band then
    select extract(hour from t.due_at at time zone tz)::integer into prev_hour from public.tasks t
     where t.lead_id = l.id and t.source in ('belt', 'call_list') and t.kind in ('call', 'visit') order by t.due_at desc limit 1;
    hr := case when prev_hour is not null and prev_hour >= 13 then 10 else 15 end;
  elsif kind = 'call' and hr is null and s.anchor in ('prev', 'named') and s.delay_hours >= 24 then
    hr := case when l.elderly_or_ill or l.grief then 9 else 14 end;
  end if;
  if (l.elderly_or_ill or l.grief) and kind = 'call' then hr := coalesce(hr, 9); end if;
  base := case when s.anchor in ('slot') then base else public.belt_slide(base, tz, kind, hr) end;
  if base < p_now and s.anchor <> 'slot' then base := public.belt_slide(p_now, tz, kind, null); end if;
  return query select base, w, public.belt_render(s.say, l), s.template_key;
end $$;

-- ------------------------------------------------------------------ cancel what is pending
create or replace function public.belt_cancel_pending(p_lead_id uuid, p_reason text, p_now timestamptz)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.tasks set done_at = p_now, note = coalesce(note, '') || ' [belt: ' || p_reason || ']'
   where lead_id = p_lead_id and source = 'belt' and done_at is null;
  update public.reply_drafts set status = 'superseded', note = coalesce(note, '') || ' | belt: ' || p_reason, updated_at = p_now
   where lead_id = p_lead_id and kind = 'belt' and status in ('queued', 'awaiting_approval', 'would_send');
end $$;

-- ------------------------------------------------------------------ enter a belt at a step
create or replace function public.belt_enter(p_lead_id uuid, p_belt text, p_step integer, p_event text, p_payload jsonb,
  p_by text, p_now timestamptz)
returns jsonb language plpgsql security definer set search_path = public as $$
declare l public.leads; r public.belt_rules; st record; from_belt text; round integer; maxs integer; step integer := greatest(p_step, 1);
  key text; title text; note text; phones text; tkind text; st_stage public.lead_stage; nxt text; who_person public.team_person;
  guard integer := 0;
begin
  select * into l from public.leads where id = p_lead_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such lead'); end if;
  select * into r from public.belt_rules where belt = p_belt;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such belt ' || p_belt); end if;
  from_belt := l.belt;
  -- a DNC card never moves (nothing outbound, ever); a dead card only by an explicit move or a STOP
  if from_belt = 'dnc' and p_belt <> 'dnc' and p_event <> 'move' then
    insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
    values (p_lead_id, p_event, from_belt, from_belt, l.belt_step, p_payload || '{"ignored":"dnc never moves"}', p_now, public.belt_actor(p_by));
    return jsonb_build_object('ok', true, 'belt', 'dnc', 'ignored', true);
  end if;
  if from_belt is distinct from p_belt then
    round := coalesce(l.belt_round, 0) + 1;
    perform public.belt_cancel_pending(p_lead_id, 'moved to ' || p_belt, p_now);
  else
    round := greatest(coalesce(l.belt_round, 0), 1);
    -- the stops before this one are over: close their tasks, drop their drafts
    update public.tasks set done_at = coalesce(done_at, p_now) where lead_id = p_lead_id and source = 'belt' and done_at is null
       and source_key <> format('belt:%s:%s:%s:%s', p_lead_id, p_belt, round, step)
       and not (p_belt in ('call_booked', 'visit_booked') and source_key = format('belt:%s:%s:%s:%s', p_lead_id, p_belt, round, 2));
    update public.reply_drafts set status = 'superseded', updated_at = p_now where lead_id = p_lead_id and kind = 'belt'
       and status in ('queued', 'awaiting_approval', 'would_send') and belt_stop_key <> format('belt:%s:%s:%s:%s', p_lead_id, p_belt, round, step);
  end if;
  maxs := public.belt_max_step(p_belt);
  -- the stops ran out, or the cap is hit: the belt's "then"
  if (step > maxs or (maxs > 0 and l.unanswered_count >= r.max_unanswered and from_belt = p_belt and step > 1)) then
    if r.then_belt is not null and r.then_belt <> p_belt then
      update public.leads set belt = p_belt, belt_step = maxs, belt_round = round, belt_entered_at = coalesce(belt_entered_at, p_now),
             next_stop_at = null, next_stop_who = null where id = p_lead_id;
      insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
      values (p_lead_id, 'stops_ran_out', from_belt, p_belt, maxs, p_payload, p_now, public.belt_actor(p_by));
      return public.belt_enter(p_lead_id, r.then_belt, 1, 'stops_ran_out', jsonb_build_object('from', p_belt), p_by, p_now);
    end if;
    -- a belt with no stops (dead, dnc, too high / listed, dormant after three rounds): the card rests
    st_stage := public.belt_stage(p_belt);
    update public.leads set belt = p_belt, belt_step = least(step, greatest(maxs, 0)), belt_round = round,
           belt_entered_at = case when from_belt is distinct from p_belt then p_now else coalesce(belt_entered_at, p_now) end,
           next_stop_at = null, next_stop_who = null, next_stop_say = null,
           unanswered_count = case when from_belt is distinct from p_belt then 0 else unanswered_count end,
           stage = coalesce(st_stage, stage), next_action = null, next_action_at = null,
           dead_reason = case when p_belt = 'dead' then coalesce(nullif(p_payload->>'reason', ''), dead_reason, p_event) else dead_reason end
     where id = p_lead_id;
    insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
    values (p_lead_id, p_event, from_belt, p_belt, 0, p_payload, p_now, public.belt_actor(p_by));
    return jsonb_build_object('ok', true, 'belt', p_belt, 'step', 0, 'next_stop_at', null);
  end if;
  -- find the first step from here whose stop still lies ahead (a reminder after 8:30 is skipped)
  loop
    select * into st from public.belt_stop_for(l, p_belt, step, p_now);
    exit when found or step > maxs;
    step := step + 1;
    guard := guard + 1;
    exit when guard > 8;
  end loop;
  if st is null or st.at is null then
    return public.belt_enter(p_lead_id, p_belt, maxs + 1, p_event, p_payload, p_by, p_now);
  end if;
  st_stage := public.belt_stage(p_belt);
  who_person := case st.who when 'thalia_call' then 'thalia'::public.team_person when 'colin_call' then 'colin' when 'colin_visit' then 'colin'
                            when 'draft_text' then 'colin' else null end;
  nxt := case st.who when 'auto_text' then 'Text goes on its own' when 'draft_text' then 'Draft text for Colin''s tap'
                     when 'thalia_call' then 'Thalia calls' when 'colin_call' then 'Colin calls' else 'Colin visits' end;
  update public.leads set belt = p_belt, belt_step = step, belt_round = round,
         belt_entered_at = case when from_belt is distinct from p_belt then p_now else coalesce(belt_entered_at, p_now) end,
         next_stop_at = st.at, next_stop_who = st.who, next_stop_say = st.say,
         unanswered_count = case when from_belt is distinct from p_belt then 0 else unanswered_count end,
         stage = case when st_stage is null then stage
                      when stage in ('under_contract', 'closed_won') and p_belt not in ('dead', 'dnc') then stage
                      -- a text in never moves a person's stage; it only lifts an automatic stage to Replied / Qualifying
                      when p_event in ('inbound_text', 'hot_reply', 'human_text', 'cold_text') and p_belt in ('yes_unbooked', 'replied_quiet', 'questions_quiet', 'call_booked')
                           then (case when stage in ('postcard_mailed', 'opener_queued', 'opener_sent', 'mail_only', 'data_fix')
                                      then (case p_belt when 'questions_quiet' then 'ai_qualifying' else 'reply_received' end)::public.lead_stage
                                      else stage end)
                      else st_stage end,
         next_action = case p_belt when 'visit_booked' then 'Walk-through' when 'call_booked' then 'Call booked' else nxt end,
         next_action_at = case when p_belt in ('visit_booked', 'call_booked') then coalesce(l.named_date, st.at) else st.at end,
         assigned_to = coalesce(who_person, assigned_to)
   where id = p_lead_id;
  insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
  values (p_lead_id, p_event, from_belt, p_belt, step,
          p_payload || jsonb_build_object('next_stop_at', st.at, 'next_stop_who', st.who, 'say', st.say), p_now, public.belt_actor(p_by));
  -- a person's stop (or a draft waiting for a tap) is a task on Today, keyed so a re-schedule updates it
  if st.who <> 'auto_text' then
    key := format('belt:%s:%s:%s:%s', p_lead_id, p_belt, round, step);
    select string_agg(format('%s (%s)', public.belt_fmt_phone(c.value_normalized), coalesce(c.line_type, 'phone')), ', ' order by c.created_at)
      into phones from public.contacts c
     where c.lead_id = p_lead_id and c.kind = 'phone' and c.status = 'ok' and not c.suppressed and not c.dnc_app and c.value_normalized ~ '^[0-9]{10}$';
    title := format('%s: stop %s of %s', r.label, step, maxs);
    note := case when st.who = 'draft_text' then 'Tap the draft on Approve. ' else '' end
         || 'Say: ' || st.say || coalesce('. Call ' || phones, '')
         || case when l.elderly_or_ill or l.grief then '. Older, ill or grieving: family on the line, their pace, no deadlines' else '' end;
    tkind := case st.who when 'colin_visit' then 'visit' when 'draft_text' then 'text' else 'call' end;
    insert into public.tasks (lead_id, due_at, kind, owner, note, title, source, source_key, phone10, created_by)
    values (p_lead_id, st.at, tkind, who_person, note, title, 'belt', key, public.belt_phone(p_lead_id), null)
    on conflict (source_key) do update set due_at = excluded.due_at, note = excluded.note, title = excluded.title,
      owner = excluded.owner, done_at = null;
  end if;
  if p_belt in ('call_booked', 'visit_booked') and step = 1 then
    select * into l from public.leads where id = p_lead_id;
    select * into st from public.belt_stop_for(l, p_belt, 2, p_now);
    if found and st.at is not null then
      who_person := case st.who when 'thalia_call' then 'thalia'::public.team_person else 'colin' end;
      insert into public.tasks (lead_id, due_at, kind, owner, note, title, source, source_key, phone10, created_by)
      values (p_lead_id, st.at, case when st.who = 'colin_visit' then 'visit' else 'call' end, who_person,
              'Say: ' || st.say || coalesce('. Call ' || phones, ''), format('%s: stop 2 of %s', r.label, maxs), 'belt',
              format('belt:%s:%s:%s:%s', p_lead_id, p_belt, round, 2), public.belt_phone(p_lead_id), null)
      on conflict (source_key) do update set due_at = excluded.due_at, note = excluded.note, title = excluded.title, owner = excluded.owner, done_at = null;
    end if;
  end if;
  return jsonb_build_object('ok', true, 'belt', p_belt, 'step', step, 'next_stop_at', st.at, 'next_stop_who', st.who, 'say', st.say);
end $$;

create or replace function public.belt_fmt_phone(p text)
returns text language sql immutable as $$
  select case when p ~ '^[0-9]{10}$' then format('(%s) %s-%s', substr(p, 1, 3), substr(p, 4, 3), substr(p, 7)) else coalesce(p, '') end
$$;

-- ------------------------------------------------------------------ the one door
-- Events (controlled): inbound_text, human_text, call_logged, next_step, verdict_no, stop_done, auto_text_sent,
-- draft_sent, draft_skipped, stop_missed, stop, dnc, wpie_event, cold_text, hot_reply, flag, move, named_date,
-- stage_changed. Returns {ok, belt, step, next_stop_at, next_stop_who}.
create or replace function public.belt_event(p_lead_id uuid, p_event text, p_payload jsonb default '{}'::jsonb,
  p_by text default null, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare l public.leads; pl jsonb := coalesce(p_payload, '{}'::jsonb); prev text; who text; o text; b text; st integer;
  res jsonb; slot timestamptz; r public.belt_rules; nd timestamptz; prior integer; reason text; maxs integer;
begin
  select * into l from public.leads where id = p_lead_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such lead'); end if;
  if p_event !~ '^[a-z_]{3,40}$' then return jsonb_build_object('ok', false, 'reason', 'bad event'); end if;
  prev := current_setting('wpie.in_belt_event', true);
  perform set_config('wpie.in_belt_event', '1', true);
  who := public.belt_actor(p_by);
  -- an outside event the card already took (a synced text, a WPIE record): once
  if pl ? 'key' and exists (select 1 from public.belt_events e where e.lead_id = p_lead_id and e.payload->>'key' = pl->>'key') then
    perform set_config('wpie.in_belt_event', coalesce(prev, ''), true);
    return jsonb_build_object('ok', true, 'belt', l.belt, 'step', l.belt_step, 'duplicate', true);
  end if;
  if pl ? 'said' and nullif(btrim(pl->>'said'), '') is not null then
    update public.leads set belt_reference = left(btrim(pl->>'said'), 300) where id = p_lead_id;
  end if;
  if pl ? 'named_date' and nullif(pl->>'named_date', '') is not null then
    begin nd := (pl->>'named_date')::timestamptz; exception when others then nd := null; end;
    if nd is not null then update public.leads set named_date = nd, named_event = coalesce(nullif(pl->>'named_event', ''), named_event) where id = p_lead_id; end if;
  elsif pl ? 'named_event' and nullif(pl->>'named_event', '') is not null then
    update public.leads set named_event = left(pl->>'named_event', 200) where id = p_lead_id;
  end if;
  select * into l from public.leads where id = p_lead_id;

  case p_event
  -- ---------------------------------------------------------------- the end of the line
  when 'stop', 'dnc' then
    res := public.belt_enter(p_lead_id, 'dnc', 0, p_event, pl, who, p_now);
  when 'flag' then
    update public.leads set elderly_or_ill = coalesce((pl->>'elderly_or_ill')::boolean, elderly_or_ill),
                            grief = coalesce((pl->>'grief')::boolean, grief) where id = p_lead_id;
    select * into l from public.leads where id = p_lead_id;
    if (l.elderly_or_ill or l.grief) and l.belt not in ('dead', 'dnc') then
      -- every pending agent text is cancelled; Colin only, by phone, at their pace
      res := public.belt_enter(p_lead_id, 'elderly', 1, 'flag', pl, who, p_now);
    else
      insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by) values (p_lead_id, 'flag', l.belt, l.belt, l.belt_step, pl, p_now, who);
      res := jsonb_build_object('ok', true, 'belt', l.belt, 'step', l.belt_step, 'next_stop_at', l.next_stop_at);
    end if;
  when 'move' then
    b := pl->>'belt';
    if b is null or not exists (select 1 from public.belt_rules where belt = b) then
      res := jsonb_build_object('ok', false, 'reason', 'pick a belt');
    else
      res := public.belt_enter(p_lead_id, b, coalesce((pl->>'step')::integer, 1), 'move', pl, who, p_now);
    end if;
  -- ---------------------------------------------------------------- they wrote
  when 'inbound_text' then
    update public.leads set unanswered_count = 0 where id = p_lead_id;
    perform public.belt_cancel_pending(p_lead_id, 'they texted', p_now);
    o := coalesce(pl->>'outcome', ''); b := coalesce(pl->>'intent', '');
    if coalesce((pl->>'removal')::boolean, false) or o = 'dnc' or b in ('opt_out', 'hostile') then
      res := public.belt_enter(p_lead_id, 'dnc', 0, 'inbound_text', pl, who, p_now);
    elsif coalesce(pl->>'kind', '') = 'after_close' then
      insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by) values (p_lead_id, 'inbound_text', l.belt, l.belt, l.belt_step, pl || '{"note":"after the thread was closed: nothing moves"}', p_now, who);
      res := jsonb_build_object('ok', true, 'belt', l.belt, 'step', l.belt_step, 'next_stop_at', l.next_stop_at);
    elsif o = 'wrong_number' or b = 'wrong_number' then
      update public.leads set belt = null, belt_step = 0, next_stop_at = null, next_stop_who = null, next_stop_say = null,
             stage = case when stage in ('dnc', 'closed_won', 'under_contract') then stage else 'data_fix' end where id = p_lead_id;
      insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by) values (p_lead_id, 'inbound_text', l.belt, null, 0, pl, p_now, who);
      res := jsonb_build_object('ok', true, 'belt', null, 'reason', 'wrong number: WPIE re-plans the next mobile');
    elsif o = 'not_interested' or (o <> 'open' and b in ('sold', 'signed_other', 'my_home', 'tenant', 'manager', 'middleman', 'burned', 'annoyed', 'joke_number')) then
      res := public.belt_enter(p_lead_id, 'dead', 0, 'inbound_text', pl || jsonb_build_object('reason', coalesce(nullif(b, ''), o)), who, p_now);
    elsif b = 'listed' and o <> 'open' then
      res := public.belt_enter(p_lead_id, 'too_high_or_listed', 0, 'inbound_text', pl, who, p_now);
    elsif coalesce((pl->'facts'->>'nurture')::boolean, false) then
      update public.leads set named_event = coalesce(nullif(left(pl->'facts'->>'condition', 200), ''), nullif(left(pl->>'said', 200), ''), named_event) where id = p_lead_id;
      res := public.belt_enter(p_lead_id, 'not_now_condition', 1, 'inbound_text', pl, who, p_now);
    elsif b = 'not_now' then
      res := public.belt_enter(p_lead_id, 'dormant', 1, 'inbound_text', pl, who, p_now);
    elsif b in ('who_is_this', 'bot_question') then
      -- a question about us, answered plainly: no nudge at all (Rick: texting a ghost only shows your cards)
      res := public.belt_enter(p_lead_id, 'dormant', 1, 'inbound_text', pl || '{"note":"no nudge: asked who we are"}', who, p_now);
    else
      slot := null;
      if coalesce(pl->>'callback_slot', pl->'facts'->>'callback_slot', '') <> '' then
        begin slot := (coalesce(pl->>'callback_slot', pl->'facts'->>'callback_slot'))::timestamptz; exception when others then slot := null; end;
      end if;
      if slot is not null and slot > p_now then
        update public.leads set named_date = slot, named_event = 'call' where id = p_lead_id;
        res := public.belt_enter(p_lead_id, 'call_booked', 1, 'inbound_text', pl, who, p_now);
      elsif coalesce((pl->>'interest')::boolean, false) or b in ('interested', 'wants_call', 'price_first', 'number_only', 'worth', 'terms')
            or coalesce(pl->>'agent_stage', '') = 'book' or coalesce(pl->>'thread_outcome', '') = 'handoff' then
        res := public.belt_enter(p_lead_id, 'yes_unbooked', 1, 'inbound_text', pl, who, p_now);
      else
        select count(*) into prior from public.twilio_inbound t where t.lead_id = p_lead_id and t.received_at < coalesce((pl->>'at')::timestamptz, p_now);
        res := public.belt_enter(p_lead_id, case when prior > 0 or coalesce(pl->>'agent_stage', '') = 'qualify' or l.belt = 'questions_quiet' then 'questions_quiet' else 'replied_quiet' end,
                 1, 'inbound_text', pl, who, p_now);
      end if;
    end if;
  when 'hot_reply' then
    update public.leads set unanswered_count = 0 where id = p_lead_id;
    res := public.belt_enter(p_lead_id, 'yes_unbooked', 1, 'hot_reply', pl, who, p_now);
  when 'human_text' then
    -- a person wrote in the thread: the pending automatic text is off; the card keeps its belt and step
    update public.reply_drafts set status = 'superseded', note = coalesce(note, '') || ' | a person texted', updated_at = p_now
     where lead_id = p_lead_id and kind = 'belt' and status in ('queued', 'awaiting_approval', 'would_send');
    insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by) values (p_lead_id, 'human_text', l.belt, l.belt, l.belt_step, pl, p_now, who);
    if l.next_stop_who in ('auto_text', 'draft_text') and l.belt is not null then
      res := public.belt_enter(p_lead_id, l.belt, l.belt_step + 1, 'human_text', pl - 'key', who, p_now);
    else
      res := jsonb_build_object('ok', true, 'belt', l.belt, 'step', l.belt_step, 'next_stop_at', l.next_stop_at);
    end if;
  -- ---------------------------------------------------------------- a call was logged
  when 'call_logged' then
    o := coalesce(pl->>'outcome', '');
    if o = 'dnc' then res := public.belt_enter(p_lead_id, 'dnc', 0, 'call_logged', pl, who, p_now);
    elsif o = 'not_interested' then res := public.belt_enter(p_lead_id, 'dead', 0, 'call_logged', pl || jsonb_build_object('reason', coalesce(nullif(pl->>'note', ''), 'Not interested (call)')), who, p_now);
    elsif o = 'wrong_number' then
      update public.leads set belt = null, belt_step = 0, next_stop_at = null, next_stop_who = null, next_stop_say = null,
             stage = case when stage in ('dnc', 'closed_won', 'under_contract') then stage else 'data_fix' end where id = p_lead_id;
      insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by) values (p_lead_id, 'call_logged', l.belt, null, 0, pl, p_now, who);
      res := jsonb_build_object('ok', true, 'belt', null);
    elsif o = 'not_now' then
      if l.named_date is not null and l.named_date > p_now then res := public.belt_enter(p_lead_id, 'not_now_dated', 1, 'call_logged', pl, who, p_now);
      else res := public.belt_enter(p_lead_id, 'not_now_condition', 1, 'call_logged', pl, who, p_now); end if;
    elsif o = 'interested' then
      if l.stage in ('walkthrough_booked', 'offer', 'under_contract', 'closed_won') and l.belt in ('visit_booked', 'offer_out') then
        res := jsonb_build_object('ok', true, 'belt', l.belt, 'step', l.belt_step, 'next_stop_at', l.next_stop_at);
        insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by) values (p_lead_id, 'call_logged', l.belt, l.belt, l.belt_step, pl, p_now, who);
      else res := public.belt_enter(p_lead_id, 'yes_unbooked', 1, 'call_logged', pl, who, p_now); end if;
    elsif o = 'reached_no_decision' then
      res := public.belt_enter(p_lead_id, 'after_call_quiet', 1, 'call_logged', pl, who, p_now);
    elsif o = 'no_answer' then
      res := public.belt_route_no_answer(p_lead_id, pl, who, p_now, p_event);
    else
      res := jsonb_build_object('ok', false, 'reason', 'unknown call outcome ' || o);
    end if;
  when 'next_step' then
    begin slot := (pl->>'at')::timestamptz; exception when others then slot := null; end;
    if slot is null then res := jsonb_build_object('ok', false, 'reason', 'a day and time');
    else
      update public.leads set named_date = slot, named_event = case when pl->>'kind' = 'walk' then 'visit' else 'call' end where id = p_lead_id;
      res := public.belt_enter(p_lead_id, case when pl->>'kind' = 'walk' then 'visit_booked' else 'call_booked' end, 1, 'next_step', pl, who, p_now);
    end if;
  when 'verdict_no' then
    reason := coalesce(pl->>'reason', '');
    if reason in ('dnc', 'removed') then res := public.belt_enter(p_lead_id, 'dnc', 0, 'verdict_no', pl, who, p_now);
    elsif reason in ('listed', 'signed_other', 'market_firm') then res := public.belt_enter(p_lead_id, 'too_high_or_listed', 0, 'verdict_no', pl, who, p_now);
    elsif reason = 'elderly_no_family' then res := public.belt_enter(p_lead_id, 'elderly', 1, 'verdict_no', pl, who, p_now);
    elsif reason = 'estate_no_signer' then res := public.belt_enter(p_lead_id, 'estate_waiting', 1, 'verdict_no', pl, who, p_now);
    elsif reason = 'spouse' then res := public.belt_enter(p_lead_id, 'needs_family', 1, 'verdict_no', pl, who, p_now);
    else res := public.belt_enter(p_lead_id, 'dead', 0, 'verdict_no', pl || jsonb_build_object('reason', coalesce(nullif(reason, ''), 'the card said do not book')), who, p_now); end if;
  -- ---------------------------------------------------------------- a stop was logged
  when 'stop_done' then
    o := coalesce(pl->>'outcome', 'done');
    if o = 'dnc' then res := public.belt_enter(p_lead_id, 'dnc', 0, 'stop_done', pl, who, p_now);
    elsif o = 'no' then res := public.belt_enter(p_lead_id, 'dead', 0, 'stop_done', pl || jsonb_build_object('reason', coalesce(nullif(pl->>'note', ''), 'said no on the call')), who, p_now);
    elsif o = 'wrong_number' then res := public.belt_event(p_lead_id, 'call_logged', pl, who, p_now);
    elsif o = 'booked' then
      begin slot := (pl->>'at')::timestamptz; exception when others then slot := null; end;
      if slot is null then res := jsonb_build_object('ok', false, 'reason', 'a day and time');
      else res := public.belt_event(p_lead_id, 'next_step', jsonb_build_object('kind', coalesce(pl->>'kind', 'callback'), 'at', slot), who, p_now); end if;
    elsif o = 'not_now' then
      if nd is not null and nd > p_now then res := public.belt_enter(p_lead_id, 'not_now_dated', 1, 'stop_done', pl, who, p_now);
      elsif nullif(pl->>'named_event', '') is not null then res := public.belt_enter(p_lead_id, 'not_now_condition', 1, 'stop_done', pl, who, p_now);
      else res := public.belt_enter(p_lead_id, 'dormant', 1, 'stop_done', pl, who, p_now); end if;
    elsif o in ('family', 'elderly', 'estate', 'hold', 'too_high', 'listed', 'offer_out') then
      b := case o when 'family' then 'needs_family' when 'elderly' then 'elderly' when 'estate' then 'estate_waiting' when 'hold' then 'hold_not_now'
                  when 'offer_out' then 'offer_out' else 'too_high_or_listed' end;
      if o = 'elderly' then update public.leads set elderly_or_ill = true where id = p_lead_id; end if;
      res := public.belt_enter(p_lead_id, b, 1, 'stop_done', pl, who, p_now);
    elsif o in ('reached', 'reached_no_decision') then
      update public.leads set unanswered_count = 0 where id = p_lead_id;
      if l.belt = 'cold_texts' then res := public.belt_enter(p_lead_id, 'yes_unbooked', 1, 'stop_done', pl, who, p_now);
      elsif l.belt = 'visit_booked' and l.belt_step = 2 then res := public.belt_enter(p_lead_id, 'after_visit_quiet', 1, 'stop_done', pl, who, p_now);
      else res := public.belt_enter(p_lead_id, 'after_call_quiet', 1, 'stop_done', pl, who, p_now); end if;
    elsif o in ('no_answer', 'voicemail') then
      res := public.belt_route_no_answer(p_lead_id, pl, who, p_now, p_event);
    elsif o = 'sent' then      -- a draft stop went out: next stop, counts as a touch with no reply yet
      update public.leads set unanswered_count = unanswered_count + 1 where id = p_lead_id and belt is not null;
      res := public.belt_enter(p_lead_id, coalesce(l.belt, 'dormant'), l.belt_step + 1, 'stop_done', pl, who, p_now);
      if l.belt = 'dormant' then update public.leads set dormant_round = least(dormant_round + 1, 3) where id = p_lead_id; end if;
    else                       -- 'done' / 'skipped': the next stop on the ladder, not counted against them
      if l.belt is null then res := jsonb_build_object('ok', true, 'belt', null);
      else res := public.belt_enter(p_lead_id, l.belt, l.belt_step + 1, 'stop_done', pl, who, p_now); end if;
      if l.belt = 'dormant' and o = 'skipped' then update public.leads set dormant_round = least(dormant_round + 1, 3) where id = p_lead_id; end if;
    end if;
  when 'auto_text_sent' then
    update public.leads set unanswered_count = unanswered_count + 1 where id = p_lead_id;
    if l.belt is null then res := jsonb_build_object('ok', true, 'belt', null);
    else res := public.belt_enter(p_lead_id, l.belt, l.belt_step + 1, 'auto_text_sent', pl, who, p_now); end if;
  when 'draft_sent' then
    res := public.belt_event(p_lead_id, 'stop_done', pl || '{"outcome":"sent"}', who, p_now);
  when 'draft_skipped' then
    res := public.belt_event(p_lead_id, 'stop_done', pl || '{"outcome":"skipped"}', who, p_now);
  when 'stop_missed' then
    -- a text stop that never went counts as unanswered; a call stop is re-slid once, then counts
    if l.next_stop_who in ('auto_text', 'draft_text') then
      update public.leads set unanswered_count = unanswered_count + 1 where id = p_lead_id;
      res := public.belt_enter(p_lead_id, l.belt, l.belt_step + 1, 'stop_missed', pl, who, p_now);
    elsif coalesce((pl->>'again')::boolean, false) then
      update public.leads set unanswered_count = unanswered_count + 1 where id = p_lead_id;
      res := public.belt_enter(p_lead_id, l.belt, l.belt_step + 1, 'stop_missed', pl, who, p_now);
    else
      res := public.belt_enter(p_lead_id, l.belt, l.belt_step, 'stop_missed', pl || '{"reslid":true}', who, p_now);
    end if;
  -- ---------------------------------------------------------------- the laptop
  when 'cold_text' then
    st := coalesce((pl->>'step')::integer, 1);
    if l.belt is null or l.belt = 'cold_texts' then
      update public.leads set belt = 'cold_texts', belt_step = st, belt_round = greatest(belt_round, 1),
             belt_entered_at = coalesce(belt_entered_at, p_now),
             next_stop_at = nullif(pl->>'next_at', '')::timestamptz,
             next_stop_who = case when nullif(pl->>'next_at', '') is null then null when st >= 3 then 'thalia_call' else 'auto_text' end,
             next_stop_say = case when st >= 3 then 'Never answered three texts; one call from the daily list' else format('Text %s goes on its own (WPIE)', st + 1) end,
             next_action = case when nullif(pl->>'next_at', '') is null then next_action else 'Cold texts (WPIE)' end,
             next_action_at = coalesce(nullif(pl->>'next_at', '')::timestamptz, next_action_at)
       where id = p_lead_id;
      insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by) values (p_lead_id, 'cold_text', l.belt, 'cold_texts', st, pl, p_now, who);
    else
      insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by) values (p_lead_id, 'cold_text', l.belt, l.belt, l.belt_step, pl || '{"ignored":"already past cold texts"}', p_now, who);
    end if;
    select * into l from public.leads where id = p_lead_id;
    res := jsonb_build_object('ok', true, 'belt', l.belt, 'step', l.belt_step, 'next_stop_at', l.next_stop_at);
  when 'wpie_event' then
    -- a new public record on a resting card: one call from Colin that references the earlier conversation, never the record
    if l.belt in ('dormant', 'too_high_or_listed', 'hold_not_now') or (l.belt = 'dead' and l.belt_entered_at < p_now - interval '90 days'
         and coalesce(l.dead_reason, '') not in ('Not interested (call)', 'not_interested', 'no_contact', 'said no on the call')) then
      update public.leads set belt_reference = coalesce(belt_reference, 'we spoke before') where id = p_lead_id;
      res := public.belt_enter(p_lead_id, 'after_call_quiet', 1, 'wpie_event',
               pl || jsonb_build_object('say', 'Re-entry: we spoke before about the place; checking in as I said I would. Never mention the record.'), who, p_now);
      update public.leads set next_stop_say = 'We spoke before about ' || public.belt_street(property_address) || '; checking in as I said I would (never mention the record)' where id = p_lead_id;
      update public.tasks set note = 'Re-entry after a new public record. Say: we spoke before about ' || public.belt_street(l.property_address) || '; checking in as I said I would. Never mention the record itself.'
       where lead_id = p_lead_id and source = 'belt' and done_at is null;
    else
      insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by) values (p_lead_id, 'wpie_event', l.belt, l.belt, l.belt_step, pl || '{"note":"card is live or closed: no re-entry"}', p_now, who);
      res := jsonb_build_object('ok', true, 'belt', l.belt, 'step', l.belt_step, 'next_stop_at', l.next_stop_at);
    end if;
  when 'named_date' then
    if l.belt in ('not_now_dated', 'elderly', 'estate_waiting', 'hold_not_now', 'needs_family') then
      res := public.belt_enter(p_lead_id, l.belt, 1, 'named_date', pl, who, p_now);
    elsif nd is not null then res := public.belt_enter(p_lead_id, 'not_now_dated', 1, 'named_date', pl, who, p_now);
    else res := jsonb_build_object('ok', false, 'reason', 'a date'); end if;
  when 'stage_changed' then
    -- a stage written outside the belt (a legacy path): keep the belt honest
    b := pl->>'to';
    if b = 'dnc' then res := public.belt_enter(p_lead_id, 'dnc', 0, 'stage_changed', pl, who, p_now);
    elsif b = 'dead' then res := public.belt_enter(p_lead_id, 'dead', 0, 'stage_changed', pl, who, p_now);
    elsif b = 'closed_no_contact' then res := public.belt_enter(p_lead_id, 'dead', 0, 'stage_changed', pl || '{"reason":"no_contact"}', who, p_now);
    elsif b = 'walkthrough_booked' and l.belt is distinct from 'visit_booked' then res := public.belt_enter(p_lead_id, 'visit_booked', 1, 'stage_changed', pl, who, p_now);
    elsif b = 'colin_call' and l.belt not in ('call_booked', 'call_missed', 'yes_unbooked') then res := public.belt_enter(p_lead_id, 'yes_unbooked', 1, 'stage_changed', pl, who, p_now);
    elsif b = 'offer' and l.belt is distinct from 'offer_out' then res := public.belt_enter(p_lead_id, 'offer_out', 1, 'stage_changed', pl, who, p_now);
    elsif b = 'follow_up' and l.belt is null then res := public.belt_enter(p_lead_id, 'not_now_condition', 1, 'stage_changed', pl, who, p_now);
    elsif b in ('reply_received', 'ai_qualifying', 'handoff') and l.belt is null then
      res := public.belt_enter(p_lead_id, case b when 'handoff' then 'yes_unbooked' when 'ai_qualifying' then 'questions_quiet' else 'replied_quiet' end, 1, 'stage_changed', pl, who, p_now);
    else
      insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by) values (p_lead_id, 'stage_changed', l.belt, l.belt, l.belt_step, pl, p_now, who);
      res := jsonb_build_object('ok', true, 'belt', l.belt, 'step', l.belt_step, 'next_stop_at', l.next_stop_at);
    end if;
  else
    res := jsonb_build_object('ok', false, 'reason', 'unknown event ' || p_event);
  end case;
  perform set_config('wpie.in_belt_event', coalesce(prev, ''), true);
  return res;
end $$;

-- No answer at a stop: the next stop on the ladder (a channel change is built into the ladders);
-- a booked call or visit that was missed goes to its missed ladder; a second no-show goes dormant.
create or replace function public.belt_route_no_answer(p_lead_id uuid, pl jsonb, p_by text, p_now timestamptz, p_event text default 'no_answer')
returns jsonb language plpgsql security definer set search_path = public as $$
declare l public.leads; n integer;
begin
  select * into l from public.leads where id = p_lead_id;
  update public.leads set unanswered_count = unanswered_count + 1 where id = p_lead_id;
  if l.belt is null then return public.belt_enter(p_lead_id, 'yes_unbooked', 2, p_event, pl, p_by, p_now); end if;
  if l.belt = 'call_booked' then
    select count(*) into n from public.belt_events e where e.lead_id = p_lead_id and e.to_belt = 'call_missed' and e.at > p_now - interval '30 days';
    if n > 0 then return public.belt_enter(p_lead_id, 'dormant', 1, p_event, pl || '{"note":"second no-show"}', p_by, p_now); end if;
    return public.belt_enter(p_lead_id, 'call_missed', 1, p_event, pl, p_by, p_now);
  elsif l.belt = 'visit_booked' then
    select count(*) into n from public.belt_events e where e.lead_id = p_lead_id and e.to_belt = 'visit_missed' and e.at > p_now - interval '30 days';
    if n > 0 then return public.belt_enter(p_lead_id, 'dormant', 1, p_event, pl || '{"note":"second no-show"}', p_by, p_now); end if;
    return public.belt_enter(p_lead_id, 'visit_missed', 1, p_event, pl, p_by, p_now);
  end if;
  return public.belt_enter(p_lead_id, l.belt, l.belt_step + 1, p_event, pl, p_by, p_now);
end $$;

-- ------------------------------------------------------------------ Today's outcome buttons
-- outcomes: reached | reached_no_decision | no_answer | voicemail | booked (kind, at) | not_now (named_date / named_event)
--           | no | wrong_number | dnc | family | elderly | estate | hold | too_high | listed | done
create or replace function public.belt_stop_done(p_task_id uuid, p_outcome text, p_note text default null, p_detail jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare t public.tasks; who text; pl jsonb; res jsonb;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  select * into t from public.tasks where id = p_task_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such stop'); end if;
  if t.done_at is not null then return jsonb_build_object('ok', false, 'reason', 'already logged'); end if;
  select display_name into who from public.team_members where lower(email) = lower(auth.jwt() ->> 'email');
  pl := coalesce(p_detail, '{}'::jsonb) || jsonb_build_object('outcome', p_outcome, 'task_id', t.id, 'note', p_note, 'source', t.source);
  perform set_config('wpie.task_outcome', '1', true);
  update public.tasks set done_at = now(),
         note = coalesce(note, '') || ' [' || replace(p_outcome, '_', ' ') || coalesce(': ' || nullif(btrim(coalesce(p_note, '')), ''), '') || ']'
   where id = t.id;
  perform set_config('wpie.task_outcome', '', true);
  if t.lead_id is null then return jsonb_build_object('ok', true, 'belt', null); end if;
  if t.source in ('belt', 'call_list', 'nurture', 'after_stop') then
    res := public.belt_event(t.lead_id, 'stop_done', pl, who, now());
  else
    res := jsonb_build_object('ok', true);
  end if;
  if p_outcome in ('reached', 'reached_no_decision', 'booked', 'not_now', 'no', 'family', 'elderly', 'estate', 'hold', 'too_high', 'listed') then
    perform public.mark_called(t.lead_id, now());
    insert into public.messages (lead_id, direction, channel, body, sent_at, seen_at, status)
    values (t.lead_id, 'in', 'call', format('Stop logged (%s): %s%s', coalesce(who, 'team'), replace(p_outcome, '_', ' '),
            coalesce(E'\n' || nullif(btrim(coalesce(p_note, '')), ''), '')), now(), now(), p_outcome);
  elsif p_outcome in ('no_answer', 'voicemail') then
    insert into public.messages (lead_id, direction, channel, body, sent_at, seen_at, status)
    values (t.lead_id, 'out', 'call', format('%s (%s)%s', case when p_outcome = 'voicemail' then 'Left a voicemail' else 'No answer' end, coalesce(who, 'team'),
            coalesce(E'\n' || nullif(btrim(coalesce(p_note, '')), ''), '')), now(), now(), p_outcome);
  end if;
  return res;
end $$;
revoke all on function public.belt_stop_done(uuid, text, text, jsonb) from public, anon;
grant execute on function public.belt_stop_done(uuid, text, text, jsonb) to authenticated, service_role;

-- The card's "move" (Colin or Thalia): a belt by hand, a flag, a named date. Replaces the stage form's direct write.
create or replace function public.lead_move(p_lead_id uuid, p_belt text default null, p_reason text default null, p_named_date timestamptz default null,
  p_named_event text default null, p_elderly boolean default null, p_grief boolean default null, p_assigned_to text default null, p_notes text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare who text; res jsonb := '{"ok":true}'::jsonb;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  select display_name into who from public.team_members where lower(email) = lower(auth.jwt() ->> 'email');
  if p_notes is not null then update public.leads set notes = nullif(btrim(p_notes), '') where id = p_lead_id; end if;
  if p_assigned_to is not null then
    perform set_config('wpie.in_belt_event', '1', true);
    update public.leads set assigned_to = nullif(p_assigned_to, '')::public.team_person where id = p_lead_id;
    perform set_config('wpie.in_belt_event', '', true);
  end if;
  if p_elderly is not null or p_grief is not null then
    res := public.belt_event(p_lead_id, 'flag', jsonb_strip_nulls(jsonb_build_object('elderly_or_ill', p_elderly, 'grief', p_grief, 'reason', p_reason)), who);
  end if;
  if p_named_date is not null or nullif(p_named_event, '') is not null then
    res := public.belt_event(p_lead_id, 'named_date', jsonb_strip_nulls(jsonb_build_object('named_date', p_named_date, 'named_event', p_named_event, 'reason', p_reason)), who);
  end if;
  if p_belt is not null then
    res := public.belt_event(p_lead_id, 'move', jsonb_strip_nulls(jsonb_build_object('belt', p_belt, 'reason', p_reason)), who);
  end if;
  return res;
end $$;
revoke all on function public.lead_move(uuid, text, text, timestamptz, text, boolean, boolean, text, text) from public, anon;
grant execute on function public.lead_move(uuid, text, text, timestamptz, text, boolean, boolean, text, text) to authenticated;

revoke all on function public.belt_event(uuid, text, jsonb, text, timestamptz), public.belt_enter(uuid, text, integer, text, jsonb, text, timestamptz),
  public.belt_cancel_pending(uuid, text, timestamptz), public.belt_route_no_answer(uuid, jsonb, text, timestamptz, text) from public, anon;
grant execute on function public.belt_event(uuid, text, jsonb, text, timestamptz) to authenticated, service_role;
grant execute on function public.belt_enter(uuid, text, integer, text, jsonb, text, timestamptz), public.belt_cancel_pending(uuid, text, timestamptz),
  public.belt_route_no_answer(uuid, jsonb, text, timestamptz, text) to service_role;
grant execute on function public.belt_tz(text), public.belt_slide(timestamptz, text, text, integer), public.belt_street(text), public.belt_label(text),
  public.belt_fmt_time(timestamptz, text), public.belt_fmt_phone(text), public.belt_render(text, public.leads), public.belt_stage(text),
  public.belt_max_step(text), public.belt_in_event(), public.belt_actor(text), public.belt_phone(uuid), public.belt_our_number(uuid, text),
  public.belt_stop_for(public.leads, text, integer, timestamptz) to authenticated, service_role;
