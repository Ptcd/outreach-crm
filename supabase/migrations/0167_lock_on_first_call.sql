-- 0167: a card locks to Thalia or Adil on their first call, whatever the outcome (Colin 2026-11-03: "cards need to get
-- locked to adil and thalia after their first call"). Until now (0148) only a reached outcome or taking the text thread
-- locked it, so a card dialed three times with no answer stayed open to both callers. The lock now rides on the call
-- record itself: any call logged on a card (log_call, the call notes, a belt stop, Power hour) by a caller's login locks
-- the card to that caller if it is not locked yet; it never moves after that (lock_card_to only fills an empty lock).
-- A missed inbound call (the seller rang and nobody picked up) is not a call by anyone and locks nothing.
-- Backfill: every unlocked card a caller has already called goes to whoever called it first.

create or replace function public.lock_on_call() returns trigger
language plpgsql security definer set search_path = public as $$
declare who public.team_person;
begin
  if new.lead_id is null or new.status is not distinct from 'inbound_missed' then return new; end if;
  select tm.person into who from auth.users u join public.team_members tm on lower(u.email) = tm.email where u.id = new.created_by;
  if who is null then who := public.wpie_person(); end if;
  if who in ('thalia', 'adil') then perform public.lock_card_to(new.lead_id, who, 'first call'); end if;
  return new;
end $$;

drop trigger if exists messages_lock_on_call on public.messages;
create trigger messages_lock_on_call after insert on public.messages
  for each row when (new.channel = 'call') execute function public.lock_on_call();

-- backfill: the first caller of each unlocked card
with firsts as (
  select distinct on (m.lead_id) m.lead_id, tm.person, m.sent_at
    from public.messages m
    join auth.users u on u.id = m.created_by
    join public.team_members tm on lower(u.email) = tm.email
    join public.leads l on l.id = m.lead_id
   where m.channel = 'call' and m.status is distinct from 'inbound_missed' and tm.person in ('thalia', 'adil') and l.locked_to is null
   order by m.lead_id, coalesce(m.sent_at, m.created_at), m.created_at
)
select count(*) filter (where public.lock_card_to(lead_id, person, 'first call, ' || to_char(sent_at at time zone 'America/Chicago', 'MM/DD'))) from firsts;
