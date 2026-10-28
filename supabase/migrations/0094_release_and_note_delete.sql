-- Release a hold, delete a note (Muse 2026-10-28: "Cards whose blockers have cleared stay held because there is no
-- un-hold/release mark. Notes can't be edited or deleted either - one card today picked up three layered correction notes
-- ... Please add: a release/un-hold mark, and a note delete").
--   * release (reason = what cleared): a held or not-now card leaves its belt, its "Waiting on" line and its date, and
--     goes back to the stage it had before it was held (a texting thread picks up its follow-ups again).
--   * note_delete (reason = words from the note): removes Muse's own notes that hold those words; a team member's note
--     is never touched. What was removed stays in the card's history. To correct a note: note_delete, then note.

create or replace function public.agent_mark_card(p_lead_id uuid, p_mark text, p_reason text, p_date timestamptz, p_phone text, p_agent text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  l    public.leads;
  who  text := 'Muse (' || coalesce(p_agent, 'agent') || ')';
  d    text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10);
  why  text := nullif(btrim(coalesce(p_reason, '')), '');
  phones text[];
  prev text;
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
end $$;
