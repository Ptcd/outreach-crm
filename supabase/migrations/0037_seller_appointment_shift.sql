-- Seller -> appointment continuity (2026-10-23).
--
-- This extends the existing conveyor; it does not create another scheduler or state machine.
-- A human who starts an outbound call pauses the current belt in place until the outcome is logged.
-- A call that never started can be resumed without moving or rebuilding the stop. The recovery view is
-- the one list for an overdue stop, a missing stop, or a human call whose outcome still needs logging.

alter table public.leads
  add column if not exists human_takeover_at timestamptz,
  add column if not exists human_takeover_by text,
  add column if not exists human_takeover_phone text,
  add column if not exists human_takeover_key text,
  add column if not exists human_takeover_drafts jsonb;

create unique index if not exists leads_human_takeover_key_idx
  on public.leads (human_takeover_key) where human_takeover_key is not null;

-- The app Call button and the "personal phone" button both use this door before a call starts.
-- It rejects a blocked/unknown destination through 0036 and then freezes the current belt in place.
-- The client-supplied UUID makes network retries idempotent; a second call cannot start until the first
-- one's outcome is logged or the caller explicitly says that it never started.
create or replace function public.begin_human_call(p_lead_id uuid, p_phone text, p_source text,
  p_key text, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare l public.leads; d text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10);
  gate jsonb; who text; person public.team_person; held jsonb;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  if p_source not in ('app', 'personal') then return jsonb_build_object('ok', false, 'reason', 'unknown call source'); end if;
  if coalesce(p_key, '') !~ '^[A-Za-z0-9_-]{8,100}$' then return jsonb_build_object('ok', false, 'reason', 'bad call key'); end if;
  select * into l from public.leads where id = p_lead_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such lead'); end if;
  if l.human_takeover_key = p_key then
    return jsonb_build_object('ok', true, 'duplicate', true, 'paused', true, 'key', p_key);
  end if;
  if exists (select 1 from public.belt_events e where e.lead_id = p_lead_id and e.payload->>'key' = 'human_call:' || p_key) then
    return jsonb_build_object('ok', true, 'duplicate', true, 'paused', l.human_takeover_at is not null, 'key', p_key);
  end if;
  if l.human_takeover_at is not null then
    return jsonb_build_object('ok', false, 'reason', 'another call is waiting for its outcome', 'paused', true);
  end if;
  if l.stage in ('dnc', 'dead', 'closed_no_contact', 'closed_won') or l.belt in ('dnc', 'dead') then
    return jsonb_build_object('ok', false, 'reason', 'this card is closed or do-not-contact');
  end if;
  if not exists (select 1 from public.contacts c where c.lead_id = p_lead_id and c.kind = 'phone'
      and c.value_normalized = d) then
    return jsonb_build_object('ok', false, 'reason', 'that phone is not on this card');
  end if;
  gate := public.phone_is_blocked(d);
  if coalesce((gate->>'blocked')::boolean, true) then
    return jsonb_build_object('ok', false, 'reason', coalesce(gate->>'reason', 'phone block check failed'));
  end if;
  select tm.display_name, tm.person into who, person from public.team_members tm
   where lower(tm.email) = lower(auth.jwt() ->> 'email');
  -- Serialize with the reply sender's claim update. An already-sending text has an uncertain external
  -- outcome, so do not start a call beside it; queued/draft rows can be held and restored exactly.
  perform 1 from public.reply_drafts r where r.lead_id = p_lead_id and r.kind = 'belt'
    and r.status in ('queued', 'awaiting_approval', 'would_send', 'sending') for update;
  if exists (select 1 from public.reply_drafts r where r.lead_id = p_lead_id and r.kind = 'belt' and r.status = 'sending') then
    return jsonb_build_object('ok', false, 'reason', 'an automated text is already sending; check its result before calling');
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'status', r.status)), '[]'::jsonb) into held
    from public.reply_drafts r where r.lead_id = p_lead_id and r.kind = 'belt'
      and r.status in ('queued', 'awaiting_approval', 'would_send');
  update public.leads set human_takeover_at = p_now, human_takeover_by = coalesce(who, person::text, 'team'),
    human_takeover_phone = d, human_takeover_key = p_key, human_takeover_drafts = held,
    assigned_to = coalesce(assigned_to, person)
   where id = p_lead_id;
  update public.reply_drafts set status = 'superseded', note = coalesce(note, '') || ' | human call ' || p_key, updated_at = p_now
   where lead_id = p_lead_id and kind = 'belt' and status in ('queued', 'awaiting_approval', 'would_send');
  update public.hot_alerts set called_at = p_now where lead_id = p_lead_id and called_at is null and created_at <= p_now;
  insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
    values (p_lead_id, 'human_call_started', l.belt, l.belt, l.belt_step,
      jsonb_build_object('key', 'human_call:' || p_key, 'source', p_source, 'phone', d), p_now, coalesce(who, person::text, 'team'));
  return jsonb_build_object('ok', true, 'duplicate', false, 'paused', true, 'key', p_key);
