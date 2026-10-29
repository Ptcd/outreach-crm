-- The check-in task's note no longer repeats its title (Today's list shows "title: note").

create or replace function public.cold_rest(p_lead_id uuid, p_why text, p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public as $$
declare due timestamptz; tz text := 'America/Chicago'; last_try text; dials integer;
begin
  due := (((p_now at time zone tz)::date + 90) + time '16:30') at time zone tz;
  if extract(isodow from due at time zone tz) in (6, 7) then due := due + make_interval(days => (8 - extract(isodow from due at time zone tz)::int)); end if;
  select to_char(max(m.sent_at) at time zone tz, 'Mon DD'), count(*) into last_try, dials from public.messages m
   where m.lead_id = p_lead_id and m.channel = 'call' and coalesce(m.status, '') not like 'inbound%';
  update public.tasks set done_at = now() where lead_id = p_lead_id and done_at is null and (source = 'belt' or source = 'checkin');
  insert into public.tasks (lead_id, due_at, kind, owner, source, title, note)
  values (p_lead_id, due, 'call', 'thalia', 'checkin', '90-day check-in call',
          coalesce(dials, 0) || ' tries with no answer, last on ' || coalesce(last_try, '?') || ' (' || p_why || '). '
          || 'Call it like a fresh cold call: "Are you still the owner?", then "Any interest in selling it?"');
  perform set_config('wpie.in_belt_event', '1', true);
  update public.leads set stage = 'follow_up', belt = null, belt_step = 0, next_stop_at = null, next_stop_who = null, next_stop_say = null,
         next_action = '90-day check-in call', next_action_at = due where id = p_lead_id;
  perform set_config('wpie.in_belt_event', '', true);
  insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
  values (p_lead_id, 'move', null, null, 0, jsonb_build_object('reason', '90-day rest: ' || p_why, 'checkin_at', due), p_now, 'conveyor');
  return jsonb_build_object('ok', true, 'rest', true, 'checkin_at', due);
end $$;
