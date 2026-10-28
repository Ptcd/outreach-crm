-- Two gaps in the warm/hot path (Colin 2026-10-28: "make sure the morning-of walk reminder text goes out, and flag a
-- callback whose number isn't ready yet").
--  1. The morning-of reminder ("Colin here. We are set to come by {street} today around {time}. Still good?") never went
--     out: since 0064 the belt skips its own texts (Muse writes them), the reminder template's switch was off, and queued
--     belt texts were refused while routine replies are off. Now the belt drafts the morning-of reminders even with agent
--     texting on, those two reminders send with routine replies off, and the walk reminder's switch is on (the call
--     reminder's stays Colin's to turn on).
--  2. A callback promised for a time Colin's number isn't in by: package_number_due_claim hands the reply agent's minute
--     run each package whose callback is within 3 hours (or past) and still waiting for a number, once, for a push to
--     Colin; package_move_callback moves a promised callback (Thalia calls at the promised time and sets a new one).

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
  -- the sender agent writes every text now (agent_runs_texting): the belt's own nudge is skipped, the stop moves on
  -- except the morning-of reminder for a booked call or walk: a fixed confirmation, not a nudge, and nobody else sends it
  if (select agent_runs_texting from public.campaign_control where id = 1)
     and coalesce((select bs.anchor from public.belt_steps bs where bs.belt = l.belt and bs.step = l.belt_step), '') <> 'slot_morning' then
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
end $$;