end $$;

-- Safe recovery when the phone never dialled. Nothing on the belt moved while paused, so clearing the
-- marker resumes the exact stop. A key can only resume its own attempt.
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
    human_takeover_phone = null, human_takeover_key = null, human_takeover_drafts = null where id = p_lead_id;
  insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
    values (p_lead_id, 'human_call_resumed', l.belt, l.belt, l.belt_step,
      jsonb_build_object('key', 'human_resume:' || p_key, 'reason', 'call did not start'), p_now, coalesce(who, 'team'));
  return jsonb_build_object('ok', true, 'duplicate', false, 'paused', false);
end $$;

revoke all on function public.begin_human_call(uuid, text, text, text, timestamptz),
  public.resume_human_call(uuid, text, timestamptz) from public, anon;
grant execute on function public.begin_human_call(uuid, text, text, text, timestamptz),
  public.resume_human_call(uuid, text, timestamptz) to authenticated;

-- A saved call outcome is the hand-back to the conveyor. `zz_` makes this run after belt_on_message,
-- so the outcome first creates the correct next stop and only then clears the pause marker.
create or replace function public.clear_human_call_on_outcome() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.lead_id is not null and new.channel = 'call'
     and new.status in ('interested', 'not_now', 'not_interested', 'wrong_number', 'dnc', 'no_answer', 'reached_no_decision') then
    update public.leads set human_takeover_at = null, human_takeover_by = null,
      human_takeover_phone = null, human_takeover_key = null, human_takeover_drafts = null where id = new.lead_id;
  end if;
  return new;
end $$;
drop trigger if exists zz_clear_human_call_on_outcome on public.messages;
create trigger zz_clear_human_call_on_outcome after insert on public.messages
  for each row execute function public.clear_human_call_on_outcome();

-- STOP/terminal state also clears a stale pause. The belt's own DNC invariants remain authoritative.
create or replace function public.clear_human_call_on_terminal() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.stage in ('dnc', 'dead', 'closed_no_contact', 'closed_won') or new.belt in ('dnc', 'dead') then
    new.human_takeover_at := null; new.human_takeover_by := null;
    new.human_takeover_phone := null; new.human_takeover_key := null; new.human_takeover_drafts := null;
  end if;
  return new;
end $$;
drop trigger if exists zz_clear_human_call_on_terminal on public.leads;
create trigger zz_clear_human_call_on_terminal before update of stage, belt on public.leads
  for each row execute function public.clear_human_call_on_terminal();

-- The scheduler only sees automatic text stops that have no active human takeover.
create or replace function public.belt_due_texts(p_now timestamptz default now(), p_limit integer default 50)
returns table (id uuid, belt text, belt_step smallint, next_stop_who text, next_stop_at timestamptz)
language sql stable security definer set search_path = public as $$
  select l.id, l.belt, l.belt_step, l.next_stop_who, l.next_stop_at from public.leads l
   where l.next_stop_who in ('auto_text', 'draft_text') and l.next_stop_at is not null and l.next_stop_at <= p_now
     and l.belt not in ('cold_texts', 'dead', 'dnc') and l.human_takeover_at is null
   order by l.next_stop_at limit p_limit
$$;

