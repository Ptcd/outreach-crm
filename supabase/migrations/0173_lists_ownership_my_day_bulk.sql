-- 0173: the lists (piece 3 of 3; Colin 2026-11-03). Ownership is consistent: the 90-day check-in call and the confirm-walk
-- call go to the card's caller (0168 split, 0167 lock), not to Thalia by name or by weekday; open check-ins and hand-made
-- tasks already on the wrong caller's list move to the card's owner. my_day(person) counts a caller's day for Today's
-- tiles (dials, reached, packages, follow-ups done, follow-ups set). Bulk actions on My cards go through the single
-- doors of 0170 one task at a time, so ownership and the belt are respected: followups_move_many, followups_done_many,
-- cards_hand_many (each card handed to Colin with the same line).

CREATE OR REPLACE FUNCTION public.cold_rest(p_lead_id uuid, p_why text, p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare due timestamptz; tz text := 'America/Chicago'; last_try text; dials integer;
begin
  due := (((p_now at time zone tz)::date + 90) + time '16:30') at time zone tz;
  if extract(isodow from due at time zone tz) in (6, 7) then due := due + make_interval(days => (8 - extract(isodow from due at time zone tz)::int)); end if;
  select to_char(max(m.sent_at) at time zone tz, 'Mon DD'), count(*) into last_try, dials from public.messages m
   where m.lead_id = p_lead_id and m.channel = 'call' and coalesce(m.status, '') not like 'inbound%';
  update public.tasks set done_at = now() where lead_id = p_lead_id and done_at is null and (source = 'belt' or source = 'checkin');
  insert into public.tasks (lead_id, due_at, kind, owner, source, title, note)
  values (p_lead_id, due, 'call', coalesce((select l2.locked_to from public.leads l2 where l2.id = p_lead_id and l2.locked_to in ('thalia', 'adil')), 'thalia'), 'checkin', '90-day check-in call',
          coalesce(dials, 0) || ' tries with no answer, last on ' || coalesce(last_try, '?') || ' (' || p_why || '). '
          || 'Call it like a fresh cold call: "Are you still the owner?", then "Any interest in selling it?"');
  perform set_config('wpie.in_belt_event', '1', true);
  update public.leads set stage = 'follow_up', belt = null, belt_step = 0, next_stop_at = null, next_stop_who = null, next_stop_say = null,
         next_action = '90-day check-in call', next_action_at = due where id = p_lead_id;
  perform set_config('wpie.in_belt_event', '', true);
  insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
  values (p_lead_id, 'move', null, null, 0, jsonb_build_object('reason', '90-day rest: ' || p_why, 'checkin_at', due), p_now, 'conveyor');
  return jsonb_build_object('ok', true, 'rest', true, 'checkin_at', due);
end $function$;

CREATE OR REPLACE FUNCTION public.walk_confirm_task()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare tz text := 'America/Chicago'; due timestamptz; who public.team_person;
begin
  if new.belt is not distinct from old.belt and new.named_date is not distinct from old.named_date then return new; end if;
  update public.tasks set done_at = now() where lead_id = new.id and source = 'walk_confirm' and done_at is null;
  if new.belt <> 'visit_booked' or new.named_date is null or new.named_date <= now() then return new; end if;
  due := ((new.named_date at time zone tz)::date - 1 + time '10:00') at time zone tz;
  if due < now() + interval '30 minutes' then due := new.named_date - interval '3 hours'; end if;
  if due < now() + interval '30 minutes' then return new; end if;   -- booked for the next few hours: they just said yes
  -- the card's caller confirms the walk (0173); the weekday rule only for a card nobody owns yet
  who := coalesce((select l2.locked_to from public.leads l2 where l2.id = new.id and l2.locked_to in ('thalia', 'adil')),
                  (case when extract(isodow from due at time zone tz) in (6, 7) then 'adil' else 'thalia' end)::public.team_person);
  insert into public.tasks (lead_id, due_at, kind, owner, source, note)
  values (new.id, due, 'confirm_walk', who, 'walk_confirm',
          'Confirm Colin''s walk ' || to_char(new.named_date at time zone tz, 'FMDy FMHH12:MI AM')
          || ': still good? Everyone on the title there? "If his number works for you, are you ready to give him a yes or a no that day? A no is completely fine."');
  return new;
end $function$;

-- open check-ins and hand-made tasks follow the card's owner (0168's re-owner covered belt, call-list and reserve only)
update public.tasks t set owner = l.locked_to, updated_at = now()
  from public.leads l
 where l.id = t.lead_id and t.done_at is null and t.kind in ('call', 'visit', 'text', 'other')
   and (t.source = 'checkin' or t.source = 'walk_confirm' or t.source is null)
   and t.owner in ('thalia', 'adil') and l.locked_to in ('thalia', 'adil') and t.owner <> l.locked_to;

