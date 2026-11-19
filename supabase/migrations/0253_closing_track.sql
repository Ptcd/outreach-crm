-- 0253: the closing track. What happens after a seller signs.
--
-- Colin, 2026-11-19, the morning after 991 Howard St (Green Bay) was signed at $60,000: "Probably gotta build out the
-- system for everything post offer signing now?" Until now a signature did three things: the deal read "Signed: to
-- title", the card read "under contract", and Colin got one task, "Contract + deposit to title today". Nothing carried
-- the dates the contract itself sets (earnest money in 5 days, proof of funds in 7, the closing day), and the sales
-- belt kept running: on Howard St Tyler still had a "Said yes, not booked" call to make to a seller who had signed.
--
-- Now a signature opens a track of dated steps on the deal, written from the contract's own terms:
--   the title company, earnest money, proof of funds, the payoff letter, the title search, access, the walk-through,
--   the closing statement, clear to close, the closing.
-- A probate card adds two: the seller's papers (letters, the will) and who signs (the estate by its personal
-- representative, and anyone the will leaves the house to: Wis. Stat. 860.11 (2)).
-- Colin has one open task per deal, always the next step that is due; ticking a step moves the task to the next one.
-- Ticking "Closing" closes the deal and the card. A signature also stops the selling: the belt ends, the callers' open
-- tasks on the card close, and a belt text that was waiting is withdrawn.
--
-- The track is Colin's (owner role), like the deal row it hangs on. A caller and the agents do not read or write it.

alter table public.deals
  add column if not exists price numeric,
  add column if not exists closing_on date,
  add column if not exists title_company text,
  add column if not exists title_contact text,
  add column if not exists title_phone text,
  add column if not exists title_email text;

create table if not exists public.closing_steps (
  id uuid primary key default gen_random_uuid(),
  deal_id uuid not null references public.deals(id) on delete cascade,
  lead_id uuid not null references public.leads(id) on delete cascade,
  key text not null,
  label text not null,
  why text,
  sort integer not null,
  due_on date,
  done_at timestamptz,
  done_by text,
  skipped boolean not null default false,
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (deal_id, key)
);
create index if not exists closing_steps_lead_idx on public.closing_steps (lead_id, sort);
drop trigger if exists closing_steps_touch on public.closing_steps;
create trigger closing_steps_touch before update on public.closing_steps for each row execute function public.touch_updated_at();

alter table public.closing_steps enable row level security;
drop policy if exists closing_steps_owner on public.closing_steps;
create policy closing_steps_owner on public.closing_steps for all using (public.is_owner()) with check (public.is_owner());
grant select, insert, update, delete on public.closing_steps to authenticated, service_role;

-- ---------------------------------------------------------------- one task per deal: the next step that is due
create or replace function public.closing_next_task(p_deal_id uuid, p_now timestamptz default now()) returns uuid
language plpgsql security definer set search_path = public as $fn$
declare d public.deals; s public.closing_steps; addr text; tid uuid; k text := 'closing:' || p_deal_id::text;
begin
  select * into d from public.deals where id = p_deal_id;
  if not found then return null; end if;
  if d.status not in ('dead', 'closed') then
    select * into s from public.closing_steps
     where deal_id = p_deal_id and done_at is null and not skipped
     order by due_on nulls last, sort limit 1;
  end if;
  if s.id is null then
    update public.tasks set done_at = coalesce(done_at, p_now) where source_key = k and done_at is null;
    return null;
  end if;
  select coalesce(property_address, owner_name) into addr from public.leads where id = d.lead_id;
  insert into public.tasks (lead_id, due_at, kind, owner, note, source, source_key, title)
  values (d.lead_id, ((coalesce(s.due_on, (p_now at time zone 'America/Chicago')::date))::timestamp + time '09:00') at time zone 'America/Chicago',
          'other', 'colin', s.why, 'closing', k, 'Closing: ' || s.label || ': ' || coalesce(addr, ''))
  on conflict (source_key) do update
    set due_at = excluded.due_at, note = excluded.note, title = excluded.title, done_at = null, updated_at = now()
  returning id into tid;
  return tid;
