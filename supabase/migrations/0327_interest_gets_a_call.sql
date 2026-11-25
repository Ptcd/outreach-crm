-- 0327: an interested seller gets a call, whoever is or is not at work.
--
-- Colin 2026-11-25: "I'm finding that the cards that have some interest aren't getting the action they need from
-- thalia and Tyler, how [can] we just make that a function of our program, e2e check into this and test it".
--
-- What the records showed that day (14 days): Thalia had 18 interested sellers, called 10 inside a day, never called
-- 6. Tyler had 23, called 4 inside a day, never called 17; of his 10 cards that said yes, 5 had never been dialed.
-- Tyler dialed on 4 of the last 11 weekdays. The chain interest -> task -> top of the list (0315, two days old)
-- worked for the caller who was at work. Two leaks in it, and one hole behind it:
--
--   1. A seller who said yes got no reply call when the card already held ANY call task (its belt follow-up, or a
--      morning-list task): warm_sellers counted that as "has a task". Olson and Devey said yes on 2026-11-24 and sat
--      at places 34 and 35 of Tyler's list behind 19 cold sale cards; Palace Investments ("Yes. I am selling these
--      houses", 8 days) was not in the first 200. Now only a task that puts the card at the top counts.
--   2. (the app) a list handed to Power hour from Today went ahead of the reply calls, and Skip sent a reply call
--      behind the whole cold list. Fixed in PowerDial.
--   3. The hole: a card has one owner (0250), so when its caller does not dial, nobody may. warm_rescue_tick moves an
--      interested seller to the other caller when their own caller has not dialed them in warm_rescue_hours (24) and
--      the other caller is working (not off today, dialed in the last 26 hours). Once per card; the move is the same
--      one Colin makes by hand (card_move, which card_reassign now calls), so the card still has one owner, the open
--      call goes with it and lands at the top of the new caller's list. OFF as shipped (campaign_control.warm_rescue):
--      taking cards from a caller is Colin's word. warm_rescue_tick(now(), true) says what it would move.

alter table public.campaign_control add column if not exists warm_rescue boolean not null default false;
alter table public.campaign_control add column if not exists warm_rescue_hours int not null default 24;
alter table public.campaign_control add column if not exists warm_rescue_max_day int not null default 12;

create table if not exists public.warm_rescues (
  lead_id   uuid primary key references public.leads(id) on delete cascade,
  from_who  text not null,
  to_who    text not null,
  waited_h  numeric,
  why       text,
  at        timestamptz not null default now()
);
alter table public.warm_rescues enable row level security;
grant select on public.warm_rescues to authenticated, service_role;
drop policy if exists warm_rescues_owner_read on public.warm_rescues;
create policy warm_rescues_owner_read on public.warm_rescues for select to authenticated using (public.is_owner());

-- the move itself, shared by Colin's reassign and the rescue
create or replace function public.card_move(p_lead_id uuid, p_person public.team_person, p_why text, p_by text) returns jsonb
language plpgsql security definer set search_path = public as $function$
declare l public.leads; was public.team_person; n integer;
begin
  if p_person not in ('thalia', 'adil') then return jsonb_build_object('ok', false, 'reason', 'a card belongs to Thalia or Adil'); end if;
  select * into l from public.leads where id = p_lead_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card'); end if;
  was := l.locked_to;
  if was is not distinct from p_person then return jsonb_build_object('ok', true, 'already', true); end if;
  update public.leads set locked_to = p_person, locked_at = now(),
         assigned_to = case when assigned_to in ('thalia', 'adil') or assigned_to is null then p_person else assigned_to end,
         human_takeover_assigned_to = case when human_takeover_assigned_to in ('thalia', 'adil') then p_person else human_takeover_assigned_to end,
         next_stop_who = next_stop_who
   where id = p_lead_id;
  -- the card's open calls and callbacks go with it (Colin's own stay his)
  update public.tasks set owner = p_person, updated_at = now(), notified_at = null
   where lead_id = p_lead_id and done_at is null and owner in ('thalia', 'adil') and owner <> p_person;
  get diagnostics n = row_count;
  insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
  values (p_lead_id, 'reassigned', l.belt, l.belt, l.belt_step, jsonb_build_object('from', was, 'to', p_person, 'why', p_why, 'tasks_moved', n), now(), p_by);
  insert into public.messages (lead_id, direction, channel, body, status, created_by, sent_at)
  values (p_lead_id, 'out', 'note', 'Card moved to ' || initcap(p_person::text) || coalesce(' from ' || initcap(was::text), '') || coalesce(': ' || nullif(btrim(p_why), ''), ''), null, auth.uid(), now());
  return jsonb_build_object('ok', true, 'from', was, 'to', p_person, 'tasks_moved', n);
