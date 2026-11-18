-- 0250: a card has one owner, end to end, and the other caller never sees it.
--
-- Colin 2026-11-17, an hour after 0249: "Cards should have one fucking owner end to end the other caller shouldn't see
-- it". 0249 sent a card's alerts to its caller and refused the other caller's text and dial, but it left two ways in
-- that I had added myself (the card's caller is off today; the other caller holds a task on the card), it left the
-- database answering any caller about any card, and 33 cards carried two callers' names (locked to one, assigned to
-- the other, or with the other's task on them). All of that goes:
--   * No exceptions. A card is its caller's on their day off too. To have someone else work it, Colin moves it.
--   * One owner. On a card, the lock, the assignment and every open caller task name the same caller. Triggers keep it
--     so, whatever writes the row (the laptop's daily call list gave Thalia 31 calls on Tyler's cards this morning).
--   * The database hides it. A caller login cannot read another caller's card or anything that hangs off it (texts,
--     phones, tasks, notes, calls, offers): the read rules themselves, not only the page.
--   * Every list a caller reads leaves the other caller's cards out on the server, and every card action a caller login
--     can run refuses on a card that is not theirs.
--   * A card a caller makes (a new caller on the phone, a card from a text) is theirs.
-- Colin and Muse (owners) and the system see and do everything, as before. Nothing here touches a seller.

-- the callers whose cards the person on this login does not see: for a caller, every other caller; for anyone else, nobody
create or replace function public.caller_blind_to() returns public.team_person[]
language sql stable security definer set search_path = public as $$
  select case when public.wpie_role()::text = 'caller'
    then coalesce((select array_agg(m.person) from public.team_members m
                    where m.role = 'caller' and m.person is not null and m.person is distinct from public.wpie_person()), '{}'::public.team_person[])
    else '{}'::public.team_person[] end
$$;
grant execute on function public.caller_blind_to() to anon, authenticated, service_role;

create or replace function public.is_caller_person(p public.team_person) returns boolean
language sql stable security definer set search_path = public as $$
  select p is not null and exists (select 1 from public.team_members m where m.person = p and m.role = 'caller')
$$;
revoke all on function public.is_caller_person(public.team_person) from public, anon;
grant execute on function public.is_caller_person(public.team_person) to authenticated, service_role;

