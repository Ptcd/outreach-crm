-- 0170: callers manage their own follow-ups (Colin 2026-11-03: "they can manage all of their cards and followup stuff
-- and everything like this were a pro enterprise grade thought out CRM"; "build all three"). Piece 1 of 3.
--
-- Until now a follow-up, once set, could not be moved: no reschedule, snooze, edit or delete anywhere, editing
-- tasks.due_at by hand left the belt's next_stop_at stale (the sweep then fired "missed" and the next belt_enter put
-- the old time back), and a caller's "check back on <date>" sent the card to not_now_dated, whose two stops are
-- Colin's calls, so the follow-up left the caller's list. Any team login could also edit or delete anyone's tasks.
--
-- Four functions, one door each, all belt-aware:
--   followup_set(lead, at, kind, note)   the caller's own follow-up on a card (source 'mine', one open per card per
--                                        person; setting again moves it). Shows on Today, My cards and Power hour.
--   followup_move(task, at, why)         move any follow-up of mine: a belt stop moves with leads.next_stop_at and is
--                                        logged on the belt; a promised callback moves with the package's callback_at.
--   followup_done(task, outcome, note)   close it the right way: a belt stop through belt_stop_done, a callback through
--                                        callback_done, anything else just closes and writes a note.
--   followup_delete(task, why)           my own non-belt follow-up only; a belt stop is moved or closed, never deleted.
-- Every move is kept in task_moves (who, from, to, why). A caller may touch only tasks they own; Colin any.
-- not_now_dated stops now go to the card's caller (locked_to) instead of Colin: "they said call me in March" is the
-- caller's follow-up; Colin still gets every package.
-- followups_due_to_alert feeds the reminder (reply-agent, every minute): a push/email/WhatsApp to the task's owner ten
-- minutes before their call or callback, once per task (tasks.notified_at).

-- ---------------------------------------------------------------- ownership on tasks
drop policy if exists tasks_update on public.tasks;
create policy tasks_update on public.tasks for update to authenticated
  using (public.is_owner() or owner = public.wpie_person() or created_by = auth.uid())
  with check (public.is_team());
drop policy if exists tasks_delete on public.tasks;
create policy tasks_delete on public.tasks for delete to authenticated
  using ((public.is_owner() or owner = public.wpie_person() or created_by = auth.uid()) and coalesce(source, '') <> 'belt');

create table if not exists public.task_moves (
  id bigserial primary key,
  task_id uuid not null,
  lead_id uuid,
  by text not null,
  from_at timestamptz,
  to_at timestamptz,
  why text,
  at timestamptz not null default now()
);
create index if not exists task_moves_task_idx on public.task_moves (task_id, at desc);
create index if not exists task_moves_lead_idx on public.task_moves (lead_id, at desc);
alter table public.task_moves enable row level security;
drop policy if exists task_moves_read on public.task_moves;
create policy task_moves_read on public.task_moves for select to authenticated using (public.is_team());
grant select on public.task_moves to authenticated;

-- who may touch this task: Colin any; a caller their own
create or replace function public.task_is_mine(t public.tasks) returns boolean
language sql stable security definer set search_path = public as $$
  -- coalesce: a null (no user id on the token) must read as 'not mine', never slip past an 'if not'
  select coalesce(public.is_owner(), false) or coalesce(t.owner = public.wpie_person(), false) or coalesce(t.created_by = auth.uid(), false)
$$;

