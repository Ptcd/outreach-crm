-- A text Muse queued stays Muse's (Muse 2026-10-28: "laptop-planned texts never release - the 298 first texts, the 102
-- dropped in the handoff, and the 40 stuck step-2s are one bug").
--
-- Why: the laptop plans each day's texts, the app hands them to Muse (hand_opener_to_agent, 0059/0064), and when Muse
-- queues a card the laptop planned, its text takes over the laptop's row (0062): lane 'agent', approved, planned. The
-- laptop's push runs every 10 minutes and updates every row of its plan that is still 'planned', so it put the row back:
-- the laptop's lane, the laptop's words, and 'pending' because the words now differed. The sender only takes approved
-- texts, so nothing Muse queued at 8:46 AM on 10/28 went out after the next push (2 of 300 did). On 10/27 most sent
-- inside those ten minutes, which hid it.
-- Now:
--   * a row Muse owns (lane 'agent') ignores any update that would take it back to another lane: the laptop's push
--     leaves it alone (wpie/live/sync.py also stops trying);
--   * the laptop's follow-ups still waiting for an approval no one gives (step 2-5, planned before Muse ran the
--     follow-ups: 40 since 10/25) go to Muse the way new ones do. While one waited, the card was "already waiting" and
--     never came up as due, and Muse's own copy for it was overwritten the same way.

create or replace function public.agent_row_stays_agent() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.lane = 'agent' and new.lane is distinct from 'agent' then
    return old;   -- skip this update: the row is Muse's
  end if;
  return new;
end $$;

drop trigger if exists agent_row_stays_agent on public.planned_openers;
create trigger agent_row_stays_agent before update on public.planned_openers
  for each row execute function public.agent_row_stays_agent();

update public.planned_openers p
   set send_status = 'withdrawn', send_reason = 'handed to the sender agent', send_updated_at = now()
 where p.lane <> 'agent' and p.step > 1 and p.send_status = 'planned' and p.decision = 'pending'
   and (select agent_runs_texting from public.campaign_control where id = 1);
