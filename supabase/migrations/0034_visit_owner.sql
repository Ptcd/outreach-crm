-- A booked walk-through belongs to Colin even when its first conveyor stop is an
-- automatic reminder. belt_enter normally derives assigned_to from the current
-- stop owner; visit_booked starts with an auto_text stop, so it otherwise leaves
-- the previous caller (usually Thalia) on the card.
create or replace function public.belt_visit_owner() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.belt = 'visit_booked' then
    new.assigned_to := 'colin';
  end if;
  return new;
end $$;

drop trigger if exists belt_visit_owner on public.leads;
create trigger belt_visit_owner
before insert or update of belt, assigned_to on public.leads
for each row execute function public.belt_visit_owner();

-- Repair bookings created before this invariant landed. This is local migration
-- behavior only; applying migrations to a deployed project remains a separate,
-- explicitly authorized operation.
update public.leads
   set assigned_to = 'colin'
 where belt = 'visit_booked'
   and assigned_to is distinct from 'colin'::public.team_person;

-- A browser retry of the same handoff must not duplicate the note or page Colin
-- twice. Suppress only an exact same caller + exact same line inside five minutes;
-- a corrected line, another caller, or a later handoff remains a new event.
create or replace function public.handoff_to_colin(p_lead_id uuid, p_note text, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare who text; l public.leads; ph text; tid uuid; note_id uuid; first text; key text; line text; res jsonb; note_body text;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  line := nullif(btrim(coalesce(p_note, '')), '');
  if line is null then return jsonb_build_object('ok', false, 'reason', 'Say why in one line.'); end if;
  select display_name into who from public.team_members where lower(email) = lower(auth.jwt() ->> 'email');
  select * into l from public.leads where id = p_lead_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such lead'); end if;
  note_body := 'Handed to Colin by ' || coalesce(who, 'the team') || ': ' || line;
  if exists (
    select 1 from public.messages m
     where m.lead_id = p_lead_id and m.channel = 'note' and m.body = note_body
       and m.sent_at between p_now - interval '5 minutes' and p_now + interval '5 minutes'
  ) then
    select t.id into tid from public.tasks t
     where t.lead_id = p_lead_id and t.done_at is null and t.owner = 'colin' and t.source = 'belt' and t.kind = 'call'
     order by t.created_at desc limit 1;
    return jsonb_build_object('ok', true, 'duplicate', true, 'task_id', tid, 'belt', l.belt);
  end if;
  select c.value_normalized into ph from public.contacts c
   where c.lead_id = p_lead_id and c.kind = 'phone' and c.value_normalized ~ '^[0-9]{10}$' and not c.suppressed and c.status = 'ok'
   order by c.created_at limit 1;
  perform set_config('wpie.task_outcome', '1', true);
  update public.tasks set done_at = p_now, note = coalesce(tasks.note, '') || ' [handed to Colin]'
   where lead_id = p_lead_id and done_at is null and kind in ('call', 'visit') and owner <> 'colin';
  perform set_config('wpie.task_outcome', '', true);

  update public.leads set assigned_to = 'colin',
         stage = case when stage in ('walkthrough_booked', 'offer', 'under_contract', 'closed_won', 'dead', 'dnc') then stage else 'colin_call' end,
         next_action = 'Colin: ' || left(line, 80), next_action_at = p_now
   where id = p_lead_id;
  insert into public.messages (lead_id, direction, channel, body, sent_at, seen_at)
  values (p_lead_id, 'out', 'note', note_body, p_now, p_now)
  returning id into note_id;
  key := 'handoff:' || p_lead_id || ':' || note_id;

  res := public.belt_event(p_lead_id, 'next_step', jsonb_build_object('kind', 'callback', 'at', p_now, 'key', key,
           'said', 'Handed off by ' || coalesce(who, 'the team') || ': ' || line), who, p_now);
  update public.tasks set title = 'From ' || coalesce(who, 'the team') || ': worth a look',
         note = tasks.note || ' | ' || coalesce(who, 'The team') || ' says: ' || line
   where lead_id = p_lead_id and done_at is null and owner = 'colin' and source = 'belt' and kind = 'call'
  returning id into tid;

  first := initcap(split_part(coalesce(l.owner_name, ''), ' ', 1));
  perform public.hot_record(key, p_lead_id, coalesce(ph, ''), first, l.property_address,
          coalesce(who, 'The team') || ' hands off: ' || line, false, p_now);
  return jsonb_build_object('ok', true, 'duplicate', false, 'task_id', tid, 'belt', res->>'belt');
end $$;
revoke all on function public.handoff_to_colin(uuid, text, timestamptz) from public, anon;
grant execute on function public.handoff_to_colin(uuid, text, timestamptz) to authenticated;
