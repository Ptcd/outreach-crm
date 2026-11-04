-- 0185: the parked-card wake (0183) read new.event on every table it watches. twilio_inbound and inbound_calls have no
-- event column, and PL/pgSQL resolves the field when the UPDATE's parameters are fetched, before the CASE can skip it,
-- so an inbound text or call on a card would have raised "record new has no field event" and the insert would have
-- failed (caught by the agentDoor tests on 2026-11-04; no inbound text or call arrived on a card between 0183 and this
-- fix, so nothing was lost). The row is read as JSON, which any table can give.

create or replace function public.unpark_on_event() returns trigger
language plpgsql security definer set search_path = public as $$
declare lead uuid := (to_jsonb(new) ->> 'lead_id')::uuid; ev text := to_jsonb(new) ->> 'event';
begin
  if lead is null then return new; end if;
  update public.leads
     set parked_at = null,
         parked_why = concat_ws(' | ', parked_why, to_char(now() at time zone 'America/Chicago', 'YYYY-MM-DD') || ' woke: ' || tg_argv[0]
                      || case when tg_table_name = 'belt_events' and ev is not null then ' (' || ev || ')' else '' end)
   where id = lead and parked_at is not null;
  return new;
end $$;
