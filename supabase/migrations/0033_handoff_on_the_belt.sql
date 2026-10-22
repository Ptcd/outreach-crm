-- The hand-off rides the belt (0028 handoff_to_colin, written before the conveyor landed in 0029-0032):
--   * the ping row it writes into hot_alerts is not a seller reply, so belt_on_hot leaves it alone (it used
--     to read as a hot reply, hand the card to Thalia and open her stop);
--   * instead of its own task, the hand-off closes the caller's open stop and fires belt_event('next_step',
--     callback now), so the card lands on "Call booked" with Colin's stop now, titled with the caller's line.

create or replace function public.belt_on_hot() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.lead_id is null or new.is_test then return new; end if;
  if new.body ~ '^\S+ hands off: ' then return new; end if;    -- a caller's hand-off ping, not a seller reply
  perform public.belt_event(new.lead_id, 'hot_reply', jsonb_build_object('key', 'hot:' || new.inbound_sid, 'said', left(new.body, 300)), 'reply agent', new.created_at);
  return new;
end $$;

create or replace function public.handoff_to_colin(p_lead_id uuid, p_note text, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare who text; l public.leads; ph text; tid uuid; first text; key text; line text; res jsonb;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  line := nullif(btrim(coalesce(p_note, '')), '');
  if line is null then return jsonb_build_object('ok', false, 'reason', 'Say why in one line.'); end if;
  select display_name into who from public.team_members where lower(email) = lower(auth.jwt() ->> 'email');
  select * into l from public.leads where id = p_lead_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such lead'); end if;
  select c.value_normalized into ph from public.contacts c
   where c.lead_id = p_lead_id and c.kind = 'phone' and c.value_normalized ~ '^[0-9]{10}$' and not c.suppressed and c.status = 'ok'
   order by c.created_at limit 1;
  key := 'handoff:' || p_lead_id || ':' || extract(epoch from p_now)::bigint;

  -- the caller's open stops on this card are done: it is Colin's now (not an outcome against anyone)
  perform set_config('wpie.task_outcome', '1', true);
  update public.tasks set done_at = p_now, note = coalesce(tasks.note, '') || ' [handed to Colin]'
   where lead_id = p_lead_id and done_at is null and kind in ('call', 'visit') and owner <> 'colin';
  perform set_config('wpie.task_outcome', '', true);

  update public.leads set assigned_to = 'colin',
         stage = case when stage in ('walkthrough_booked', 'offer', 'under_contract', 'closed_won', 'dead', 'dnc') then stage else 'colin_call' end,
         next_action = 'Colin: ' || left(line, 80), next_action_at = p_now
   where id = p_lead_id;
  insert into public.messages (lead_id, direction, channel, body, sent_at, seen_at)
  values (p_lead_id, 'out', 'note', 'Handed to Colin by ' || coalesce(who, 'the team') || ': ' || line, p_now, p_now);

  -- the belt: "Call booked", Colin's stop now; its task carries the caller's line
  res := public.belt_event(p_lead_id, 'next_step', jsonb_build_object('kind', 'callback', 'at', p_now, 'key', key,
           'said', 'Handed off by ' || coalesce(who, 'the team') || ': ' || line), who, p_now);
  update public.tasks set title = 'From ' || coalesce(who, 'the team') || ': worth a look',
         note = tasks.note || ' | ' || coalesce(who, 'The team') || ' says: ' || line
   where lead_id = p_lead_id and done_at is null and owner = 'colin' and source = 'belt' and kind = 'call'
  returning id into tid;

  -- the ping: text to Colin's cell, push and email to everyone, through the hot-alert path (belt_on_hot skips it)
  first := initcap(split_part(coalesce(l.owner_name, ''), ' ', 1));
  perform public.hot_record(key, p_lead_id, coalesce(ph, ''), first, l.property_address,
          coalesce(who, 'The team') || ' hands off: ' || line, false, p_now);
  return jsonb_build_object('ok', true, 'task_id', tid, 'belt', res->>'belt');
end $$;
revoke all on function public.handoff_to_colin(uuid, text, timestamptz) from public, anon;
grant execute on function public.handoff_to_colin(uuid, text, timestamptz) to authenticated;
