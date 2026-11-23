-- 0311: best first, every day. Colin 2026-11-23, after four weeks of the callers' dials were read (886 cards, about 4%
-- reached, 80% of them tier C or D, while 191 tier B cards with a phone had never been called): "Yes, every day" to
-- the strongest-first order being the standing order of both call lists.
--
-- power_list_by_need (0262) ranked one caller's list for one day when someone asked. Now power_lists_morning runs it
-- for each caller who works that day, before the day starts (5 AM Central or later, once a day; cron tries at three
-- UTC hours so the clock change needs no edit). Calls rest on Sunday and a caller who is off (caller_is_off) gets
-- no list. The ranking itself is 0262's: a sheriff sale 14+ days out, then tier A, B, C, then the kind of need; tier D
-- is never put on the list by it; the rest of the caller's list stays, behind. A ranked task from an earlier day
-- whose card fell off the list is closed as power_hour_dropped (not a call made), so an old ranking does not keep a
-- card on the list. Switch: campaign_control.power_list_daily; size: power_list_top (120). Each run is a row in
-- power_list_runs.

alter table public.campaign_control add column if not exists power_list_daily boolean not null default true;
alter table public.campaign_control add column if not exists power_list_top integer not null default 120;
comment on column public.campaign_control.power_list_daily is 'Rank both callers'' call lists strongest first every working morning (0311).';
comment on column public.campaign_control.power_list_top is 'How many ranked cards the morning list gives each caller (0311).';

create table if not exists public.power_list_runs (
  day date not null,
  person public.team_person not null,
  at timestamptz not null default now(),
  result jsonb not null,
  primary key (day, person)
);
alter table public.power_list_runs enable row level security;
revoke all on public.power_list_runs from anon, authenticated;
grant select on public.power_list_runs to service_role;

