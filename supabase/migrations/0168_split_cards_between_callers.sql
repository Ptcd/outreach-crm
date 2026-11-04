-- 0168: every open card belongs to Thalia or Adil (Colin 2026-11-03: "all new and existing cards should be split between
-- thalia and adil as they come in and exist in our crm"). The owner is leads.locked_to, the same lock the first call sets
-- (0148, 0167): it decides whose Power hour shows the card, whose phone rings when the seller calls back, who gets the
-- missed-call alert, and who owns the card's follow-up calls (belt_enter). It never moves on its own; Colin moves one by hand.
--
-- Existing open cards with no lock: a card keeps the caller it is already theirs by (a promised callback, a call in
-- tonight's power-hour set, assigned to them, their texts taken); every other card is split evenly, interleaved by
-- motivation tier, stage and county so each caller gets the same mix. Open follow-up calls on the belt move to the
-- card's owner. New cards alternate Thalia, Adil, Thalia ... as they are inserted (laptop sync, Muse's door, manual),
-- and so does a closed card that reopens. Closed cards (dead, do not contact, closed) are left alone.

create table if not exists public.card_split_state (
  id integer primary key default 1 check (id = 1),
  diff integer not null default 0          -- Thalia's auto-split cards minus Adil's: the next card goes to whoever is behind
);
insert into public.card_split_state (id, diff) values (1, 0) on conflict (id) do nothing;
alter table public.card_split_state enable row level security;

create or replace function public.card_is_closed(p_stage public.lead_stage) returns boolean
language sql immutable as $$ select p_stage::text in ('dead', 'dnc', 'closed_won', 'closed_no_contact', 'mail_only') $$;

-- the next owner for a new card: whoever is behind, Thalia on a tie
create or replace function public.next_card_owner() returns public.team_person
language plpgsql security definer set search_path = public as $$
declare d integer; who public.team_person;
begin
  select diff into d from public.card_split_state where id = 1 for update;
  if coalesce(d, 0) <= 0 then who := 'thalia'; else who := 'adil'; end if;
  update public.card_split_state set diff = coalesce(d, 0) + case when who = 'thalia' then 1 else -1 end where id = 1;
  return who;
end $$;

create or replace function public.split_new_card() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.locked_to is null and not public.card_is_closed(new.stage) then
    update public.leads set locked_to = public.next_card_owner(), locked_at = now() where id = new.id and locked_to is null;
  end if;
  return null;
end $$;

-- AFTER INSERT fires only for a row really inserted (an upsert that updates an existing card does not count)
drop trigger if exists leads_split_new_card on public.leads;
create trigger leads_split_new_card after insert on public.leads for each row execute function public.split_new_card();
drop trigger if exists leads_split_reopened_card on public.leads;
create trigger leads_split_reopened_card after update of stage on public.leads for each row
  when (public.card_is_closed(old.stage) and not public.card_is_closed(new.stage) and new.locked_to is null)
  execute function public.split_new_card();

-- ---------------------------------------------------------------- existing cards
-- 1. cards already some caller's
with mine as (
  select l.id, coalesce(
    (select t.owner from public.tasks t where t.lead_id = l.id and t.done_at is null and t.owner in ('thalia', 'adil')
        and (t.kind = 'callback' or t.source in ('power_hour', 'power_hour_after')) order by t.due_at nulls last limit 1),
    case when l.assigned_to in ('thalia', 'adil') then l.assigned_to end,
    case when l.human_takeover_assigned_to in ('thalia', 'adil') then l.human_takeover_assigned_to end) who
  from public.leads l where l.locked_to is null and not public.card_is_closed(l.stage)
)
update public.leads l set locked_to = m.who, locked_at = now() from mine m where m.id = l.id and m.who is not null;

-- 2. the rest, split evenly and interleaved so both callers get the same mix
with counts as (
  select count(*) filter (where locked_to = 'thalia') t, count(*) filter (where locked_to = 'adil') a,
         count(*) filter (where locked_to is null) r
    from public.leads where not public.card_is_closed(stage)
), quota as (
  select r, greatest(0, least(r, (r + t - a) / 2)) adil_n from counts
), rest as (
  select l.id, row_number() over (order by coalesce(lm.tier, 'Z'), l.stage, coalesce(l.county, ''), md5(l.id::text)) rn
    from public.leads l left join public.lead_motivation lm on lm.lead_id = l.id
   where l.locked_to is null and not public.card_is_closed(l.stage)
)
update public.leads l
   set locked_to = case when floor(x.rn * q.adil_n::numeric / nullif(q.r, 0)) > floor((x.rn - 1) * q.adil_n::numeric / nullif(q.r, 0))
                        then 'adil'::public.team_person else 'thalia'::public.team_person end,
       locked_at = now()
  from rest x, quota q where x.id = l.id;

-- the new-card split starts from where the existing split left off
update public.card_split_state set diff = (select count(*) filter (where locked_to = 'thalia') - count(*) filter (where locked_to = 'adil')
                                             from public.leads where not public.card_is_closed(stage)) where id = 1;

-- 3. open calls on the belt, the call list and tomorrow's power-hour reserve go to the card's owner (a promised callback
--    stays with whoever promised it; tonight's loaded sets stay with their caller)
update public.tasks t set owner = l.locked_to
  from public.leads l
 where l.id = t.lead_id and t.done_at is null and t.kind = 'call' and coalesce(t.source, '') in ('belt', 'call_list', 'power_hour_reserve')
   and t.owner in ('thalia', 'adil') and l.locked_to in ('thalia', 'adil') and t.owner <> l.locked_to;
