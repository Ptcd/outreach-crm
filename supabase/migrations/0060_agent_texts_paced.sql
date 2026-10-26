-- The sender agent's texts are paced like the laptop's (2026-10-26): at most 35 an hour, so a morning's queue spreads
-- over the 10 AM - 7 PM window instead of going out in one burst carriers notice.
create or replace function public.pace_agent_texts() returns trigger
language plpgsql as $$
begin
  if new.lane = 'agent' and new.per_hour is null then new.per_hour := 35; end if;
  return new;
end $$;
drop trigger if exists pace_agent_texts on public.planned_openers;
create trigger pace_agent_texts before insert on public.planned_openers
  for each row execute function public.pace_agent_texts();