create or replace function public.my_day(p_person public.team_person default null, p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare who public.team_person; day_start timestamptz; uid uuid;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  who := coalesce(p_person, public.wpie_person());
  if who is distinct from public.wpie_person() and not public.is_owner() then who := public.wpie_person(); end if;
  day_start := date_trunc('day', p_now at time zone 'America/Chicago') at time zone 'America/Chicago';
  select u.id into uid from public.team_members m join auth.users u on lower(u.email) = m.email where m.person = who limit 1;
  return jsonb_build_object(
    'person', who,
    'dials', (select count(*) from public.messages m where m.channel = 'call' and m.created_by = uid and m.sent_at >= day_start and m.sent_at <= p_now
                and m.status is distinct from 'inbound_missed'),
    'reached', (select count(*) from public.messages m where m.channel = 'call' and m.created_by = uid and m.sent_at >= day_start and m.sent_at <= p_now
                  and m.status in ('interested', 'reached_no_decision', 'not_now', 'not_interested', 'inbound_answered')),
    'packages', (select count(*) from public.deal_packages d where d.created_by = who and d.created_at >= day_start and d.created_at <= p_now),
    'done', (select count(*) from public.tasks t where t.owner = who and t.done_at >= day_start and t.done_at <= p_now),
    'set', (select count(*) from public.task_moves x where x.by = who::text and x.at >= day_start and x.at <= p_now)
          + (select count(*) from public.tasks t where t.source = 'mine' and t.owner = who and t.created_at >= day_start and t.created_at <= p_now),
    'left_today', (select count(*) from public.tasks t where t.owner = who and t.done_at is null and t.kind in ('call', 'callback', 'visit')
                     and t.due_at < day_start + interval '1 day' and coalesce(t.source, '') not in ('power_hour_reserve')));
end $$;
revoke all on function public.my_day(public.team_person, timestamptz) from public, anon;
grant execute on function public.my_day(public.team_person, timestamptz) to authenticated;

create or replace function public.followups_move_many(p_task_ids uuid[], p_at timestamptz, p_why text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t uuid; r jsonb; moved integer := 0; refused jsonb := '[]'::jsonb;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  foreach t in array coalesce(p_task_ids, '{}') loop
    r := public.followup_move(t, p_at, p_why);
    if coalesce((r->>'ok')::boolean, false) then moved := moved + 1; else refused := refused || jsonb_build_object('task_id', t, 'reason', r->>'reason'); end if;
  end loop;
  return jsonb_build_object('ok', true, 'moved', moved, 'refused', refused);
end $$;

create or replace function public.followups_done_many(p_task_ids uuid[], p_outcome text default 'done', p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t uuid; r jsonb; done_n integer := 0; refused jsonb := '[]'::jsonb;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  foreach t in array coalesce(p_task_ids, '{}') loop
    r := public.followup_done(t, p_outcome, p_note);
    if coalesce((r->>'ok')::boolean, false) then done_n := done_n + 1; else refused := refused || jsonb_build_object('task_id', t, 'reason', r->>'reason'); end if;
  end loop;
  return jsonb_build_object('ok', true, 'done', done_n, 'refused', refused);
end $$;

create or replace function public.cards_hand_many(p_lead_ids uuid[], p_note text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare l uuid; r jsonb; handed integer := 0; refused jsonb := '[]'::jsonb;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  if nullif(btrim(coalesce(p_note, '')), '') is null then return jsonb_build_object('ok', false, 'reason', 'one line for Colin'); end if;
  foreach l in array coalesce(p_lead_ids, '{}') loop
    r := public.handoff_to_colin(l, p_note, now());
    if coalesce((r->>'ok')::boolean, false) then handed := handed + 1; else refused := refused || jsonb_build_object('lead_id', l, 'reason', r->>'reason'); end if;
  end loop;
  return jsonb_build_object('ok', true, 'handed', handed, 'refused', refused);
end $$;
revoke all on function public.followups_move_many(uuid[], timestamptz, text) from public, anon;
revoke all on function public.followups_done_many(uuid[], text, text) from public, anon;
revoke all on function public.cards_hand_many(uuid[], text) from public, anon;
grant execute on function public.followups_move_many(uuid[], timestamptz, text) to authenticated;
grant execute on function public.followups_done_many(uuid[], text, text) to authenticated;
grant execute on function public.cards_hand_many(uuid[], text) to authenticated;
