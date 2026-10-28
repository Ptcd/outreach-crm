-- Ask first (Colin 2026-10-28, on Shirikin's package: "i received the package but now how do i dispo it"): besides walk
-- it and pass, Colin can send the caller questions he needs answered before he decides (the timeline, what "$1.5"
-- means, how many units and the rents). The promised callback carries them; the caller records the answers on the
-- package, Colin gets a push, and then decides walk it or pass as usual.

alter table public.deal_packages add column if not exists colin_asks text;
alter table public.deal_packages add column if not exists asks_at timestamptz;
alter table public.deal_packages add column if not exists caller_answers text;
alter table public.deal_packages add column if not exists answered_at timestamptz;
alter table public.deal_packages add column if not exists answers_pinged_at timestamptz;

create or replace function public.package_ask(p_id uuid, p_asks text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d public.deal_packages;
begin
  if not public.is_owner() then raise exception 'only Colin asks'; end if;
  select * into d from public.deal_packages where id = p_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such package'); end if;
  if d.status not in ('waiting_value', 'waiting_number') then return jsonb_build_object('ok', false, 'reason', 'this package is ' || d.status); end if;
  if coalesce(btrim(p_asks), '') = '' then return jsonb_build_object('ok', false, 'reason', 'write what you need to know first'); end if;
  if p_asks ~ '\$|\m[0-9]{2,3}[,.]?[0-9]{3}\M|\m[0-9]+(\.[0-9]+)? ?(k|m|million|thousand)\M' and p_asks ~* '\m(offer|pay|give|our number|my number|around)\M' then
    return jsonb_build_object('ok', false, 'reason', 'no number of ours goes to the seller on the phone; ask questions only');
  end if;
  update public.deal_packages set colin_asks = left(btrim(p_asks), 1000), asks_at = now(), caller_answers = null, answered_at = null,
         answers_pinged_at = null, number_due_pinged_at = now() where id = p_id;
  update public.tasks set note = 'Callback: Colin needs answers first: ' || left(btrim(p_asks), 300) || ' (package ' || left(p_id::text, 8) || ')'
   where lead_id = d.lead_id and kind = 'callback' and done_at is null and coalesce(source, '') <> 'walk_confirm';
  update public.leads set next_action = 'Callback: get Colin''s answers' where id = d.lead_id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.package_answer(p_id uuid, p_answers text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d public.deal_packages;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  select * into d from public.deal_packages where id = p_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such package'); end if;
  if d.colin_asks is null then return jsonb_build_object('ok', false, 'reason', 'Colin has not asked anything on this package'); end if;
  if coalesce(btrim(p_answers), '') = '' then return jsonb_build_object('ok', false, 'reason', 'write their answers, in their words'); end if;
  update public.deal_packages set caller_answers = left(btrim(p_answers), 2000), answered_at = now(), answers_pinged_at = null where id = p_id;
  update public.leads set next_action = 'Package with Colin: answers in, walk it or pass' where id = d.lead_id;
  return jsonb_build_object('ok', true);
end $$;

-- the push to Colin when the answers are in (the reply agent's minute run)
create or replace function public.package_answers_claim() returns jsonb language plpgsql security definer set search_path = public as $$
declare out jsonb; ids uuid[];
begin
  with c as (select d.id from public.deal_packages d where d.answered_at is not null and d.answers_pinged_at is null
               and d.status in ('waiting_value', 'waiting_number') for update skip locked),
  u as (update public.deal_packages d set answers_pinged_at = now() from c where d.id = c.id returning d.id)
  select coalesce(array_agg(id), '{}') into ids from u;
  select coalesce(jsonb_agg(jsonb_build_object('package_id', d.id, 'lead_id', l.id, 'property_address', l.property_address)), '[]'::jsonb) into out
    from public.deal_packages d join public.leads l on l.id = d.lead_id where d.id = any(ids);
  return out;
end $$;

-- "walk it or pass, by": not while Colin is waiting on the answers he asked for
create or replace function public.package_number_due_claim() returns jsonb language plpgsql security definer set search_path = public as $$
declare out jsonb; ids uuid[];
begin
  with c as (select d.id from public.deal_packages d
              where d.status in ('waiting_value', 'waiting_number') and d.callback_at is not null
                and d.callback_at < now() + interval '3 hours' and d.number_due_pinged_at is null
                and (d.colin_asks is null or d.answered_at is not null)
              for update skip locked),
  u as (update public.deal_packages d set number_due_pinged_at = now() from c where d.id = c.id returning d.id)
  select coalesce(array_agg(id), '{}') into ids from u;
  select coalesce(jsonb_agg(jsonb_build_object('package_id', d.id, 'lead_id', l.id, 'property_address', l.property_address,
           'callback_at', d.callback_at, 'status', d.status)), '[]'::jsonb) into out
    from public.deal_packages d join public.leads l on l.id = d.lead_id where d.id = any(ids);
  return out;
end $$;

revoke all on function public.package_ask(uuid, text), public.package_answer(uuid, text) from public, anon;
grant execute on function public.package_ask(uuid, text), public.package_answer(uuid, text) to authenticated, service_role;
revoke all on function public.package_answers_claim(), public.package_number_due_claim() from public, anon, authenticated;
grant execute on function public.package_answers_claim(), public.package_number_due_claim() to service_role;
