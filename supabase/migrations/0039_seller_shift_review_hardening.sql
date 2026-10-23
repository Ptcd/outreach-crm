-- Independent-review hardening for the seller -> appointment shift.
-- Keep the same conveyor and lock order: lead first, then reply drafts.

alter table public.leads add column if not exists human_takeover_assigned_to public.team_person;
update public.leads set human_takeover_assigned_to = assigned_to
 where human_takeover_at is not null and human_takeover_assigned_to is null;

-- A date input is a calendar-day promise, not an explicit noon appointment. Resolve that day to the
-- first call stop at the configured call hour. If that hour has already passed today, use the next
-- legal call minute; belt_slide keeps Sunday and the 08:00-20:00 window fail-closed.
create or replace function public.not_now_followup_at(p_day date, p_state text,
  p_now timestamptz default now())
returns timestamptz language plpgsql stable set search_path = public as $$
declare tz text := public.belt_tz(p_state); hr integer; target timestamptz;
begin
  if p_day is null or p_day < (p_now at time zone tz)::date then return null; end if;
  select coalesce(call_hour, 10) into hr from public.belt_steps
   where belt = 'not_now_dated' and step = 1;
  hr := coalesce(hr, 10);
  target := (p_day + make_time(hr, 0, 0)) at time zone tz;
  if target <= p_now then
    return public.belt_slide(p_now + interval '1 minute', tz, 'call', null);
  end if;
  return public.belt_slide(target, tz, 'call', hr);
end $$;

revoke all on function public.not_now_followup_at(date, text, timestamptz) from public, anon;
grant execute on function public.not_now_followup_at(date, text, timestamptz) to authenticated, service_role;

-- A used attempt key is only an idempotent success while the exact authorization is still active.
-- STOP/DNC, suppression, reassignment, a changed destination, resume, or a logged outcome invalidates it.
create or replace function public.begin_human_call(p_lead_id uuid, p_phone text, p_source text,
  p_key text, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare l public.leads; d text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10);
  gate jsonb; who text; person public.team_person; held jsonb; actor text;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  if p_source not in ('app', 'personal') then return jsonb_build_object('ok', false, 'reason', 'unknown call source', 'paused', false); end if;
  if coalesce(p_key, '') !~ '^[A-Za-z0-9_-]{8,100}$' then return jsonb_build_object('ok', false, 'reason', 'bad call key', 'paused', false); end if;

  -- Same first lock as the conveyor worker. Draft locks remain below every lead-state check.
  select * into l from public.leads where id = p_lead_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such lead', 'paused', false); end if;
  select tm.display_name, tm.person into who, person from public.team_members tm
   where lower(tm.email) = lower(auth.jwt() ->> 'email');
  if person is null then return jsonb_build_object('ok', false, 'reason', 'caller is not an active team member', 'paused', false); end if;
  actor := coalesce(who, person::text);

  -- Recheck every mutable authorization fact before recognizing an attempt key.
  if l.stage in ('dnc', 'dead', 'closed_no_contact', 'closed_won') or l.belt in ('dnc', 'dead') then
    return jsonb_build_object('ok', false, 'reason', 'this card is closed or do-not-contact', 'paused', false);
  end if;
  if not exists (select 1 from public.contacts c where c.lead_id = p_lead_id and c.kind = 'phone'
      and c.value_normalized = d) then
    return jsonb_build_object('ok', false, 'reason', 'that phone is not on this card', 'paused', l.human_takeover_at is not null);
  end if;
  gate := public.phone_is_blocked(d);
  if coalesce((gate->>'blocked')::boolean, true) then
    return jsonb_build_object('ok', false, 'reason', coalesce(gate->>'reason', 'phone block check failed'), 'paused', l.human_takeover_at is not null);
  end if;

  if l.human_takeover_at is not null then
    -- A retry belongs to the original caller and the assignment snapshot it authorized. A fresh
    -- deliberate takeover may cover another caller's card (for example Adil's weekend shift).
    if l.assigned_to is distinct from l.human_takeover_assigned_to then
      return jsonb_build_object('ok', false, 'reason', 'the card assignment changed after authorization', 'paused', true);
    end if;
    if l.human_takeover_key is distinct from p_key then
      return jsonb_build_object('ok', false, 'reason', 'another call is waiting for its outcome', 'paused', true);
    end if;
    if l.human_takeover_phone is distinct from d then
      return jsonb_build_object('ok', false, 'reason', 'the active call has a different destination', 'paused', true);
    end if;
    if l.human_takeover_by is distinct from actor then
      return jsonb_build_object('ok', false, 'reason', 'the active call belongs to another caller', 'paused', true);
    end if;
    return jsonb_build_object('ok', true, 'duplicate', true, 'paused', true, 'key', p_key);
  end if;
  if exists (select 1 from public.belt_events e where e.lead_id = p_lead_id
      and e.payload->>'key' = 'human_call:' || p_key) then
    return jsonb_build_object('ok', false, 'duplicate', true,
      'reason', 'that call authorization is no longer active', 'paused', false);
  end if;

  perform 1 from public.reply_drafts r where r.lead_id = p_lead_id and r.kind = 'belt'
    and r.status in ('queued', 'awaiting_approval', 'would_send', 'sending') for update;
  if exists (select 1 from public.reply_drafts r where r.lead_id = p_lead_id and r.kind = 'belt' and r.status = 'sending') then
    return jsonb_build_object('ok', false, 'reason', 'an automated text is already sending; check its result before calling', 'paused', false);
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'status', r.status)), '[]'::jsonb) into held
    from public.reply_drafts r where r.lead_id = p_lead_id and r.kind = 'belt'
      and r.status in ('queued', 'awaiting_approval', 'would_send');
  update public.leads set human_takeover_at = p_now, human_takeover_by = actor,
    human_takeover_phone = d, human_takeover_key = p_key, human_takeover_drafts = held,
    assigned_to = coalesce(assigned_to, person), human_takeover_assigned_to = coalesce(assigned_to, person)
   where id = p_lead_id;
  update public.reply_drafts set status = 'superseded', note = coalesce(note, '') || ' | human call ' || p_key, updated_at = p_now
   where lead_id = p_lead_id and kind = 'belt' and status in ('queued', 'awaiting_approval', 'would_send');
  update public.hot_alerts set called_at = p_now where lead_id = p_lead_id and called_at is null and created_at <= p_now;
  insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
    values (p_lead_id, 'human_call_started', l.belt, l.belt, l.belt_step,
      jsonb_build_object('key', 'human_call:' || p_key, 'source', p_source, 'phone', d), p_now, actor);
  return jsonb_build_object('ok', true, 'duplicate', false, 'paused', true, 'key', p_key);