CREATE OR REPLACE FUNCTION public.power_list_by_need(p_person team_person, p_day date DEFAULT NULL::date, p_top integer DEFAULT 120, p_dry boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  d date := coalesce(p_day, (now() at time zone 'America/Chicago')::date);
  -- 6 AM: before the laptop's own call list (due 7 AM), because the queue takes a card's earliest open task and a
  -- card whose earliest task is not a list task falls out of the list's place in the order
  base timestamptz := (coalesce(p_day, (now() at time zone 'America/Chicago')::date) + time '06:00') at time zone 'America/Chicago';
  r record; tid uuid; n_new integer := 0; n_moved integer := 0; n_behind integer := 0; n_dropped integer := 0; top jsonb; by_tier jsonb;
begin
  if not (public.is_owner() or auth.uid() is null) then raise exception 'only Colin or the desk ranks a caller''s list'; end if;
  if not public.is_caller_person(p_person) then return jsonb_build_object('ok', false, 'reason', 'a list is a caller''s: thalia or adil'); end if;
  drop table if exists _need;
  create temp table _need on commit drop as
  with c as (
    select l.id as lead_id, l.owner_name, l.property_address, l.municipality, l.stacked_at,
           coalesce(f.tier, m.tier) as tier, coalesce(m.families, 0) as families, coalesce(m.family_list, f.need_why) as family_list,
           coalesce(m.tax_years, 0) as tax_years, sd.sale_date, coalesce(sd.sale_date >= d + 14, false) as sale_ahead,
           coalesce(f.equity, sd.equity) as equity
      from public.leads l
      left join public.text_fitness f on f.wpie_owner_id = l.wpie_owner_id and l.wpie_owner_id > 0
      left join public.lead_motivation m on m.lead_id = l.id
      left join public.card_sale_dates sd on sd.lead_id = l.id
     where public.card_caller(l.id) = p_person
       and not public.card_is_closed(l.stage) and l.stage::text not in ('under_contract', 'data_fix')
       and coalesce(f.tier, m.tier) in ('A', 'B', 'C')
       -- a phone that may be dialed
       and exists (select 1 from public.contacts ct where ct.lead_id = l.id and ct.kind = 'phone' and ct.status = 'ok' and not ct.dnc_app
                      and not ct.suppressed and not ct.dnc_vendor and ct.dnc_scrub <> 'dnc'
                      and not exists (select 1 from public.suppressed_phones s where s.phone10 = ct.value_normalized)
                      and public.phone_person_block(ct.value_normalized) is null)
       -- fewer than three dials this week, and nobody reached in the last two weeks (that card is on its follow-up)
       and (select count(*) from public.messages mm where mm.lead_id = l.id and mm.channel = 'call' and coalesce(mm.status, '') not like 'inbound%'
              and mm.sent_at > now() - interval '7 days') < 3
       -- 0265: not a card already dialed on the day the list is for. A list built in the morning has none; a list
       -- topped up in the afternoon must not hand back the cards the caller just tried.
       and not exists (select 1 from public.messages mm where mm.lead_id = l.id and mm.channel = 'call' and coalesce(mm.status, '') not like 'inbound%'
                          and (mm.sent_at at time zone 'America/Chicago')::date = d)
       and not exists (select 1 from public.messages mm where mm.lead_id = l.id and mm.channel = 'call' and mm.sent_at > now() - interval '14 days'
                          and coalesce(mm.status, '') not in ('no_answer', 'voicemail', 'inbound_missed', 'missed', 'busy', 'failed', 'canceled', 'blocked')
                          and coalesce(mm.status, '') not like 'inbound%')
  ), ok as (
    -- the records and the holds, asked only of the cards that got this far (the two checks are the slow part)
    select c.* from c where coalesce(public.card_hold_block(c.lead_id, now()), public.card_record_block(c.lead_id, d)) is null
  )
  select ok.*, row_number() over (order by ok.sale_ahead desc, case when ok.sale_ahead then ok.sale_date end nulls last,
           case ok.tier when 'A' then 1 when 'B' then 2 else 3 end,
           case when ok.family_list ~* 'foreclos|sheriff|lis pendens' then 1 when ok.family_list ~* 'probate|estate|inherit' then 2
                when ok.family_list ~* 'court|judgment|warrant|debt' then 3 when ok.tax_years >= 2 then 4
                when ok.family_list ~* 'condition|vacant|raze|code|fire' then 5 else 6 end,
           ok.tax_years desc, (coalesce(ok.equity, '') in ('clear', 'likely')) desc, ok.stacked_at desc nulls last, ok.lead_id) as rk
    from ok;

  select coalesce(jsonb_object_agg(x.tier, x.n), '{}'::jsonb) into by_tier
    from (select tier, count(*) n from _need where rk <= p_top group by 1) x;
  select coalesce(jsonb_agg(jsonb_build_object('rank', rk, 'owner', owner_name, 'address', property_address, 'town', municipality, 'tier', tier,
           'why', family_list, 'sale_date', sale_date) order by rk), '[]'::jsonb) into top from _need where rk <= 15;
  if p_dry then
    return jsonb_build_object('ok', true, 'dry_run', true, 'person', p_person, 'day', d, 'can_be_called', (select count(*) from _need),
      'on_the_list', least(p_top, (select count(*) from _need)), 'by_tier', by_tier, 'sale_ahead', (select count(*) from _need where rk <= p_top and sale_ahead), 'top', top);
  end if;

  for r in select * from _need where rk <= p_top order by rk loop
    select t.id into tid from public.tasks t
     where t.lead_id = r.lead_id and t.done_at is null and t.owner = p_person and t.source in ('power_hour', 'power_hour_reserve')
     order by t.due_at limit 1;
    if tid is not null then
      update public.tasks set due_at = base + make_interval(secs => r.rk), source = 'power_hour', updated_at = now() where id = tid;
      n_moved := n_moved + 1;
    else
      insert into public.tasks (lead_id, due_at, kind, owner, source, source_key, title, note)
      values (r.lead_id, base + make_interval(secs => r.rk), 'call', p_person, 'power_hour', 'need:' || d::text || ':' || r.lead_id::text,
              left('Need first: ' || coalesce(r.family_list, 'tier ' || r.tier) || coalesce(', sale ' || to_char(r.sale_date, 'Mon FMDD'), ''), 120),
              'Ranked ' || r.rk || ' of the list for ' || to_char(d, 'Dy Mon FMDD') || ' by need: tier ' || r.tier
                || coalesce(' (' || r.family_list || ')', '') || coalesce('; sheriff sale ' || to_char(r.sale_date, 'Mon FMDD'), '') || '.')
      on conflict (source_key) do update set due_at = excluded.due_at, done_at = null, owner = excluded.owner, updated_at = now();
      n_new := n_new + 1;
    end if;
  end loop;
  -- 0311: a ranked task from an earlier day whose card did not make this list is closed (marked power_hour_dropped,
  -- not a call made): the card was dialed out for the week, reached, held or blocked by the records since, and an old
  -- ranking must not keep it on the list. Only the ranking's own tasks (need:...); an agent's or a caller's are untouched.
  update public.tasks t set done_at = now(), source = 'power_hour_dropped', updated_at = now(),
         note = coalesce(t.note || ' ', '') || 'Off the ranked list on ' || to_char(d, 'Dy Mon FMDD') || '.'
   where t.done_at is null and t.owner = p_person and t.source = 'power_hour' and t.source_key like 'need:%'
     and t.source_key not like 'need:' || d::text || ':%'
     and not exists (select 1 from _need n where n.lead_id = t.lead_id and n.rk <= p_top);
  get diagnostics n_dropped = row_count;
  -- the rest of the caller's list goes behind the ranked cards, in the order it was in
  with rest as (
    select t.id, row_number() over (order by t.due_at, t.id) as rn from public.tasks t
     where t.done_at is null and t.owner = p_person and t.source in ('power_hour', 'power_hour_reserve')
       and not exists (select 1 from _need n where n.lead_id = t.lead_id and n.rk <= p_top))
  update public.tasks t set due_at = base + make_interval(secs => p_top + 600 + rest.rn::int), updated_at = now() from rest where rest.id = t.id;
  get diagnostics n_behind = row_count;
  return jsonb_build_object('ok', true, 'person', p_person, 'day', d, 'can_be_called', (select count(*) from _need),
    'on_the_list', least(p_top, (select count(*) from _need)), 'new_tasks', n_new, 'retimed', n_moved, 'moved_behind', n_behind, 'dropped', n_dropped,
    'by_tier', by_tier, 'sale_ahead', (select count(*) from _need where rk <= p_top and sale_ahead), 'top', top);
end $function$;

create or replace function public.power_lists_morning(p_now timestamptz default now(), p_force boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare
  c public.campaign_control;
  d date := (p_now at time zone 'America/Chicago')::date;
  hr integer := extract(hour from (p_now at time zone 'America/Chicago'))::int;
  who public.team_person; r jsonb; out jsonb := '{}'::jsonb;
begin
  if not (public.is_owner() or auth.uid() is null) then raise exception 'only Colin or the desk ranks the call lists'; end if;
  select * into c from public.campaign_control where id = 1;
  if not coalesce(c.power_list_daily, true) and not p_force then return jsonb_build_object('day', d, 'ran', false, 'why', 'switched off'); end if;
  if extract(isodow from d) = 7 and not p_force then return jsonb_build_object('day', d, 'ran', false, 'why', 'Sunday: calls rest'); end if;
  if hr < 5 and not p_force then return jsonb_build_object('day', d, 'ran', false, 'why', 'before 5 AM Central'); end if;
  foreach who in array array['thalia', 'adil']::public.team_person[] loop
    if exists (select 1 from public.power_list_runs pr where pr.day = d and pr.person = who) and not p_force then
      out := out || jsonb_build_object(who::text, 'already ranked today');
    elsif public.caller_is_off(who, d) then
      out := out || jsonb_build_object(who::text, 'off today');
    else
      r := public.power_list_by_need(who, d, greatest(1, coalesce(c.power_list_top, 120)), false);
      insert into public.power_list_runs (day, person, at, result) values (d, who, p_now, r - 'top')
      on conflict (day, person) do update set at = excluded.at, result = excluded.result;
      out := out || jsonb_build_object(who::text, r - 'top');
    end if;
  end loop;
  return jsonb_build_object('day', d, 'ran', true, 'lists', out);
end $fn$;
revoke all on function public.power_lists_morning(timestamptz, boolean) from public, anon, authenticated;
grant execute on function public.power_lists_morning(timestamptz, boolean) to service_role;

do $do$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if exists (select 1 from cron.job where jobname = 'wpie-power-lists') then
      perform cron.unschedule('wpie-power-lists');
    end if;
    -- 10:35, 11:35 and 12:35 UTC: the first one at or after 5 AM Central ranks the day (5:35 AM in winter and summer);
    -- the others find the day done
    perform cron.schedule('wpie-power-lists', '35 10,11,12 * * *', 'select public.power_lists_morning()');
  end if;
end
$do$;