-- Null when the person on this login may see and work the card; otherwise the words that say whose it is. No exceptions.
create or replace function public.card_not_yours(p_lead_id uuid, p_now timestamptz default now()) returns text
language plpgsql stable security definer set search_path = public as $$
declare me public.team_person := public.wpie_person(); cc public.team_person; nm text;
begin
  if coalesce(public.wpie_role()::text, '') <> 'caller' or me is null or p_lead_id is null then return null; end if;
  cc := public.card_caller(p_lead_id);
  if cc is null or cc = me then return null; end if;
  select coalesce(nullif(btrim(m.display_name), ''), initcap(cc::text)) into nm from public.team_members m where m.person = cc limit 1;
  nm := coalesce(nm, initcap(cc::text));
  return 'This is ' || nm || '''s card. Only ' || nm || ' and Colin see it or work it.';
end $$;

-- the first statement of every card action a caller login can run
create or replace function public.card_guard(p_lead_id uuid) returns void
language plpgsql stable security definer set search_path = public as $$
declare nope text := public.card_not_yours(p_lead_id);
begin
  if nope is not null then raise exception '%', nope; end if;
end $$;
revoke all on function public.card_guard(uuid) from public, anon;
grant execute on function public.card_guard(uuid) to authenticated, service_role;

-- Who is told about a card: everyone when it has no caller; otherwise its caller and the owners. Nobody covers.
create or replace function public.card_tell(p_lead_id uuid, p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare cc public.team_person; people text[];
begin
  if p_lead_id is null then return jsonb_build_object('everyone', true); end if;
  cc := public.card_caller(p_lead_id);
  if cc is null then return jsonb_build_object('everyone', true); end if;
  select coalesce(array_agg(distinct x.person), '{}') into people from (
    select m.person::text as person from public.team_members m where m.role = 'owner'
    union all select cc::text) x where x.person is not null;
  return jsonb_build_object('everyone', false, 'card_caller', cc::text, 'people', to_jsonb(people));
end $$;

-- ---------------------------------------------------------------- one owner
-- lock and assignment never name two different callers
create or replace function public.leads_one_owner() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.locked_to is distinct from new.assigned_to and public.is_caller_person(new.locked_to) and public.is_caller_person(new.assigned_to) then
    -- a call in progress keeps its authorization (begin_human_call compares the two)
    if new.human_takeover_assigned_to is not distinct from new.assigned_to then new.human_takeover_assigned_to := new.locked_to; end if;
    new.assigned_to := new.locked_to;
  end if;
  return new;
end $$;
drop trigger if exists leads_one_owner on public.leads;
create trigger leads_one_owner before insert or update of locked_to, assigned_to on public.leads
  for each row execute function public.leads_one_owner();

-- a caller's open task on a card belongs to the card's caller, whoever wrote it
create or replace function public.task_owner_is_card_owner() returns trigger
language plpgsql security definer set search_path = public as $$
declare cc public.team_person;
begin
  if new.lead_id is null or new.done_at is not null or not public.is_caller_person(new.owner) then return new; end if;
  cc := public.card_caller(new.lead_id);
  if cc is not null and cc <> new.owner then new.owner := cc; end if;
  return new;
end $$;
drop trigger if exists tasks_owner_is_card_owner on public.tasks;
create trigger tasks_owner_is_card_owner before insert or update of owner, lead_id on public.tasks
  for each row execute function public.task_owner_is_card_owner();

-- when a card moves, its open caller tasks go with it
create or replace function public.tasks_follow_lock() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.locked_to is distinct from old.locked_to and public.is_caller_person(new.locked_to) then
    update public.tasks t set owner = new.locked_to, updated_at = now()
     where t.lead_id = new.id and t.done_at is null and t.owner <> new.locked_to and public.is_caller_person(t.owner);
  end if;
  return null;
end $$;
drop trigger if exists leads_tasks_follow_lock on public.leads;
create trigger leads_tasks_follow_lock after update of locked_to on public.leads
  for each row execute function public.tasks_follow_lock();

-- the cards and tasks that carried two names on 2026-11-17 (33 cards, 33 open tasks)
update public.leads l set assigned_to = l.locked_to
 where l.locked_to is distinct from l.assigned_to and public.is_caller_person(l.locked_to) and public.is_caller_person(l.assigned_to);
update public.tasks t set owner = public.card_caller(t.lead_id), updated_at = now()
 where t.done_at is null and t.lead_id is not null and public.is_caller_person(t.owner)
   and public.card_caller(t.lead_id) is not null and public.card_caller(t.lead_id) <> t.owner;

-- ---------------------------------------------------------------- the database hides it
-- The card: a caller login reads and updates only cards that are not another caller's. Everything that hangs off a
-- card (any table with a lead_id whose rule was "the team"): only rows of a card that login can read.
do $$
declare p record;
begin
  for p in select policyname from pg_policies
            where schemaname = 'public' and tablename = 'leads' and cmd in ('SELECT', 'UPDATE') and qual = 'is_team()' loop
    execute format($f$alter policy %I on public.leads using (public.is_team() and not (
      coalesce(locked_to = any ((select public.caller_blind_to())::public.team_person[]), false)
      or (locked_to is distinct from (select public.wpie_person()) and coalesce(assigned_to = any ((select public.caller_blind_to())::public.team_person[]), false))))$f$, p.policyname);
  end loop;
  for p in select pol.tablename, pol.policyname from pg_policies pol
            where pol.schemaname = 'public' and pol.tablename <> 'leads' and pol.cmd in ('SELECT', 'UPDATE', 'DELETE') and pol.qual = 'is_team()'
              and exists (select 1 from information_schema.columns c
                           where c.table_schema = 'public' and c.table_name = pol.tablename and c.column_name = 'lead_id' and c.data_type = 'uuid') loop
    execute format('alter policy %I on public.%I using (public.is_team() and (lead_id is null or exists (select 1 from public.leads l where l.id = %I.lead_id)))',
                   p.policyname, p.tablename, p.tablename);
  end loop;
end $$;

-- ---------------------------------------------------------------- the lists a caller reads
-- Each as it stood live on 2026-11-17, with the one line that leaves out the other caller's cards.

CREATE OR REPLACE FUNCTION public.texts_live(p_hours integer DEFAULT 48, p_limit integer DEFAULT 80)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
  with recent as (
    select t.from10 as phone10, max(t.received_at) as last_in_at
      from public.twilio_inbound t
     where t.received_at > now() - make_interval(hours => greatest(1, least(coalesce(p_hours, 48), 24 * 14)))
     group by t.from10
     order by max(t.received_at) desc
     limit greatest(1, least(coalesce(p_limit, 80), 300))),
  last_in as (
    select distinct on (t.from10) t.from10 as phone10, t.sid, t.body, t.received_at, t.is_opt_out, t.lead_id
      from public.twilio_inbound t join recent r on r.phone10 = t.from10
     order by t.from10, t.received_at desc),
  outs as (
    select d.phone10, d.sent_body as body, d.sent_at as at, coalesce(nullif(d.decided_by, ''), 'automation') as by, 0 as src
      from public.reply_drafts d join recent r on r.phone10 = d.phone10 where d.status = 'sent' and d.sent_at is not null
    union all
    select right(regexp_replace(coalesce(m.to_number, ''), '\D', '', 'g'), 10), m.body, m.sent_at, case when m.is_opener then 'first text' else 'automation' end, 1 as src
      from public.messages m join recent r on r.phone10 = right(regexp_replace(coalesce(m.to_number, ''), '\D', '', 'g'), 10)
     where m.direction = 'out' and m.channel = 'sms' and m.provider_sid is not null and m.sent_at is not null),
  last_out as (select distinct on (phone10) phone10, body, at, by from outs order by phone10, at desc, src)
  select coalesce(jsonb_agg(jsonb_build_object(
      'phone10', li.phone10, 'lead_id', coalesce(li.lead_id, o.lead_id), 'owner_name', l.owner_name, 'address', l.property_address,
      'municipality', l.municipality, 'stage', l.stage, 'hot', l.hot_at is not null,
      'last_in', jsonb_build_object('body', li.body, 'at', li.received_at, 'opt_out', li.is_opt_out),
      'last_out', case when lo.phone10 is null then null else jsonb_build_object('body', lo.body, 'at', lo.at, 'by', lo.by) end,
      'unanswered', lo.at is null or lo.at < li.received_at,
      'owner', o.person, 'owned_at', o.taken_at,
      'intent', th.intent, 'outcome', th.outcome, 'agent_stage', th.agent_stage, 'callback_slot', th.callback_slot)
      order by li.received_at desc), '[]'::jsonb)
    from last_in li
    left join last_out lo on lo.phone10 = li.phone10
    left join public.thread_owners o on o.phone10 = li.phone10
    left join public.leads l on l.id = coalesce(li.lead_id, o.lead_id)
    left join public.reply_threads th on th.phone10 = li.phone10
   where public.is_team() and coalesce(l.owner_name, '') not ilike 'TEST %'
     and not (coalesce(l.locked_to = any ((select public.caller_blind_to())::public.team_person[]), false) or (l.locked_to is distinct from (select public.wpie_person()) and coalesce(l.assigned_to = any ((select public.caller_blind_to())::public.team_person[]), false)))
$fn$;

CREATE OR REPLACE FUNCTION public.missed_calls_recent(p_hours integer DEFAULT 48)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
  select coalesce(jsonb_agg(jsonb_build_object(
      'call_sid', ic.call_sid, 'at', ic.created_at, 'phone', ic.from10, 'status', ic.status, 'voicemail', ic.voicemail,
      'words', nullif(substring(m.body from 'Voicemail: "(.*)"'), ''),
      'verdict', ic.vm_verdict, 'verdict_reason', ic.vm_reason,
      'lead_id', l.id, 'owner_name', l.owner_name, 'property_address', l.property_address, 'municipality', l.municipality, 'stage', l.stage,
      'closed', l.stage::text in ('dnc', 'dead', 'closed_no_contact') or exists (select 1 from public.suppressed_phones s where s.phone10 = ic.from10),
      'card_closed', l.stage::text in ('dnc', 'dead', 'closed_no_contact'),
      'phone_blocked', exists (select 1 from public.suppressed_phones s where s.phone10 = ic.from10),
      'called_back', exists (select 1 from public.messages o where o.lead_id = ic.lead_id and o.channel = 'call' and o.sent_at > ic.created_at
                               and coalesce(o.status, '') not like 'inbound%'))
    order by ic.created_at desc), '[]'::jsonb)
    from public.inbound_calls ic
    left join public.leads l on l.id = ic.lead_id
    left join public.messages m on m.id = ic.message_id
   where (public.is_team() or auth.uid() is null)
     and not (coalesce(l.locked_to = any ((select public.caller_blind_to())::public.team_person[]), false) or (l.locked_to is distinct from (select public.wpie_person()) and coalesce(l.assigned_to = any ((select public.caller_blind_to())::public.team_person[]), false)))
     and ic.created_at > now() - make_interval(hours => greatest(1, least(p_hours, 336)))
     and (ic.status in ('missed', 'blocked', 'no_answer', 'busy', 'failed') or ic.voicemail)
$fn$;

CREATE OR REPLACE FUNCTION public.packages_open()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
  select coalesce(jsonb_agg(jsonb_build_object(
      'package', to_jsonb(d) - 'comps', 'comps', d.comps,
      'lead', jsonb_build_object('id', l.id, 'owner_name', l.owner_name, 'property_address', l.property_address, 'municipality', l.municipality,
                                 'property_zip', l.property_zip, 'property_type', l.property_type, 'units', l.units),
      'person', (select pe.name from public.interests i join public.people pe on pe.id = i.person_id where i.id = d.interest_id),
      'late', case
        when d.status in ('waiting_value', 'waiting_number')
             and now() > (((d.created_at at time zone 'America/Chicago')::date + time '18:00') at time zone 'America/Chicago') then 'Colin: walk it or pass, today'
        when d.status = 'go_walk' and d.callback_at is not null and now() > d.callback_at + interval '30 minutes' then 'callback is late' end)
    order by d.created_at), '[]'::jsonb)
    from public.deal_packages d join public.leads l on l.id = d.lead_id
   where (public.is_team() or auth.uid() is null) and not (coalesce(l.locked_to = any ((select public.caller_blind_to())::public.team_person[]), false) or (l.locked_to is distinct from (select public.wpie_person()) and coalesce(l.assigned_to = any ((select public.caller_blind_to())::public.team_person[]), false)))
     and d.status in ('waiting_value', 'waiting_number', 'go_walk', 'number_ready', 'counter', 'agreed')
$fn$;

CREATE OR REPLACE FUNCTION public.phone_lookup(p_digits text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
declare d text := regexp_replace(coalesce(p_digits, ''), '\D', '', 'g'); out jsonb;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  if length(d) > 10 then d := right(d, 10); end if;
  if length(d) < 3 then return '[]'::jsonb; end if;
  select coalesce(jsonb_agg(x order by x->>'exact' desc, x->>'owner_name'), '[]'::jsonb) into out from (
    select distinct on (l.id) jsonb_build_object(
      'lead_id', l.id, 'owner_name', l.owner_name, 'property_address', l.property_address, 'municipality', l.municipality,
      'lane', l.lane, 'stage', l.stage, 'phone', c.value_normalized, 'person_name', c.person_name,
      'blocked', c.suppressed or c.dnc_app or c.dnc_vendor or l.stage = 'dnc', 'exact', c.value_normalized = d) as x
    from public.contacts c join public.leads l on l.id = c.lead_id
    where c.kind = 'phone' and c.value_normalized is not null
      and not (coalesce(l.locked_to = any ((select public.caller_blind_to())::public.team_person[]), false) or (l.locked_to is distinct from (select public.wpie_person()) and coalesce(l.assigned_to = any ((select public.caller_blind_to())::public.team_person[]), false)))
      and (case when length(d) = 4 then right(c.value_normalized, 4) = d else c.value_normalized like '%' || d end)
    order by l.id, (c.value_normalized = d) desc
    limit 50
  ) s;
  return out;
end $fn$;

CREATE OR REPLACE FUNCTION public.warm_board(p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
begin
  if not public.is_team() then raise exception 'not on the team'; end if;
  return coalesce((
    select jsonb_agg(row_to_json(x)::jsonb order by x.sort_at nulls last)
    from (
      select l.id, l.owner_name, l.property_address, l.municipality, l.county, l.belt, l.stage::text as stage,
             l.belt_step, l.next_stop_at, l.next_stop_who, l.next_stop_say, l.named_date, l.named_event,
             l.assigned_to::text as assigned_to, l.hot_at, l.human_takeover_at, l.human_takeover_by, l.call_facts,
             l.elderly_or_ill, l.grief,
             coalesce((select jsonb_object_agg(k, v) from (
                 select distinct on (e.key) e.key as k, e.value as v
                   from public.reply_drafts d, jsonb_each(d.facts) e
                  where d.lead_id = l.id and d.facts is not null and jsonb_typeof(d.facts) = 'object'
                  order by e.key, d.inbound_at desc) f), '{}'::jsonb) as facts,
             li.body as last_in_body, li.received_at as last_in_at,
             (select max(m.sent_at) from public.messages m where m.lead_id = l.id and m.direction = 'out') as last_out_at,
             (select count(*) from public.twilio_inbound t where t.lead_id = l.id) as replies,
             g.grp, g.why,
             case g.grp when 'booked' then coalesce(l.named_date, l.next_stop_at) else coalesce(l.next_stop_at, l.named_date) end as sort_at
        from public.leads l
        left join lateral (select t.body, t.received_at from public.twilio_inbound t where t.lead_id = l.id
                            order by t.received_at desc limit 1) li on true
        cross join lateral (select
          case
            when l.human_takeover_at is not null then 'decide'
            when l.next_stop_who in ('thalia_call', 'colin_call', 'colin_visit') and l.next_stop_at < p_now - interval '1 day' then 'decide'
            when l.next_stop_at is null and l.belt not in ('too_high_or_listed', 'dormant') then 'decide'
            when l.belt in ('yes_unbooked', 'call_missed', 'visit_missed', 'after_call_quiet') then 'hot'
            when l.belt in ('call_booked', 'visit_booked', 'offer_out') then 'booked'
            when l.belt in ('replied_quiet', 'questions_quiet') then 'talking'
            when l.belt = 'not_now_dated' then 'callback'
            else 'nurture' end as grp,
          case
            when l.human_takeover_at is not null then 'A call was started ' || to_char(l.human_takeover_at at time zone 'America/Chicago', 'Dy FMHH12:MI AM') || ' and never logged'
            when l.next_stop_who in ('thalia_call', 'colin_call', 'colin_visit') and l.next_stop_at < p_now - interval '1 day' then 'The call is more than a day overdue'
            when l.next_stop_at is null and l.belt not in ('too_high_or_listed', 'dormant') then 'No next step on this card'
          end as why) g
       where l.belt is not null and l.belt not in ('cold_texts', 'dead', 'dnc')
         and not (coalesce(l.locked_to = any ((select public.caller_blind_to())::public.team_person[]), false) or (l.locked_to is distinct from (select public.wpie_person()) and coalesce(l.assigned_to = any ((select public.caller_blind_to())::public.team_person[]), false)))
         and l.stage not in ('dnc', 'dead', 'closed_no_contact', 'closed_won')
         and (l.belt <> 'dormant' or exists (select 1 from public.twilio_inbound t where t.lead_id = l.id))
    ) x), '[]'::jsonb);
end $fn$;

CREATE OR REPLACE FUNCTION public.my_piles(p_person team_person DEFAULT NULL::team_person)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
declare who public.team_person; eod timestamptz; res jsonb;
begin
  if not public.is_team() then raise exception 'only the team'; end if;
  who := coalesce(p_person, public.wpie_person());
  if who is distinct from public.wpie_person()
     and coalesce((select role::text from public.team_members where person = public.wpie_person() limit 1), '') <> 'owner' then
    who := public.wpie_person();
  end if;
  eod := (date_trunc('day', now() at time zone 'America/Chicago') + interval '1 day') at time zone 'America/Chicago';
  with ppl as (
    select tm.person, u.id uid from public.team_members tm join auth.users u on lower(u.email) = tm.email where tm.person = who
  ), mine as (
    select id lead_id, 'your card' why from public.leads where locked_to = who
    union select id, 'assigned' from public.leads where assigned_to = who
    union select id, 'took the texts' from public.leads where human_takeover_assigned_to = who or lower(coalesce(human_takeover_by, '')) = who::text
    union select lead_id, 'built the package' from public.deal_packages where created_by = who
    union select m.lead_id, 'logged a call' from public.messages m join ppl on ppl.uid = m.created_by where m.channel = 'call' and m.lead_id is not null
    union select lead_id, 'call on their list' from public.tasks
           where owner = who and done_at is null and lead_id is not null and coalesce(source, '') not in ('power_hour', 'power_hour_after')
  ), cards as (
    select l.id, l.owner_name, l.property_address, l.municipality, l.county, l.stage::text stage, l.belt, l.next_stop_at, l.next_stop_say,
           l.named_date, l.named_event, l.hot_at, l.locked_to,
           l.lane, l.say_next, l.reasons_to_sell, l.rest_until, l.parked_at, l.parked_why, l.next_stop_who,
           (select string_agg(c3.value_normalized, ' ') from public.contacts c3 where c3.lead_id = l.id and c3.kind = 'phone') phones,
           (select count(*) from public.messages mt where mt.lead_id = l.id and mt.channel in ('call', 'sms')) touches,
           (select left(mi.body, 160) from public.messages mi where mi.lead_id = l.id and mi.direction = 'in' and mi.channel = 'sms' order by mi.sent_at desc limit 1) last_words,
           (select left(coalesce(nz.note, nz.title), 200) from public.tasks nz where nz.lead_id = l.id and nz.kind = 'nudge' and nz.owner = who and nz.done_at is null order by nz.created_at desc limit 1) nudge,
           (select left(coalesce(pm.note, ''), 200) from public.tasks pm where pm.lead_id = l.id and pm.source = 'mine' and pm.owner = who and pm.done_at is null order by pm.due_at limit 1) promise,
           (select string_agg(distinct m2.why, ', ') from mine m2 where m2.lead_id = l.id) why,
           t.id task_id, t.due_at task_due, t.kind task_kind, t.source task_source, coalesce(t.title, left(t.note, 140)) task_what,
           pk.status pkg,
           (l.human_takeover_assigned_to = who
            or exists (select 1 from public.deal_packages d2 where d2.lead_id = l.id)
            or exists (select 1 from public.messages m3 where m3.lead_id = l.id and m3.channel = 'call'
                        and m3.status in ('interested', 'reached_no_decision', 'not_now', 'inbound_answered'))
            or l.stage in ('reply_received', 'ai_qualifying', 'handoff', 'colin_call', 'walk_decision', 'human_owned')) talked,
           lm.tier,
           (lc.sent_at is not null) dialed,
           lc.sent_at last_call_at, left(regexp_replace(coalesce(lc.body, ''), '^Call \([^)]*\) from \d+:\s*', ''), 220) last_call
      from public.leads l
      left join public.lead_motivation lm on lm.lead_id = l.id
      left join lateral (select x.* from public.tasks x where x.lead_id = l.id and x.owner = who and x.done_at is null
                          order by x.due_at nulls last limit 1) t on true
      left join lateral (select d.status from public.deal_packages d where d.lead_id = l.id order by d.created_at desc limit 1) pk on true
      left join lateral (select mm.sent_at, mm.body from public.messages mm where mm.lead_id = l.id and mm.channel = 'call' and mm.status is distinct from 'inbound_missed'
                          order by mm.sent_at desc limit 1) lc on true
     where l.id in (select lead_id from mine)
       and not (coalesce(l.locked_to = any ((select public.caller_blind_to())::public.team_person[]), false) or (l.locked_to is distinct from (select public.wpie_person()) and coalesce(l.assigned_to = any ((select public.caller_blind_to())::public.team_person[]), false)))
       -- a card Colin parked is hidden; a card the caller rested (rest_until) stays, in the Resting pile until it wakes (0186)
       and (l.parked_at is null or l.rest_until is not null)
  ), piled as (
    select c.*,
      case
        when c.stage in ('dead', 'dnc', 'closed_won', 'closed_no_contact', 'mail_only') then 'closed'
        when c.parked_at is not null and c.rest_until > now() then 'resting'
        when c.task_due is not null and c.task_due < eod then 'call_now'
        when c.belt in ('call_booked', 'visit_booked', 'visit_missed', 'call_missed', 'offer_out') or c.stage in ('walkthrough_booked', 'offer', 'under_contract')
             or (c.hot_at is not null and c.hot_at > now() - interval '14 days') then 'booked'
        when c.pkg in ('waiting_value', 'waiting_number', 'counter') then 'colin'
        when c.task_due is not null and c.task_due < now() + interval '7 days' then 'this_week'
        when c.task_due is not null or (c.next_stop_at is not null and c.next_stop_at > now())
             or c.belt in ('not_now_dated', 'not_now_condition', 'needs_family', 'elderly', 'estate_waiting', 'hold_not_now', 'dormant', 'too_high_or_listed') then 'later'
        when c.talked then 'no_step'
        when c.dialed then 'tried'
        else 'not_called'
      end pile,
      coalesce(c.task_due, case when c.next_stop_at > now() then c.next_stop_at end, case when c.named_date > now() then c.named_date end) next_at
    from cards c
  )
  select jsonb_build_object('person', who, 'cards', coalesce(jsonb_agg(jsonb_build_object(
           'lead_id', id, 'owner_name', owner_name, 'address', property_address, 'municipality', municipality, 'county', county,
           'stage', stage, 'belt', belt, 'pile', pile, 'next_at', next_at,
           'next_what', coalesce(task_what, case when next_stop_at > now() then next_stop_say end),
           'last_call_at', last_call_at, 'last_call', nullif(last_call, ''), 'why', why, 'locked_to', locked_to, 'tier', tier,
           'task_id', task_id, 'task_kind', task_kind, 'task_source', task_source,
           'lane', lane, 'say_next', say_next, 'reasons', reasons_to_sell, 'phones', phones, 'touches', touches, 'last_words', last_words,
           'nudge', nudge, 'promise', promise, 'rest_until', case when parked_at is not null then rest_until end, 'rest_why', case when parked_at is not null then parked_why end,
           'next_plain', public.next_plain(belt, next_stop_at, next_stop_who, next_stop_say, named_date, named_event, who),
           'walk_at', case when belt in ('visit_booked', 'call_booked') or stage = 'walkthrough_booked' then named_date end, 'named_event', named_event, 'hot_at', hot_at)
         order by array_position(array['call_now','booked','colin','this_week','later','no_step','tried','not_called','resting','closed'], pile),
                  case when pile in ('no_step', 'tried', 'not_called') then null else next_at end nulls last,
                  case when pile = 'not_called' then coalesce(tier, 'Z') end, last_call_at desc nulls last), '[]'::jsonb))
    into res from piled;
  return res;
end $fn$;

CREATE OR REPLACE FUNCTION public.power_dial_queue(p_limit integer DEFAULT 80, p_now timestamp with time zone DEFAULT now(), p_test boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
  with me as (select public.is_team() as ok),
  today as (select (p_now at time zone 'America/Chicago')::date as d),
  -- the phones a person's status blocks (phone_person_block, 0084), computed once for the whole queue instead of once
  -- per contact per card: as a per-row call it stopped using the index and the queue took minutes (2026-10-29)
  blocked as (
    select distinct c.value_normalized as ph from public.contacts c join public.people pe on pe.id = c.person_id
     where pe.status = 'do_not_contact'
        or (pe.status = 'deceased' and not exists (select 1 from public.contacts c2 join public.people p2 on p2.id = c2.person_id
                                                    where c2.value_normalized = c.value_normalized and p2.status = 'active'))),
  dialed as (
    select m.lead_id, count(*) filter (where m.sent_at > p_now - interval '7 days') as dials_7d, count(*) as dials_total, max(m.sent_at) as last_dial,
           count(*) filter (where (m.sent_at at time zone 'America/Chicago')::date = (p_now at time zone 'America/Chicago')::date) as dials_today
      -- our dials only: a logged call is stored as 'in' with its outcome; their own calls to us are 'inbound...'
      from public.messages m where m.channel = 'call' and coalesce(m.status, '') not like 'inbound%' group by m.lead_id),
  reached as (
    select distinct m.lead_id from public.messages m
     where m.channel = 'call' and coalesce(m.status, '') not in ('no_answer', 'voicemail', 'inbound_missed', 'missed', 'busy', 'failed', 'canceled', 'blocked')),
  first_text as (
    select distinct on (m.lead_id) m.lead_id, right(regexp_replace(m.to_number, '\D', '', 'g'), 10) as phone, m.sent_at
      from public.messages m
     where m.direction = 'out' and m.channel = 'sms' and m.is_opener and m.provider_sid is not null and coalesce(m.status, '') not in ('undelivered', 'failed')
     order by m.lead_id, m.sent_at),
  texts as (
    select m.lead_id, count(*) as n, max(m.sent_at) as last_at from public.messages m
     where m.direction = 'out' and m.channel = 'sms' and m.provider_sid is not null group by m.lead_id),
  -- a seller who called us and nobody picked up, not called back since (the same rule as Today's Missed calls box)
  missed as (
    select distinct on (ic.lead_id) ic.lead_id, ic.from10 as missed_phone, ic.created_at as missed_at, ic.voicemail,
           nullif(substring(m.body from 'Voicemail: "(.*)"'), '') as vm_words
      from public.inbound_calls ic left join public.messages m on m.id = ic.message_id
     where ic.lead_id is not null and ic.created_at > p_now - interval '48 hours'
       and (ic.status in ('missed', 'blocked', 'no_answer', 'busy', 'failed') or ic.voicemail)
       -- a caller whose number is on the stop list ("erase my number") is never a callback, on any of the card's numbers
       and not exists (select 1 from public.suppressed_phones s where s.phone10 = ic.from10)
       -- the voicemail was read (0118): an upset caller, a stop, the wrong person or someone who isn't a seller is never a
       -- callback; a voicemail not read yet waits up to 10 minutes so nobody calls a caller who was angry
       and coalesce(ic.vm_verdict, '') not in ('stop', 'wrong_person', 'upset', 'not_seller')
       and not (ic.voicemail and ic.vm_verdict is null and ic.created_at > p_now - interval '10 minutes')
       and not exists (select 1 from public.messages o where o.lead_id = ic.lead_id and o.channel = 'call' and o.sent_at > ic.created_at
                         and coalesce(o.status, '') not like 'inbound%')
     order by ic.lead_id, ic.created_at desc),
  due_tasks as (
    select distinct on (t.lead_id) t.lead_id, t.id as task_id, t.title, t.due_at, t.source as task_source, t.kind as task_kind, t.note as task_note, t.quote as reply_words,
           nullif(t.phone10, '') as reply_phone, t.created_at as task_at,
           -- a follow-up a conversation set (the belt's call, the caller's own, a check-in) that is due now (0233)
           bool_or(coalesce(t.source, '') in ('belt', 'mine', 'checkin') and t.due_at <= p_now) over (partition by t.lead_id) as followup_due
      from public.tasks t
     where t.done_at is null and t.lead_id is not null
       and ((t.kind = 'call' and t.due_at <= p_now + interval '12 hours')
         -- a callback promised to a seller comes up from 15 minutes before its time (0124)
         or (t.kind = 'callback' and t.due_at <= p_now + interval '15 minutes'))
       and t.owner in ('thalia', 'adil')
       -- a callback promised by one caller is that caller's (Colin 2026-10-30): on a caller's own login only their own come up
       and (t.kind <> 'callback' or public.wpie_person() not in ('thalia', 'adil') or t.owner = public.wpie_person())
       -- a power-hour set is loaded per caller (Colin 2026-11-03: "50 in each and then followups"): only its caller sees it
       and (coalesce(t.source, '') not in ('power_hour', 'power_hour_after') or public.wpie_person() not in ('thalia', 'adil') or t.owner = public.wpie_person())
     order by t.lead_id, (t.kind = 'callback') desc, (t.source = 'call_next') desc, t.due_at),
  pool as (
    select l.*, dt.task_id, dt.title as task_title, dt.reply_words, dt.task_at, dt.due_at as task_due, (dt.task_source = 'call_next') as replied,
           mc.missed_at, mc.voicemail as missed_voicemail, mc.vm_words, mc.missed_phone,
           coalesce(mc.missed_phone, dt.reply_phone, ft.phone) as thread_phone, ft.sent_at as first_text_at,
           coalesce(tx.n, 0) as texts_sent, tx.last_at as last_text_at, coalesce(d.dials_7d, 0) as dials_7d, coalesce(d.dials_total, 0) as dials_total, d.last_dial, coalesce(d.dials_today, 0) as dials_today,
           dt.task_source, case when mc.lead_id is not null then -3 when dt.task_kind = 'callback' then -2 when dt.task_source = 'call_next' then -1
                when dt.task_id is not null then 0 else 1 end as src, dt.task_note,
           -- a sheriff sale 14 or more days out, on a card that is not thin or underwater (0233): first on the list
           sl.sale_date, sl.equity as sale_equity, coalesce(sl.sale_date >= (select d from today) + 14 and sl.equity not in ('thin', 'underwater'), false) as sale_ahead,
           coalesce(dt.followup_due, false) as followup_due
      from public.leads l
      left join missed mc on mc.lead_id = l.id
      left join due_tasks dt on dt.lead_id = l.id
      left join first_text ft on ft.lead_id = l.id
      left join texts tx on tx.lead_id = l.id
      left join dialed d on d.lead_id = l.id
      left join public.card_sale_dates sl on sl.lead_id = l.id
     where (select ok from me)
       and not (coalesce(l.locked_to = any ((select public.caller_blind_to())::public.team_person[]), false) or (l.locked_to is distinct from (select public.wpie_person()) and coalesce(l.assigned_to = any ((select public.caller_blind_to())::public.team_person[]), false)))
       -- a card on another caller's screen right now is theirs (two callers in Power hour, 0120)
       -- a card locked to the other caller, or with the other caller's open callback, is not mine to dial (0148)
       and (public.wpie_person() not in ('thalia', 'adil') or l.locked_to is null or l.locked_to = public.wpie_person())
       and not exists (select 1 from public.tasks cb where cb.lead_id = l.id and cb.kind = 'callback' and cb.done_at is null
                         and public.wpie_person() in ('thalia', 'adil') and cb.owner <> public.wpie_person())
       and not exists (select 1 from public.power_claims pc where pc.lead_id = l.id and pc.until > p_now
                         and pc.person is distinct from public.wpie_person())
       -- a walkthrough runs on TEST cards only, and the real queue never shows them
       and (l.owner_name ilike 'TEST %') = coalesce(p_test, false)
       -- a seller who called us comes first, whatever the card's stage or dial count (Colin 2026-10-28: "should
       -- automatically be top of the list to call"); only a dead or do-not-contact card is left out
       and (((mc.lead_id is not null or dt.task_kind = 'callback') and l.stage not in ('dnc', 'dead', 'closed_no_contact')) or (
           (dt.task_id is not null or (l.stage = 'opener_sent' and ft.sent_at < p_now - interval '3 days')
            or (coalesce(p_test, false) and l.stage = 'opener_sent')   -- a TEST card needs no task and no texts
            -- a sale ahead needs no task either (0233): it is on the list by itself until someone is reached
            or (coalesce(sl.sale_date >= (select d from today) + 14 and sl.equity not in ('thin', 'underwater'), false) and l.stage in ('opener_queued', 'postcard_mailed', 'opener_sent', 'data_fix', 'follow_up')
                and l.id not in (select lead_id from reached)))
       -- the 14-day rule (0233): a sale inside two weeks, or already past, is never dialed from a list; a follow-up a
       -- conversation set still comes up
       and (sl.sale_date is null or sl.sale_date >= (select d from today) + 14
            or coalesce(dt.task_source, '') in ('call_next', 'belt', 'mine', 'checkin'))
       and l.stage not in ('dnc', 'dead', 'closed_no_contact', 'closed_won', 'under_contract', 'walkthrough_booked', 'offer')
       and not coalesce(l.elderly_or_ill, false) and not coalesce(l.grief, false)
       -- a caller's due follow-up call (the belt's) still comes up when a caller took the text thread (0163)
       -- a dial placed over 12 hours ago and never logged no longer hides the card from its list (0231)
       and (l.human_takeover_at is null or l.human_takeover_at < p_now - interval '12 hours' or dt.task_source in ('belt', 'mine'))
       and (l.named_date is null or l.named_date <= p_now)
        and (l.parked_at is null or (l.rest_until is not null and l.rest_until <= p_now))   -- parked (0182) or rested by the caller (0186) until it wakes
       -- four numbers a sitting (Thalia 2026-11-04, Colin: 'do what thalia asked for'): after four dials on a card in a day the
       -- card leaves today's queue and comes back the next day at its next untried number; a seller who called us, or a
       -- promised callback, is never capped
       and (mc.lead_id is not null or dt.task_kind = 'callback' or coalesce(d.dials_today, 0) < 4)
       -- someone who just texted back with a bit of interest (Muse's call_next) is called next, whatever the dial rules say
       -- and a seller who texted back gets the follow-up call the belt set for them (Colin 2026-11-03: "behind them any followups needed")
       and (dt.task_source in ('call_next', 'belt', 'mine', 'power_hour', 'power_hour_after') or coalesce(sl.sale_date >= (select d from today) + 14 and sl.equity not in ('thin', 'underwater'), false) or (
            coalesce(d.dials_7d, 0) < 3
        and (d.last_dial is null or d.last_dial < p_now - interval '2 days')
        and (dt.task_id is not null or l.id not in (select lead_id from reached))
        and not exists (select 1 from public.twilio_inbound ti where ti.lead_id = l.id)
        and not exists (select 1 from public.messages mi where mi.lead_id = l.id and mi.direction = 'in' and mi.channel = 'sms')))))
       and extract(hour from (p_now at time zone public.agent_tz(coalesce(l.mailing_state, 'WI')))) between 9 and 19),
  pick as (
    select p.*,
           -- the order of the list (0233): a seller who called, a promised callback, a reply; then a sale ahead; then a
           -- follow-up that is due; then the caller's list; then texted-and-silent cards
           case when p.src < 0 then p.src when p.sale_ahead then 0 when p.followup_due then 1 else 2 + p.src end as prio,
           -- need first (0189): the motivation tier from the laptop's records, A..D; a card with no row is D
           coalesce((select case m.tier when 'A' then 0 when 'B' then 1 when 'C' then 2 else 3 end
                       from public.lead_motivation m where m.lead_id = p.id), 3) as need_rank,
           ph.value_normalized as phone, ph.line_type, ph.person_name as phone_person,
           (select count(*) from public.contacts c2 where c2.lead_id = p.id and c2.kind = 'phone' and c2.status = 'ok' and not c2.suppressed
              and not exists (select 1 from public.messages m where m.lead_id = p.id and m.channel = 'call' and coalesce(m.status, '') not like 'inbound%'
                              and right(regexp_replace(coalesce(m.to_number, ''), '\D', '', 'g'), 10) = c2.value_normalized and (m.sent_at at time zone 'America/Chicago')::date = (p_now at time zone 'America/Chicago')::date)) - 1 as other_phones
      from pool p
      cross join lateral (
        select c.value_normalized, c.line_type, c.person_name from public.contacts c
         where c.lead_id = p.id and c.kind = 'phone' and c.status = 'ok' and c.value_normalized ~ '^[0-9]{10}$'
           and not c.suppressed and not coalesce(c.dnc_app, false)
           and (c.value_normalized = p.missed_phone or (not coalesce(c.dnc_vendor, false) and coalesce(c.dnc_scrub, '') <> 'dnc'))
           and not exists (select 1 from public.suppressed_phones s where s.phone10 = c.value_normalized)
           and not exists (select 1 from blocked b where b.ph = c.value_normalized)
           -- a number already dialed today is not offered again today (0184), except to call a seller back
           and (p.src <= -2 or (true and not exists (select 1 from public.messages m where m.lead_id = p.id and m.channel = 'call' and coalesce(m.status, '') not like 'inbound%'
                              and right(regexp_replace(coalesce(m.to_number, ''), '\D', '', 'g'), 10) = c.value_normalized and (m.sent_at at time zone 'America/Chicago')::date = (p_now at time zone 'America/Chicago')::date)))
         order by (c.value_normalized = p.thread_phone) desc,
                  (c.person_id is not null and exists (select 1 from public.interests i where i.lead_id = p.id and i.person_id = c.person_id
                     and i.role in ('owner_of_record', 'co_owner', 'personal_representative', 'trustee') and i.status = 'active')) desc,
                  (c.line_type = 'mobile') desc, c.created_at
         limit 1) ph
     order by prio, p.missed_at desc nulls last, (p.sale_ahead and p.sale_equity in ('clear', 'likely')) desc,
              case when p.sale_ahead then p.sale_date end nulls last, (coalesce(p.task_source, '') = 'power_hour') desc,
              case when p.task_source = 'power_hour' then p.task_due end nulls last, p.task_at nulls last, need_rank, cardinality(p.reasons_to_sell) desc, p.dials_total, p.first_text_at nulls last, p.id
     limit greatest(1, least(coalesce(p_limit, 80), 200)))
  select coalesce(jsonb_agg(jsonb_build_object(
      'lead_id', id, 'task_id', task_id, 'source', case when src = -3 then 'missed_call' when src = -2 then 'callback' when src = -1 then 'replied'
        when task_source = 'checkin' then 'checkin' when src = 0 or sale_ahead then 'call_list' else 'texted_silent' end,
      'why', case when sale_ahead then 'Sheriff sale ' || to_char(sale_date, 'Mon FMDD') || ': last call day ' || to_char(sale_date - 14, 'Mon FMDD')
                  else task_title end,
      'sale_date', sale_date,
      'missed_at', missed_at, 'voicemail', missed_voicemail, 'voicemail_words', vm_words,
      'reply', reply_words, 'task_note', task_note,
      -- the card's latest package: what Colin decided, so the caller says the right thing (0124)
      'package', (select jsonb_build_object('id', d.id, 'status', d.status, 'colin_call', d.colin_call, 'colin_asks', d.colin_asks,
                    'caller_answers', d.caller_answers, 'callback_at', d.callback_at, 'number_note', d.number_note,
                    'our_number', d.our_number, 'their_number', d.their_number)
                    from public.deal_packages d where d.lead_id = pick.id order by d.created_at desc limit 1),
      'owner_name', owner_name, 'address', property_address, 'municipality', municipality, 'mailing_state', mailing_state,
      'reasons', reasons_to_sell, 'lane', lane, 'stage', stage,
      'texts_sent', texts_sent, 'first_text_at', first_text_at, 'last_text_at', last_text_at,
      'dials_7d', dials_7d, 'dials_total', dials_total, 'last_dial', last_dial, 'dials_today', dials_today,
      'phone', phone, 'line_type', line_type, 'phone_person', phone_person, 'other_phones', greatest(other_phones, 0),
      'say_next', say_next, 'next_plain', public.next_plain(belt, next_stop_at, next_stop_who, next_stop_say, named_date, named_event, public.wpie_person()))
      order by prio, missed_at desc nulls last, (sale_ahead and sale_equity in ('clear', 'likely')) desc,
        case when sale_ahead then sale_date end nulls last, (coalesce(task_source, '') = 'power_hour') desc,
        case when task_source = 'power_hour' then task_due end nulls last, task_at nulls last, need_rank, cardinality(reasons_to_sell) desc, dials_total, first_text_at nulls last, id), '[]'::jsonb)
    from pick
$fn$;

-- ---------------------------------------------------------------- nobody covers a card

CREATE OR REPLACE FUNCTION public.live_threads_claim(p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
declare
  out   jsonb := '[]'::jsonb;
  c     public.campaign_control;
  r     record;
  today date := (p_now at time zone 'America/Chicago')::date;
  owner_ text; who text; aid uuid; m public.team_members; mo public.team_members;
begin
  select * into c from public.campaign_control where id = 1;
  if not coalesce(c.live_thread_alerts, true) then return out; end if;
  if public.in_quiet_hours(p_now) then return out; end if;
  for r in
    select distinct on (i.lead_id) i.lead_id, i.sid, i.body, i.received_at, l.owner_name, l.property_address, l.municipality,
           l.locked_to::text as locked_to, l.assigned_to::text as assigned_to,
           (select count(*) from public.twilio_inbound x where x.lead_id = i.lead_id and not coalesce(x.is_opt_out, false)
                and x.received_at > p_now - interval '60 minutes' and x.received_at <= p_now) as theirs
      from public.twilio_inbound i
      join public.leads l on l.id = i.lead_id
     where i.received_at > p_now - interval '15 minutes' and i.received_at <= p_now
       and not coalesce(i.is_opt_out, false)
       and l.stage::text not in ('dnc', 'dead')
       and l.human_takeover_at is null
       and exists (
         select 1 from public.messages o
          where o.lead_id = i.lead_id and o.direction = 'out' and o.channel = 'sms' and coalesce(o.status, '') not in ('failed', 'undelivered')
            and coalesce(o.sent_at, o.created_at) <= i.received_at
            and coalesce(o.sent_at, o.created_at) > i.received_at - interval '30 minutes'
            and exists (select 1 from public.twilio_inbound p
                         where p.lead_id = i.lead_id and not coalesce(p.is_opt_out, false)
                           and p.received_at < coalesce(o.sent_at, o.created_at)
                           and p.received_at > i.received_at - interval '60 minutes'))
       and not exists (select 1 from public.live_thread_alerts a
                        where a.lead_id = i.lead_id and a.at > p_now - make_interval(mins => greatest(coalesce(c.live_thread_gap_min, 60), 5)))
     order by i.lead_id, i.received_at desc
  loop
    owner_ := case when r.locked_to in ('thalia', 'adil') then r.locked_to when r.assigned_to in ('thalia', 'adil') then r.assigned_to end;
    if owner_ is null then continue; end if;                       -- a card with no caller: nobody to tell
    who := owner_;
    -- 0250: a card has one owner. When its caller is off today nobody else is told: the thread waits for them.
    if public.caller_is_off(who::public.team_person, today) then continue; end if;
    select * into m from public.team_members where person::text = who limit 1;
    select * into mo from public.team_members where person::text = owner_ limit 1;
    insert into public.live_thread_alerts (lead_id, person, card_caller, inbound_sid, their_words, at)
    values (r.lead_id, who, owner_, r.sid, left(r.body, 300), p_now) returning id into aid;
    out := out || jsonb_build_object('alert_id', aid, 'lead_id', r.lead_id, 'person', who, 'display_name', m.display_name,
      'card_caller', owner_, 'card_caller_name', mo.display_name, 'email', nullif(btrim(m.alert_email), ''),
      'owner_name', r.owner_name, 'address', r.property_address, 'municipality', r.municipality,
      'their_words', left(r.body, 300), 'texts_this_hour', r.theirs, 'at', r.received_at);
  end loop;
  return out;
end $fn$;

CREATE OR REPLACE FUNCTION public.split_new_card()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
begin
  if new.locked_to is null and not public.card_is_closed(new.stage) then
    -- 0250: a card a caller makes (a new caller on the phone, a card from a text) is that caller's
    update public.leads set locked_to = coalesce(case when public.wpie_role()::text = 'caller' then public.wpie_person() end, public.next_card_owner()),
           locked_at = now() where id = new.id and locked_to is null;
  end if;
  return null;
end $fn$;

-- ---------------------------------------------------------------- every card action a caller login can run
-- Each as it stood live on 2026-11-17, with card_guard as its first statement: belt_event, call_answer, callback_done, card_brief, card_nudge, card_rest, card_say_next, card_unrest, contact_add, followup_set, followup_set_how, handoff_to_colin, lead_fix, lead_move, log_call, mark_called, note_add, offer_said, offer_setup, offer_shoot, power_claim, release_unclaimed_human_call, resume_human_call, verdict_no, walk_outcome.

CREATE OR REPLACE FUNCTION public.belt_event(p_lead_id uuid, p_event text, p_payload jsonb DEFAULT '{}'::jsonb, p_by text DEFAULT NULL::text, p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
declare l public.leads; pl jsonb := coalesce(p_payload, '{}'::jsonb); prev text; who text; o text; b text; st integer;
  res jsonb; slot timestamptz; r public.belt_rules; nd timestamptz; prior integer; reason text; maxs integer;
begin
  perform public.card_guard(p_lead_id);   -- 0250: a card is its caller's
  select * into l from public.leads where id = p_lead_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such lead'); end if;
  if p_event !~ '^[a-z_]{3,40}$' then return jsonb_build_object('ok', false, 'reason', 'bad event'); end if;
  prev := current_setting('wpie.in_belt_event', true);
  perform set_config('wpie.in_belt_event', '1', true);
  who := public.belt_actor(p_by);
  -- an outside event the card already took (a synced text, a WPIE record): once
  if pl ? 'key' and exists (select 1 from public.belt_events e where e.lead_id = p_lead_id and e.payload->>'key' = pl->>'key') then
    perform set_config('wpie.in_belt_event', coalesce(prev, ''), true);
    return jsonb_build_object('ok', true, 'belt', l.belt, 'step', l.belt_step, 'duplicate', true);
  end if;
  if pl ? 'said' and nullif(btrim(pl->>'said'), '') is not null then
    update public.leads set belt_reference = left(btrim(pl->>'said'), 300) where id = p_lead_id;
  end if;
  if pl ? 'named_date' and nullif(pl->>'named_date', '') is not null then
    begin nd := (pl->>'named_date')::timestamptz; exception when others then nd := null; end;
    if nd is not null then update public.leads set named_date = nd, named_event = coalesce(nullif(pl->>'named_event', ''), named_event) where id = p_lead_id; end if;
  elsif pl ? 'named_event' and nullif(pl->>'named_event', '') is not null then
    update public.leads set named_event = left(pl->>'named_event', 200) where id = p_lead_id;
  end if;
  select * into l from public.leads where id = p_lead_id;

  case p_event
  -- ---------------------------------------------------------------- the end of the line
  when 'stop', 'dnc' then
    res := public.belt_enter(p_lead_id, 'dnc', 0, p_event, pl, who, p_now);
  when 'flag' then
    update public.leads set elderly_or_ill = coalesce((pl->>'elderly_or_ill')::boolean, elderly_or_ill),
                            grief = coalesce((pl->>'grief')::boolean, grief) where id = p_lead_id;
    select * into l from public.leads where id = p_lead_id;
    if (l.elderly_or_ill or l.grief) and l.belt not in ('dead', 'dnc') then
      -- every pending agent text is cancelled; Colin only, by phone, at their pace
      res := public.belt_enter(p_lead_id, 'elderly', 1, 'flag', pl, who, p_now);
    else
      insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by) values (p_lead_id, 'flag', l.belt, l.belt, l.belt_step, pl, p_now, who);
      res := jsonb_build_object('ok', true, 'belt', l.belt, 'step', l.belt_step, 'next_stop_at', l.next_stop_at);
    end if;
  when 'move' then
    b := pl->>'belt';
    if b is null or not exists (select 1 from public.belt_rules where belt = b) then
      res := jsonb_build_object('ok', false, 'reason', 'pick a belt');
    else
      res := public.belt_enter(p_lead_id, b, coalesce((pl->>'step')::integer, 1), 'move', pl, who, p_now);
    end if;
  -- ---------------------------------------------------------------- they wrote
  when 'inbound_text' then
    update public.leads set unanswered_count = 0 where id = p_lead_id;
    perform public.belt_cancel_pending(p_lead_id, 'they texted', p_now);
    o := coalesce(pl->>'outcome', ''); b := coalesce(pl->>'intent', '');
    if coalesce((pl->>'removal')::boolean, false) or o = 'dnc' or b in ('opt_out', 'hostile') then
      res := public.belt_enter(p_lead_id, 'dnc', 0, 'inbound_text', pl, who, p_now);
    elsif coalesce(pl->>'kind', '') = 'after_close' then
      insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by) values (p_lead_id, 'inbound_text', l.belt, l.belt, l.belt_step, pl || '{"note":"after the thread was closed: nothing moves"}', p_now, who);
      res := jsonb_build_object('ok', true, 'belt', l.belt, 'step', l.belt_step, 'next_stop_at', l.next_stop_at);
    elsif o = 'wrong_number' or b = 'wrong_number' then
      update public.leads set belt = null, belt_step = 0, next_stop_at = null, next_stop_who = null, next_stop_say = null,
             stage = case when stage in ('dnc', 'closed_won', 'under_contract') then stage else 'data_fix' end where id = p_lead_id;
      insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by) values (p_lead_id, 'inbound_text', l.belt, null, 0, pl, p_now, who);
      res := jsonb_build_object('ok', true, 'belt', null, 'reason', 'wrong number: WPIE re-plans the next mobile');
    elsif o = 'not_interested' or (o <> 'open' and b in ('sold', 'signed_other', 'my_home', 'tenant', 'manager', 'middleman', 'burned', 'annoyed', 'joke_number')) then
      res := public.belt_enter(p_lead_id, 'dead', 0, 'inbound_text', pl || jsonb_build_object('reason', coalesce(nullif(b, ''), o)), who, p_now);
    elsif b = 'not_interested' and position('own anything else' in coalesce(pl->>'reply', '')) > 0 then
      -- a no that got the one exit question (outcome open): the card is dead now, not "replied, went quiet"
      -- (2026-10-24: belt nudges were drafted to six people who had said no). An answer to the exit question that
      -- names another property arrives as a new text and moves the card again.
      res := public.belt_enter(p_lead_id, 'dead', 0, 'inbound_text', pl || jsonb_build_object('reason', 'not interested (exit question asked)'), who, p_now);
    elsif b = 'listed' and o <> 'open' then
      res := public.belt_enter(p_lead_id, 'too_high_or_listed', 0, 'inbound_text', pl, who, p_now);
    elsif l.belt = 'not_now_dated' and l.named_date is not null and l.named_date > p_now
          and not (coalesce((pl->>'interest')::boolean, false) or b in ('interested', 'wants_call', 'price_first', 'number_only', 'worth', 'terms')
                   or coalesce(pl->>'agent_stage', '') = 'book' or coalesce(pl->>'thread_outcome', '') = 'handoff'
                   or coalesce(pl->>'callback_slot', pl->'facts'->>'callback_slot', '') <> '') then
      -- they gave a date and this text is not interest (0229: "I will", "thanks", "who are you?", another "not yet"): the
      -- date stands. Before, any such text restarted the follow-ups or sent the card dormant, and the caller's call on
      -- the date was lost (Jeri Weger, 2026-11-13: check back in February, then "I will" put a call on for next week).
      res := public.belt_enter(p_lead_id, 'not_now_dated', 1, 'inbound_text',
               pl || '{"note":"the date they gave stands: this text does not restart the follow-ups"}'::jsonb, who, p_now);
    elsif coalesce((pl->'facts'->>'nurture')::boolean, false) then
      update public.leads set named_event = coalesce(nullif(left(pl->'facts'->>'condition', 200), ''), nullif(left(pl->>'said', 200), ''), named_event) where id = p_lead_id;
      res := public.belt_enter(p_lead_id, 'not_now_condition', 1, 'inbound_text', pl, who, p_now);
    elsif b = 'not_now' then
      res := public.belt_enter(p_lead_id, 'dormant', 1, 'inbound_text', pl, who, p_now);
    elsif b in ('who_is_this', 'bot_question') then
      -- a question about us, answered plainly: no nudge at all (Rick: texting a ghost only shows your cards)
      res := public.belt_enter(p_lead_id, 'dormant', 1, 'inbound_text', pl || '{"note":"no nudge: asked who we are"}', who, p_now);
    else
      slot := null;
      if coalesce(pl->>'callback_slot', pl->'facts'->>'callback_slot', '') <> '' then
        begin slot := (coalesce(pl->>'callback_slot', pl->'facts'->>'callback_slot'))::timestamptz; exception when others then slot := null; end;
      end if;
      if slot is not null and slot > p_now then
        update public.leads set named_date = slot, named_event = 'call' where id = p_lead_id;
        res := public.belt_enter(p_lead_id, 'call_booked', 1, 'inbound_text', pl, who, p_now);
      elsif coalesce((pl->>'interest')::boolean, false) or b in ('interested', 'wants_call', 'price_first', 'number_only', 'worth', 'terms')
            or coalesce(pl->>'agent_stage', '') = 'book' or coalesce(pl->>'thread_outcome', '') = 'handoff' then
        res := public.belt_enter(p_lead_id, 'yes_unbooked', 1, 'inbound_text', pl, who, p_now);
      elsif l.belt = 'yes_unbooked' then
        -- 0244: they said yes and nobody has reached them: a text that is not a no keeps the caller's call on, now
        res := public.belt_enter(p_lead_id, 'yes_unbooked', 1, 'inbound_text',
                 pl || '{"note":"said yes and not reached yet: the call stays on"}'::jsonb, who, p_now);
        update public.tasks set notified_at = null
         where lead_id = p_lead_id and source = 'belt' and kind = 'call' and done_at is null
           and notified_at is not null and notified_at < p_now - interval '30 minutes';
      else
        select count(*) into prior from public.twilio_inbound t where t.lead_id = p_lead_id and t.received_at < coalesce((pl->>'at')::timestamptz, p_now);
        res := public.belt_enter(p_lead_id, case when prior > 0 or coalesce(pl->>'agent_stage', '') = 'qualify' or l.belt = 'questions_quiet' then 'questions_quiet' else 'replied_quiet' end,
                 1, 'inbound_text', pl, who, p_now);
      end if;
    end if;
  when 'hot_reply' then
    update public.leads set unanswered_count = 0 where id = p_lead_id;
    res := public.belt_enter(p_lead_id, 'yes_unbooked', 1, 'hot_reply', pl, who, p_now);
  when 'human_text' then
    -- a person wrote in the thread: the pending automatic text is off; the card keeps its belt and step
    update public.reply_drafts set status = 'superseded', note = coalesce(note, '') || ' | a person texted', updated_at = p_now
     where lead_id = p_lead_id and kind = 'belt' and status in ('queued', 'awaiting_approval', 'would_send');
    insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by) values (p_lead_id, 'human_text', l.belt, l.belt, l.belt_step, pl, p_now, who);
    if l.next_stop_who in ('auto_text', 'draft_text') and l.belt is not null then
      res := public.belt_enter(p_lead_id, l.belt, l.belt_step + 1, 'human_text', pl - 'key', who, p_now);
    else
      res := jsonb_build_object('ok', true, 'belt', l.belt, 'step', l.belt_step, 'next_stop_at', l.next_stop_at);
    end if;
  -- ---------------------------------------------------------------- a call was logged
  when 'call_logged' then
    o := coalesce(pl->>'outcome', '');
    if o = 'dnc' then res := public.belt_enter(p_lead_id, 'dnc', 0, 'call_logged', pl, who, p_now);
    elsif o = 'not_interested' then res := public.belt_enter(p_lead_id, 'dead', 0, 'call_logged', pl || jsonb_build_object('reason', coalesce(nullif(pl->>'note', ''), 'Not interested (call)')), who, p_now);
    elsif o = 'wrong_number' then
      update public.leads set belt = null, belt_step = 0, next_stop_at = null, next_stop_who = null, next_stop_say = null,
             stage = case when stage in ('dnc', 'closed_won', 'under_contract') then stage else 'data_fix' end where id = p_lead_id;
      insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by) values (p_lead_id, 'call_logged', l.belt, null, 0, pl, p_now, who);
      res := jsonb_build_object('ok', true, 'belt', null);
    elsif o = 'not_now' then
      if l.named_date is not null and l.named_date > p_now then res := public.belt_enter(p_lead_id, 'not_now_dated', 1, 'call_logged', pl, who, p_now);
      else res := public.belt_enter(p_lead_id, 'not_now_condition', 1, 'call_logged', pl, who, p_now); end if;
    elsif o = 'interested' then
      if (l.stage in ('walkthrough_booked', 'offer', 'under_contract', 'closed_won') and l.belt in ('visit_booked', 'offer_out'))
         or (l.belt = 'call_booked' and l.next_stop_at > p_now) then
        res := jsonb_build_object('ok', true, 'belt', l.belt, 'step', l.belt_step, 'next_stop_at', l.next_stop_at);
        insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by) values (p_lead_id, 'call_logged', l.belt, l.belt, l.belt_step, pl, p_now, who);
      else res := public.belt_enter(p_lead_id, 'yes_unbooked', 1, 'call_logged', pl, who, p_now); end if;
    elsif o = 'reached_no_decision' then
      if l.belt = 'call_booked' and l.next_stop_at > p_now then
        res := jsonb_build_object('ok', true, 'belt', l.belt, 'step', l.belt_step, 'next_stop_at', l.next_stop_at);
        insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by) values (p_lead_id, 'call_logged', l.belt, l.belt, l.belt_step, pl, p_now, who);
      else res := public.belt_enter(p_lead_id, 'after_call_quiet', 1, 'call_logged', pl, who, p_now); end if;
    elsif o = 'no_answer' then
      res := public.belt_route_no_answer(p_lead_id, pl, who, p_now, p_event);
    else
      res := jsonb_build_object('ok', false, 'reason', 'unknown call outcome ' || o);
    end if;
  when 'next_step' then
    begin slot := (pl->>'at')::timestamptz; exception when others then slot := null; end;
    if slot is null then res := jsonb_build_object('ok', false, 'reason', 'a day and time');
    else
      update public.leads set named_date = slot, named_event = case when pl->>'kind' = 'walk' then 'visit' else 'call' end where id = p_lead_id;
      res := public.belt_enter(p_lead_id, case when pl->>'kind' = 'walk' then 'visit_booked' else 'call_booked' end, 1, 'next_step', pl, who, p_now);
    end if;
  when 'verdict_no' then
    reason := coalesce(pl->>'reason', '');
    if reason in ('dnc', 'removed') then res := public.belt_enter(p_lead_id, 'dnc', 0, 'verdict_no', pl, who, p_now);
    elsif reason in ('listed', 'signed_other', 'market_firm') then res := public.belt_enter(p_lead_id, 'too_high_or_listed', 0, 'verdict_no', pl, who, p_now);
    elsif reason = 'elderly_no_family' then res := public.belt_enter(p_lead_id, 'elderly', 1, 'verdict_no', pl, who, p_now);
    elsif reason = 'estate_no_signer' then res := public.belt_enter(p_lead_id, 'estate_waiting', 1, 'verdict_no', pl, who, p_now);
    elsif reason = 'spouse' then res := public.belt_enter(p_lead_id, 'needs_family', 1, 'verdict_no', pl, who, p_now);
    else res := public.belt_enter(p_lead_id, 'dead', 0, 'verdict_no', pl || jsonb_build_object('reason', coalesce(nullif(reason, ''), 'the card said do not book')), who, p_now); end if;
  -- ---------------------------------------------------------------- a stop was logged
  when 'stop_done' then
    o := coalesce(pl->>'outcome', 'done');
    if o = 'dnc' then res := public.belt_enter(p_lead_id, 'dnc', 0, 'stop_done', pl, who, p_now);
    elsif o = 'no' then res := public.belt_enter(p_lead_id, 'dead', 0, 'stop_done', pl || jsonb_build_object('reason', coalesce(nullif(pl->>'note', ''), 'said no on the call')), who, p_now);
    elsif o = 'wrong_number' then res := public.belt_event(p_lead_id, 'call_logged', pl, who, p_now);
    elsif o = 'booked' then
      begin slot := (pl->>'at')::timestamptz; exception when others then slot := null; end;
      if slot is null then res := jsonb_build_object('ok', false, 'reason', 'a day and time');
      else res := public.belt_event(p_lead_id, 'next_step', jsonb_build_object('kind', coalesce(pl->>'kind', 'callback'), 'at', slot), who, p_now); end if;
    elsif o = 'not_now' then
      if nd is not null and nd > p_now then res := public.belt_enter(p_lead_id, 'not_now_dated', 1, 'stop_done', pl, who, p_now);
      elsif nullif(pl->>'named_event', '') is not null then res := public.belt_enter(p_lead_id, 'not_now_condition', 1, 'stop_done', pl, who, p_now);
      else res := public.belt_enter(p_lead_id, 'dormant', 1, 'stop_done', pl, who, p_now); end if;
    elsif o in ('family', 'elderly', 'estate', 'hold', 'too_high', 'listed', 'offer_out') then
      b := case o when 'family' then 'needs_family' when 'elderly' then 'elderly' when 'estate' then 'estate_waiting' when 'hold' then 'hold_not_now'
                  when 'offer_out' then 'offer_out' else 'too_high_or_listed' end;
      if o = 'elderly' then update public.leads set elderly_or_ill = true where id = p_lead_id; end if;
      res := public.belt_enter(p_lead_id, b, 1, 'stop_done', pl, who, p_now);
    elsif o in ('reached', 'reached_no_decision') then
      update public.leads set unanswered_count = 0 where id = p_lead_id;
      if l.belt = 'cold_texts' then res := public.belt_enter(p_lead_id, 'yes_unbooked', 1, 'stop_done', pl, who, p_now);
      elsif l.belt = 'visit_booked' and l.belt_step = 2 then res := public.belt_enter(p_lead_id, 'after_visit_quiet', 1, 'stop_done', pl, who, p_now);
      else res := public.belt_enter(p_lead_id, 'after_call_quiet', 1, 'stop_done', pl, who, p_now); end if;
    elsif o in ('no_answer', 'voicemail') then
      res := public.belt_route_no_answer(p_lead_id, pl, who, p_now, p_event);
    elsif o = 'sent' then      -- a draft stop went out: next stop, counts as a touch with no reply yet
      update public.leads set unanswered_count = unanswered_count + 1 where id = p_lead_id and belt is not null;
      res := public.belt_enter(p_lead_id, coalesce(l.belt, 'dormant'), l.belt_step + 1, 'stop_done', pl, who, p_now);
      if l.belt = 'dormant' then update public.leads set dormant_round = least(dormant_round + 1, 3) where id = p_lead_id; end if;
    else                       -- 'done' / 'skipped': the next stop on the ladder, not counted against them
      if l.belt is null then res := jsonb_build_object('ok', true, 'belt', null);
      else res := public.belt_enter(p_lead_id, l.belt, l.belt_step + 1, 'stop_done', pl, who, p_now); end if;
      if l.belt = 'dormant' and o = 'skipped' then update public.leads set dormant_round = least(dormant_round + 1, 3) where id = p_lead_id; end if;
    end if;
  when 'auto_text_sent' then
    update public.leads set unanswered_count = unanswered_count + 1 where id = p_lead_id;
    if l.belt is null then res := jsonb_build_object('ok', true, 'belt', null);
    else res := public.belt_enter(p_lead_id, l.belt, l.belt_step + 1, 'auto_text_sent', pl, who, p_now); end if;
  when 'draft_sent' then
    res := public.belt_event(p_lead_id, 'stop_done', pl || '{"outcome":"sent"}', who, p_now);
  when 'draft_skipped' then
    res := public.belt_event(p_lead_id, 'stop_done', pl || '{"outcome":"skipped"}', who, p_now);
  when 'stop_missed' then
    -- a text stop that never went counts as unanswered; a call stop is re-slid once, then counts
    if l.next_stop_who in ('auto_text', 'draft_text') then
      update public.leads set unanswered_count = unanswered_count + 1 where id = p_lead_id;
      res := public.belt_enter(p_lead_id, l.belt, l.belt_step + 1, 'stop_missed', pl, who, p_now);
    elsif coalesce((pl->>'again')::boolean, false) then
      update public.leads set unanswered_count = unanswered_count + 1 where id = p_lead_id;
      res := public.belt_enter(p_lead_id, l.belt, l.belt_step + 1, 'stop_missed', pl, who, p_now);
    else
      res := public.belt_enter(p_lead_id, l.belt, l.belt_step, 'stop_missed', pl || '{"reslid":true}', who, p_now);
    end if;
  -- ---------------------------------------------------------------- the laptop
  when 'cold_text' then
    st := coalesce((pl->>'step')::integer, 1);
    if l.belt is null or l.belt = 'cold_texts' then
      update public.leads set belt = 'cold_texts', belt_step = st, belt_round = greatest(belt_round, 1),
             belt_entered_at = coalesce(belt_entered_at, p_now),
             next_stop_at = nullif(pl->>'next_at', '')::timestamptz,
             next_stop_who = case when nullif(pl->>'next_at', '') is null then null when st >= 5 then 'thalia_call' else 'auto_text' end,
             next_stop_say = case when st >= 5 then 'Never answered five texts; one call from the daily list' else format('Text %s goes on its own (WPIE)', st + 1) end,
             next_action = case when nullif(pl->>'next_at', '') is null then next_action else 'Cold texts (WPIE)' end,
             next_action_at = coalesce(nullif(pl->>'next_at', '')::timestamptz, next_action_at)
       where id = p_lead_id;
      insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by) values (p_lead_id, 'cold_text', l.belt, 'cold_texts', st, pl, p_now, who);
    else
      insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by) values (p_lead_id, 'cold_text', l.belt, l.belt, l.belt_step, pl || '{"ignored":"already past cold texts"}', p_now, who);
    end if;
    select * into l from public.leads where id = p_lead_id;
    res := jsonb_build_object('ok', true, 'belt', l.belt, 'step', l.belt_step, 'next_stop_at', l.next_stop_at);
  when 'wpie_event' then
    -- a new public record on a resting card: one call from Colin that references the earlier conversation, never the record
    if l.belt in ('dormant', 'too_high_or_listed', 'hold_not_now') or (l.belt = 'dead' and l.belt_entered_at < p_now - interval '90 days'
         and coalesce(l.dead_reason, '') not in ('Not interested (call)', 'not_interested', 'no_contact', 'said no on the call')) then
      update public.leads set belt_reference = coalesce(belt_reference, 'we spoke before') where id = p_lead_id;
      res := public.belt_enter(p_lead_id, 'after_call_quiet', 1, 'wpie_event',
               pl || jsonb_build_object('say', 'Re-entry: we spoke before about the place; checking in as I said I would. Never mention the record.'), who, p_now);
      update public.leads set next_stop_say = 'We spoke before about ' || public.belt_street(property_address) || '; checking in as I said I would (never mention the record)' where id = p_lead_id;
      update public.tasks set note = 'Re-entry after a new public record. Say: we spoke before about ' || public.belt_street(l.property_address) || '; checking in as I said I would. Never mention the record itself.'
       where lead_id = p_lead_id and source = 'belt' and done_at is null;
    else
      insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by) values (p_lead_id, 'wpie_event', l.belt, l.belt, l.belt_step, pl || '{"note":"card is live or closed: no re-entry"}', p_now, who);
      res := jsonb_build_object('ok', true, 'belt', l.belt, 'step', l.belt_step, 'next_stop_at', l.next_stop_at);
    end if;
  when 'named_date' then
    if l.belt in ('not_now_dated', 'elderly', 'estate_waiting', 'hold_not_now', 'needs_family') then
      res := public.belt_enter(p_lead_id, l.belt, 1, 'named_date', pl, who, p_now);
    elsif nd is not null then res := public.belt_enter(p_lead_id, 'not_now_dated', 1, 'named_date', pl, who, p_now);
    else res := jsonb_build_object('ok', false, 'reason', 'a date'); end if;
  when 'stage_changed' then
    -- a stage written outside the belt (a legacy path): keep the belt honest
    b := pl->>'to';
    if b = 'dnc' then res := public.belt_enter(p_lead_id, 'dnc', 0, 'stage_changed', pl, who, p_now);
    elsif b = 'dead' then res := public.belt_enter(p_lead_id, 'dead', 0, 'stage_changed', pl, who, p_now);
    elsif b = 'closed_no_contact' then res := public.belt_enter(p_lead_id, 'dead', 0, 'stage_changed', pl || '{"reason":"no_contact"}', who, p_now);
    elsif b = 'walkthrough_booked' and l.belt is distinct from 'visit_booked' then res := public.belt_enter(p_lead_id, 'visit_booked', 1, 'stage_changed', pl, who, p_now);
    elsif b = 'colin_call' and l.belt not in ('call_booked', 'call_missed', 'yes_unbooked') then res := public.belt_enter(p_lead_id, 'yes_unbooked', 1, 'stage_changed', pl, who, p_now);
    elsif b = 'offer' and l.belt is distinct from 'offer_out' then res := public.belt_enter(p_lead_id, 'offer_out', 1, 'stage_changed', pl, who, p_now);
    elsif b = 'follow_up' and l.belt is null then res := public.belt_enter(p_lead_id, 'not_now_condition', 1, 'stage_changed', pl, who, p_now);
    elsif b in ('reply_received', 'ai_qualifying', 'handoff') and l.belt is null then
      res := public.belt_enter(p_lead_id, case b when 'handoff' then 'yes_unbooked' when 'ai_qualifying' then 'questions_quiet' else 'replied_quiet' end, 1, 'stage_changed', pl, who, p_now);
    else
      insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by) values (p_lead_id, 'stage_changed', l.belt, l.belt, l.belt_step, pl, p_now, who);
      res := jsonb_build_object('ok', true, 'belt', l.belt, 'step', l.belt_step, 'next_stop_at', l.next_stop_at);
    end if;
  else
    res := jsonb_build_object('ok', false, 'reason', 'unknown event ' || p_event);
  end case;
  perform set_config('wpie.in_belt_event', coalesce(prev, ''), true);
  return res;
end $fn$;

CREATE OR REPLACE FUNCTION public.call_answer(p_lead_id uuid, p_key text, p_value jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
declare who text; at timestamptz; kind text; res jsonb;
begin
  perform public.card_guard(p_lead_id);   -- 0250: a card is its caller's
  if not public.is_team() then raise exception 'team only'; end if;
  if p_key !~ '^[a-z_]{2,40}$' then return jsonb_build_object('ok', false, 'reason', 'bad key'); end if;
  select display_name into who from public.team_members where lower(email) = lower(auth.jwt() ->> 'email');
  update public.leads
     set call_facts = case when p_value is null or p_value = 'null'::jsonb then call_facts - p_key
                           else jsonb_set(call_facts, array[p_key], jsonb_build_object('value', p_value, 'at', now(), 'by', who)) end
   where id = p_lead_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such lead'); end if;
  if p_key = 'next_step' and jsonb_typeof(p_value) = 'object' then
    kind := p_value->>'kind';
    at := nullif(p_value->>'at', '')::timestamptz;
    if kind in ('walk', 'callback') and at is not null then
      res := public.belt_event(p_lead_id, 'next_step', jsonb_build_object('kind', kind, 'at', at), who, now());
      return jsonb_build_object('ok', true, 'belt', res->>'belt', 'next_stop_at', res->>'next_stop_at');
    end if;
  end if;
  return jsonb_build_object('ok', true);
end $fn$;

CREATE OR REPLACE FUNCTION public.callback_done(p_lead_id uuid, p_note text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
declare who text; n integer;
begin
  perform public.card_guard(p_lead_id);   -- 0250: a card is its caller's
  if not public.is_team() then raise exception 'team only'; end if;
  select display_name into who from public.team_members where lower(email) = lower(auth.jwt() ->> 'email');
  update public.tasks set done_at = now(), note = concat_ws(E'\n', note, 'Done: ' || coalesce(nullif(btrim(coalesce(p_note, '')), ''), 'callback made'))
   where lead_id = p_lead_id and kind = 'callback' and done_at is null;
  get diagnostics n = row_count;
  insert into public.messages (lead_id, direction, channel, body, sent_at, seen_at, status)
  values (p_lead_id, 'out', 'note', format('Callback (%s): %s', coalesce(who, 'team'), coalesce(nullif(btrim(coalesce(p_note, '')), ''), 'done')), now(), now(), 'callback_done');
  update public.leads set human_takeover_at = null, human_takeover_by = null, human_takeover_phone = null, human_takeover_key = null,
         human_takeover_drafts = null, human_takeover_assigned_to = null where id = p_lead_id;
  return jsonb_build_object('ok', true, 'closed', n);
end $fn$;

CREATE OR REPLACE FUNCTION public.card_brief(p_lead_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
declare l public.leads; me team_person; res jsonb;
begin
  perform public.card_guard(p_lead_id);   -- 0250: a card is its caller's
  if not public.is_team() then raise exception 'team only'; end if;
  me := public.wpie_person();
  select * into l from public.leads where id = p_lead_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card'); end if;
  select jsonb_build_object(
    'ok', true,
    'lane', l.lane,
    'say_next', l.say_next,
    'next_plain', public.next_plain(l.belt, l.next_stop_at, l.next_stop_who, l.next_stop_say, l.named_date, l.named_event, me),
    'mine_next', (select jsonb_build_object('task_id', t.id, 'due_at', t.due_at, 'kind', t.kind, 'note', t.note, 'owner', t.owner, 'source', t.source)
                    from public.tasks t where t.lead_id = l.id and t.done_at is null and t.kind in ('call', 'callback', 'visit', 'text', 'other')
                   order by t.due_at nulls last limit 1),
    'why', jsonb_build_object(
       'reasons', l.reasons_to_sell,
       'motivation', (select lm.lines from public.lead_motivation lm where lm.lead_id = l.id),
       'last_words', (select left(mi.body, 240) from public.messages mi where mi.lead_id = l.id and mi.direction = 'in' and mi.channel = 'sms' order by mi.sent_at desc limit 1),
       'last_call', (select left(regexp_replace(coalesce(lc.body, ''), '^Call \([^)]*\) from \d+:\s*', ''), 240) from public.messages lc
                       where lc.lead_id = l.id and lc.channel = 'call' and lc.status is distinct from 'inbound_missed' order by lc.sent_at desc limit 1),
       'promise', (select pm.note from public.tasks pm where pm.lead_id = l.id and pm.source = 'mine' and pm.done_at is null order by pm.due_at limit 1)),
    'touches', (select coalesce(jsonb_agg(x order by x.at desc), '[]'::jsonb) from (
                  select m.sent_at at, m.channel, m.direction, coalesce(m.status, '') status, left(m.body, 140) body
                    from public.messages m where m.lead_id = l.id and m.channel in ('call', 'sms', 'note') order by m.sent_at desc limit 3) x),
    'touches_total', (select count(*) from public.messages m where m.lead_id = l.id and m.channel in ('call', 'sms')),
    'planned', (select coalesce(jsonb_agg(y order by y.at), '[]'::jsonb) from (
                  select t.due_at at, t.kind what, coalesce(t.title, t.note) words, t.owner::text who from public.tasks t
                   where t.lead_id = l.id and t.done_at is null and t.due_at is not null and t.kind <> 'nudge'
                  union all
                  select l.next_stop_at, 'belt', l.next_stop_say, l.next_stop_who where l.next_stop_at is not null and l.next_stop_at > now()
                  order by 1 limit 2) y),
    'rest', case when l.parked_at is not null then jsonb_build_object('until', l.rest_until, 'why', l.parked_why, 'by_colin', l.rest_until is null) end,
    'nudges', (select coalesce(jsonb_agg(jsonb_build_object('task_id', n.id, 'from', n.title, 'text', n.note, 'at', n.created_at, 'to', n.owner) order by n.created_at desc), '[]'::jsonb)
                 from public.tasks n where n.lead_id = l.id and n.kind = 'nudge' and n.done_at is null),
    'locked_to', l.locked_to, 'belt', l.belt, 'stage', l.stage)
  into res;
  return res;
end $fn$;

CREATE OR REPLACE FUNCTION public.card_nudge(p_lead_id uuid, p_to team_person, p_text text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
declare me team_person; t public.tasks; by_name text;
begin
  perform public.card_guard(p_lead_id);   -- 0250: a card is its caller's
  if not public.is_team() then raise exception 'team only'; end if;
  me := public.wpie_person(); by_name := initcap(coalesce(me::text, 'team'));
  if p_to is null or p_to = me then return jsonb_build_object('ok', false, 'reason', 'pick the other person'); end if;
  if nullif(btrim(p_text), '') is null then return jsonb_build_object('ok', false, 'reason', 'say something'); end if;
  if not exists (select 1 from public.leads where id = p_lead_id) then return jsonb_build_object('ok', false, 'reason', 'no such card'); end if;
  insert into public.tasks (lead_id, due_at, kind, owner, note, created_by, source, title)
  values (p_lead_id, now(), 'nudge', p_to, btrim(p_text), auth.uid(), 'nudge', 'Heads-up from ' || by_name)
  returning * into t;
  insert into public.messages (lead_id, direction, channel, body, status, created_by, sent_at)
  values (p_lead_id, 'out', 'note', 'Heads-up to ' || initcap(p_to::text) || ' from ' || by_name || ': ' || btrim(p_text), null, auth.uid(), now());
  return jsonb_build_object('ok', true, 'task_id', t.id);
end $fn$;

CREATE OR REPLACE FUNCTION public.card_rest(p_lead_id uuid, p_until timestamp with time zone, p_why text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
declare l public.leads; me team_person; by_name text;
begin
  perform public.card_guard(p_lead_id);   -- 0250: a card is its caller's
  if not public.is_team() then raise exception 'team only'; end if;
  me := public.wpie_person(); by_name := initcap(coalesce(me::text, 'team'));
  select * into l from public.leads where id = p_lead_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card'); end if;
  if not public.is_owner() and l.locked_to is distinct from me then return jsonb_build_object('ok', false, 'reason', 'not your card'); end if;
  if p_until is null or p_until <= now() then return jsonb_build_object('ok', false, 'reason', 'a day in the future'); end if;
  if p_until > now() + interval '18 months' then return jsonb_build_object('ok', false, 'reason', 'at most 18 months'); end if;
  if l.belt in ('call_booked', 'visit_booked') or l.hot_at > now() - interval '14 days' then return jsonb_build_object('ok', false, 'reason', 'a booked or hot card does not rest'); end if;
  update public.leads set parked_at = now(), rest_until = p_until,
         parked_why = concat_ws(' | ', parked_why, to_char(now() at time zone 'America/Chicago', 'YYYY-MM-DD') || ' rested by ' || by_name
                      || ' until ' || to_char(p_until at time zone 'America/Chicago', 'Mon FMDD, YYYY') || coalesce(': ' || nullif(btrim(p_why), ''), ''))
   where id = p_lead_id;
  insert into public.messages (lead_id, direction, channel, body, status, created_by, sent_at)
  values (p_lead_id, 'out', 'note', 'Resting until ' || to_char(p_until at time zone 'America/Chicago', 'Mon FMDD, YYYY') || coalesce(': ' || nullif(btrim(p_why), ''), '')
          || ' (' || by_name || '). Wakes sooner on a text, a call or a new record.', null, auth.uid(), now());
  return jsonb_build_object('ok', true, 'rest_until', p_until);
end $fn$;

CREATE OR REPLACE FUNCTION public.card_say_next(p_lead_id uuid, p_text text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
declare l public.leads; me team_person;
begin
  perform public.card_guard(p_lead_id);   -- 0250: a card is its caller's
  if not public.is_team() then raise exception 'team only'; end if;
  me := public.wpie_person();
  select * into l from public.leads where id = p_lead_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card'); end if;
  if not public.is_owner() and l.locked_to is distinct from me then return jsonb_build_object('ok', false, 'reason', 'not your card'); end if;
  update public.leads set say_next = nullif(btrim(p_text), ''), updated_at = now() where id = p_lead_id;
  return jsonb_build_object('ok', true, 'say_next', nullif(btrim(p_text), ''));
end $fn$;

CREATE OR REPLACE FUNCTION public.card_unrest(p_lead_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
declare l public.leads; me team_person;
begin
  perform public.card_guard(p_lead_id);   -- 0250: a card is its caller's
  if not public.is_team() then raise exception 'team only'; end if;
  me := public.wpie_person();
  select * into l from public.leads where id = p_lead_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card'); end if;
  if not public.is_owner() and l.locked_to is distinct from me then return jsonb_build_object('ok', false, 'reason', 'not your card'); end if;
  if l.parked_at is not null and l.rest_until is null and not public.is_owner() then return jsonb_build_object('ok', false, 'reason', 'Colin parked this one'); end if;
  update public.leads set parked_at = null, rest_until = null,
         parked_why = concat_ws(' | ', parked_why, to_char(now() at time zone 'America/Chicago', 'YYYY-MM-DD') || ' woke: ' || initcap(coalesce(me::text, 'team')) || ' took it back')
   where id = p_lead_id;
  return jsonb_build_object('ok', true);
end $fn$;

CREATE OR REPLACE FUNCTION public.contact_add(p_lead_id uuid, p_kind text, p_value text, p_person_name text DEFAULT NULL::text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
declare v text; norm text; cid uuid; who text;
begin
  perform public.card_guard(p_lead_id);   -- 0250: a card is its caller's
  if not public.is_team() then raise exception 'team only'; end if;
  -- the name the team knows (Tyler), not the login key (0209); log_call does the same
  select display_name into who from public.team_members where lower(email) = lower(auth.jwt() ->> 'email');
  who := coalesce(who, public.wpie_person()::text, 'team');
  if p_kind = 'phone' then
    norm := right(regexp_replace(coalesce(p_value, ''), '\D', '', 'g'), 10);
    if length(norm) <> 10 then return jsonb_build_object('ok', false, 'reason', 'a phone needs 10 digits'); end if;
    v := norm;
  elsif p_kind = 'email' then
    v := lower(btrim(coalesce(p_value, '')));
    if v !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then return jsonb_build_object('ok', false, 'reason', 'that is not an email address'); end if;
    norm := v;
  else
    return jsonb_build_object('ok', false, 'reason', 'phone or email');
  end if;
  if exists (select 1 from public.contacts c where c.lead_id = p_lead_id and c.kind = p_kind::public.contact_kind and coalesce(c.value_normalized, c.value) = norm) then
    return jsonb_build_object('ok', false, 'reason', 'already on the card');
  end if;
  insert into public.contacts (lead_id, kind, value, value_normalized, person_name, source, status, note, created_at, updated_at)
  values (p_lead_id, p_kind::public.contact_kind, v, norm, nullif(btrim(p_person_name), ''), 'added by ' || initcap(who), 'ok',
          concat_ws(' | ', nullif(btrim(p_note), ''), to_char(now() at time zone 'America/Chicago', 'YYYY-MM-DD') || ' added by ' || initcap(who)), now(), now())
  returning id into cid;
  return jsonb_build_object('ok', true, 'id', cid);
end $fn$;

CREATE OR REPLACE FUNCTION public.followup_set(p_lead_id uuid, p_at timestamp with time zone, p_kind text DEFAULT 'call'::text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
declare who public.team_person; k text; key text; t public.tasks; was timestamptz; l public.leads;
begin
  perform public.card_guard(p_lead_id);   -- 0250: a card is its caller's
  if not public.is_team() then raise exception 'team only'; end if;
  if p_at is null then return jsonb_build_object('ok', false, 'reason', 'pick a time'); end if;
  select * into l from public.leads where id = p_lead_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card'); end if;
  who := public.wpie_person();
  if who not in ('thalia', 'adil') then who := 'colin'; end if;
  k := case when p_kind in ('call', 'text', 'visit', 'other') then p_kind else 'call' end;
  key := 'mine:' || p_lead_id::text || ':' || who::text;
  select * into t from public.tasks where source_key = key and done_at is null;
  if found then
    was := t.due_at;
    update public.tasks set due_at = p_at, kind = k, note = coalesce(nullif(btrim(p_note), ''), note), updated_at = now() where id = t.id;
    insert into public.task_moves (task_id, lead_id, by, from_at, to_at, why) values (t.id, p_lead_id, who::text, was, p_at, 'set again');
  else
    insert into public.tasks (lead_id, due_at, kind, owner, note, created_by, source, source_key, title)
    values (p_lead_id, p_at, k, who, nullif(btrim(p_note), ''), auth.uid(), 'mine', key, 'My follow-up')
    on conflict (source_key) do update set due_at = excluded.due_at, kind = excluded.kind, note = excluded.note, done_at = null, updated_at = now()
    returning * into t;
  end if;
  -- the card's "next action" line follows the earliest open follow-up on it
  update public.leads set next_action = coalesce(nullif(btrim(p_note), ''), 'Follow-up (' || initcap(who::text) || ')'),
         next_action_at = least(coalesce(next_action_at, p_at), p_at)
   where id = p_lead_id and (next_action_at is null or next_action_at > p_at or next_action_at < now());
  return jsonb_build_object('ok', true, 'task_id', t.id, 'due_at', p_at, 'owner', who);
end $fn$;

CREATE OR REPLACE FUNCTION public.followup_set_how(p_lead_id uuid, p_at timestamp with time zone, p_how text DEFAULT 'call'::text, p_say text DEFAULT NULL::text, p_phone text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
declare r jsonb; k text := case when p_how in ('call', 'text') then p_how else 'call' end;
        p text := nullif(right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10), '');
        say text := nullif(btrim(coalesce(p_say, '')), '');
begin
  perform public.card_guard(p_lead_id);   -- 0250: a card is its caller's
  if k = 'text' and p is not null and exists (select 1 from public.suppressed_phones s where s.phone10 = p) then
    return jsonb_build_object('ok', false, 'reason', 'that phone opted out: no text follow-up to it (set a call, or nothing)');
  end if;
  r := public.followup_set(p_lead_id, p_at, k, say);
  if coalesce((r->>'ok')::boolean, false) is false then return r; end if;
  update public.tasks set phone10 = coalesce(p, phone10), title = case when k = 'text' then 'Text them back' else 'Call them back' end,
         updated_at = now()
   where id = (r->>'task_id')::uuid;
  if say is not null then perform public.card_say_next(p_lead_id, say); end if;
  return r || jsonb_build_object('how', k, 'phone10', p);
end $fn$;

CREATE OR REPLACE FUNCTION public.handoff_to_colin(p_lead_id uuid, p_note text, p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
declare who text; l public.leads; ph text; tid uuid; note_id uuid; first text; key text; line text; res jsonb; note_body text;
begin
  perform public.card_guard(p_lead_id);   -- 0250: a card is its caller's
  if not public.is_team() then raise exception 'team only'; end if;
  line := nullif(btrim(coalesce(p_note, '')), '');
  if line is null then return jsonb_build_object('ok', false, 'reason', 'Say why in one line.'); end if;
  select display_name into who from public.team_members where lower(email) = lower(auth.jwt() ->> 'email');
  select * into l from public.leads where id = p_lead_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such lead'); end if;
  note_body := 'Handed to Colin by ' || coalesce(who, 'the team') || ': ' || line;
  if exists (
    select 1 from public.messages m
     where m.lead_id = p_lead_id and m.channel = 'note' and m.body = note_body
       and m.sent_at between p_now - interval '5 minutes' and p_now + interval '5 minutes'
  ) then
    select t.id into tid from public.tasks t
     where t.lead_id = p_lead_id and t.done_at is null and t.owner = 'colin' and t.source = 'belt' and t.kind = 'call'
     order by t.created_at desc limit 1;
    return jsonb_build_object('ok', true, 'duplicate', true, 'task_id', tid, 'belt', l.belt);
  end if;
  select c.value_normalized into ph from public.contacts c
   where c.lead_id = p_lead_id and c.kind = 'phone' and c.value_normalized ~ '^[0-9]{10}$' and not c.suppressed and c.status = 'ok'
   order by c.created_at limit 1;
  perform set_config('wpie.task_outcome', '1', true);
  update public.tasks set done_at = p_now, note = coalesce(tasks.note, '') || ' [handed to Colin]'
   where lead_id = p_lead_id and done_at is null and kind in ('call', 'visit') and owner <> 'colin';
  perform set_config('wpie.task_outcome', '', true);

  update public.leads set assigned_to = 'colin',
         stage = case when stage in ('walkthrough_booked', 'offer', 'under_contract', 'closed_won', 'dead', 'dnc') then stage else 'colin_call' end,
         next_action = 'Colin: ' || left(line, 80), next_action_at = p_now
   where id = p_lead_id;
  insert into public.messages (lead_id, direction, channel, body, sent_at, seen_at)
  values (p_lead_id, 'out', 'note', note_body, p_now, p_now)
  returning id into note_id;
  key := 'handoff:' || p_lead_id || ':' || note_id;

  res := public.belt_event(p_lead_id, 'next_step', jsonb_build_object('kind', 'callback', 'at', p_now, 'key', key,
           'said', 'Handed off by ' || coalesce(who, 'the team') || ': ' || line), who, p_now);
  update public.tasks set title = 'From ' || coalesce(who, 'the team') || ': worth a look',
         note = tasks.note || ' | ' || coalesce(who, 'The team') || ' says: ' || line
   where lead_id = p_lead_id and done_at is null and owner = 'colin' and source = 'belt' and kind = 'call'
  returning id into tid;

  first := initcap(split_part(coalesce(l.owner_name, ''), ' ', 1));
  perform public.hot_record(key, p_lead_id, coalesce(ph, ''), first, l.property_address,
          coalesce(who, 'The team') || ' hands off: ' || line, false, p_now);
  return jsonb_build_object('ok', true, 'duplicate', false, 'task_id', tid, 'belt', res->>'belt');
end $fn$;

CREATE OR REPLACE FUNCTION public.lead_fix(p_lead_id uuid, p_owner_name text DEFAULT NULL::text, p_property_address text DEFAULT NULL::text, p_municipality text DEFAULT NULL::text, p_property_zip text DEFAULT NULL::text, p_why text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
declare l public.leads; who text; changed text[] := '{}';
begin
  perform public.card_guard(p_lead_id);   -- 0250: a card is its caller's
  if not public.is_team() then raise exception 'team only'; end if;
  select * into l from public.leads where id = p_lead_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card'); end if;
  who := coalesce(public.wpie_person()::text, 'team');
  if nullif(btrim(coalesce(p_owner_name, '')), '') is not null and btrim(p_owner_name) is distinct from l.owner_name then
    update public.leads set owner_name = btrim(p_owner_name) where id = l.id; changed := changed || ('name was ' || coalesce(l.owner_name, '(blank)'));
  end if;
  if nullif(btrim(coalesce(p_property_address, '')), '') is not null and btrim(p_property_address) is distinct from l.property_address then
    update public.leads set property_address = btrim(p_property_address) where id = l.id; changed := changed || ('address was ' || coalesce(l.property_address, '(blank)'));
  end if;
  if nullif(btrim(coalesce(p_municipality, '')), '') is not null and btrim(p_municipality) is distinct from l.municipality then
    update public.leads set municipality = btrim(p_municipality) where id = l.id; changed := changed || ('town was ' || coalesce(l.municipality, '(blank)'));
  end if;
  if nullif(btrim(coalesce(p_property_zip, '')), '') is not null and btrim(p_property_zip) is distinct from l.property_zip then
    update public.leads set property_zip = btrim(p_property_zip) where id = l.id; changed := changed || ('zip was ' || coalesce(l.property_zip, '(blank)'));
  end if;
  if cardinality(changed) = 0 then return jsonb_build_object('ok', true, 'changed', changed); end if;
  insert into public.messages (lead_id, direction, channel, body, status, created_by, sent_at)
  values (p_lead_id, 'out', 'note', 'Card fixed by ' || initcap(who) || ': ' || array_to_string(changed, '; ') || coalesce(' (' || nullif(btrim(p_why), '') || ')', ''), null, auth.uid(), now());
  return jsonb_build_object('ok', true, 'changed', changed);
end $fn$;

CREATE OR REPLACE FUNCTION public.lead_move(p_lead_id uuid, p_belt text DEFAULT NULL::text, p_reason text DEFAULT NULL::text, p_named_date timestamp with time zone DEFAULT NULL::timestamp with time zone, p_named_event text DEFAULT NULL::text, p_elderly boolean DEFAULT NULL::boolean, p_grief boolean DEFAULT NULL::boolean, p_assigned_to text DEFAULT NULL::text, p_notes text DEFAULT NULL::text, p_stage text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
declare who text; res jsonb := '{"ok":true}'::jsonb; l public.leads;
begin
  perform public.card_guard(p_lead_id);   -- 0250: a card is its caller's
  if not public.is_team() then raise exception 'team only'; end if;
  select display_name into who from public.team_members where lower(email) = lower(auth.jwt() ->> 'email');
  if p_notes is not null then update public.leads set notes = nullif(btrim(p_notes), '') where id = p_lead_id; end if;
  -- Colin's deal stages (offer, under contract, closed) are his to set; the belt follows (offer -> offer out)
  if p_stage is not null then
    if not public.is_owner() then raise exception 'only Colin (owner) sets a deal stage'; end if;
    if p_stage not in ('offer', 'under_contract', 'closed_won', 'walk_decision', 'walkthrough_booked') then raise exception 'not a deal stage: %', p_stage; end if;
    select * into l from public.leads where id = p_lead_id;
    perform set_config('wpie.in_belt_event', '1', true);
    update public.leads set stage = p_stage::public.lead_stage where id = p_lead_id;
    insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
    values (p_lead_id, 'stage_set', l.belt, l.belt, l.belt_step, jsonb_build_object('from', l.stage::text, 'to', p_stage, 'reason', p_reason), now(), who);
    perform set_config('wpie.in_belt_event', '', true);
    if p_stage = 'offer' and p_belt is null then res := public.belt_event(p_lead_id, 'move', jsonb_build_object('belt', 'offer_out', 'reason', coalesce(p_reason, 'offer out')), who); end if;
  end if;
  if p_assigned_to is not null then
    perform set_config('wpie.in_belt_event', '1', true);
    update public.leads set assigned_to = nullif(p_assigned_to, '')::public.team_person where id = p_lead_id;
    perform set_config('wpie.in_belt_event', '', true);
  end if;
  if p_elderly is not null or p_grief is not null then
    res := public.belt_event(p_lead_id, 'flag', jsonb_strip_nulls(jsonb_build_object('elderly_or_ill', p_elderly, 'grief', p_grief, 'reason', p_reason)), who);
  end if;
  if p_named_date is not null or nullif(p_named_event, '') is not null then
    res := public.belt_event(p_lead_id, 'named_date', jsonb_strip_nulls(jsonb_build_object('named_date', p_named_date, 'named_event', p_named_event, 'reason', p_reason)), who);
  end if;
  if p_belt is not null then
    res := public.belt_event(p_lead_id, 'move', jsonb_strip_nulls(jsonb_build_object('belt', p_belt, 'reason', p_reason)), who);
  end if;
  return res;
end $fn$;

CREATE OR REPLACE FUNCTION public.log_call(p_lead_id uuid, p_phone text, p_outcome text, p_note text DEFAULT NULL::text, p_when timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
declare who text; d text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10); l public.leads;
  phones text[]; label text; named_day date; follow_at timestamptz; tz text; disconnected boolean := p_outcome = 'disconnected';
begin
  perform public.card_guard(p_lead_id);   -- 0250: a card is its caller's
  if not public.is_team() then raise exception 'team only'; end if;
  -- a disconnected number (Colin 2026-10-28: "add an option on dialer for disconnected number") is logged the wrong-number
  -- way, so the belt, the call lock and the lists all treat it as they do today: that number is marked bad, the card
  -- stays open, and the owner's next number gets a first text (ready_to_text next_numbers). The card says which.
  if disconnected then p_outcome := 'wrong_number'; end if;
  if p_outcome not in ('interested', 'not_now', 'not_interested', 'wrong_number', 'dnc', 'no_answer', 'reached_no_decision') then
    return jsonb_build_object('ok', false, 'reason', 'pick an outcome');
  end if;
  select * into l from public.leads where id = p_lead_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such lead'); end if;
  tz := public.belt_tz(l.mailing_state);
  if p_outcome = 'not_now' and p_when is not null then
    named_day := (p_when at time zone tz)::date;
    follow_at := public.not_now_followup_at(named_day, l.mailing_state, now());
    if follow_at is null then
      return jsonb_build_object('ok', false, 'reason', 'the check-back date cannot be before today');
    end if;
  end if;
  select display_name into who from public.team_members where lower(email) = lower(auth.jwt() ->> 'email');
  if p_outcome in ('interested', 'reached_no_decision', 'not_now') then perform public.lock_card_to(p_lead_id, public.wpie_person(), 'reached on a call'); end if;
  label := case p_outcome when 'interested' then 'Interested' when 'not_now' then 'Not now' when 'not_interested' then 'Not interested'
                          when 'wrong_number' then case when disconnected then 'Disconnected number' else 'Wrong number' end when 'no_answer' then 'No answer'
                          when 'reached_no_decision' then 'Reached, no decision' else 'Do not contact' end;
  if p_outcome = 'not_now' and p_when is not null then
    update public.leads set named_date = follow_at where id = p_lead_id;
    label := label || ' until ' || to_char(named_day, 'Mon DD');
  end if;
  insert into public.messages (lead_id, direction, channel, body, from_number, sent_at, seen_at, status)
  values (p_lead_id, 'in', 'call', format('Call (%s)%s: %s%s', coalesce(who, 'team'),
            case when d ~ '^[0-9]{10}$' then ' from ' || d else '' end, label,
            coalesce(E'\n' || nullif(btrim(coalesce(p_note, '')), ''), '')),
          case when d ~ '^[0-9]{10}$' then '+1' || d end, now(), now(), p_outcome);
  update public.leads set call_facts = jsonb_set(call_facts, '{last_call}', jsonb_build_object('value', p_outcome, 'at', now(), 'by', who))
   where id = p_lead_id;

  if p_outcome in ('interested', 'reached_no_decision') then
    update public.leads set stage = case when stage in ('walkthrough_booked', 'offer', 'under_contract', 'closed_won') then stage else 'colin_call' end
     where id = p_lead_id;
  elsif p_outcome = 'no_answer' then
    null;
  elsif p_outcome = 'not_now' then
    update public.leads set stage = 'follow_up', next_action = coalesce(next_action, 'Check back'),
           next_action_at = coalesce(follow_at, next_action_at, now() + interval '30 days') where id = p_lead_id;
  elsif p_outcome = 'not_interested' then
    update public.leads set stage = 'dead', dead_reason = coalesce(nullif(btrim(coalesce(p_note, '')), ''), 'Not interested (call)') where id = p_lead_id;
  elsif p_outcome = 'wrong_number' then
    if d ~ '^[0-9]{10}$' then
      update public.contacts set status = 'bad',
             note = case when disconnected then concat_ws('; ', note, 'disconnected (call ' || to_char(now() at time zone 'America/Chicago', 'YYYY-MM-DD') || ')') else note end
       where lead_id = p_lead_id and value_normalized = d;
    end if;
    update public.leads set stage = 'data_fix' where id = p_lead_id;
  else
    select array_agg(distinct c.value_normalized) into phones from public.contacts c
     where c.lead_id = p_lead_id and c.kind = 'phone' and c.value_normalized ~ '^[0-9]{10}$';
    phones := coalesce(phones, '{}');
    if d ~ '^[0-9]{10}$' and not d = any(phones) then phones := array_append(phones, d); end if;
    insert into public.suppressed_phones (phone10, reason, source)
      select distinct p, 'dnc_call', 'app' from unnest(phones) p on conflict (phone10) do nothing;
    update public.contacts set suppressed = true, dnc_app = true where value_normalized = any(phones);
    update public.leads set stage = 'dnc' where id = p_lead_id;
  end if;
  return jsonb_build_object('ok', true, 'outcome', p_outcome, 'until', follow_at, 'named_day', named_day);
end $fn$;

CREATE OR REPLACE FUNCTION public.mark_called(p_lead_id uuid, p_at timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
begin
  perform public.card_guard(p_lead_id);   -- 0250: a card is its caller's
  if not public.is_team() then raise exception 'team only'; end if;
  update public.hot_alerts set called_at = p_at where lead_id = p_lead_id and called_at is null and created_at <= p_at;
  return jsonb_build_object('ok', true);
end $fn$;

CREATE OR REPLACE FUNCTION public.note_add(p_lead_id uuid, p_body text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
declare mid uuid;
begin
  perform public.card_guard(p_lead_id);   -- 0250: a card is its caller's
  if not public.is_team() then raise exception 'team only'; end if;
  if nullif(btrim(coalesce(p_body, '')), '') is null then return jsonb_build_object('ok', false, 'reason', 'an empty note'); end if;
  insert into public.messages (lead_id, direction, channel, body, status, created_by, sent_at)
  values (p_lead_id, 'out', 'note', btrim(p_body), null, auth.uid(), now()) returning id into mid;
  return jsonb_build_object('ok', true, 'id', mid, 'by', public.wpie_person());
end $fn$;

CREATE OR REPLACE FUNCTION public.offer_said(p_lead_id uuid, p_number numeric, p_reaction text, p_counter numeric DEFAULT NULL::numeric, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
declare s public.offer_settings; who text; shot jsonb;
begin
  perform public.card_guard(p_lead_id);   -- 0250: a card is its caller's
  if not public.is_team() then raise exception 'only the team'; end if;
  select * into s from public.offer_settings where id = 1;
  if s.mode = 'off' then return jsonb_build_object('ok', false, 'reason', 'the anchor is off: no number on the phone'); end if;
  if p_reaction not in ('gave_number', 'open', 'no', 'later') then return jsonb_build_object('ok', false, 'reason', 'reaction is gave_number, open, no or later'); end if;
  if p_reaction = 'gave_number' and (p_counter is null or p_counter <= 0) then return jsonb_build_object('ok', false, 'reason', 'write the number they said'); end if;
  shot := public.offer_shoot(p_lead_id);
  if not coalesce((shot->>'ok')::boolean, false) or (shot->>'number')::numeric is distinct from p_number then
    return jsonb_build_object('ok', false, 'reason', 'the only number you say is the one on the card' || coalesce(': ' || (shot->>'number'), ''));
  end if;
  select display_name into who from public.team_members where lower(email) = lower(auth.jwt() ->> 'email');
  update public.leads set
    call_facts = coalesce(call_facts, '{}'::jsonb) || jsonb_build_object('our_number', jsonb_build_object(
        'value', jsonb_build_object('number', p_number, 'choices', jsonb_build_array(p_reaction), 'counter', p_counter, 'text', nullif(btrim(coalesce(p_note, '')), '')),
        'at', now(), 'by', who)),
    notes = concat_ws(' | ', notes, to_char(now() at time zone 'America/Chicago', 'YYYY-MM-DD') || ' anchor said by ' || coalesce(who, 'the team')
            || ': around ' || p_number::text || ', they ' || case p_reaction when 'gave_number' then 'said ' || p_counter::text when 'open' then 'stayed open'
               when 'no' then 'said no' else 'said later' end || coalesce(' (' || nullif(btrim(p_note), '') || ')', ''))
   where id = p_lead_id;
  -- their counter is their number: the script's "Their number" fills in, so the package carries it
  if p_reaction = 'gave_number' then
    update public.leads set call_facts = call_facts || jsonb_build_object('price', jsonb_build_object('value', jsonb_build_object('number', p_counter::text),
      'at', now(), 'by', who)) where id = p_lead_id and nullif(call_facts->'price'->'value'->>'number', '') is null;
  end if;
  return jsonb_build_object('ok', true);
end $fn$;

CREATE OR REPLACE FUNCTION public.offer_setup(p_lead_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
declare s public.offer_standards; me public.team_person := public.wpie_person(); boss boolean;
begin
  perform public.card_guard(p_lead_id);   -- 0250: a card is its caller's
  if not public.is_team() then return jsonb_build_object('ok', false, 'reason', 'not on the team'); end if;
  select * into s from public.offer_standards where id = 1;
  boss := public.is_owner() and me is distinct from 'muse';
  return jsonb_build_object('ok', true,
    'standards', (to_jsonb(s) - 'signature_png' - 'id') || jsonb_build_object('has_signature', s.signature_png is not null),
    'signature_png', case when boss then s.signature_png end,
    'colin_number', public.offer_colin_number(p_lead_id),
    'can_send', me is distinct from 'muse',
    'can_set_price', boss,
    'can_edit_standards', boss);
end $fn$;

CREATE OR REPLACE FUNCTION public.offer_shoot(p_lead_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
declare s public.offer_settings; l public.leads; pv public.property_values; pc public.property_comps; pk public.deal_packages; rh jsonb;
        value numeric; value_basis text; sqft integer; sqft_basis text; units integer; beds integer; baths integer;
        cond text[]; happened text[]; layout text; their text; f jsonb;
        q_roof text; q_hvac text; q_kb text; q_big text; newish boolean := false;
        lines jsonb := '[]'::jsonb; sub numeric := 0; amt numeric; buffer numeric; repairs numeric;
        pct numeric; off numeric; band jsonb; mao numeric; lao numeric; num numeric; asked integer := 0;
        band_key text; tier text; res jsonb;
begin
  perform public.card_guard(p_lead_id);   -- 0250: a card is its caller's
  if not public.is_team() then raise exception 'only the team'; end if;
  select * into s from public.offer_settings where id = 1;
  rh := s.rehab;
  select * into l from public.leads where id = p_lead_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card', 'mode', s.mode); end if;
  f := coalesce(l.call_facts, '{}'::jsonb);
  select * into pk from public.deal_packages d where d.lead_id = p_lead_id
     and d.status in ('waiting_value', 'waiting_number', 'go_walk', 'number_ready', 'counter', 'agreed') order by created_at desc limit 1;
  if l.wpie_property_id is not null then
    select * into pv from public.property_values where wpie_property_id = l.wpie_property_id;
    select * into pc from public.property_comps where wpie_property_id = l.wpie_property_id;
  end if;

  their := nullif(f->'price'->'value'->>'number', '');
  -- size: the county's records, else the bedrooms they said (the Quick number's tap, then the script's layout), else assumed
  units := greatest(coalesce(l.units, 1), 1);
  layout := coalesce(f->'layout'->'value'->>'text', '');
  beds := coalesce(nullif(f->'quick_beds'->'value'->'choices'->>0, '')::integer,
                   nullif(substring(layout from '(\d+)\s*(?:-\s*)?(?:bed|br\b|bd\b|bdrm)'), '')::integer);
  baths := coalesce(nullif(substring(layout from '(\d+)\s*(?:-\s*)?(?:bath|ba\b)'), '')::integer, 1);
  if pv.building_sqft is not null and pv.building_sqft > 0 then sqft := pv.building_sqft; sqft_basis := 'county records';
  elsif beds is not null then sqft := (case when beds <= 1 then 750 when beds = 2 then 950 when beds = 3 then 1250 when beds = 4 then 1600 else 2000 end) * units;
       sqft_basis := beds::text || ' bedrooms, as they said';
  else sqft := s.default_sqft * units; sqft_basis := 'assumed: ask how many bedrooms'; end if;

  -- the value fixed up: the package's (Colin or Muse), else the sold comps' price per square foot x the size (0158)
  if pk.arv is not null and pk.arv > 0 then value := pk.arv; value_basis := 'the package''s value (' || coalesce(pk.valued_by, 'Muse') || ')';
  elsif pc.median_ppsf is not null and pc.median_ppsf > 0 then
    value := round(pc.median_ppsf * sqft / 1000) * 1000;
    value_basis := coalesce(pc.n_comps, 0)::text || ' sold comps (' || coalesce(pc.tier, 'nearby') || ', ' || coalesce(pc.window_months, 12)::text
                   || ' months) at $' || round(pc.median_ppsf)::text || ' a sq ft x ' || sqft::text || ' sq ft';
  elsif pc.median_price is not null and pc.median_price > 0 then
    value := pc.median_price; value_basis := coalesce(pc.n_comps, 0)::text || ' sold comps, median price (no sizes to compare)';
  end if;
  if value is null then
    return jsonb_build_object('ok', false, 'mode', s.mode, 'their_number', their, 'sqft_basis', sqft_basis,
      'reason', 'no sold comps near this house yet: ask for their number, or book Colin');
  end if;

  newish := pv.year_built is not null and pv.year_built >= extract(year from now())::integer - coalesce((rh->>'new_house_years')::integer, 5);

  -- the four quick answers, else the call script's condition chips, else unknown
  select coalesce(array_agg(x), '{}') into cond from jsonb_array_elements_text(coalesce(f->'condition'->'value'->'choices', '[]'::jsonb)) x;
  select coalesce(array_agg(x), '{}') into happened from jsonb_array_elements_text(coalesce(f->'happened'->'value'->'choices', '[]'::jsonb)) x;
  q_roof := f->'quick_roof'->'value'->'choices'->>0;
  q_hvac := f->'quick_hvac'->'value'->'choices'->>0;
  q_kb   := f->'quick_kb'->'value'->'choices'->>0;
  q_big  := f->'quick_big'->'value'->'choices'->>0;
  if q_roof is null then q_roof := case when 'roof' = any(cond) then 'old' when cond && array['cosmetic', 'perfect'] then 'new' end; end if;
  if q_hvac is null then q_hvac := case when 'furnace' = any(cond) then 'old' when cond && array['cosmetic', 'perfect'] then 'new' end; end if;
  if q_kb is null then q_kb := case when 'kitchen_baths' = any(cond) then 'original' when cond && array['cosmetic', 'perfect'] then 'updated' end; end if;
  if q_big is null then q_big := case when cond && array['foundation', 'water'] or happened && array['fire', 'foundation', 'code', 'leak'] then 'yes'
                                       when 'none' = any(happened) then 'no' end; end if;
  asked := (q_roof is not null)::int + (q_hvac is not null)::int + (q_kb is not null)::int + (q_big is not null)::int;

  if q_big = 'yes' then
    return jsonb_build_object('ok', false, 'mode', s.mode, 'their_number', their, 'value', value, 'value_basis', value_basis, 'walk_first', true,
      'reason', 'water, foundation, fire or a code order: no number on the phone, Colin walks it first');
  end if;

  -- Rick's repairs by the square foot (Flip With Rick, "How to Easily Estimate Repair Costs"): the county's square feet
  -- under air times a rate for the condition. Light (carpet, paint, cleanup) $5-10, medium (new roof, carpets, AC, a
  -- kitchen and a bath) $25-30, heavy (the dumps) $50-70, sometimes 100; the padded end of each range by default. The
  -- medium rate already carries the roof and AC, so nothing is added on top. The taps pick the condition: all three
  -- good = light; any old or not asked = medium; nothing asked at all = heavy (Rick: when unsure, go heavy).
  tier := case
    when q_roof is null and q_hvac is null and q_kb is null and not newish then 'heavy'
    when coalesce(q_roof, case when newish then 'new' end) = 'new' and coalesce(q_hvac, case when newish then 'new' end) = 'new'
         and coalesce(q_kb, case when newish then 'updated' end) = 'updated' then 'light'
    else 'medium' end;
  amt := round((rh->>(tier || '_per_ft'))::numeric * sqft);
  lines := lines || jsonb_build_object('item', 'Rick''s rate: ' || tier, 'amount', amt,
    'why', sqft::text || ' sq ft (' || sqft_basis || ') x $' || (rh->>(tier || '_per_ft')) || ' a sq ft; '
           || case tier when 'light' then 'roof, furnace/AC, kitchen and baths all in good shape'
                        when 'heavy' then 'nothing asked yet: heavy' else 'something old or not asked' end);
  sub := sub + amt;
  repairs := sub;

  -- Rick's math: (value - repairs) x the band's percent = the buyer's most; the anchor opens the band's discount under it
  pct := null; off := null;
  for band in select * from jsonb_array_elements(s.bands) loop
    if band->>'upto' is null or value <= (band->>'upto')::numeric then
      pct := (band->>'pct')::numeric; off := nullif(band->>'off', '')::numeric; exit;
    end if;
  end loop;
  pct := coalesce(pct, 0.70); off := coalesce(off, s.lao_discount);
  mao := (value - repairs) * pct;
  lao := mao * (1 - off);
  num := floor(lao / greatest(s.round_to, 1)) * greatest(s.round_to, 1);
  if num < s.min_number then
    return jsonb_build_object('ok', false, 'mode', s.mode, 'their_number', their, 'value', value, 'value_basis', value_basis,
      'repairs', repairs, 'lines', lines, 'asked', asked,
      'reason', 'too thin to say a number (' || round(lao)::text || '): book Colin instead');
  end if;
  res := jsonb_build_object('ok', true, 'mode', s.mode, 'their_number', their,
    'value', value, 'value_basis', value_basis, 'sqft', sqft, 'sqft_basis', sqft_basis, 'units', units, 'size_known', sqft_basis not like 'assumed%',
    'comps', case when pc.wpie_property_id is not null then pc.comps end,
    'lines', lines, 'repairs', repairs, 'asked', asked,
    'tier', tier, 'tier_basis', asked::text || ' of 4 quick answers given; not asked counts as needing work',
    'pct', pct, 'off', off, 'mao', round(mao), 'lao', round(lao), 'number', num,
    'say', 'I can''t give you a firm number on a place we haven''t seen. Rough, and going off what you''ve told me and what the county shows, we''d be somewhere around $' || to_char(num, 'FM999,999,999') || '. Is that even in the conversation?');
  -- the buyer's price stays with Colin (Colin 2026-10-31: "don't show buyers price"): callers get the number to say
  return case when public.is_owner() then res else res - 'mao' - 'lao' - 'pct' end;
end $fn$;

CREATE OR REPLACE FUNCTION public.power_claim(p_lead_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
declare me public.team_person := public.wpie_person(); other public.power_claims;
begin
  perform public.card_guard(p_lead_id);   -- 0250: a card is its caller's
  if me is null then raise exception 'team only'; end if;
  select * into other from public.power_claims where lead_id = p_lead_id for update;
  if found and other.person <> me and other.until > now() then
    return jsonb_build_object('ok', false, 'reason', 'on ' || initcap(other.person::text) || '''s screen', 'person', other.person);
  end if;
  insert into public.power_claims (lead_id, person, until) values (p_lead_id, me, now() + interval '4 minutes')
  on conflict (lead_id) do update set person = excluded.person, until = excluded.until;
  return jsonb_build_object('ok', true);
