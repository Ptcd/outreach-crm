-- 0237: a caller who is off gets no texts on their cards that day.
--
-- Colin 2026-11-14, with the day's texts dripping: "make sure we only do Tyler's cards thalia isn't working". A text
-- on a card brings its reply to that card's caller; on a day they are off nobody is there for it. There was no way
-- to say so: the day's list is built from every card.
--
--   caller_off(person, day): who is off which day.
--   caller_off_set(person, day, note): records it and withdraws that day's texts still waiting on that caller's cards.
--   card_record_block: 'caller_off_today' for any text on such a card (the pool, the list, the queue door, the
--     server's own writer all read it).
--   text_day_build: a row whose text was withdrawn and that is no longer ready leaves the list, so the day's room
--     goes to cards whose caller is working.

create table if not exists public.caller_off (
  person  public.team_person not null,
  day     date not null,
  note    text,
  set_by  text,
  set_at  timestamptz not null default now(),
  primary key (person, day)
);
alter table public.caller_off enable row level security;
revoke all on public.caller_off from anon, authenticated;

create or replace function public.caller_off_set(p_person text, p_day date, p_note text default null, p_by text default 'desk')
returns jsonb language plpgsql security definer set search_path = public as $$
declare who public.team_person; n integer;
begin
  if lower(coalesce(p_person, '')) = 'tyler' then p_person := 'adil'; end if;
  if lower(coalesce(p_person, '')) not in ('thalia', 'adil') then
    return jsonb_build_object('ok', false, 'reason', 'a caller is thalia or adil (Tyler is adil in the app)');
  end if;
  if p_day is null then return jsonb_build_object('ok', false, 'reason', 'say which day'); end if;
  who := lower(p_person)::public.team_person;
  insert into public.caller_off (person, day, note, set_by) values (who, p_day, nullif(btrim(coalesce(p_note, '')), ''), p_by)
  on conflict (person, day) do update set note = excluded.note, set_by = excluded.set_by, set_at = now();
  -- that day's texts still waiting on their cards: withdrawn (one the sender has already taken is left to finish)
  update public.planned_openers po set send_status = 'withdrawn', send_reason = 'the card''s caller is off that day', send_updated_at = now()
   where po.plan_date = p_day and po.send_status in ('planned', 'would_send') and po.claim_mode is null
     and exists (select 1 from public.leads l where l.id = po.lead_id and l.locked_to = who);
  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'person', who, 'day', p_day, 'texts_withdrawn', n);
end $$;
revoke all on function public.caller_off_set(text, date, text, text) from public, anon, authenticated;

create or replace function public.caller_off_clear(p_person text, p_day date)
returns jsonb language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if lower(coalesce(p_person, '')) = 'tyler' then p_person := 'adil'; end if;
  delete from public.caller_off where person::text = lower(coalesce(p_person, '')) and day = p_day;
  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'cleared', n);
end $$;
revoke all on function public.caller_off_clear(text, date) from public, anon, authenticated;

CREATE OR REPLACE FUNCTION public.card_record_block(p_lead_id uuid, p_day date)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case
    when not coalesce((select cc.day_rules_on from public.campaign_control cc where cc.id = 1), true) then null
    -- the card's caller is off that day (0237): nobody is there for the reply
    when exists (select 1 from public.caller_off o where o.day = p_day and o.person = l.locked_to) then 'caller_off_today'
    when l.wpie_owner_id > 0 and f.wpie_owner_id is null then 'no_record_verdict'
    when l.wpie_owner_id > 0 and f.as_of < p_day - 7 then 'record_verdict_stale'
    when l.wpie_owner_id > 0 and f.verdict <> 'ok'
         and not (f.verdict = 'probate_floor_30d' and f.not_before is not null and f.not_before <= p_day) then f.verdict
    -- any card's sale date, the agents' cards too (0233)
    when (select s.sale_date from public.card_sale_dates s where s.lead_id = l.id) < p_day + 14 then 'sheriff_sale_inside_14d'
    when not (coalesce(f.need, false) or coalesce(m.tax_years, 0) >= 2
              or coalesce(m.family_list, '') ~ '(estate|foreclosure|condition|legal_money)'
              or array_to_string(l.reasons_to_sell, ', ') ~* 'foreclos|sheriff|estate|inherit|probate|court debt|judgment|tax warrant|code|nuisance|vacan|raze|condemn')
      then 'want_not_need'
    when coalesce(f.equity, e.equity_grade) = 'thin' then 'equity_thin'
    when coalesce(f.equity, e.equity_grade) = 'underwater' then 'equity_underwater'
  end
  from public.leads l
  left join public.text_fitness f on f.wpie_owner_id = l.wpie_owner_id and l.wpie_owner_id > 0
  left join public.lead_motivation m on m.lead_id = l.id
  left join public.equity_inputs e on e.lead_id = l.id
  where l.id = p_lead_id
$function$;

CREATE OR REPLACE FUNCTION public.text_day_build(p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c       public.campaign_control;
  d       date := (p_now at time zone 'America/Chicago')::date;
  cap     integer;
  room    integer;
  n       integer;
  nxt     integer;
  added   jsonb := '{}'::jsonb;
  ph      record;
  left_out integer;
begin
  select * into c from public.campaign_control where id = 1;
  if coalesce(c.no_sundays, true) and extract(isodow from d) = 7 then
    return jsonb_build_object('day', d, 'built', false, 'why', 'Sunday: no texts');
  end if;
  cap := coalesce(c.daily_cap, 400);
  drop table if exists _day_pool;
  create temp table _day_pool on commit drop as select * from public.text_pool(p_now) where block is null;

  delete from public.text_day t
   where t.day = d
     and not exists (select 1 from public.planned_openers po where po.lead_id = t.lead_id and po.step = t.step and po.plan_date = d and po.lane = 'agent'
                        and po.send_status <> 'withdrawn')   -- a withdrawn text does not keep its row on the list (0237)
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
      ('first_floor', 'first', array[1], greatest(0, coalesce(c.day_first_floor, 140) - (select count(*) from public.text_day t where t.day = d and t.kind = 'first')::int)),
      ('followups_2_3', 'followup', array[2, 3], 100000),
      ('next_numbers', 'next_number', array[1], 100000),
      ('followups_4_5', 'followup', array[4, 5], 100000),
      ('more_first', 'first', array[1], 100000)) as v(name, kind, steps, quota)
  loop
    exit when room <= 0;
    with pick as (
      select p.*, row_number() over (order by p.step, p.ord) as rn from _day_pool p
       where p.kind = ph.kind and p.step = any (ph.steps)
         and not exists (select 1 from public.text_day t where t.day = d and t.lead_id = p.lead_id)
       order by p.step, p.ord limit least(room, ph.quota))
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
end $function$;
