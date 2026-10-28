-- A logged call finishes that card's call-list task (Thalia 2026-10-28: "there's only one lead showing up on my today's
-- list ... I already called and left her a voicemail"). The laptop's day list and hand-made call tasks stayed open after
-- the call was logged, so the card she had just called stayed first on her list. Now any outcome logged on a card closes
-- its open call-list and manual call tasks due by the end of today. The belt's own stops are left to the belt (its
-- trigger closes them on the logged call; closing them by hand would read as a plain Done and route the card again).
create or replace function public.logged_call_closes_list_task() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.channel = 'call' and new.lead_id is not null
     and new.status in ('no_answer', 'interested', 'reached_no_decision', 'not_now', 'not_interested', 'wrong_number', 'dnc') then
    update public.tasks set done_at = now(),
           note = concat_ws(E'\n', note, 'Called: ' || new.status || ' (' || to_char(now() at time zone 'America/Chicago', 'Mon DD HH12:MI AM') || ')')
     where lead_id = new.lead_id and kind = 'call' and done_at is null and coalesce(source, '') <> 'belt'
       and due_at <= ((now() at time zone 'America/Chicago')::date + 1)::timestamp at time zone 'America/Chicago';
  end if;
  return new;
end $$;
drop trigger if exists logged_call_closes_list_task on public.messages;
create trigger logged_call_closes_list_task after insert on public.messages
  for each row when (new.channel = 'call') execute function public.logged_call_closes_list_task();

-- today's: every card already called today with an open list task
update public.tasks t set done_at = now(), note = concat_ws(E'\n', t.note, 'Called earlier today (closed by 0102)')
 where t.kind = 'call' and t.done_at is null and coalesce(t.source, '') <> 'belt'
   and t.due_at <= ((now() at time zone 'America/Chicago')::date + 1)::timestamp at time zone 'America/Chicago'
   and exists (select 1 from public.messages m where m.lead_id = t.lead_id and m.channel = 'call'
                 and m.status in ('no_answer', 'interested', 'reached_no_decision', 'not_now', 'not_interested', 'wrong_number', 'dnc')
                 and (m.sent_at at time zone 'America/Chicago')::date = (now() at time zone 'America/Chicago')::date);
