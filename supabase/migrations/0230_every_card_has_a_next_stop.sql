-- 0230: every live card has a next stop.
--
-- The morning email has said "Belts: BROKEN ... live card(s) have no next stop" every day since 2026-11-04 (Colin
-- sent the 2026-11-14 one: 17 cards). Four causes, each fixed where it starts, then the 17 cards are put right by
-- the same rules:
--   1. The 90-day rest (cold_rest) made the check-in task and then wiped the card's next stop, so every resting card
--      was on the alarm. The check-in call is now the card's next stop.
--   2. A no-answer always used up the belt's next stop, due or not. A caller who tried a card's three numbers in one
--      sitting ran it through all three dormant stops (90 days apart) in two minutes and left it on nothing. A dial
--      ahead of the stop now leaves the follow-ups alone; the stop itself, or a call that was due, still counts.
--   3. A dormant card whose stops are all done is resting by design, but the alarm only knew that when three texts
--      had gone. It now also knows a dormant card on its last step with nothing ahead.
--   4. Muse's release took a card off its hold and left the hold's task open; a card that had replied before the hold
--      went back to no belt at all. A release now closes the hold's task and puts the card back on the follow-ups it
--      was on before the hold.

-- the belt a card was on before its last hold, and the step it had reached there
create or replace function public.belt_before_hold(p_lead_id uuid)
returns table (belt text, step integer) language sql stable security definer set search_path = public as $$
  with h as (
    select e.from_belt, e.at from public.belt_events e
     where e.lead_id = p_lead_id and e.to_belt in ('hold_not_now', 'not_now_condition', 'not_now_dated')
       and e.from_belt is distinct from e.to_belt
     order by e.at desc limit 1)
  select h.from_belt,
         greatest(coalesce((select e2.step from public.belt_events e2
                             where e2.lead_id = p_lead_id and e2.to_belt = h.from_belt and e2.at < h.at and e2.step > 0
                             order by e2.at desc limit 1), 1), 1)
    from h
   where h.from_belt is not null
     and h.from_belt not in ('hold_not_now', 'not_now_condition', 'not_now_dated', 'dead', 'dnc', 'too_high_or_listed', 'cold_texts')
     and public.belt_max_step(h.from_belt) > 0
$$;
revoke all on function public.belt_before_hold(uuid) from public, anon;