end $fn$;

CREATE OR REPLACE FUNCTION public.release_unclaimed_human_call(p_lead_id uuid, p_key text, p_error text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
declare who text; r jsonb; e text := nullif(left(btrim(coalesce(p_error, '')), 300), '');
begin
  perform public.card_guard(p_lead_id);   -- 0250: a card is its caller's
  if not public.is_team() then raise exception 'team only'; end if;
  select tm.display_name into who from public.team_members tm where lower(tm.email) = lower(auth.jwt() ->> 'email');
  r := public.release_unclaimed_call_core(p_lead_id, p_key, 'the call never reached the phone company', coalesce(who, 'team'), now());
  if e is not null and coalesce((r->>'released')::boolean, false) then
    update public.belt_events set payload = payload || jsonb_build_object('client_error', e)
     where lead_id = p_lead_id and event = 'human_call_resumed' and payload->>'key' = 'human_resume:' || p_key;
  end if;
  return r;
end $fn$;

CREATE OR REPLACE FUNCTION public.resume_human_call(p_lead_id uuid, p_key text, p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
declare l public.leads; who text; d record;
begin
  perform public.card_guard(p_lead_id);   -- 0250: a card is its caller's
  if not public.is_team() then raise exception 'team only'; end if;
  select * into l from public.leads where id = p_lead_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such lead'); end if;
  if l.human_takeover_at is null then return jsonb_build_object('ok', true, 'duplicate', true, 'paused', false); end if;
  if l.human_takeover_key is distinct from p_key then return jsonb_build_object('ok', false, 'reason', 'that is not the active call'); end if;
  select tm.display_name into who from public.team_members tm where lower(tm.email) = lower(auth.jwt() ->> 'email');
  for d in select x->>'id' as id, x->>'status' as status from jsonb_array_elements(coalesce(l.human_takeover_drafts, '[]'::jsonb)) x loop
    update public.reply_drafts set status = d.status,
      note = regexp_replace(coalesce(note, ''), ' \| human call ' || p_key || '$', ''), updated_at = p_now
      where id = d.id::uuid and lead_id = p_lead_id and status = 'superseded';
  end loop;
  update public.leads set human_takeover_at = null, human_takeover_by = null,
    human_takeover_phone = null, human_takeover_key = null, human_takeover_drafts = null,
    human_takeover_assigned_to = null where id = p_lead_id;
  insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
    values (p_lead_id, 'human_call_resumed', l.belt, l.belt, l.belt_step,
      jsonb_build_object('key', 'human_resume:' || p_key, 'reason', 'call did not start'), p_now, coalesce(who, 'team'));
  return jsonb_build_object('ok', true, 'duplicate', false, 'paused', false);
end $fn$;

CREATE OR REPLACE FUNCTION public.verdict_no(p_lead_id uuid, p_reason text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
declare who text;
begin
  perform public.card_guard(p_lead_id);   -- 0250: a card is its caller's
  if not public.is_team() then raise exception 'team only'; end if;
  select display_name into who from public.team_members where lower(email) = lower(auth.jwt() ->> 'email');
  return public.belt_event(p_lead_id, 'verdict_no', jsonb_build_object('reason', p_reason, 'note', p_note), who, now());
end $fn$;

CREATE OR REPLACE FUNCTION public.walk_outcome(p_lead_id uuid, p_outcome text, p_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
declare l public.leads; who public.team_person; what text; res jsonb; at timestamptz; ev text; n integer; by_name text;
begin
  perform public.card_guard(p_lead_id);   -- 0250: a card is its caller's
  if not public.is_team() then raise exception 'team only'; end if;
  select * into l from public.leads where id = p_lead_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card'); end if;
  who := public.wpie_person();
  by_name := initcap(coalesce(who::text, 'team'));
  if not public.is_owner() and l.locked_to is distinct from who then return jsonb_build_object('ok', false, 'reason', 'not your card'); end if;
  -- what is booked: a walk (Colin's visit) or a call
  what := case when l.belt in ('visit_booked', 'visit_missed') or l.stage::text = 'walkthrough_booked' then 'walk' else 'call' end;
  if p_outcome = 'rebook' then
    if p_at is null then return jsonb_build_object('ok', false, 'reason', 'a day and time'); end if;
    res := public.belt_event(p_lead_id, 'next_step', jsonb_build_object('kind', case when what = 'walk' then 'walk' else 'callback' end, 'at', p_at, 'note', p_note), by_name, now());
    insert into public.messages (lead_id, direction, channel, body, status, created_by, sent_at)
    values (p_lead_id, 'out', 'note', initcap(what) || ' moved to ' || to_char(p_at at time zone 'America/Chicago', 'Dy Mon FMDD, FMHH:MI AM')
            || coalesce(' (' || nullif(btrim(p_note), '') || ')', '') || ' by ' || by_name, null, auth.uid(), now());
    return coalesce(res, '{}'::jsonb) || jsonb_build_object('ok', true, 'outcome', 'rebook', 'at', p_at);
  elsif p_outcome = 'waver' then
    insert into public.messages (lead_id, direction, channel, body, status, created_by, sent_at)
    values (p_lead_id, 'out', 'note', 'Wavering before the ' || what || ': ' || coalesce(nullif(btrim(p_note), ''), 'no words given') || ' (' || by_name || ')', null, auth.uid(), now());
    at := greatest(now() + interval '5 minutes', coalesce(l.named_date, now()) - interval '1 hour');
    insert into public.tasks (lead_id, due_at, kind, owner, note, created_by, source, source_key, title)
    values (p_lead_id, at, 'call', 'colin', 'Seller wavered before the ' || what || coalesce(' at ' || to_char(l.named_date at time zone 'America/Chicago', 'Dy FMHH:MI AM'), '')
            || ': "' || coalesce(nullif(btrim(p_note), ''), '') || '". Decide whether to go; the ' || what || ' is still on.', auth.uid(), 'waver',
            'waver:' || p_lead_id::text || ':' || to_char(now(), 'YYYYMMDDHH24MI'), 'Seller wavered: go or not?')
    on conflict (source_key) do nothing;
    insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
    values (p_lead_id, 'flag', l.belt, l.belt, l.belt_step, jsonb_build_object('flag', 'waver', 'note', p_note), now(), by_name);
    return jsonb_build_object('ok', true, 'outcome', 'waver', 'colin_call_at', at);
  elsif p_outcome in ('no_show', 'check_back') then
    at := coalesce(p_at, now() + interval '3 days');
    ev := coalesce(nullif(btrim(p_note), ''), case when p_outcome = 'no_show' then 'no-show on the ' || what else 'check back' end);
    -- the walk's own tasks come off (the belt change cancels its stops; the confirm call is not a belt stop)
    update public.tasks t set done_at = now(), note = concat_ws(' | ', t.note, p_outcome || ' (' || by_name || ')')
     where t.lead_id = p_lead_id and t.done_at is null and (t.source in ('walk_confirm', 'waver') or (t.kind = 'callback' and t.source is distinct from 'belt'));
    get diagnostics n = row_count;
    res := public.belt_event(p_lead_id, 'named_date', jsonb_build_object('named_date', at, 'named_event', ev, 'reason', p_outcome), by_name, now());
    insert into public.messages (lead_id, direction, channel, body, status, created_by, sent_at)
    values (p_lead_id, 'out', 'note', (case when p_outcome = 'no_show' then 'No-show on the ' || what else 'Off the ' || what || ', check back' end) || ': ' || ev
            || '. Check-back ' || to_char(at at time zone 'America/Chicago', 'Dy Mon FMDD') || ' (' || by_name || ')', null, auth.uid(), now());
    return coalesce(res, '{}'::jsonb) || jsonb_build_object('ok', true, 'outcome', p_outcome, 'check_back_at', at, 'tasks_closed', n);
  end if;
  return jsonb_build_object('ok', false, 'reason', 'rebook, waver, no_show or check_back');
end $fn$;

-- the one view a login reads straight (cards with no next stop) read past the read rules: from here it reads as the person asking
alter view public.cards_no_stop set (security_invoker = true);