CREATE OR REPLACE FUNCTION public.reply_claim_send(p_id uuid, p_mode text, p_body text, p_actor text, p_dry boolean, p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
declare
  d public.reply_drafts;
  c public.campaign_control;
  b text;
begin
  select * into d from public.reply_drafts where id = p_id for update;
  if not found then return jsonb_build_object('outcome', 'refused', 'reason', 'no such draft'); end if;
  select * into c from public.campaign_control where id = 1;
  if p_mode = 'auto' then
    if d.status <> 'queued' then return jsonb_build_object('outcome', 'refused', 'reason', 'not queued'); end if;
    -- the morning-of reminder for a booked call or walk goes even with routine replies off (Muse answers replies)
    if not c.routine_enabled and not (d.kind = 'belt' and d.outcome in ('reminder_visit', 'reminder_call')) then
      return jsonb_build_object('outcome', 'refused', 'reason', 'routine replies are off');
    end if;
    if d.send_after is not null and d.send_after > p_now then return jsonb_build_object('outcome', 'queued', 'reason', 'quiet hours'); end if;
  elsif p_mode = 'approve' then
    if d.status not in ('awaiting_approval', 'would_send', 'no_reply', 'dry_sent') then
      return jsonb_build_object('outcome', 'refused', 'reason', 'already ' || d.status);
    end if;
  else
    raise exception 'unknown mode %', p_mode;
  end if;
  -- Approve never texts a lead marked do not contact; a removal confirmation still goes (0044)
  if p_mode = 'approve' and d.kind <> 'removal' and d.lead_id is not null and public.lead_is_dnc(d.lead_id) then
    update public.reply_drafts set status = 'skipped', note = coalesce(note, '') || ' | lead marked do not contact',
           updated_at = p_now where id = d.id;
    return jsonb_build_object('outcome', 'refused', 'reason', 'this lead is marked do not contact');
  end if;
  b := btrim(coalesce(case when p_mode = 'approve' then p_body end, d.body, ''));
  if b = '' then return jsonb_build_object('outcome', 'refused', 'reason', 'empty reply'); end if;
  if length(b) > 480 then return jsonb_build_object('outcome', 'refused', 'reason', 'over 480 characters'); end if;
  -- a newer text from them makes this reply stale
  if exists (select 1 from public.twilio_inbound i where i.from10 = d.phone10 and i.received_at > d.inbound_at) then
    update public.reply_drafts set status = 'superseded', updated_at = p_now where id = d.id;
    return jsonb_build_object('outcome', 'refused', 'reason', 'they texted again after this draft - see the newer one');
  end if;
  -- after a removal only the removal confirmation itself may go
  if d.kind <> 'removal' and exists (select 1 from public.suppressed_phones s where s.phone10 = d.phone10) then
    update public.reply_drafts set status = 'skipped', note = coalesce(note, '') || ' | phone opted out', updated_at = p_now where id = d.id;
    return jsonb_build_object('outcome', 'refused', 'reason', 'this phone opted out');
  end if;
  if public.in_quiet_hours(p_now) then
    update public.reply_drafts set status = 'queued', body = b, send_after = public.quiet_hours_end(p_now),
           decided_by = coalesce(p_actor, decided_by), decided_at = coalesce(decided_at, p_now), updated_at = p_now
     where id = d.id;
    return jsonb_build_object('outcome', 'queued', 'reason', 'quiet hours - goes at ' || to_char(public.quiet_hours_end(p_now) at time zone c.timezone, 'HH24:MI'));
  end if;
  if p_dry then
    update public.reply_drafts set status = 'dry_sent', sent_body = b, decided_by = coalesce(p_actor, decided_by),
           decided_at = p_now, updated_at = p_now, note = coalesce(note, '') || ' | would send (live sending is off)'
     where id = d.id;
    return jsonb_build_object('outcome', 'dry_sent', 'body', b);
  end if;
  update public.reply_drafts set status = 'sending', sent_body = b, decided_by = coalesce(p_actor, decided_by),
         decided_at = coalesce(decided_at, p_now), updated_at = p_now where id = d.id;
  return jsonb_build_object('outcome', 'send', 'id', d.id, 'to', '+1' || d.phone10, 'from', d.our_number, 'body', b);
end $$;

update public.touch_templates set enabled = true where key = 'reminder_visit';

alter table public.deal_packages add column if not exists number_due_pinged_at timestamptz;

create or replace function public.package_number_due_claim() returns jsonb language plpgsql security definer set search_path = public as $$
declare out jsonb; ids uuid[];
begin
  with c as (select d.id from public.deal_packages d
              where d.status in ('waiting_value', 'waiting_number') and d.callback_at is not null
                and d.callback_at < now() + interval '3 hours' and d.number_due_pinged_at is null
              for update skip locked),
  u as (update public.deal_packages d set number_due_pinged_at = now() from c where d.id = c.id returning d.id)
  select coalesce(array_agg(id), '{}') into ids from u;
  select coalesce(jsonb_agg(jsonb_build_object('package_id', d.id, 'lead_id', l.id, 'property_address', l.property_address,
           'callback_at', d.callback_at, 'status', d.status)), '[]'::jsonb) into out
    from public.deal_packages d join public.leads l on l.id = d.lead_id where d.id = any(ids);
  return out;
end $$;
revoke all on function public.package_number_due_claim() from public, anon, authenticated;
grant execute on function public.package_number_due_claim() to service_role;

create or replace function public.package_move_callback(p_id uuid, p_at timestamptz) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d public.deal_packages;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  select * into d from public.deal_packages where id = p_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such package'); end if;
  if p_at is null or p_at < now() then return jsonb_build_object('ok', false, 'reason', 'pick the new callback time (not in the past)'); end if;
  update public.deal_packages set callback_at = p_at, number_due_pinged_at = null, updated_at = now() where id = p_id;
  update public.tasks set due_at = p_at where lead_id = d.lead_id and kind = 'callback' and done_at is null;
  update public.leads set next_action = 'Package with Colin: callback ' || to_char(p_at at time zone 'America/Chicago', 'Dy Mon DD HH12:MI AM'),
         next_action_at = p_at where id = d.lead_id;
  return jsonb_build_object('ok', true, 'callback_at', p_at);
end $$;
revoke all on function public.package_move_callback(uuid, timestamptz) from public, anon;
grant execute on function public.package_move_callback(uuid, timestamptz) to authenticated, service_role;
