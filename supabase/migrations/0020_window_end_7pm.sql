-- Sending window ends at 7 PM Central (Colin 2026-10-21: "It's fine, before 7pm is fine"), for openers
-- and follow-ups alike; start stays 10:00, no Sundays. The live row already reads 19:00; this makes
-- it the default too, so a reset or a fresh database cannot fall back to 18:15.
alter table public.campaign_control alter column window_end set default '19:00';
update public.campaign_control set window_end = '19:00', window_start = '10:00', no_sundays = true where id = 1;