end $$;

-- Include the assignment snapshot in every existing close/resume path.
create or replace function public.resume_human_call(p_lead_id uuid, p_key text, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare l public.leads; who text; d record;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  select * into l from public.leads where id = p_lead_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such lead'); end if;
  if l.human_takeover_at is null then return jsonb_build_object('ok', true, 'duplicate', true, 'paused', false); end if;
  if l.human_takeover_key is distinct from p_key then return jsonb_build_object('ok', false, 'reason', 'that is not the active call'); end if;
  select tm.display_name into who from public.team_members tm where lower(tm.email) = lower(auth.jwt() ->> 'email');
  for d in select x->>'id' as id, x->>'status' as status from jsonb_array_elements(coalesce(l.human_takeover_drafts, '[]'::jsonb)) x loop
    update public.reply_drafts set status = d.status,
      note = regexp_replace(coalesce(note, ''), ' \| human call ' || p_key || '$', ''), updated_at = p_now
      where id = d.id::uuid and lead_id = p_lead_id and status = 'superseded';
  end loop;
  update public.leads set human_takeover_at = null, human_takeover_by = null,
    human_takeover_phone = null, human_takeover_key = null, human_takeover_drafts = null,
    human_takeover_assigned_to = null where id = p_lead_id;
  insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
    values (p_lead_id, 'human_call_resumed', l.belt, l.belt, l.belt_step,
      jsonb_build_object('key', 'human_resume:' || p_key, 'reason', 'call did not start'), p_now, coalesce(who, 'team'));
  return jsonb_build_object('ok', true, 'duplicate', false, 'paused', false);
end $$;

create or replace function public.clear_human_call_on_outcome() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.lead_id is not null and new.channel = 'call'
     and new.status in ('interested', 'not_now', 'not_interested', 'wrong_number', 'dnc', 'no_answer', 'reached_no_decision') then
    update public.leads set human_takeover_at = null, human_takeover_by = null,
      human_takeover_phone = null, human_takeover_key = null, human_takeover_drafts = null,
      human_takeover_assigned_to = null where id = new.lead_id;
  end if;
  return new;
end $$;

create or replace function public.clear_human_call_on_terminal() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.stage in ('dnc', 'dead', 'closed_no_contact', 'closed_won') or new.belt in ('dnc', 'dead') then
    new.human_takeover_at := null; new.human_takeover_by := null;
    new.human_takeover_phone := null; new.human_takeover_key := null;
    new.human_takeover_drafts := null; new.human_takeover_assigned_to := null;
  end if;
  return new;
end $$;

-- Treat p_when as a calendar-date carrier. The UI deliberately sends noon Central so the selected
-- date survives every supported US lead timezone; the server chooses the real call instant.
create or replace function public.log_call(p_lead_id uuid, p_phone text, p_outcome text, p_note text default null,
  p_when timestamptz default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare who text; d text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10); l public.leads;
  phones text[]; label text; named_day date; follow_at timestamptz; tz text;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  if p_outcome not in ('interested', 'not_now', 'not_interested', 'wrong_number', 'dnc', 'no_answer', 'reached_no_decision') then
    return jsonb_build_object('ok', false, 'reason', 'pick an outcome');
  end if;
  select * into l from public.leads where id = p_lead_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such lead'); end if;
  tz := public.belt_tz(l.mailing_state);
  if p_outcome = 'not_now' and p_when is not null then
    named_day := (p_when at time zone tz)::date;
    follow_at := public.not_now_followup_at(named_day, l.mailing_state, now());
    if follow_at is null then
      return jsonb_build_object('ok', false, 'reason', 'the check-back date cannot be before today');
    end if;
  end if;
  select display_name into who from public.team_members where lower(email) = lower(auth.jwt() ->> 'email');
  label := case p_outcome when 'interested' then 'Interested' when 'not_now' then 'Not now' when 'not_interested' then 'Not interested'
                          when 'wrong_number' then 'Wrong number' when 'no_answer' then 'No answer'
                          when 'reached_no_decision' then 'Reached, no decision' else 'Do not contact' end;
  if p_outcome = 'not_now' and p_when is not null then
    update public.leads set named_date = follow_at where id = p_lead_id;
    label := label || ' until ' || to_char(named_day, 'Mon DD');
  end if;
  insert into public.messages (lead_id, direction, channel, body, from_number, sent_at, seen_at, status)
  values (p_lead_id, 'in', 'call', format('Call (%s)%s: %s%s', coalesce(who, 'team'),
            case when d ~ '^[0-9]{10}$' then ' from ' || d else '' end, label,
            coalesce(E'\n' || nullif(btrim(coalesce(p_note, '')), ''), '')),
          case when d ~ '^[0-9]{10}$' then '+1' || d end, now(), now(), p_outcome);
  update public.leads set call_facts = jsonb_set(call_facts, '{last_call}', jsonb_build_object('value', p_outcome, 'at', now(), 'by', who))
   where id = p_lead_id;

  if p_outcome in ('interested', 'reached_no_decision') then
    update public.leads set stage = case when stage in ('walkthrough_booked', 'offer', 'under_contract', 'closed_won') then stage else 'colin_call' end
     where id = p_lead_id;
  elsif p_outcome = 'no_answer' then
    null;
  elsif p_outcome = 'not_now' then
    update public.leads set stage = 'follow_up', next_action = coalesce(next_action, 'Check back'),
           next_action_at = coalesce(follow_at, next_action_at, now() + interval '30 days') where id = p_lead_id;
  elsif p_outcome = 'not_interested' then
    update public.leads set stage = 'dead', dead_reason = coalesce(nullif(btrim(coalesce(p_note, '')), ''), 'Not interested (call)') where id = p_lead_id;
  elsif p_outcome = 'wrong_number' then
    if d ~ '^[0-9]{10}$' then update public.contacts set status = 'bad' where lead_id = p_lead_id and value_normalized = d; end if;
    update public.leads set stage = 'data_fix' where id = p_lead_id;
  else
    select array_agg(distinct c.value_normalized) into phones from public.contacts c
     where c.lead_id = p_lead_id and c.kind = 'phone' and c.value_normalized ~ '^[0-9]{10}$';
    phones := coalesce(phones, '{}');
    if d ~ '^[0-9]{10}$' and not d = any(phones) then phones := array_append(phones, d); end if;
    insert into public.suppressed_phones (phone10, reason, source)
      select distinct p, 'dnc_call', 'app' from unnest(phones) p on conflict (phone10) do nothing;
    update public.contacts set suppressed = true, dnc_app = true where value_normalized = any(phones);
    update public.leads set stage = 'dnc' where id = p_lead_id;
  end if;
  return jsonb_build_object('ok', true, 'outcome', p_outcome, 'until', follow_at, 'named_day', named_day);
end $$;

revoke all on function public.begin_human_call(uuid, text, text, text, timestamptz),
  public.resume_human_call(uuid, text, timestamptz), public.log_call(uuid, text, text, text, timestamptz) from public, anon;
grant execute on function public.begin_human_call(uuid, text, text, text, timestamptz),
  public.resume_human_call(uuid, text, timestamptz), public.log_call(uuid, text, text, text, timestamptz) to authenticated;
