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
before insert or update of belt on public.leads
for each row execute function public.belt_visit_owner();
