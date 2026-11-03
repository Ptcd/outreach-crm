-- 0165: a logged call keeps a call the caller already booked (Thalia 2026-11-03, 8795 Happiness Dr: she booked Colin's
-- call for Nov 14, then logged the call 'Interested' a minute later, and the card fell back to 'Said yes, not booked' on
-- Warm). belt_event, call_logged: an 'Interested' or 'Talked, no decision' outcome on a card whose booked call is still
-- ahead leaves the booking as it is and only records the call; with no booking ahead it moves the card as before.

CREATE OR REPLACE FUNCTION public.belt_event(p_lead_id uuid, p_event text, p_payload jsonb DEFAULT '{}'::jsonb, p_by text DEFAULT NULL::text, p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    elsif b = 'not_interested' and position('own anything else' in coalesce(pl->>'reply', '')) > 0 then
      -- a no that got the one exit question (outcome open): the card is dead now, not "replied, went quiet"
      -- (2026-10-24: belt nudges were drafted to six people who had said no). An answer to the exit question that
      -- names another property arrives as a new text and moves the card again.
      res := public.belt_enter(p_lead_id, 'dead', 0, 'inbound_text', pl || jsonb_build_object('reason', 'not interested (exit question asked)'), who, p_now);
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
      if (l.stage in ('walkthrough_booked', 'offer', 'under_contract', 'closed_won') and l.belt in ('visit_booked', 'offer_out'))
         or (l.belt = 'call_booked' and l.next_stop_at > p_now) then
        res := jsonb_build_object('ok', true, 'belt', l.belt, 'step', l.belt_step, 'next_stop_at', l.next_stop_at);
        insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by) values (p_lead_id, 'call_logged', l.belt, l.belt, l.belt_step, pl, p_now, who);
      else res := public.belt_enter(p_lead_id, 'yes_unbooked', 1, 'call_logged', pl, who, p_now); end if;
    elsif o = 'reached_no_decision' then
      if l.belt = 'call_booked' and l.next_stop_at > p_now then
        res := jsonb_build_object('ok', true, 'belt', l.belt, 'step', l.belt_step, 'next_stop_at', l.next_stop_at);
        insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by) values (p_lead_id, 'call_logged', l.belt, l.belt, l.belt_step, pl, p_now, who);
      else res := public.belt_enter(p_lead_id, 'after_call_quiet', 1, 'call_logged', pl, who, p_now); end if;
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
             next_stop_who = case when nullif(pl->>'next_at', '') is null then null when st >= 5 then 'thalia_call' else 'auto_text' end,
             next_stop_say = case when st >= 5 then 'Never answered five texts; one call from the daily list' else format('Text %s goes on its own (WPIE)', st + 1) end,
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
end $function$;
