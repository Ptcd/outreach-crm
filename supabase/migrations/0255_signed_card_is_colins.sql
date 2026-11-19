-- 0255: a signed card is Colin's.
--
-- Colin 2026-11-19, the morning 991 Howard St had its closing track: "i think it should be in colins tasks now, the
-- card should move to me as my first and currently only card". Until now a card could only be Thalia's or Tyler's:
-- the signed card stayed Tyler's, read "Tyler's card", and sat in nobody's list of Colin's cards.
--
-- Now the signature moves the card to Colin (lock and assignment), the same moment it opens the closing track and
-- stops the selling. One owner end to end still holds (0250), so a card locked to Colin is not shown to a caller:
-- not in a list, not by its address, not through a phone lookup. Its alerts go to the owners only, and the seller's
-- call rings Colin. The caller whose card it was is kept on the deal (deals.caller_was). Colin can hand the card
-- back with card_reassign (the Move control on the card) if a deal falls through.

alter table public.deals add column if not exists caller_was public.team_person;
comment on column public.deals.caller_was is 'The caller whose card this was when the offer was signed (0255). The card itself moves to Colin.';

-- ---------------------------------------------------------------- whose card it is
-- A caller's card: locked to a caller, else (when no owner holds the lock) assigned to one. As 0249, plus: a card an
-- owner holds the lock on has no caller, whatever its assignment says.
create or replace function public.card_caller(p_lead_id uuid) returns public.team_person
language sql stable security definer set search_path = public as $$
  select case
    when exists (select 1 from public.team_members m where m.person = l.locked_to and m.role = 'caller') then l.locked_to
    when exists (select 1 from public.team_members m where m.person = l.locked_to and m.role = 'owner') then null
    when exists (select 1 from public.team_members m where m.person = l.assigned_to and m.role = 'caller') then l.assigned_to
  end
  from public.leads l where l.id = p_lead_id
$$;

-- The owner who holds a card: its lock. Null for a caller's card and for a card nobody holds. An assignment to Colin
-- with no lock (a card nobody has yet) is still nobody's card, seen by both callers, as before.
create or replace function public.card_owner_person(p_lead_id uuid) returns public.team_person
language sql stable security definer set search_path = public as $$
  select case when exists (select 1 from public.team_members m where m.person = l.locked_to and m.role = 'owner') then l.locked_to end
  from public.leads l where l.id = p_lead_id
$$;
revoke all on function public.card_owner_person(uuid) from public, anon;
grant execute on function public.card_owner_person(uuid) to authenticated, service_role;

-- Whose LOCK a caller login does not see past: the other caller's (0250), and now an owner's. caller_blind_to() stays
-- as it was and still answers for the assignment, so a card assigned to Colin with no lock is not hidden.
create or replace function public.caller_blind_locks() returns public.team_person[]
language sql stable security definer set search_path = public as $$
  select case when public.wpie_role()::text = 'caller'
    then coalesce((select array_agg(m.person) from public.team_members m
                    where m.role in ('caller', 'owner') and m.person is not null and m.person is distinct from public.wpie_person()), '{}'::public.team_person[])
    else '{}'::public.team_person[] end
$$;
grant execute on function public.caller_blind_locks() to anon, authenticated, service_role;

-- the card's read rules, and every list and lookup that leaves out the other caller's cards: the lock test asks the
-- new function. The functions are rewritten in place (each has exactly one lock test, written the same way in 0250).
do $$
declare p record; f record; n integer := 0;
begin
  for p in select policyname from pg_policies where schemaname = 'public' and tablename = 'leads' and qual like '%caller_blind_to%' loop
    execute format($f$alter policy %I on public.leads using (public.is_team() and not (
      coalesce(locked_to = any ((select public.caller_blind_locks())::public.team_person[]), false)
      or (locked_to is distinct from (select public.wpie_person()) and coalesce(assigned_to = any ((select public.caller_blind_to())::public.team_person[]), false))))$f$, p.policyname);
    n := n + 1;
  end loop;
  if n <> 2 then raise exception '0255: expected the two card read rules, found %', n; end if;
  n := 0;
  for f in select pr.proname, pg_get_functiondef(pr.oid) as def from pg_proc pr join pg_namespace ns on ns.oid = pr.pronamespace
            where ns.nspname = 'public' and pr.prokind = 'f' and pr.prosrc like '%locked_to = any ((select public.caller_blind_to())%' order by pr.proname loop
    execute replace(f.def, 'locked_to = any ((select public.caller_blind_to())', 'locked_to = any ((select public.caller_blind_locks())');
    n := n + 1;
  end loop;
  if n <> 7 then raise exception '0255: expected 7 lists and lookups with a lock test, found %', n; end if;
