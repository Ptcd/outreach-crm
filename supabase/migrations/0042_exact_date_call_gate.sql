-- A seller who named an exact Not-now date must not receive an outbound call before the
-- conveyor's recipient-local due instant. This is enforced at the same authoritative door
-- used by both the browser dialer and the personal-phone authorization button. Incoming calls
-- are intentionally separate: the seller can still call us before that date.
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
  -- Do not trust the caller-supplied p_now for authorization; it exists for deterministic
  -- event timestamps in the existing RPC and must not let a client fast-forward the clock.
  if l.belt = 'not_now_dated' and l.named_date is not null and now() < l.named_date then
    return jsonb_build_object('ok', false, 'reason', 'the seller asked us to wait until the scheduled date',
      'paused', l.human_takeover_at is not null, 'not_before', l.named_date);
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

revoke all on function public.begin_human_call(uuid, text, text, text, timestamptz) from public, anon;
grant execute on function public.begin_human_call(uuid, text, text, text, timestamptz) to authenticated;