end $fn$;
revoke all on function public.closing_next_task(uuid, timestamptz) from public, anon, authenticated;
grant execute on function public.closing_next_task(uuid, timestamptz) to service_role;

-- ---------------------------------------------------------------- a signature stops the selling
create or replace function public.closing_stop_sales(p_lead_id uuid, p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare l public.leads; n_tasks integer := 0; n_drafts integer := 0;
begin
  select * into l from public.leads where id = p_lead_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card'); end if;
  perform set_config('wpie.in_belt_event', '1', true);
  update public.leads set belt = null, belt_step = 0, next_stop_at = null, next_stop_who = null, next_stop_say = null where id = p_lead_id;
  -- the callers' open work on the card, and anything the belt or a reply made: the sale is made
  update public.tasks t set done_at = p_now, note = concat_ws(' | ', t.note, 'Closed by the system: the offer is signed')
   where t.lead_id = p_lead_id and t.done_at is null and coalesce(t.source, '') not in ('closing')
     and (public.is_caller_person(t.owner) or coalesce(t.source, '') in ('belt', 'call_list', 'reply', 'checkin', 'contract'));
  get diagnostics n_tasks = row_count;
  update public.reply_drafts set status = 'superseded', note = coalesce(note, '') || ' | the offer is signed', updated_at = p_now
   where lead_id = p_lead_id and kind = 'belt' and status in ('queued', 'awaiting_approval', 'would_send');
  get diagnostics n_drafts = row_count;
  if l.belt is not null or n_tasks > 0 or n_drafts > 0 then
    insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
    values (p_lead_id, 'contract_signed', l.belt, null, 0,
            jsonb_build_object('key', 'contract_signed:' || p_lead_id::text || ':' || to_char(p_now at time zone 'UTC', 'YYYYMMDDHH24MISS'), 'tasks_closed', n_tasks, 'texts_withdrawn', n_drafts,
                               'reason', 'the offer is signed: the selling stops and the closing track takes over'), p_now, 'system');
  end if;
  perform set_config('wpie.in_belt_event', '', true);
  return jsonb_build_object('ok', true, 'tasks_closed', n_tasks, 'texts_withdrawn', n_drafts);
end $fn$;
revoke all on function public.closing_stop_sales(uuid, timestamptz) from public, anon, authenticated;
grant execute on function public.closing_stop_sales(uuid, timestamptz) to service_role;

-- ---------------------------------------------------------------- open the track from a signed contract
create or replace function public.closing_track_open(p_contract_id uuid, p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare c public.contracts; l public.leads; d public.deals; t jsonb; a date; cl date; v_price numeric; v_holder text;
  probate boolean; e_days integer; p_days integer; i_days integer; tid uuid; n integer;
  v_day text;
begin
  select * into c from public.contracts where id = p_contract_id;
  if not found or c.status <> 'signed' then return jsonb_build_object('ok', false, 'reason', 'that contract is not signed'); end if;
  select * into l from public.leads where id = c.lead_id;
  select * into d from public.deals where lead_id = c.lead_id order by created_at desc limit 1;
  if d.id is null then return jsonb_build_object('ok', false, 'reason', 'no deal on this card'); end if;
  t := coalesce(c.terms, '{}'::jsonb);
  a := (coalesce(c.signed_at, p_now) at time zone 'America/Chicago')::date;
  v_day := nullif(t->>'closingOn', '');
  begin cl := v_day::date; exception when others then cl := null; end;
  if cl is null and nullif(t->>'closing', '') is not null then   -- the long form keeps only the written date ("November 20, 2026")
    begin cl := to_date(t->>'closing', 'FMMonth DD, YYYY'); exception when others then cl := null; end;
  end if;
  begin v_price := nullif(regexp_replace(coalesce(t->>'price', ''), '[^0-9.]', '', 'g'), '')::numeric; exception when others then v_price := null; end;
  v_holder := nullif(btrim(coalesce(t->>'earnestHolder', '')), '');
  if v_holder ~* '^the title company' then v_holder := null; end if;   -- "the title company selected by Buyer": no company was named
  e_days := coalesce(nullif(regexp_replace(coalesce(t->>'earnestDays', ''), '\D', '', 'g'), '')::integer, 5);
  p_days := nullif(regexp_replace(coalesce(t->>'proofOfFundsDays', ''), '\D', '', 'g'), '')::integer;
  i_days := case when coalesce((t->>'inspection')::boolean, false)
                 then coalesce(nullif(regexp_replace(coalesce(t->>'inspectionDays', ''), '\D', '', 'g'), '')::integer, 10) end;
  probate := coalesce(l.reasons_to_sell::text, '') ~* 'probate|estate of|personal rep';

  update public.deals dd set price = coalesce(dd.price, v_price), closing_on = coalesce(dd.closing_on, cl),
         title_company = coalesce(dd.title_company, v_holder)
   where dd.id = d.id returning dd.* into d;

  insert into public.closing_steps (deal_id, lead_id, key, label, why, sort, due_on)
  select d.id, c.lead_id, x.key, x.label, x.why, x.sort, x.due_on
    from (values
      ('title', case when d.title_company is null then 'Pick the title company and send them the signed contract'
                     else 'Signed contract to ' || d.title_company end,
        'They open the file, hold the earnest money and run the title search. Nothing else starts until they have it.', 10, a + 1),
      ('earnest', 'Earnest money' || coalesce(' ($' || nullif(regexp_replace(coalesce(t->>'earnestMoney', ''), '[^0-9.]', '', 'g'), '') || ')', '') || ' to the title company',
        'The contract gives ' || e_days || ' days from acceptance. Late earnest money gives the seller a way out.', 20, a + e_days),
      ('proof', 'Proof of funds to the seller',
        'The contract gives ' || coalesce(p_days, 0) || ' days from acceptance.', 30, case when p_days is not null then a + p_days end),
      ('inspection', 'Inspection done and any notice delivered',
        'The contract gives ' || coalesce(i_days, 0) || ' days from acceptance.', 35, case when i_days is not null then a + i_days end),
      ('seller_papers', 'Seller''s papers to title: the letters naming the personal representative, and the will',
        'The house is in a dead owner''s name. Title insures the sale on the court''s letters, and usually wants a fresh certified copy.',
        40, case when probate then a + 5 end),
      ('who_signs', 'Who signs: the estate by its personal representative, and anyone the will leaves the house to',
        'Wis. Stat. 860.11 (2): a personal representative who sells a house the will leaves to a named person needs that person to join the sale. Ask title what they want signed, and get it early.',
        45, case when probate then a + 5 end),
      ('payoff', 'Payoff letter ordered for every loan on the house',
        'Title orders it with the seller''s permission. The payoff, with fees, is what has to fit under the price.', 50, a + 7),
      ('title_back', 'Title search back: read it for liens, judgments and unpaid taxes',
        'Anything recorded against the house or its owner is paid at closing out of the price. If it does not fit, the deal is short.', 60, a + 10),
      ('access', 'Keys and access for the walk-through',
        'The walk-through is the buyer''s only out, and it ends at closing.', 70, greatest(a + 1, least(a + 10, cl - 10))),
      ('walk', 'Walk-through done: go or no go',
        'A no has to be in writing to the seller before closing.', 80, cl - 7),
      ('numbers', 'Closing statement checked against the contract',
        'Price, who pays what, the payoff, the taxes and the seller''s proceeds.', 90, cl - 3),
      ('clear', 'Clear to close, and the money wired to title', 'Call title to confirm wiring instructions by phone before sending anything.', 100, cl - 1),
      ('closing', 'Closing', 'Ticking this closes the deal and the card.', 110, cl)
    ) as x(key, label, why, sort, due_on)
   where x.key not in ('proof', 'inspection', 'seller_papers', 'who_signs') or x.due_on is not null
  on conflict (deal_id, key) do nothing;
  get diagnostics n = row_count;

  perform public.closing_stop_sales(c.lead_id, p_now);
  tid := public.closing_next_task(d.id, p_now);
  return jsonb_build_object('ok', true, 'deal_id', d.id, 'steps_added', n, 'task_id', tid, 'probate', probate);
end $fn$;
revoke all on function public.closing_track_open(uuid, timestamptz) from public, anon, authenticated;
grant execute on function public.closing_track_open(uuid, timestamptz) to service_role;

-- ---------------------------------------------------------------- Colin ticks a step, moves its date, skips it, notes it
create or replace function public.closing_step_set(p_step_id uuid, p_done boolean default null, p_skipped boolean default null,
                                                   p_due date default null, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare s public.closing_steps; who text; all_done boolean;
begin
  if not public.is_owner() then raise exception 'only Colin (owner) works the closing track'; end if;
  select * into s from public.closing_steps where id = p_step_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such step'); end if;
  select display_name into who from public.team_members where lower(email) = lower(auth.jwt() ->> 'email');
  update public.closing_steps set
    done_at = case when p_done is null then done_at when p_done then coalesce(done_at, now()) else null end,
    done_by = case when p_done is null then done_by when p_done then coalesce(done_by, who, 'Colin') else null end,
    skipped = case when p_done is true then false else coalesce(p_skipped, skipped) end,
    due_on = coalesce(p_due, due_on),
    note = case when p_note is null then note else nullif(btrim(p_note), '') end
   where id = p_step_id returning * into s;

  -- the closing itself: ticked, the deal and the card are closed; unticked, they are under contract again
  if s.key = 'closing' and p_done is not null then
    perform set_config('wpie.in_belt_event', '1', true);
    if p_done then
      update public.deals set status = 'closed', close_date = coalesce(close_date, (now() at time zone 'America/Chicago')::date) where id = s.deal_id;
      update public.leads set stage = 'closed_won' where id = s.lead_id and stage = 'under_contract';
      if found then
        insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
        values (s.lead_id, 'stage_set', null, null, 0, jsonb_build_object('from', 'under_contract', 'to', 'closed_won', 'reason', 'closing ticked on the closing track'), now(), coalesce(who, 'Colin'));
      end if;
    else
      update public.deals set status = 'signed_to_title', close_date = null where id = s.deal_id and status = 'closed';
      update public.leads set stage = 'under_contract' where id = s.lead_id and stage = 'closed_won';
      if found then
        insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
        values (s.lead_id, 'stage_set', null, null, 0, jsonb_build_object('from', 'closed_won', 'to', 'under_contract', 'reason', 'closing unticked on the closing track'), now(), coalesce(who, 'Colin'));
      end if;
    end if;
    perform set_config('wpie.in_belt_event', '', true);
  end if;
  perform public.closing_next_task(s.deal_id);
  select not exists (select 1 from public.closing_steps where deal_id = s.deal_id and done_at is null and not skipped) into all_done;
  return jsonb_build_object('ok', true, 'all_done', all_done);
end $fn$;
revoke all on function public.closing_step_set(uuid, boolean, boolean, date, text) from public, anon;
grant execute on function public.closing_step_set(uuid, boolean, boolean, date, text) to authenticated, service_role;

-- a step of Colin's own (a survey, a tenant's keys, a second lien): last on the list unless he dates it
create or replace function public.closing_step_add(p_deal_id uuid, p_label text, p_due date default null) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare d public.deals; sid uuid;
begin
  if not public.is_owner() then raise exception 'only Colin (owner) works the closing track'; end if;
  if nullif(btrim(coalesce(p_label, '')), '') is null then return jsonb_build_object('ok', false, 'reason', 'say what the step is'); end if;
  select * into d from public.deals where id = p_deal_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such deal'); end if;
  insert into public.closing_steps (deal_id, lead_id, key, label, sort, due_on)
  values (d.id, d.lead_id, 'own_' || replace(gen_random_uuid()::text, '-', ''), left(btrim(p_label), 200),
          (select coalesce(max(sort), 100) + 1 from public.closing_steps where deal_id = d.id and key <> 'closing' and sort < 110), p_due)
  returning id into sid;
  perform public.closing_next_task(d.id);
  return jsonb_build_object('ok', true, 'id', sid);
end $fn$;
revoke all on function public.closing_step_add(uuid, text, date) from public, anon;
grant execute on function public.closing_step_add(uuid, text, date) to authenticated, service_role;

-- a deal that died or was closed by hand on the Deal block: its closing task goes with it
create or replace function public.deals_closing_follow() returns trigger language plpgsql security definer set search_path = public as $fn$
begin
  if new.status is distinct from old.status then perform public.closing_next_task(new.id); end if;
  return new;
end $fn$;
drop trigger if exists deals_closing_follow on public.deals;
create trigger deals_closing_follow after update of status on public.deals for each row execute function public.deals_closing_follow();

-- ---------------------------------------------------------------- sealing opens the track (it made one task before)
create or replace function public.contract_sealed(p_id uuid, p_final_path text, p_final_sha256 text, p_now timestamp with time zone default now())
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare c public.contracts; addr text; tid uuid; tr jsonb;
begin
  select * into c from public.contracts where id = p_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such contract'); end if;
  if c.status = 'signed' then return jsonb_build_object('ok', true, 'already', true); end if;
  if c.status <> 'sent' or exists (select 1 from public.contract_signers where contract_id = p_id and signed_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'not everyone has signed');
  end if;
  update public.contracts set status = 'signed', signed_at = p_now, final_path = p_final_path, final_sha256 = p_final_sha256 where id = p_id;
  insert into public.contract_events (contract_id, at, actor, kind, detail)
  values (p_id, p_now, 'system', 'sealed', jsonb_build_object('final_sha256', p_final_sha256));
  if exists (select 1 from public.deals where lead_id = c.lead_id) then
    update public.deals set status = 'signed_to_title', contract_date = coalesce(contract_date, (p_now at time zone 'America/Chicago')::date)
     where id = (select id from public.deals where lead_id = c.lead_id order by created_at desc limit 1);
  else
    insert into public.deals (lead_id, status, contract_date) values (c.lead_id, 'signed_to_title', (p_now at time zone 'America/Chicago')::date);
  end if;
  update public.leads set stage = 'under_contract' where id = c.lead_id;
  select coalesce(property_address, owner_name) into addr from public.leads where id = c.lead_id;
  -- 0253: the closing track, dated from the contract's own terms; its first step is Colin's task
  tr := public.closing_track_open(p_id, p_now);
  tid := nullif(tr->>'task_id', '')::uuid;
  insert into public.messages (lead_id, direction, channel, body, sent_at, status)
  values (c.lead_id, 'out', 'note', format('Offer signed by every seller. Sealed PDF SHA-256 %s.', p_final_sha256), p_now, 'contract');
  return jsonb_build_object('ok', true, 'lead_id', c.lead_id, 'task_id', tid, 'address', addr);
end $function$;

-- ---------------------------------------------------------------- the contracts already signed (not the test cards)
do $$
declare r record; res jsonb;
begin
  for r in select c.id from public.contracts c join public.leads l on l.id = c.lead_id
            where c.status = 'signed' and l.owner_name not ilike 'TEST %' and l.stage = 'under_contract' order by c.signed_at loop
    res := public.closing_track_open(r.id, now());
    raise notice 'closing track: contract % -> %', r.id, res;
  end loop;
end $$;
