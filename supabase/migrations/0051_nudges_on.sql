-- Automatic nudges, on (Colin 2026-10-24: "As long as you think the system is smart enough to know the difference").
--   * belt_claim_text: no automatic nudge while one of their texts still waits for Colin's answer (it slides a day).
--     Already in place: nothing to a dead or DNC card, an elderly, ill or grieving owner, an opted-out phone, anyone
--     who wrote since the stop was set; 8am-8pm their time, never Sunday.
--   * replied_reask: "Did not mean to leave you hanging" was wrong (they went quiet, not us); door_open: "We tried you
--     the other day" was false when nobody called. New wordings as shown to Colin, and both switched on.

CREATE OR REPLACE FUNCTION public.belt_claim_text(p_lead_id uuid, p_dry boolean DEFAULT true, p_force boolean DEFAULT false, p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
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
end $$;


update public.touch_templates set enabled = true, changed_by = 'Colin (chat 2026-10-24)', changed_at = now(),
       wording = 'Hi, Colin Merrill again about {street}. Would you ever consider selling it, or is it a no for now? Either answer is fine. Reply STOP to opt out.'
 where key = 'replied_reask';
update public.touch_templates set enabled = true, changed_by = 'Colin (chat 2026-10-24)', changed_at = now(),
       wording = 'Colin here, about {street}. Happy to pick this up whenever suits; just reply here or call this number. No worries if not, just reply STOP.'
 where key = 'door_open';