-- Locking the lead closes the race between the due scan and a person tapping either call button.
create or replace function public.belt_claim_text_guarded(p_lead_id uuid, p_dry boolean default true,
  p_force boolean default false, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare paused timestamptz;
begin
  select human_takeover_at into paused from public.leads where id = p_lead_id for update;
  if paused is not null then return jsonb_build_object('outcome', 'refused', 'reason', 'human call in progress'); end if;
  return public.belt_claim_text(p_lead_id, p_dry, p_force, p_now);
end $$;
revoke all on function public.belt_claim_text_guarded(uuid, boolean, boolean, timestamptz) from public, anon, authenticated;
grant execute on function public.belt_claim_text_guarded(uuid, boolean, boolean, timestamptz) to service_role;

-- The missed-stop sweep also leaves a paused card exactly where the person found it.
create or replace function public.belt_sweep_missed(p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare l record; n integer := 0; again boolean; out jsonb := '[]'::jsonb;
begin
  for l in
    select x.* from public.leads x
     where x.next_stop_at is not null and x.next_stop_at < p_now - interval '20 hours'
       and x.belt not in ('cold_texts', 'dead', 'dnc', 'too_high_or_listed')
       and x.human_takeover_at is null
       and (x.next_stop_who in ('thalia_call', 'colin_call', 'colin_visit')
            or (x.next_stop_who in ('auto_text', 'draft_text') and x.next_stop_at < p_now - interval '3 days'))
     order by x.next_stop_at limit 200
  loop
    again := exists (select 1 from public.belt_events e where e.lead_id = l.id and e.event = 'stop_missed' and e.to_belt = l.belt and e.step = l.belt_step);
    perform public.belt_event(l.id, 'stop_missed', jsonb_build_object('again', again, 'was_due', l.next_stop_at), 'conveyor', p_now);
    n := n + 1;
    out := out || jsonb_build_object('lead_id', l.id, 'belt', l.belt, 'step', l.belt_step, 'again', again);
  end loop;
  return jsonb_build_object('swept', n, 'rows', out);
end $$;

-- A single recovery list. "Touched" means a real conversation/call fact exists or the lead has already
-- entered a working stage/belt. Fully suppressed/terminal records stay out; DNC remains final.
create or replace function public.seller_recovery_owner(p_assigned public.team_person, p_next_who text,
  p_belt text, p_stage public.lead_stage, p_at timestamptz default now())
returns public.team_person language sql stable set search_path = public as $$
  select case
    when p_assigned is not null then p_assigned
    when p_next_who in ('colin_call', 'colin_visit') or p_belt in ('visit_booked', 'after_visit_quiet', 'elderly', 'estate_waiting', 'needs_family', 'offer_out')
      or p_stage in ('walk_decision', 'walkthrough_booked', 'offer', 'under_contract') then 'colin'::public.team_person
    when extract(isodow from p_at at time zone 'America/Chicago') in (6, 7) then 'adil'::public.team_person
    else 'thalia'::public.team_person
  end
$$;

create or replace view public.seller_recovery_queue with (security_invoker = true) as
select l.id as lead_id, l.owner_name, l.property_address, l.stage, l.belt, l.belt_step,
  l.next_stop_at, l.next_stop_who, l.next_action_at, l.next_action, l.assigned_to,
  case
    when l.human_takeover_at is not null then 'call_outcome_needed'
    when l.next_stop_at is null and l.next_action_at is null then 'missing_next_action'
    when l.next_stop_at is null then 'missing_next_stop'
    else 'overdue'
  end as reason,
  public.seller_recovery_owner(l.assigned_to, l.next_stop_who, l.belt, l.stage, now()) as recovery_owner,
  l.human_takeover_at, l.human_takeover_by, l.human_takeover_phone, l.updated_at
from public.leads l
where l.stage not in ('dnc', 'dead', 'closed_no_contact', 'closed_won')
  and coalesce(l.belt, '') not in ('dnc', 'dead', 'too_high_or_listed')
  and not (l.belt = 'dormant' and l.dormant_round >= 3)
  and (
    not exists (select 1 from public.contacts cp where cp.lead_id = l.id and cp.kind = 'phone')
    or exists (select 1 from public.contacts cp where cp.lead_id = l.id and cp.kind = 'phone'
      and cp.status = 'ok' and not cp.suppressed and not cp.dnc_app and not cp.dnc_vendor and cp.dnc_scrub <> 'dnc'
      and cp.value_normalized ~ '^[0-9]{10}$'
      and not exists (select 1 from public.suppressed_phones sp where sp.phone10 = cp.value_normalized))
  )
  and (l.human_takeover_at is not null or l.next_stop_at < now()
    or ((l.next_stop_at is null or l.next_action_at is null)
      and ((l.belt is not null and l.belt <> 'cold_texts') or l.stage in ('reply_received', 'ai_qualifying', 'handoff', 'colin_call', 'walk_decision',
        'walkthrough_booked', 'offer', 'follow_up', 'human_owned')
        or l.last_inbound_at is not null or l.call_facts <> '{}'::jsonb
        or exists (select 1 from public.messages m where m.lead_id = l.id and (m.direction = 'in' or m.channel = 'call')))))
  and (l.belt is distinct from 'cold_texts' or l.human_takeover_at is not null or l.last_inbound_at is not null
    or l.call_facts <> '{}'::jsonb or exists (select 1 from public.messages m where m.lead_id = l.id and (m.direction = 'in' or m.channel = 'call')))
order by case when l.human_takeover_at is not null then 0 when l.next_stop_at is null then 1 else 2 end,
  coalesce(l.human_takeover_at, l.next_stop_at, l.updated_at);

grant select on public.seller_recovery_queue to authenticated, service_role;
