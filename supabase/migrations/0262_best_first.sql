-- 0262: best first. A caller's list ranked by need, and a day when the strongest cards are texted first.
--
-- Colin, 2026-11-20: "Tomorrow Tyler is working alone and in his call list and in texts going out we need the best of
-- the best most motivated, soonest to foreclosure, or multi stacked cards".
--
-- What "best" is, from the records the card already carries: a sheriff sale 14 or more days ahead (soonest first),
-- then how many kinds of need are stacked on the card (tier A is three, B is two, C is one), then the kind
-- (foreclosure, an estate, a court debt, two or more years of unpaid tax, the building's condition).
--
-- 1. power_list_by_need(person, day, top): the caller's list for a day. The top cards of theirs that can be called
--    (a phone that may be dialed, nothing in the records against it, not held, fewer than three dials this week, nobody
--    reached in the last two weeks) get a list task in rank order; a card that already has a list task keeps it and
--    is re-timed. The caller's other list tasks are moved behind them, not closed. Tier D is never put on the list
--    by this: a single weak reason is not "best".
-- 2. day_best_first(day, by, why): one day on which the text list takes every tier A, B and C text that is ready
--    (first texts, the owner's next number, follow-ups) before any tier D one. The cap, the records gate and every
--    wording rule are as on any day. It is a day, not a setting: the next day builds as usual.
--
-- Who works that day is caller_off, as before.

alter table public.campaign_control add column if not exists day_best_first_day date;
alter table public.campaign_control add column if not exists day_best_first_by text;
alter table public.campaign_control add column if not exists day_best_first_why text;

create or replace function public.day_best_first(p_day date, p_by text default 'desk', p_why text default null) returns jsonb
language plpgsql security definer set search_path = public as $fn$
begin
  if not (public.is_owner() or auth.uid() is null) then raise exception 'only Colin or the desk sets a best-first day'; end if;
  update public.campaign_control set day_best_first_day = p_day, day_best_first_by = nullif(btrim(coalesce(p_by, '')), ''),
         day_best_first_why = nullif(btrim(coalesce(p_why, '')), '') where id = 1;
  return jsonb_build_object('ok', true, 'day', p_day, 'what', case when p_day is null then 'no best-first day is set'
    else 'on that day every tier A, B and C text that is ready goes on the list before any tier D one' end);
end $fn$;
revoke all on function public.day_best_first(date, text, text) from public, anon;
grant execute on function public.day_best_first(date, text, text) to authenticated, service_role;

create or replace function public.power_list_by_need(p_person public.team_person, p_day date default null, p_top integer default 120,
                                                     p_dry boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare
  d date := coalesce(p_day, (now() at time zone 'America/Chicago')::date);
  -- 6 AM: before the laptop's own call list (due 7 AM), because the queue takes a card's earliest open task and a
  -- card whose earliest task is not a list task falls out of the list's place in the order
  base timestamptz := (coalesce(p_day, (now() at time zone 'America/Chicago')::date) + time '06:00') at time zone 'America/Chicago';
  r record; tid uuid; n_new integer := 0; n_moved integer := 0; n_behind integer := 0; top jsonb; by_tier jsonb;
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
  -- the rest of the caller's list goes behind the ranked cards, in the order it was in; nothing is closed
  with rest as (
    select t.id, row_number() over (order by t.due_at, t.id) as rn from public.tasks t
     where t.done_at is null and t.owner = p_person and t.source in ('power_hour', 'power_hour_reserve')
       and not exists (select 1 from _need n where n.lead_id = t.lead_id and n.rk <= p_top))
  update public.tasks t set due_at = base + make_interval(secs => p_top + 600 + rest.rn::int), updated_at = now() from rest where rest.id = t.id;
  get diagnostics n_behind = row_count;
  return jsonb_build_object('ok', true, 'person', p_person, 'day', d, 'can_be_called', (select count(*) from _need),
    'on_the_list', least(p_top, (select count(*) from _need)), 'new_tasks', n_new, 'retimed', n_moved, 'moved_behind', n_behind,
    'by_tier', by_tier, 'sale_ahead', (select count(*) from _need where rk <= p_top and sale_ahead), 'top', top);
end $fn$;
revoke all on function public.power_list_by_need(public.team_person, date, integer, boolean) from public, anon;
grant execute on function public.power_list_by_need(public.team_person, date, integer, boolean) to authenticated, service_role;

-- ---------------------------------------------------------------- the day's build (recreated from live): the best-first phases
CREATE OR REPLACE FUNCTION public.text_day_build(p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
declare
  c       public.campaign_control;
  d       date := (p_now at time zone 'America/Chicago')::date;
  cap     integer;
  room    integer;
  n       integer;
  nxt     integer;
  added   jsonb := '{}'::jsonb;
  ph      record;
  best    boolean;
  left_out integer;
begin
  select * into c from public.campaign_control where id = 1;
  if coalesce(c.no_sundays, true) and extract(isodow from d) = 7 then
    return jsonb_build_object('day', d, 'built', false, 'why', 'Sunday: no texts');
  end if;
  -- a text carried over to a day its card's caller is off does not go (0238)
  perform public.caller_off_sweep(d);
  cap := coalesce(c.daily_cap, 400);
  best := c.day_best_first_day is not distinct from d;   -- 0262: a day the strongest cards go first
  drop table if exists _day_pool;
  create temp table _day_pool on commit drop as select * from public.text_pool(p_now) where block is null;

  delete from public.text_day t
   where t.day = d
     and not exists (select 1 from public.planned_openers po where po.lead_id = t.lead_id and po.step = t.step and po.plan_date = d and po.lane = 'agent'
                        and po.send_status not in ('withdrawn', 'skipped'))   -- a withdrawn text does not keep its row on the list (0237), nor one the send check refused (0257)
     and not exists (select 1 from _day_pool p where p.lead_id = t.lead_id and p.step = t.step);
  get diagnostics left_out = row_count;

  -- what the day has already spent: the list, and any text the agent queued for today that is not on it
  select count(*) into n from public.text_day t where t.day = d;
  room := cap - n - (select count(*) from public.planned_openers po
                      where po.plan_date = d and po.lane = 'agent' and po.send_status in ('planned', 'would_send', 'sending', 'sent', 'delivered', 'undelivered', 'failed', 'uncertain')
                        and not exists (select 1 from public.text_day t where t.day = d and t.lead_id = po.lead_id and t.step = po.step));
  select coalesce(max(t.ord), 0) into nxt from public.text_day t where t.day = d;

  for ph in
    select * from (values
      -- 0262: on a best-first day every tier A, B or C text that is ready goes on the list before anything weaker
      (0, 'best_first', 'first', array[1], case when best then 100000 else 0 end, array['A', 'B', 'C']),
      (1, 'best_followups_2_3', 'followup', array[2, 3], case when best then 100000 else 0 end, array['A', 'B', 'C']),
      (2, 'best_next_numbers', 'next_number', array[1], case when best then 100000 else 0 end, array['A', 'B', 'C']),
      (3, 'best_followups_4_5', 'followup', array[4, 5], case when best then 100000 else 0 end, array['A', 'B', 'C']),
      (4, 'first_floor', 'first', array[1], greatest(0, coalesce(c.day_first_floor, 140) - (select count(*) from public.text_day t where t.day = d and t.kind = 'first')::int), null::text[]),
      (5, 'followups_2_3', 'followup', array[2, 3], 100000, null::text[]),
      (6, 'next_numbers', 'next_number', array[1], 100000, null::text[]),
      (7, 'followups_4_5', 'followup', array[4, 5], 100000, null::text[]),
      (8, 'more_first', 'first', array[1], 100000, null::text[])) as v(n, name, kind, steps, quota, tiers)
     order by n
  loop
    exit when room <= 0;
    continue when ph.quota <= 0;
    with pick as (
      select p.*, row_number() over (order by case when ph.tiers is null then 9 else case p.tier when 'A' then 1 when 'B' then 2 else 3 end end, p.step, p.ord) as rn from _day_pool p
       where p.kind = ph.kind and p.step = any (ph.steps)
         and (ph.tiers is null or p.tier = any (ph.tiers))
         and not exists (select 1 from public.text_day t where t.day = d and t.lead_id = p.lead_id)
       order by case when ph.tiers is null then 9 else case p.tier when 'A' then 1 when 'B' then 2 else 3 end end, p.step, p.ord limit least(room, ph.quota))
    insert into public.text_day (day, lead_id, step, kind, phone, voice, tier, need_why, due_day, ord, listed_at)
    select d, k.lead_id, k.step, k.kind, k.phone, public.card_voice(k.lead_id), k.tier, k.need_why, k.due_day, nxt + k.rn, p_now from pick k
    on conflict (day, lead_id, step) do nothing;
    get diagnostics n = row_count;
    room := room - n;
    nxt := nxt + n;
    added := added || jsonb_build_object(ph.name, n);
  end loop;

  update public.campaign_control set day_last_build_at = p_now where id = 1;
  insert into public.text_day_runs (day, at, kind, summary)
  values (d, p_now, 'build', jsonb_build_object('added', added, 'left_the_list', left_out, 'room_left', greatest(room, 0), 'cap', cap,
          'listed', (select count(*) from public.text_day t where t.day = d)));
  return jsonb_build_object('day', d, 'built', true, 'cap', cap, 'added', added, 'left_the_list', left_out,
    'listed', (select count(*) from public.text_day t where t.day = d), 'room_left', greatest(room, 0));
end $fn$;