CREATE OR REPLACE FUNCTION public.cold_rest(p_lead_id uuid, p_why text, p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare due timestamptz; tz text := 'America/Chicago'; last_try text; dials integer;
begin
  due := (((p_now at time zone tz)::date + 90) + time '16:30') at time zone tz;
  if extract(isodow from due at time zone tz) in (6, 7) then due := due + make_interval(days => (8 - extract(isodow from due at time zone tz)::int)); end if;
  select to_char(max(m.sent_at) at time zone tz, 'Mon DD'), count(*) into last_try, dials from public.messages m
   where m.lead_id = p_lead_id and m.channel = 'call' and coalesce(m.status, '') not like 'inbound%';
  update public.tasks set done_at = now() where lead_id = p_lead_id and done_at is null and (source = 'belt' or source = 'checkin');
  insert into public.tasks (lead_id, due_at, kind, owner, source, title, note)
  values (p_lead_id, due, 'call', coalesce((select l2.locked_to from public.leads l2 where l2.id = p_lead_id and l2.locked_to in ('thalia', 'adil')), 'thalia'), 'checkin', '90-day check-in call',
          coalesce(dials, 0) || ' tries with no answer, last on ' || coalesce(last_try, '?') || ' (' || p_why || '). '
          || 'Call it like a fresh cold call: "Are you still the owner?", then "Any interest in selling it?"');
  perform set_config('wpie.in_belt_event', '1', true);
  -- the check-in call IS the card's next stop (0230): before, the rest wiped it, so every resting card read as
  -- "no next stop" on the belt alarm
  update public.leads set stage = 'follow_up', belt = null, belt_step = 0, next_stop_at = due, next_stop_who = 'thalia_call',
         next_stop_say = 'The 90-day check-in call: still the owner, and any interest in selling?',
         next_action = '90-day check-in call', next_action_at = due where id = p_lead_id;
  perform set_config('wpie.in_belt_event', '', true);
  insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
  values (p_lead_id, 'move', null, null, 0, jsonb_build_object('reason', '90-day rest: ' || p_why, 'checkin_at', due), p_now, 'conveyor');
  return jsonb_build_object('ok', true, 'rest', true, 'checkin_at', due);
end $function$;

CREATE OR REPLACE FUNCTION public.belt_route_no_answer(p_lead_id uuid, pl jsonb, p_by text, p_now timestamp with time zone, p_event text DEFAULT 'no_answer'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare l public.leads; n integer; dials integer;
begin
  select * into l from public.leads where id = p_lead_id;
  update public.leads set unanswered_count = unanswered_count + 1 where id = p_lead_id;
  if l.belt is null then
    -- a cold owner who didn't answer stays cold (Colin 2026-10-28: "what happens with all these leads that didnt answer?"):
    -- never the warm "said yes, not booked" track, which is for people who replied or talked to us. Power hour and the
    -- call list pace the next dials (3 a week, never two days running); after 9 dials with no contact, a 90-day rest.
    if not exists (select 1 from public.twilio_inbound ti where ti.lead_id = p_lead_id)
       and not exists (select 1 from public.messages m where m.lead_id = p_lead_id and m.channel = 'call'
                        and m.status in ('interested', 'reached_no_decision', 'not_now', 'not_interested'))
       and not exists (select 1 from public.hot_alerts h where h.lead_id = p_lead_id) then
      select count(*) into dials from public.messages m where m.lead_id = p_lead_id and m.channel = 'call' and coalesce(m.status, '') not like 'inbound%';
      -- resting: a check-in call that got no answer sets the next one; 9 dials with no contact start the rest (0127)
      if l.stage = 'follow_up' and exists (select 1 from public.tasks t where t.lead_id = p_lead_id and t.source = 'checkin') then
        return public.cold_rest(p_lead_id, 'the 90-day check-in call got no answer too', p_now);
      end if;
      if dials >= 9 then
        return public.cold_rest(p_lead_id, dials || ' dials, never reached', p_now);
      end if;
      return jsonb_build_object('ok', true, 'cold', true, 'dials', dials, 'note', 'a cold no-answer: the next dial comes from Power hour or the call list');
    end if;
    return public.belt_enter(p_lead_id, 'yes_unbooked', 2, p_event, pl, p_by, p_now);
  end if;
  if l.belt = 'call_booked' then
    select count(*) into n from public.belt_events e where e.lead_id = p_lead_id and e.to_belt = 'call_missed' and e.at > p_now - interval '30 days';
    if n > 0 then return public.belt_enter(p_lead_id, 'dormant', 1, p_event, pl || '{"note":"second no-show"}', p_by, p_now); end if;
    return public.belt_enter(p_lead_id, 'call_missed', 1, p_event, pl, p_by, p_now);
  elsif l.belt = 'visit_booked' then
    select count(*) into n from public.belt_events e where e.lead_id = p_lead_id and e.to_belt = 'visit_missed' and e.at > p_now - interval '30 days';
    if n > 0 then return public.belt_enter(p_lead_id, 'dormant', 1, p_event, pl || '{"note":"second no-show"}', p_by, p_now); end if;
    return public.belt_enter(p_lead_id, 'visit_missed', 1, p_event, pl, p_by, p_now);
  end if;
  -- A no-answer uses up the belt's stop only when that stop is a call that was due (0230): the stop itself was logged,
  -- or the belt's next stop is a person's call due by tomorrow. A dial made ahead of the stop (a caller trying a card's
  -- three numbers in one sitting, a card opened from a list months early) leaves the follow-ups as they are. Before,
  -- three no-answers in two minutes ran a card through all three dormant stops, each 90 days apart, and left it on nothing.
  if (p_event = 'stop_done' and coalesce(pl->>'source', 'belt') = 'belt')
     or (l.next_stop_who in ('thalia_call', 'colin_call') and l.next_stop_at <= p_now + interval '36 hours') then
    return public.belt_enter(p_lead_id, l.belt, l.belt_step + 1, p_event, pl, p_by, p_now);
  end if;
  insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
  values (p_lead_id, p_event, l.belt, l.belt, l.belt_step,
          pl || '{"note":"a dial before the stop was due: the follow-ups stay as they are"}'::jsonb, p_now, public.belt_actor(p_by));
  return jsonb_build_object('ok', true, 'belt', l.belt, 'step', l.belt_step, 'next_stop_at', l.next_stop_at, 'kept', true);
end $function$;

CREATE OR REPLACE FUNCTION public.agent_mark_card(p_lead_id uuid, p_mark text, p_reason text, p_date timestamp with time zone, p_phone text, p_agent text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  l    public.leads;
  who  text := 'Muse (' || coalesce(p_agent, 'agent') || ')';
  d    text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10);
  why  text := nullif(btrim(coalesce(p_reason, '')), '');
  phones text[];
  prev text;
  pbelt text;
  pstep integer;
  kept text[];
  gone text[];
  part text;
  ph   text;
  res  jsonb;
  dt   timestamptz := p_date;
begin
  -- a check-back date the agent picks: never in the past, never more than a year out, never a Sunday (10 AM their
  -- time on the next Monday instead); a hold with no date comes back in 45 days
  if dt is not null then
    if dt > now() + interval '366 days' then return jsonb_build_object('ok', false, 'reason', 'a check-back more than a year out is a dead card: mark dead, or pick a date inside a year'); end if;
    if extract(isodow from dt at time zone 'America/Chicago') = 7 then dt := dt + interval '1 day'; end if;
  elsif p_mark = 'held' then
    dt := now() + interval '45 days';
  end if;
  select * into l from public.leads where id = p_lead_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card'); end if;
  if l.stage = 'dnc' and p_mark not in ('note', 'note_delete') then return jsonb_build_object('ok', false, 'reason', 'this card is do-not-contact: it stays that way'); end if;
  case p_mark
    when 'note' then
      if why is null then return jsonb_build_object('ok', false, 'reason', 'a note needs words'); end if;
      update public.leads set notes = concat_ws(' | ', notes, 'Muse: ' || why), updated_at = now() where id = p_lead_id;
      return jsonb_build_object('ok', true, 'mark', 'note');
    when 'note_delete' then
      -- Muse's own notes only (a team member's note is theirs): every Muse note holding these words goes; what went is
      -- kept in the card's history (belt_events), never lost
      if why is null or length(why) < 8 then return jsonb_build_object('ok', false, 'reason', 'note_delete needs at least 8 characters of the note to remove (reason)'); end if;
      kept := '{}'; gone := '{}';
      foreach part in array string_to_array(coalesce(l.notes, ''), ' | ') loop
        if part ~ '^Muse( \([a-z_]+\))?: ' and position(lower(why) in lower(part)) > 0 then gone := gone || part;
        elsif part <> '' then kept := kept || part; end if;
      end loop;
      if coalesce(array_length(gone, 1), 0) = 0 then
        return jsonb_build_object('ok', false, 'reason', 'no note by Muse on this card holds those words (team notes cannot be deleted from here)');
      end if;
      update public.leads set notes = nullif(array_to_string(kept, ' | '), ''), updated_at = now() where id = p_lead_id;
      insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
      values (p_lead_id, 'note_deleted', l.belt, l.belt, l.belt_step, jsonb_build_object('removed', to_jsonb(gone)), now(), who);
      return jsonb_build_object('ok', true, 'mark', 'note_delete', 'removed', to_jsonb(gone));
    when 'release' then
      -- a hold (or a not-now) whose blocker cleared: off the hold belt, back to the stage the card had before it was
      -- held; a texting thread picks up its follow-ups again
      if l.belt not in ('hold_not_now', 'not_now_condition', 'not_now_dated') and l.stage <> 'follow_up' then
        return jsonb_build_object('ok', false, 'reason', 'this card is not held (belt ' || coalesce(l.belt, 'none') || ', stage ' || l.stage::text || ')');
      end if;
      if why is null then return jsonb_build_object('ok', false, 'reason', 'release needs what cleared (reason)'); end if;
      select e.from_stage::text into prev from public.lead_stage_events e
       where e.lead_id = p_lead_id and e.to_stage = 'follow_up' and e.from_stage is not null and e.from_stage <> 'follow_up'
       order by e.at desc limit 1;
      perform set_config('wpie.in_belt_event', '1', true);
      update public.leads set belt = null, belt_step = 0, next_stop_at = null, next_stop_who = null, next_stop_say = null,
             named_event = null, named_date = null,
             stage = case when stage = 'follow_up' then coalesce(prev, 'opener_sent')::public.lead_stage else stage end,
             next_action = 'Released: ' || left(why, 120), next_action_at = now(), updated_at = now()
       where id = p_lead_id;
      perform set_config('wpie.in_belt_event', '', true);
      insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
      values (p_lead_id, 'released', l.belt, null, 0, jsonb_build_object('reason', why, 'back_to_stage', coalesce(prev, 'opener_sent')), now(), who);
      res := jsonb_build_object('ok', true, 'released', true);
      -- the hold's own stop is over, and a card that was on a belt before the hold goes back to it (0230). Before, a
      -- released card kept its hold task, and one that had already replied was left on no belt with no next stop.
      update public.tasks set done_at = now(), note = coalesce(note, '') || ' [released: ' || left(why, 80) || ']'
       where lead_id = p_lead_id and source = 'belt' and done_at is null;
      select bb.belt, bb.step into pbelt, pstep from public.belt_before_hold(p_lead_id) bb;
      if pbelt is not null then
        perform set_config('wpie.in_belt_event', '1', true);
        res := res || jsonb_build_object('back_on', public.belt_enter(p_lead_id, pbelt, pstep, 'released',
                 jsonb_build_object('reason', why, 'note', 'back on the follow-ups it was on before the hold'), who, now()));
        perform set_config('wpie.in_belt_event', '', true);
      end if;
    when 'dead' then
      update public.leads set stage = 'dead', dead_reason = coalesce(why, 'not interested (texting agent)') where id = p_lead_id;
      res := public.belt_event(p_lead_id, 'move', jsonb_build_object('belt', 'dead', 'reason', coalesce(why, 'not interested (texting agent)')), who);
    when 'dnc' then
      select array_agg(distinct c.value_normalized) into phones from public.contacts c
       where c.lead_id = p_lead_id and c.kind = 'phone' and c.value_normalized ~ '^[0-9]{10}$';
      phones := coalesce(phones, '{}');
      if d ~ '^[0-9]{10}$' and not d = any(phones) then phones := array_append(phones, d); end if;
      insert into public.suppressed_phones (phone10, reason, source) select distinct p, 'dnc_agent', 'agent' from unnest(phones) p on conflict (phone10) do nothing;
      update public.contacts set suppressed = true, dnc_app = true where value_normalized = any(phones);
      update public.leads set stage = 'dnc', dead_reason = coalesce(why, 'asked not to be contacted') where id = p_lead_id;
      res := public.belt_event(p_lead_id, 'move', jsonb_build_object('belt', 'dnc', 'reason', coalesce(why, 'asked not to be contacted')), who);
    when 'not_now' then
      if dt is not null then
        if dt < now() then return jsonb_build_object('ok', false, 'reason', 'the check-back date cannot be in the past'); end if;
        update public.leads set stage = 'follow_up', next_action = 'Check back', next_action_at = dt where id = p_lead_id;
        res := public.belt_event(p_lead_id, 'named_date', jsonb_strip_nulls(jsonb_build_object('named_date', dt, 'named_event', why, 'reason', why)), who);
      else
        if why is null then return jsonb_build_object('ok', false, 'reason', 'not now needs a date, or the thing that has to change (reason)'); end if;
        update public.leads set stage = 'follow_up', named_event = left(why, 200), next_action = 'Check back', next_action_at = coalesce(next_action_at, now() + interval '30 days') where id = p_lead_id;
        res := public.belt_event(p_lead_id, 'move', jsonb_build_object('belt', 'not_now_condition', 'reason', why), who);
      end if;
    when 'hot' then
      if why is null then return jsonb_build_object('ok', false, 'reason', 'hot needs the reason in their words: Colin reads it on his phone'); end if;
      update public.leads set stage = case when stage in ('colin_call', 'walk_decision', 'walkthrough_booked', 'offer', 'under_contract', 'closed_won') then stage else 'colin_call' end,
             hot_at = coalesce(hot_at, now()) where id = p_lead_id;
      res := public.belt_event(p_lead_id, 'hot_reply', jsonb_strip_nulls(jsonb_build_object('reason', why, 'key', 'agent_hot:' || p_lead_id::text || ':' || to_char(now(), 'YYYYMMDDHH24MI'))), who);
      select c.value_normalized into ph from public.contacts c where c.lead_id = p_lead_id and c.kind = 'phone'
        and (d = '' or c.value_normalized = d) and c.status = 'ok' order by (c.value_normalized = d) desc, c.created_at limit 1;
      perform public.hot_record('agent:' || p_lead_id::text || ':' || to_char(now(), 'YYYYMMDDHH24MI'), p_lead_id, coalesce(ph, d, ''),
        split_part(l.owner_name, ' ', 1), l.property_address, 'Muse: ' || why, false, now());
    when 'held' then
      if why is null then return jsonb_build_object('ok', false, 'reason', 'held needs the blocker (reason)'); end if;
      update public.leads set named_event = left(why, 200), next_action = 'Waiting on: ' || left(why, 120), named_date = dt where id = p_lead_id;
      res := public.belt_event(p_lead_id, 'move', jsonb_strip_nulls(jsonb_build_object('belt', 'hold_not_now', 'reason', why, 'named_date', dt)), who);
    when 'wrong_number' then
      if d !~ '^[0-9]{10}$' then return jsonb_build_object('ok', false, 'reason', 'wrong_number needs the phone'); end if;
      update public.contacts set status = 'bad', note = concat_ws('; ', note, 'wrong number (texting agent)') where lead_id = p_lead_id and value_normalized = d;
      if not exists (select 1 from public.contacts c where c.lead_id = p_lead_id and c.kind = 'phone' and c.status = 'ok' and not c.suppressed and not c.dnc_app) then
        update public.leads set stage = 'data_fix' where id = p_lead_id and stage in ('postcard_mailed', 'opener_queued', 'opener_sent', 'reply_received');
      end if;
      res := jsonb_build_object('ok', true, 'phone_marked_bad', d);
    when 'elderly', 'grief' then
      res := public.belt_event(p_lead_id, 'flag', jsonb_strip_nulls(jsonb_build_object(case p_mark when 'elderly' then 'elderly_or_ill' else 'grief' end, true, 'reason', why)), who);
    else
      return jsonb_build_object('ok', false, 'reason', 'mark is one of: dead, dnc, not_now, hot, held, release, wrong_number, elderly, grief, note, note_delete');
  end case;
  if why is not null and p_mark <> 'note' then
    update public.leads set notes = concat_ws(' | ', notes, 'Muse (' || p_mark || '): ' || why), updated_at = now() where id = p_lead_id;
  end if;
  return coalesce(res, '{}'::jsonb) || jsonb_build_object('mark', p_mark,
    'card', (select jsonb_build_object('stage', x.stage, 'belt', x.belt, 'next_step_at', x.next_stop_at) from public.leads x where x.id = p_lead_id));
end $function$;

create or replace view public.cards_no_stop as
select id as lead_id, owner_name, property_address, stage, belt, belt_step, assigned_to, belt_entered_at, updated_at
  from public.leads l
 where owner_name not ilike 'TEST %' and next_stop_at is null
   and ((belt is not null and belt not in ('dead', 'dnc', 'too_high_or_listed', 'cold_texts')
         -- dormant, finished: three texts gone, or its last stop done
         and not (belt = 'dormant' and (dormant_round >= 3 or belt_step >= public.belt_max_step('dormant'))))
        or (belt is null and stage in ('reply_received', 'ai_qualifying', 'handoff', 'colin_call', 'walk_decision', 'walkthrough_booked',
                                       'offer', 'follow_up', 'human_owned')));

-- ---------------------------------------------------------------- the cards already stranded, by the same rules
do $$
declare r record; n_rest int := 0; n_dorm int := 0; n_hold int := 0; n_rel int := 0; res jsonb;
begin
  perform set_config('wpie.in_belt_event', '1', true);
  -- 1. resting cards: the open check-in call is the next stop
  for r in select l.id, (select min(t.due_at) from public.tasks t where t.lead_id = l.id and t.source = 'checkin' and t.done_at is null) as due
             from public.leads l
            where l.belt is null and l.stage = 'follow_up' and l.next_stop_at is null
              and exists (select 1 from public.tasks t where t.lead_id = l.id and t.source = 'checkin' and t.done_at is null) loop
    update public.leads set next_stop_at = r.due, next_stop_who = 'thalia_call',
           next_stop_say = 'The 90-day check-in call: still the owner, and any interest in selling?' where id = r.id;
    n_rest := n_rest + 1;
  end loop;
  -- 2. dormant cards whose three stops went to no-answers in a sitting, with no dormant text ever sent: start the wait again
  for r in select l.id from public.leads l
            where l.belt = 'dormant' and l.next_stop_at is null and l.dormant_round = 0 and l.belt_step >= public.belt_max_step('dormant')
              and l.owner_name not ilike 'TEST %' loop
    update public.leads set unanswered_count = 0 where id = r.id;
    res := public.belt_enter(r.id, 'dormant', 1, 'restored',
             '{"note":"0230: its dormant stops were used up by no-answers in one sitting; the 90-day wait starts again"}'::jsonb, 'desk', now());
    n_dorm := n_dorm + 1;
  end loop;
  -- 3. cards off their hold belt with the hold's task still open (no event says how; 2026-11-04): back on the hold
  for r in select l.id from public.leads l
            where l.belt is null and l.stage = 'follow_up' and l.next_stop_at is null and l.owner_name not ilike 'TEST %'
              and exists (select 1 from public.tasks t where t.lead_id = l.id and t.source = 'belt' and t.done_at is null
                           and t.source_key like 'belt:%:hold_not_now:%') loop
    res := public.belt_enter(r.id, 'hold_not_now', 1, 'restored',
             '{"note":"0230: the card had lost its hold while the hold task stayed open; back on the hold"}'::jsonb, 'desk', now());
    n_hold := n_hold + 1;
  end loop;
  -- 4. cards a release left on nothing: back on the follow-ups they were on before the hold
  for r in select l.id, bb.belt, bb.step from public.leads l cross join lateral public.belt_before_hold(l.id) bb
            where l.belt is null and l.next_stop_at is null and l.owner_name not ilike 'TEST %'
              and l.stage in ('reply_received', 'ai_qualifying', 'handoff', 'colin_call', 'walk_decision', 'walkthrough_booked', 'offer', 'follow_up', 'human_owned')
              and (select e.event from public.belt_events e where e.lead_id = l.id and e.event not like 'human_call%' order by e.at desc limit 1) = 'released' loop
    res := public.belt_enter(r.id, r.belt, r.step, 'restored',
             '{"note":"0230: released from a hold onto nothing; back on the follow-ups it was on before"}'::jsonb, 'desk', now());
    n_rel := n_rel + 1;
  end loop;
  perform set_config('wpie.in_belt_event', '', true);
  raise notice '0230: % resting, % dormant, % hold, % released card(s) given their next stop', n_rest, n_dorm, n_hold, n_rel;
end $$;