end $$;

create or replace function public.card_not_yours(p_lead_id uuid, p_now timestamptz default now()) returns text
language plpgsql stable security definer set search_path = public as $$
declare me public.team_person := public.wpie_person(); cc public.team_person; op public.team_person; nm text;
begin
  if coalesce(public.wpie_role()::text, '') <> 'caller' or me is null or p_lead_id is null then return null; end if;
  cc := public.card_caller(p_lead_id);
  if cc = me then return null; end if;
  if cc is not null then
    select coalesce(nullif(btrim(m.display_name), ''), initcap(cc::text)) into nm from public.team_members m where m.person = cc limit 1;
    nm := coalesce(nm, initcap(cc::text));
    return 'This is ' || nm || '''s card. Only ' || nm || ' and Colin see it or work it.';
  end if;
  op := public.card_owner_person(p_lead_id);
  if op is null then return null; end if;
  select coalesce(nullif(btrim(m.display_name), ''), initcap(op::text)) into nm from public.team_members m where m.person = op limit 1;
  nm := coalesce(nm, initcap(op::text));
  return 'This is ' || nm || '''s card. Only ' || nm || ' sees it or works it.';
end $$;

-- who is told about a card: its caller and the owners; an owner's card, the owners only; nobody's card, everyone
create or replace function public.card_tell(p_lead_id uuid, p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare cc public.team_person; people text[];
begin
  if p_lead_id is null then return jsonb_build_object('everyone', true); end if;
  cc := public.card_caller(p_lead_id);
  if cc is null and public.card_owner_person(p_lead_id) is null then return jsonb_build_object('everyone', true); end if;
  select coalesce(array_agg(distinct x.person), '{}') into people from (
    select m.person::text as person from public.team_members m where m.role = 'owner'
    union all select cc::text) x where x.person is not null;
  return jsonb_build_object('everyone', false, 'card_caller', cc::text, 'people', to_jsonb(people));
end $$;

-- ---------------------------------------------------------------- the signature moves the card
create or replace function public.closing_card_to_colin(p_lead_id uuid, p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare l public.leads; was public.team_person; was_name text;
begin
  select * into l from public.leads where id = p_lead_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card'); end if;
  if l.locked_to = 'colin' and l.assigned_to = 'colin' then return jsonb_build_object('ok', true, 'already', true); end if;
  was := public.card_caller(p_lead_id);
  update public.leads set locked_to = 'colin', locked_at = p_now, assigned_to = 'colin',
         human_takeover_assigned_to = case when public.is_caller_person(human_takeover_assigned_to) then 'colin' else human_takeover_assigned_to end
   where id = p_lead_id;
  if was is not null then
    update public.deals set caller_was = was
     where id = (select id from public.deals where lead_id = p_lead_id order by created_at desc limit 1) and caller_was is null;
    select coalesce(nullif(btrim(m.display_name), ''), initcap(was::text)) into was_name from public.team_members m where m.person = was limit 1;
  end if;
  insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
  values (p_lead_id, 'reassigned', l.belt, l.belt, l.belt_step,
          jsonb_build_object('from', coalesce(was::text, l.locked_to::text), 'to', 'colin', 'why', 'the offer is signed: the card is Colin''s through closing'), p_now, 'system');
  insert into public.messages (lead_id, direction, channel, body, status, sent_at)
  values (p_lead_id, 'out', 'note', 'Card moved to Colin' || coalesce(' from ' || was_name, '') || ': the offer is signed.', null, p_now);
  return jsonb_build_object('ok', true, 'from', was, 'to', 'colin');
end $fn$;
revoke all on function public.closing_card_to_colin(uuid, timestamptz) from public, anon, authenticated;
grant execute on function public.closing_card_to_colin(uuid, timestamptz) to service_role;

-- stopping the selling (0253) now ends by handing the card over
create or replace function public.closing_stop_sales(p_lead_id uuid, p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare l public.leads; n_tasks integer := 0; n_drafts integer := 0; moved jsonb;
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
  moved := public.closing_card_to_colin(p_lead_id, p_now);   -- 0255: the card is Colin's from here
  perform set_config('wpie.in_belt_event', '', true);
  return jsonb_build_object('ok', true, 'tasks_closed', n_tasks, 'texts_withdrawn', n_drafts, 'card', moved);
end $fn$;
revoke all on function public.closing_stop_sales(uuid, timestamptz) from public, anon, authenticated;
grant execute on function public.closing_stop_sales(uuid, timestamptz) to service_role;

-- ---------------------------------------------------------------- the seller's call rings the card's owner
-- As 0201, with one change: a card locked to Colin rings Colin, the way a caller's card rings its caller.
create or replace function public.inbound_call_ring(p_digits text, p_at timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public as $function$
  with d as (select right(regexp_replace(coalesce(p_digits, ''), '\D', '', 'g'), 10) as ph),
  last_dialer as (
    select lower(e.by) as who from public.belt_events e, d
     where e.event = 'human_call_started' and e.at > p_at - interval '60 minutes' and e.at <= p_at
       and right(regexp_replace(coalesce(e.payload->>'phone', ''), '\D', '', 'g'), 10) = d.ph and d.ph <> ''
       and lower(e.by) in ('thalia', 'adil', 'colin')
     order by e.at desc limit 1),
  card as (
    select l.id, l.owner_name, l.property_address, l.municipality, l.locked_to::text as who
      from public.contacts c join public.leads l on l.id = c.lead_id, d
     where c.kind = 'phone' and c.value_normalized = d.ph and d.ph <> ''
     order by (l.locked_to is not null) desc, l.locked_at desc nulls last limit 1),
  locked as (select who from card where who in ('thalia', 'adil', 'colin')),
  shift as (select public.on_shift_person(p_at)::text as who,
                   extract(isodow from p_at at time zone 'America/Chicago') between 1 and 5
                   and (p_at at time zone 'America/Chicago')::time >= time '16:00' and (p_at at time zone 'America/Chicago')::time < time '18:00' as power_hour),
  ring as (
    select case
      when (select who from last_dialer) is not null and (select who from locked) is distinct from 'colin' then array[(select who from last_dialer)]
      when (select who from locked) is not null then array[(select who from locked)]
      when (select power_hour from shift) then array['thalia', 'adil']
      when (select who from shift) = 'colin' then array['colin', 'thalia', 'adil']
      else array[(select who from shift)] end as who)
  select jsonb_build_object(
    'ring', to_jsonb((select who from ring)),
    'return_call', (select who from last_dialer) is not null and (select who from locked) is distinct from 'colin',
    'locked_to', (select who from locked),
    'dialed_by', (select who from last_dialer),
    'whatsapp', (select coalesce(jsonb_object_agg(m.person::text, m.alert_whatsapp), '{}'::jsonb)
                   from public.team_members m where m.person::text in (select unnest(r.who) from ring r) and m.alert_whatsapp is not null),
    'card', (select jsonb_build_object('lead_id', c.id, 'owner_name', c.owner_name, 'address', c.property_address, 'municipality', c.municipality) from card c))
$function$;

-- ---------------------------------------------------------------- the cards already under contract (not the test cards)
do $$
declare r record; res jsonb;
begin
  for r in select distinct l.id from public.contracts c join public.leads l on l.id = c.lead_id
            where c.status = 'signed' and l.owner_name not ilike 'TEST %' and l.stage = 'under_contract' loop
    res := public.closing_card_to_colin(r.id, now());
    raise notice 'signed card to Colin: % -> %', r.id, res;
  end loop;
end $$;
