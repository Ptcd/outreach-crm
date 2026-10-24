-- A call stop due on a Saturday or Sunday goes to Adil, who works the phones on weekends; Thalia Monday to Friday
-- (Colin 2026-10-22). 2026-10-24: "We are looking to get it ready to sell" at 4:19 PM Saturday made a call task for
-- Thalia, who is off. One-time: open weekend call tasks on Thalia move to Adil.

CREATE OR REPLACE FUNCTION public.belt_enter(p_lead_id uuid, p_belt text, p_step integer, p_event text, p_payload jsonb, p_by text, p_now timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
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
  who_person := case st.who when 'thalia_call' then (case when extract(isodow from st.at at time zone 'America/Chicago') >= 6
                                                     then 'adil' else 'thalia' end)::public.team_person when 'colin_call' then 'colin' when 'colin_visit' then 'colin'
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
      who_person := case st.who when 'thalia_call' then (case when extract(isodow from st.at at time zone 'America/Chicago') >= 6
                                                     then 'adil' else 'thalia' end)::public.team_person else 'colin' end;
      insert into public.tasks (lead_id, due_at, kind, owner, note, title, source, source_key, phone10, created_by)
      values (p_lead_id, st.at, case when st.who = 'colin_visit' then 'visit' else 'call' end, who_person,
              'Say: ' || st.say || coalesce('. Call ' || phones, ''), format('%s: stop 2 of %s', r.label, maxs), 'belt',
              format('belt:%s:%s:%s:%s', p_lead_id, p_belt, round, 2), public.belt_phone(p_lead_id), null)
      on conflict (source_key) do update set due_at = excluded.due_at, note = excluded.note, title = excluded.title, owner = excluded.owner, done_at = null;
    end if;
  end if;
  return jsonb_build_object('ok', true, 'belt', p_belt, 'step', step, 'next_stop_at', st.at, 'next_stop_who', st.who, 'say', st.say);
end $$;


update public.tasks set owner = 'adil'
 where done_at is null and owner = 'thalia' and source in ('belt', 'call_list')
   and extract(isodow from due_at at time zone 'America/Chicago') >= 6;
