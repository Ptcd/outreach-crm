-- 0183: a parked card un-parks itself the moment something happens that a caller should see (Colin 2026-11-04, after
-- parking the two worst lots): the seller texts back (inbound_text, hot_reply), the seller calls us (they_called), a new
-- public record lands on the house (wpie_event: a filing, a tax petition, a probate, a listing that ended), or the belt
-- reopens the card. The belt already records each of those as a belt_events row, so the wake rides on that insert; a
-- raw inbound text with a card is covered too, in case it arrives ahead of the belt. The card comes back with its owner,
-- in the right pile, and parked_why keeps the history.

create or replace function public.unpark_on_event() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.lead_id is null then return new; end if;
  update public.leads
     set parked_at = null,
         parked_why = concat_ws(' | ', parked_why, to_char(now() at time zone 'America/Chicago', 'YYYY-MM-DD') || ' woke: ' || tg_argv[0]
                      || case when tg_table_name = 'belt_events' then ' (' || new.event || ')' else '' end)
   where id = new.lead_id and parked_at is not null;
  return new;
end $$;

drop trigger if exists belt_events_unpark on public.belt_events;
create trigger belt_events_unpark after insert on public.belt_events
  for each row when (new.event in ('inbound_text', 'hot_reply', 'they_called', 'wpie_event', 'reopened', 'after_stop_interest'))
  execute function public.unpark_on_event('the belt');

drop trigger if exists twilio_inbound_unpark on public.twilio_inbound;
create trigger twilio_inbound_unpark after insert on public.twilio_inbound
  for each row when (new.lead_id is not null) execute function public.unpark_on_event('a text in');

drop trigger if exists inbound_calls_unpark on public.inbound_calls;
create trigger inbound_calls_unpark after insert on public.inbound_calls
  for each row when (new.lead_id is not null) execute function public.unpark_on_event('a call in');
