-- 0315: a seller who writes back interested gets a call that day, and one nobody has called in 24 hours is named.
--
-- Colin 2026-11-23, after the 30-day count: 96 sellers wrote back warm (interested, asked our price, an estate, a
-- foreclosure), 43 were never dialed afterwards, 13 were talked to, one offer went out. Both callers dropped about
-- the same share (Tyler 22 of 45, Thalia 20 of 50), so it is not one person: many warm replies never became a call
-- task, and nothing said so. "Yes, build it."
--
--   warm_sellers(now)       the sellers this is about: a warm reply in the last campaign_control.warm_days (21), on a live
--                           card a caller owns, nobody reached by phone since, no later reply that ended it (a STOP, a no,
--                           sold, wrong number), not parked, resting, held to a date, elderly or grieving, not one Colin
--                           passed on, and no call already booked.
--   warm_sellers_tick(now)  every quarter hour: each of them with no call task due and no dial in the last 20 hours gets a
--                           "wrote back interested" call task for the card's caller (source call_next, which the queue
--                           puts ahead of every list). One a card a day, until someone is reached or warm_max_dials (8)
--                           dials have rung out. Not on a day the caller is off.
--   warm_sellers_open(now)  for the morning email: who wrote back warm over 24 hours ago and has not been dialed since, by
--                           caller, and how many rang out at the dial limit.
--   warm_scorecard(days)    per caller: warm sellers, called inside 24 hours, reached, never called.
--
-- A call task is the flag to the caller; the morning email's one line is the flag to Colin. No push, no text.

alter table public.campaign_control add column if not exists warm_check boolean not null default true;
alter table public.campaign_control add column if not exists warm_days integer not null default 21;
alter table public.campaign_control add column if not exists warm_max_dials integer not null default 8;
comment on column public.campaign_control.warm_check is 'Give every seller who wrote back interested a call task the same day (0315).';

create or replace function public.warm_intents() returns text[] language sql immutable as $fn$
  select array['interested', 'price_first', 'wants_call', 'estate', 'terms', 'number_only', 'think_it_over', 'foreclosure']
$fn$;

create or replace function public.warm_talk_statuses() returns text[] language sql immutable as $fn$
  select array['interested', 'reached', 'reached_no_decision', 'not_now', 'not_interested', 'booked', 'inbound_answered']
$fn$;

create or replace function public.warm_sellers(p_now timestamptz default now())
 returns table (lead_id uuid, caller public.team_person, warm_at timestamptz, intent text, words text, phone10 text,
                dials integer, last_dial timestamptz, has_task boolean)
 language sql stable security definer set search_path = public as $fn$
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
         exists (select 1 from public.tasks t where t.lead_id = l.id and t.done_at is null and t.kind = 'call' and t.due_at <= p_now + interval '12 hours')
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
$fn$;

create or replace function public.warm_sellers_tick(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public as $fn$
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
  return jsonb_build_object('ran', true, 'day', d, 'tasks_made', n, 'warm_now', (select count(*) from public.warm_sellers(p_now)));
end $fn$;

create or replace function public.warm_sellers_open(p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public as $fn$
  with w as (select w.*, l.owner_name, l.property_address, l.municipality from public.warm_sellers(p_now) w join public.leads l on l.id = w.lead_id),
  late as (select * from w where dials = 0 and warm_at < p_now - interval '24 hours'),
  out_ as (select * from w where dials >= (select coalesce(warm_max_dials, 8) from public.campaign_control where id = 1))
  select jsonb_build_object(
    'warm_now', (select count(*) from w),
    'never_called', (select count(*) from late),
    'by_caller', coalesce((select jsonb_object_agg(x.caller, x.n) from (select caller::text, count(*) n from late group by 1) x), '{}'::jsonb),
    'rang_out', (select count(*) from out_),
    'who', coalesce((select jsonb_agg(jsonb_build_object('caller', caller::text, 'owner', owner_name, 'address', property_address, 'town', municipality,
                       'said', words, 'days', floor(extract(epoch from (p_now - warm_at)) / 86400)::int) order by warm_at)
                       from (select * from late order by warm_at limit 12) x), '[]'::jsonb))
$fn$;

create or replace function public.warm_scorecard(p_days integer default 14, p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public as $fn$
  with w as (
    select distinct on (d.lead_id) d.lead_id, d.inbound_at as warm_at from public.reply_drafts d
     where d.lead_id is not null and not coalesce(d.is_test, false) and d.intent = any (public.warm_intents())
       and d.inbound_at > p_now - make_interval(days => greatest(1, p_days))
     order by d.lead_id, d.inbound_at),
  x as (
    select coalesce(public.card_caller(w.lead_id)::text, 'nobody') caller,
           (select min(m.sent_at) from public.messages m where m.lead_id = w.lead_id and m.channel = 'call' and m.sent_at > w.warm_at
               and coalesce(m.status, '') not like 'inbound%' and coalesce(m.status, '') <> 'call_notes') first_dial,
           exists (select 1 from public.messages m where m.lead_id = w.lead_id and m.channel = 'call' and m.sent_at > w.warm_at
                      and m.status = any (public.warm_talk_statuses())) talked, w.warm_at
      from w)
  select coalesce(jsonb_object_agg(caller, jsonb_build_object('warm', n, 'called_in_24h', in24, 'reached', talked, 'never_called', never)), '{}'::jsonb)
    from (select caller, count(*) n, count(*) filter (where first_dial <= warm_at + interval '24 hours') in24,
                 count(*) filter (where talked) talked, count(*) filter (where first_dial is null) never from x group by 1) y
$fn$;

revoke all on function public.warm_sellers(timestamptz), public.warm_sellers_tick(timestamptz), public.warm_sellers_open(timestamptz),
  public.warm_scorecard(integer, timestamptz) from public, anon, authenticated;
grant execute on function public.warm_sellers(timestamptz), public.warm_sellers_tick(timestamptz), public.warm_sellers_open(timestamptz),
  public.warm_scorecard(integer, timestamptz) to service_role;

do $do$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if exists (select 1 from cron.job where jobname = 'wpie-warm-sellers') then
      perform cron.unschedule('wpie-warm-sellers');
    end if;
    perform cron.schedule('wpie-warm-sellers', '6,21,36,51 * * * *', 'select public.warm_sellers_tick()');
  end if;
end
$do$;