end $function$;

create or replace function public.card_reassign(p_lead_id uuid, p_person public.team_person, p_why text default null) returns jsonb
language plpgsql security definer set search_path = public as $function$
begin
  if not public.is_owner() then raise exception 'only Colin moves a card'; end if;
  return public.card_move(p_lead_id, p_person, p_why, 'Colin');
end $function$;

-- p_dry: say what would move and change nothing (works with the switch off)
create or replace function public.warm_rescue_tick(p_now timestamptz default now(), p_dry boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare c public.campaign_control; d date := (p_now at time zone 'America/Chicago')::date; r record; other public.team_person;
  moved jsonb := '[]'::jsonb; n int := 0; today int;
begin
  select * into c from public.campaign_control where id = 1;
  if not p_dry and not coalesce(c.warm_rescue, false) then return jsonb_build_object('on', false); end if;
  select count(*) into today from public.warm_rescues w where (w.at at time zone 'America/Chicago')::date = d;
  for r in
    select w.*, l.owner_name, l.property_address
      from public.warm_sellers(p_now) w join public.leads l on l.id = w.lead_id
     where w.warm_at < p_now - make_interval(hours => c.warm_rescue_hours)
       and (w.last_dial is null or w.last_dial < p_now - make_interval(hours => c.warm_rescue_hours))
       and not exists (select 1 from public.warm_rescues x where x.lead_id = w.lead_id)
     order by w.warm_at
  loop
    exit when today + n >= c.warm_rescue_max_day;
    other := case r.caller when 'thalia' then 'adil'::public.team_person else 'thalia'::public.team_person end;
    -- the other caller has to be at work: not off today, and has dialed in the last 26 hours
    continue when public.caller_is_off(other, d);
    continue when not exists (
      select 1 from public.belt_events e where e.event = 'human_call_started' and e.at > p_now - interval '26 hours' and lower(e.by) in (other::text, case other when 'adil' then 'tyler' else other::text end));
    n := n + 1;
    moved := moved || jsonb_build_object('owner', r.owner_name, 'address', r.property_address, 'from', r.caller, 'to', other,
                                         'waited_hours', round((extract(epoch from p_now - r.warm_at) / 3600)::numeric), 'dials', r.dials, 'said', r.words);
    if p_dry then continue; end if;
    perform public.card_move(r.lead_id, other, 'said they would sell ' || to_char(r.warm_at at time zone 'America/Chicago', 'Mon FMDD')
                                              || ' and was not called for a day', 'system');
    insert into public.warm_rescues (lead_id, from_who, to_who, waited_h, why)
    values (r.lead_id, r.caller::text, other::text, round((extract(epoch from p_now - r.warm_at) / 3600)::numeric), left(r.words, 200));
    -- the reply call is the new caller's, due now, at the top of their list
    insert into public.tasks (lead_id, due_at, kind, owner, source, source_key, title, note, phone10, quote)
    values (r.lead_id, p_now, 'call', other, 'call_next', 'warm:' || r.lead_id::text || ':' || d::text || ':moved',
            'Wrote back interested: call today',
            'Moved to you: they wrote on ' || to_char(r.warm_at at time zone 'America/Chicago', 'Mon FMDD') || ': "' || coalesce(r.words, '') || '" and nobody called for a day. Get the story, say it back, offer the fix.',
            nullif(r.phone10, ''), nullif(r.words, ''))
    on conflict (source_key) do nothing;
    update public.tasks set due_at = least(due_at, p_now), notified_at = null
     where lead_id = r.lead_id and done_at is null and source = 'call_next' and owner = other;
  end loop;
  return jsonb_build_object('on', coalesce(c.warm_rescue, false), 'dry', p_dry, 'moved', n, 'cards', moved);
end $fn$;
revoke all on function public.warm_rescue_tick(timestamptz, boolean), public.card_move(uuid, public.team_person, text, text) from public, anon, authenticated;
grant execute on function public.warm_rescue_tick(timestamptz, boolean), public.card_move(uuid, public.team_person, text, text) to service_role;

-- only a task that puts the card at the top counts as "has a task"
CREATE OR REPLACE FUNCTION public.warm_sellers(p_now timestamp with time zone DEFAULT now())
 RETURNS TABLE(lead_id uuid, caller team_person, warm_at timestamp with time zone, intent text, words text, phone10 text, dials integer, last_dial timestamp with time zone, has_task boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with c as (select * from public.campaign_control where id = 1),
  talk as (select m.lead_id, max(m.sent_at) at from public.messages m
            where m.channel = 'call' and m.status = any (public.warm_talk_statuses()) group by 1),
  -- the first warm reply since anyone last talked to them, inside the window
  w as (
    select distinct on (d.lead_id) d.lead_id, d.inbound_at as warm_at, d.intent, d.inbound_body, d.phone10
      from public.reply_drafts d left join talk t on t.lead_id = d.lead_id
     where d.lead_id is not null and not coalesce(d.is_test, false) and d.intent = any (public.warm_intents())
       and d.inbound_at > p_now - make_interval(days => (select warm_days from c))
       and (t.at is null or d.inbound_at > t.at)
     order by d.lead_id, d.inbound_at)
  select w.lead_id, public.card_caller(l.id), w.warm_at, w.intent, left(regexp_replace(coalesce(w.inbound_body, ''), '\s+', ' ', 'g'), 160), w.phone10,
         (select count(*)::int from public.messages m where m.lead_id = l.id and m.channel = 'call' and m.sent_at > w.warm_at
             and coalesce(m.status, '') not like 'inbound%' and coalesce(m.status, '') <> 'call_notes'),
         (select max(m.sent_at) from public.messages m where m.lead_id = l.id and m.channel = 'call' and m.sent_at > w.warm_at
             and coalesce(m.status, '') not like 'inbound%' and coalesce(m.status, '') <> 'call_notes'),
         -- 0327: "has a task" means a task that puts the card at the TOP of the caller's list (a reply call, the assistant's
         -- call back, a missed call), not any call task. A said-yes card with only its belt follow-up or a morning-list
         -- task used to count, so it got no reply call and sat behind the cold list.
         exists (select 1 from public.tasks t where t.lead_id = l.id and t.done_at is null and t.kind = 'call' and t.due_at <= p_now + interval '12 hours'
                    and (coalesce(t.source, '') in ('call_next', 'voice_agent') or t.title = 'They called us: call back'))
    from w join public.leads l on l.id = w.lead_id
   where l.stage::text not in ('dnc', 'dead', 'closed_no_contact', 'closed_won', 'under_contract', 'walkthrough_booked', 'offer')
     and coalesce(l.belt, '') not in ('dead', 'dnc')
     and l.owner_name not ilike 'TEST %'
     and public.card_caller(l.id)::text in ('thalia', 'adil')
     and l.parked_at is null and (l.rest_until is null or l.rest_until <= p_now) and (l.named_date is null or l.named_date <= p_now)
     and not coalesce(l.elderly_or_ill, false) and not coalesce(l.grief, false)
     -- nobody reached by phone since they wrote
     and not exists (select 1 from talk t where t.lead_id = l.id and t.at > w.warm_at)
     -- no later reply that ended it
     and not exists (select 1 from public.reply_drafts e where e.lead_id = l.id and e.inbound_at > w.warm_at and not coalesce(e.is_test, false)
                        and (e.intent in ('opt_out', 'not_interested', 'sold', 'wrong_number', 'hostile', 'signed_other')
                             or coalesce(e.outcome, '') in ('dnc', 'dead', 'not_interested', 'wrong_number', 'stop')))
     -- not one Colin passed on
     and not exists (select 1 from public.deal_sheets s where s.lead_id = l.id and s.colin_pass)
     and not exists (select 1 from public.deal_packages p where p.lead_id = l.id and (p.colin_call = 'pass' or p.status = 'declined'))
     -- no call already booked with them
     and not exists (select 1 from public.tasks t where t.lead_id = l.id and t.done_at is null and t.kind = 'callback' and t.due_at > p_now)
     -- a number someone can dial
     and public.card_has_live_phone(l.id)
$function$;

-- the quarter-hour tick also runs the rescue
CREATE OR REPLACE FUNCTION public.warm_sellers_tick(p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare c public.campaign_control; d date := (p_now at time zone 'America/Chicago')::date; r record; n integer := 0; got uuid;
begin
  select * into c from public.campaign_control where id = 1;
  if not coalesce(c.warm_check, true) then return jsonb_build_object('ran', false, 'why', 'switched off'); end if;
  for r in select * from public.warm_sellers(p_now) w
            where not w.has_task and w.dials < coalesce(c.warm_max_dials, 8)
              and (w.last_dial is null or w.last_dial < p_now - interval '20 hours')
              and not public.caller_is_off(w.caller, d)
  loop
    got := null;
    insert into public.tasks (lead_id, due_at, kind, owner, source, source_key, title, note, phone10, quote)
    values (r.lead_id, p_now, 'call', r.caller, 'call_next', 'warm:' || r.lead_id::text || ':' || d::text,
            'Wrote back interested: call today',
            'They wrote on ' || to_char(r.warm_at at time zone 'America/Chicago', 'Mon FMDD') || ': "' || coalesce(r.words, '') || '". '
              || case when r.dials = 0 then 'Nobody has called them since.' else r.dials || ' dials since, nobody reached.' end
              || ' Get the story, say it back, offer the fix.',
            nullif(r.phone10, ''), nullif(r.words, ''))
    on conflict (source_key) do nothing returning id into got;
    if got is not null then n := n + 1; end if;
  end loop;
  -- 0327: an interested seller whose caller has not dialed them in a day goes to the caller who is working (when on)
  return jsonb_build_object('ran', true, 'day', d, 'tasks_made', n, 'warm_now', (select count(*) from public.warm_sellers(p_now)),
                            'rescue', public.warm_rescue_tick(p_now, false));
end $function$;

-- A seller calling back the number they were just dialed from rings the caller who dialed. Tyler's dials are logged
-- under his name ("Tyler") while this looked for his login ("adil"), so his return calls were never his; and a card
-- assigned to a caller but not locked rang whoever was on shift. Since 0325 a call shows the card's number, not the
-- caller's own line, so this is the only thing that brings a return call to the right person.
CREATE OR REPLACE FUNCTION public.inbound_call_ring(p_digits text, p_at timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with d as (select right(regexp_replace(coalesce(p_digits, ''), '\D', '', 'g'), 10) as ph),
  last_dialer as (
    select case lower(e.by) when 'tyler' then 'adil' else lower(e.by) end as who from public.belt_events e, d
     where e.event = 'human_call_started' and e.at > p_at - interval '60 minutes' and e.at <= p_at
       and right(regexp_replace(coalesce(e.payload->>'phone', ''), '\D', '', 'g'), 10) = d.ph and d.ph <> ''
       and lower(e.by) in ('thalia', 'adil', 'tyler', 'colin')
     order by e.at desc limit 1),
  card as (
    select l.id, l.owner_name, l.property_address, l.municipality, coalesce(l.locked_to::text, public.card_caller(l.id)::text) as who
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
    -- 0316: a return call means someone was just dialing; otherwise a caller inside their hours
    'staffed', (select who from last_dialer) is not null or public.callers_working(p_at),
    'whatsapp', (select coalesce(jsonb_object_agg(m.person::text, m.alert_whatsapp), '{}'::jsonb)
                   from public.team_members m where m.person::text in (select unnest(r.who) from ring r) and m.alert_whatsapp is not null),
    'card', (select jsonb_build_object('lead_id', c.id, 'owner_name', c.owner_name, 'address', c.property_address, 'municipality', c.municipality,
                                       'lang', public.phone_lang(p_digits)) from card c))
$function$;