-- ---------------------------------------------------------------- set my own follow-up on a card
create or replace function public.followup_set(p_lead_id uuid, p_at timestamptz, p_kind text default 'call', p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare who public.team_person; k text; key text; t public.tasks; was timestamptz; l public.leads;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  if p_at is null then return jsonb_build_object('ok', false, 'reason', 'pick a time'); end if;
  select * into l from public.leads where id = p_lead_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card'); end if;
  who := public.wpie_person();
  if who not in ('thalia', 'adil') then who := 'colin'; end if;
  k := case when p_kind in ('call', 'text', 'visit', 'other') then p_kind else 'call' end;
  key := 'mine:' || p_lead_id::text || ':' || who::text;
  select * into t from public.tasks where source_key = key and done_at is null;
  if found then
    was := t.due_at;
    update public.tasks set due_at = p_at, kind = k, note = coalesce(nullif(btrim(p_note), ''), note), updated_at = now() where id = t.id;
    insert into public.task_moves (task_id, lead_id, by, from_at, to_at, why) values (t.id, p_lead_id, who::text, was, p_at, 'set again');
  else
    insert into public.tasks (lead_id, due_at, kind, owner, note, created_by, source, source_key, title)
    values (p_lead_id, p_at, k, who, nullif(btrim(p_note), ''), auth.uid(), 'mine', key, 'My follow-up')
    on conflict (source_key) do update set due_at = excluded.due_at, kind = excluded.kind, note = excluded.note, done_at = null, updated_at = now()
    returning * into t;
  end if;
  -- the card's "next action" line follows the earliest open follow-up on it
  update public.leads set next_action = coalesce(nullif(btrim(p_note), ''), 'Follow-up (' || initcap(who::text) || ')'),
         next_action_at = least(coalesce(next_action_at, p_at), p_at)
   where id = p_lead_id and (next_action_at is null or next_action_at > p_at or next_action_at < now());
  return jsonb_build_object('ok', true, 'task_id', t.id, 'due_at', p_at, 'owner', who);
end $$;

-- ---------------------------------------------------------------- move any follow-up of mine
create or replace function public.followup_move(p_task_id uuid, p_at timestamptz, p_why text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare t public.tasks; who text; l public.leads;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  select * into t from public.tasks where id = p_task_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such follow-up'); end if;
  if t.done_at is not null then return jsonb_build_object('ok', false, 'reason', 'already done'); end if;
  if not public.task_is_mine(t) then return jsonb_build_object('ok', false, 'reason', 'not your follow-up'); end if;
  if p_at is null then return jsonb_build_object('ok', false, 'reason', 'pick a time'); end if;
  who := coalesce(public.wpie_person()::text, 'team');
  update public.tasks set due_at = p_at, updated_at = now(), notified_at = null where id = t.id;
  if t.lead_id is not null then
    select * into l from public.leads where id = t.lead_id;
    if t.source = 'belt' and l.next_stop_at is not distinct from t.due_at then
      -- the belt's clock follows the moved stop, so the sweep does not count it missed and the strip shows the new time
      update public.leads set next_stop_at = p_at where id = t.lead_id;
      insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
      values (t.lead_id, 'stop_moved', l.belt, l.belt, l.belt_step, jsonb_build_object('task_id', t.id, 'from', t.due_at, 'to', p_at, 'why', p_why), now(), who);
    end if;
    if t.kind = 'callback' then
      update public.deal_packages set callback_at = p_at, updated_at = now()
       where lead_id = t.lead_id and callback_at is not distinct from t.due_at
         and status in ('waiting_value', 'waiting_number', 'go_walk', 'number_ready', 'counter');
    end if;
    if l.next_action_at is not distinct from t.due_at then update public.leads set next_action_at = p_at where id = t.lead_id; end if;
    if l.named_date is not distinct from t.due_at then update public.leads set named_date = p_at where id = t.lead_id; end if;
  end if;
  insert into public.task_moves (task_id, lead_id, by, from_at, to_at, why) values (t.id, t.lead_id, who, t.due_at, p_at, nullif(btrim(p_why), ''));
  return jsonb_build_object('ok', true, 'task_id', t.id, 'from', t.due_at, 'to', p_at);
end $$;

-- ---------------------------------------------------------------- close it the right way
create or replace function public.followup_done(p_task_id uuid, p_outcome text default 'done', p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare t public.tasks; who text; res jsonb;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  select * into t from public.tasks where id = p_task_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such follow-up'); end if;
  if t.done_at is not null then return jsonb_build_object('ok', true, 'already', true); end if;
  if not public.task_is_mine(t) then return jsonb_build_object('ok', false, 'reason', 'not your follow-up'); end if;
  who := coalesce(public.wpie_person()::text, 'team');
  if t.source in ('belt', 'call_list', 'after_stop') then
    res := public.belt_stop_done(t.id, coalesce(nullif(p_outcome, 'done'), 'reached'), p_note, null);
    return coalesce(res, '{}'::jsonb) || jsonb_build_object('ok', true, 'task_id', t.id, 'via', 'belt');
  end if;
  if t.kind = 'callback' and t.lead_id is not null then
    perform public.callback_done(t.lead_id, p_note);
    return jsonb_build_object('ok', true, 'task_id', t.id, 'via', 'callback');
  end if;
  update public.tasks set done_at = now(), note = concat_ws(' | ', note, nullif(btrim(p_note), '')), updated_at = now() where id = t.id;
  if t.lead_id is not null and nullif(btrim(p_note), '') is not null then
    insert into public.messages (lead_id, direction, channel, body, status, created_by, sent_at)
    values (t.lead_id, 'out', 'note', 'Follow-up done (' || initcap(who) || '): ' || btrim(p_note), null, auth.uid(), now());
  end if;
  return jsonb_build_object('ok', true, 'task_id', t.id, 'via', 'plain');
end $$;

-- ---------------------------------------------------------------- delete my own non-belt follow-up
create or replace function public.followup_delete(p_task_id uuid, p_why text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare t public.tasks; who text;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  select * into t from public.tasks where id = p_task_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such follow-up'); end if;
  if not public.task_is_mine(t) then return jsonb_build_object('ok', false, 'reason', 'not your follow-up'); end if;
  if t.source in ('belt', 'call_list', 'after_stop') then return jsonb_build_object('ok', false, 'reason', 'a belt stop is moved or closed, not deleted'); end if;
  if t.kind = 'callback' then return jsonb_build_object('ok', false, 'reason', 'a promised callback is closed with Callback done'); end if;
  who := coalesce(public.wpie_person()::text, 'team');
  insert into public.task_moves (task_id, lead_id, by, from_at, to_at, why) values (t.id, t.lead_id, who, t.due_at, null, 'deleted: ' || coalesce(nullif(btrim(p_why), ''), 'no reason given'));
  delete from public.tasks where id = t.id;
  return jsonb_build_object('ok', true, 'task_id', t.id);
end $$;

revoke all on function public.followup_set(uuid, timestamptz, text, text) from public, anon;
revoke all on function public.followup_move(uuid, timestamptz, text) from public, anon;
revoke all on function public.followup_done(uuid, text, text) from public, anon;
revoke all on function public.followup_delete(uuid, text) from public, anon;
revoke all on function public.task_is_mine(public.tasks) from public, anon;
grant execute on function public.followup_set(uuid, timestamptz, text, text) to authenticated;
grant execute on function public.followup_move(uuid, timestamptz, text) to authenticated;
grant execute on function public.followup_done(uuid, text, text) to authenticated;
grant execute on function public.followup_delete(uuid, text) to authenticated;
grant execute on function public.task_is_mine(public.tasks) to authenticated;

-- ---------------------------------------------------------------- "call me in March" stays with the caller
update public.belt_steps set who = 'thalia_call' where belt = 'not_now_dated' and who = 'colin_call';
-- open not-now stops already on Colin's list that belong to a caller's card go to that caller
update public.tasks t set owner = l.locked_to
  from public.leads l
 where l.id = t.lead_id and t.done_at is null and t.source = 'belt' and t.owner = 'colin' and l.belt = 'not_now_dated'
   and l.locked_to in ('thalia', 'adil');
update public.leads set next_stop_who = 'thalia_call' where belt = 'not_now_dated' and next_stop_who = 'colin_call' and locked_to in ('thalia', 'adil');

-- ---------------------------------------------------------------- the reminder feed
create or replace function public.followups_due_to_alert(p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'task_id', t.id, 'lead_id', t.lead_id, 'kind', t.kind, 'due_at', t.due_at, 'title', coalesce(t.title, t.kind),
      'note', left(coalesce(t.note, ''), 200), 'owner_name', l.owner_name, 'address', l.property_address, 'municipality', l.municipality,
      'person', t.owner::text, 'email', nullif(btrim(m.alert_email), ''), 'whatsapp', nullif(btrim(m.alert_whatsapp), ''), 'display_name', m.display_name)
      order by t.due_at), '[]'::jsonb)
    from public.tasks t
    join public.team_members m on m.person = t.owner
    left join public.leads l on l.id = t.lead_id
   where t.done_at is null and t.notified_at is null and t.owner in ('thalia', 'adil')
     and t.kind in ('call', 'callback', 'visit')
     and coalesce(t.source, '') not in ('power_hour', 'power_hour_after', 'power_hour_reserve', 'call_list', 'reply')
     and t.due_at between p_now - interval '5 minutes' and p_now + interval '10 minutes'
$$;
create or replace function public.followup_alerted(p_task_id uuid, p_note text default null) returns void
language sql security definer set search_path = public as $$
  update public.tasks set notified_at = now(), note = case when p_note is null then note else concat_ws(' | ', note, p_note) end where id = p_task_id
$$;
revoke all on function public.followups_due_to_alert(timestamptz) from public, anon, authenticated;
revoke all on function public.followup_alerted(uuid, text) from public, anon, authenticated;
grant execute on function public.followups_due_to_alert(timestamptz) to service_role;
grant execute on function public.followup_alerted(uuid, text) to service_role;
