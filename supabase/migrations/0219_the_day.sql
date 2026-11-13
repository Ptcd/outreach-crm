-- The day (Colin 2026-11-12): "redesign our system for sending messages and getting deals from cards so every day muse
-- is talking to good prospects and following up as needed. design this to work programmatically day after day".
--
-- What was wrong, measured that evening:
--   * Two pickers and no shared memory. The laptop planned 400 owners a night; the app handed that plan to Muse, who
--     picked again from ready_to_text. An owner the laptop planned was never planned again, sent or not (1,930 owners).
--   * ready_to_text showed a window of 300 cards sorted by how many reasons a card lists. 261 of the 300 were weak
--     cards (one year of tax, a want) that Colin's need rule forbids, so the cards with a real need sat behind them
--     and a day's release came to 35 of 400.
--   * The whole-store path (0208) skipped the laptop's record rules: 9 listed, 148 over the value cap and one inside
--     the sheriff's 14 days were in the first-text stages.
--   * The name changed inside a thread ("Adil here", then "Thalia again", then "Tyler here, I work with Colin"), and
--     sellers asked "Is this Colin or Thalia?". The persona and STOP rules lived in a job description, not here.
--   * A big day of first texts became three days of nothing but follow-ups (393 first texts on 11-07, then 0 and 8).
--
-- What this is: the server builds one list a day, every day, by one set of rules.
--   text_fitness      the records' verdict on a card, pushed by the laptop (wpie.live.text_fitness)
--   text_pool()       every card that could get a cold text, with the one reason it cannot (or null: ready)
--   text_day          the day's list: who, which text, which phone, whose name
--   text_day_build()  fills it: a floor of new people first, then every follow-up that is due, then more new people
--   text_day_tick()   the clock (pg_cron): build at 7, top up hourly, a noon check, the evening report on the desk
--   ready_to_text     now serves that list, so the texting agent's job does not change shape
--   agent_queue_text  refuses a text the records forbid, a second name in a thread, a STOP line on a follow-up

-- ------------------------------------------------------------------ the records' verdict
create table if not exists public.text_fitness (
  wpie_owner_id bigint primary key,
  verdict       text not null,             -- 'ok', or the laptop selector's drop code (weak_distress, actively_listed, ...)
  detail        text,
  need          boolean not null default false,   -- Colin's need rule: 2+ years of tax, or a hard record
  need_why      text,
  tier          text,                      -- motivation tier A-D
  equity        text,                      -- clear | likely | thin | underwater | unknown
  sale_date     date,                      -- the next scheduled sheriff sale; the 14-day rule is tested here every day
  not_before    date,                      -- the day a probate floor ends
  as_of         date not null,
  pushed_at     timestamptz not null default now()
);
alter table public.text_fitness enable row level security;
revoke all on public.text_fitness from public, anon, authenticated;
grant select on public.text_fitness to authenticated, service_role;
drop policy if exists text_fitness_team_read on public.text_fitness;
create policy text_fitness_team_read on public.text_fitness for select to authenticated using (public.is_team());

alter table public.campaign_control
  add column if not exists day_first_floor     integer not null default 140 check (day_first_floor between 0 and 2000),
  add column if not exists day_backstop        boolean not null default false,
  -- the kill switch for the rule gate: false = the records' verdict, the one-name rule and the follow-up STOP rule are
  -- not enforced (the store as it was before 0219). For an emergency, and for tests of the older behaviour.
  add column if not exists day_rules_on        boolean not null default true,
  add column if not exists day_backstop_after  time not null default '11:00',
  add column if not exists day_last_build_at   timestamptz,
  add column if not exists day_noon_checked    date,
  add column if not exists day_reported        date;

create table if not exists public.text_day (
  day       date not null,
  lead_id   uuid not null references public.leads (id) on delete cascade,
  step      integer not null check (step between 1 and 5),
  kind      text not null check (kind in ('first', 'followup', 'next_number')),
  phone     text not null,
  voice     text not null,
  tier      text,
  need_why  text,
  due_day   date,
  ord       integer not null,
  listed_at timestamptz not null default now(),
  primary key (day, lead_id, step)
);
create index if not exists text_day_day_ord on public.text_day (day, ord);
alter table public.text_day enable row level security;
revoke all on public.text_day from public, anon, authenticated;
grant select on public.text_day to authenticated, service_role;
drop policy if exists text_day_team_read on public.text_day;
create policy text_day_team_read on public.text_day for select to authenticated using (public.is_team());

create table if not exists public.text_day_runs (
  id      bigint generated always as identity primary key,
  day     date not null,
  at      timestamptz not null default now(),
  kind    text not null,                   -- build | noon | report | backstop
  summary jsonb not null
);
create index if not exists text_day_runs_day on public.text_day_runs (day, id);
alter table public.text_day_runs enable row level security;
revoke all on public.text_day_runs from public, anon, authenticated;
grant select on public.text_day_runs to authenticated, service_role;
drop policy if exists text_day_runs_team_read on public.text_day_runs;
create policy text_day_runs_team_read on public.text_day_runs for select to authenticated using (public.is_team());

-- ------------------------------------------------------------------ one name per thread
-- The names a text may be signed with: the callers' seller-facing names (Adil is Tyler), Colin, and Adil's own name
-- because threads were opened with it on 2026-11-07.
create or replace function public.text_voices() returns setof text language sql stable security definer set search_path = public as $$
  select distinct split_part(tm.display_name, ' ', 1) from public.team_members tm
   where tm.person is distinct from 'muse' and coalesce(tm.display_name, '') <> ''
  union select 'Adil'
$$;

-- Who a text says it is from: "this is Thalia", "Thalia here", "Thalia again", "my name is Colin Merrill".
create or replace function public.text_speaker(p_body text) returns text language sql stable security definer set search_path = public as $$
  select k.name from public.text_voices() k(name)
   where coalesce(p_body, '') ~* ('(this is|this|my name is|it''s|its)\s+' || k.name || '\M')
      or coalesce(p_body, '') ~* ('\m' || k.name || '\s+(here|again)\M')
   order by position(lower(k.name) in lower(p_body)) limit 1
$$;

-- The name this card's thread speaks with: the one the seller saw last; before any text, the caller the card belongs to.
create or replace function public.card_voice(p_lead_id uuid) returns text language sql stable security definer set search_path = public as $$
  select coalesce(
    (select public.text_speaker(m.body) from public.messages m
      where m.lead_id = p_lead_id and m.direction = 'out' and m.channel = 'sms' and m.provider_sid is not null
        and public.text_speaker(m.body) is not null
      order by m.sent_at desc nulls last limit 1),
    (select split_part(tm.display_name, ' ', 1) from public.team_members tm join public.leads l on l.locked_to = tm.person
      where l.id = p_lead_id and coalesce(tm.display_name, '') <> '' limit 1),
    'Thalia')
$$;

-- ------------------------------------------------------------------ the rules, in one place
-- What the RECORDS say against texting this card, or null. A laptop card is judged by the laptop's verdict; a card the
-- agent made itself (a negative owner id) has no verdict and is judged by the need rule on what the card carries.
create or replace function public.card_record_block(p_lead_id uuid, p_day date) returns text
language sql stable security definer set search_path = public as $$
  select case
    when not coalesce((select cc.day_rules_on from public.campaign_control cc where cc.id = 1), true) then null
    when l.wpie_owner_id > 0 and f.wpie_owner_id is null then 'no_record_verdict'
    when l.wpie_owner_id > 0 and f.as_of < p_day - 7 then 'record_verdict_stale'
    when l.wpie_owner_id > 0 and f.verdict <> 'ok'
         and not (f.verdict = 'probate_floor_30d' and f.not_before is not null and f.not_before <= p_day) then f.verdict
    when f.sale_date is not null and f.sale_date < p_day + 14 then 'sheriff_sale_inside_14d'
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
$$;

-- What the TEAM has put on the card that keeps the system's texts off it, or null.
create or replace function public.card_hold_block(p_lead_id uuid, p_now timestamptz) returns text
language sql stable security definer set search_path = public as $$
  select case
    when l.parked_at is not null then 'parked'
    when l.rest_until is not null and l.rest_until > p_now then 'resting'
    when coalesce(l.elderly_or_ill, false) or coalesce(l.grief, false) then 'elderly_or_grief'
    when l.human_takeover_at is not null then 'human_takeover'
    when public.caller_texting(l.id) is not null then 'caller_texting'
  end
  from public.leads l where l.id = p_lead_id
$$;

-- Every card a cold text could go to today, each with the ONE reason it cannot (block) or null (ready), and its place
-- in line. First texts: tier A to D, a sale date nearest first, equity on record before unknown, newest stack first.
-- Follow-ups: the cadence of 0048 (days 1, 3, 10, 17, 24; a Sunday moves to Monday), the earliest step first.
create or replace function public.text_pool(p_now timestamptz default now())
returns table (lead_id uuid, kind text, step integer, phone text, tier text, need_why text, due_day date, block text, ord bigint)
language sql stable security definer set search_path = public as $$
  with d as (select (p_now at time zone 'America/Chicago')::date as day),
  firsts as (
    select l.id, l.stacked_at, l.created_at, ph.phone,
           coalesce(f.tier, m.tier) as tier, coalesce(f.equity, e.equity_grade) as equity, f.sale_date,
           coalesce(f.need_why, m.family_list) as need_why,
           coalesce(case when ph.phone is null then 'no_textable_phone' end,
                    public.card_hold_block(l.id, p_now), public.card_record_block(l.id, d.day)) as block
      from d, public.leads l
      left join public.text_fitness f on f.wpie_owner_id = l.wpie_owner_id and l.wpie_owner_id > 0
      left join public.lead_motivation m on m.lead_id = l.id
      left join public.equity_inputs e on e.lead_id = l.id
      left join lateral (
        select c.value_normalized as phone from public.contacts c
         where c.lead_id = l.id and c.kind = 'phone' and c.status = 'ok' and not c.dnc_app and not c.suppressed and not c.dnc_vendor
           and c.dnc_scrub <> 'dnc' and public.agent_phone_ok(c.value_normalized, c.line_type)
           and not exists (select 1 from public.suppressed_phones s where s.phone10 = c.value_normalized)
           and not exists (select 1 from public.twilio_inbound ti where ti.from10 = c.value_normalized)
           and public.phone_person_block(c.value_normalized) is null
         order by (lower(coalesce(c.line_type, '')) in ('mobile', 'wireless', 'cell', 'cellular')) desc, c.created_at, c.value_normalized
         limit 1) ph on true
     where l.stage in ('opener_queued', 'postcard_mailed')
       and not exists (select 1 from public.planned_openers po where po.lead_id = l.id and po.step = 1
                        and po.send_status in ('planned', 'would_send', 'sending', 'sent', 'delivered'))
       and not exists (select 1 from public.messages mm where mm.lead_id = l.id and mm.direction = 'out' and mm.channel = 'sms')),
  first_text as (
    -- the latest first text that was not a bounce: the phone this thread runs on
    select distinct on (m.lead_id) m.lead_id, right(regexp_replace(m.to_number, '\D', '', 'g'), 10) as phone, m.sent_at as first_at
      from public.messages m join public.leads l on l.id = m.lead_id
     where l.stage = 'opener_sent' and m.direction = 'out' and m.channel = 'sms' and m.is_opener
       and m.provider_sid is not null and coalesce(m.status, '') not in ('undelivered', 'failed')
     order by m.lead_id, m.sent_at desc),
  thread as (
    select f.lead_id, f.phone, f.first_at, count(m.*)::int as n, max(m.sent_at) as last_at
      from first_text f join public.messages m on m.lead_id = f.lead_id and m.direction = 'out' and m.channel = 'sms'
       and m.provider_sid is not null and right(regexp_replace(m.to_number, '\D', '', 'g'), 10) = f.phone and m.sent_at >= f.first_at
     group by 1, 2, 3),
  due as (
    select t.lead_id, t.phone, t.n + 1 as step, t.last_at,
           (t.first_at at time zone 'America/Chicago')::date + (case t.n + 1 when 2 then 2 when 3 then 9 when 4 then 16 else 23 end) as raw_day
      from thread t where t.n between 1 and 4),
  follow as (
    select x.lead_id as id, x.step, x.phone, x.due_day, fm.tier, fm.need_why,
           coalesce(public.card_hold_block(x.lead_id, p_now), public.card_record_block(x.lead_id, d.day)) as block
      from d, (select u.*, case when extract(isodow from u.raw_day) = 7 then u.raw_day + 1 else u.raw_day end as due_day from due u) x
      join public.leads l on l.id = x.lead_id
      left join lateral (select coalesce(f.tier, m.tier) as tier, coalesce(f.need_why, m.family_list) as need_why
                           from (select 1) one
                           left join public.text_fitness f on f.wpie_owner_id = l.wpie_owner_id and l.wpie_owner_id > 0
                           left join public.lead_motivation m on m.lead_id = l.id) fm on true
     where x.due_day <= d.day and x.last_at < p_now - interval '1 day'
       -- they wrote back, from any phone on the card (or a phone that belongs to it)
       and not exists (select 1 from public.twilio_inbound ti where ti.lead_id = l.id
                         or ti.from10 in (select c.value_normalized from public.contacts c where c.lead_id = l.id and c.kind = 'phone'))
       and not exists (select 1 from public.messages m where m.lead_id = l.id and m.direction = 'in' and m.channel = 'sms')
       -- a call that REACHED them ends the texting; a dial nobody answered does not
       and not exists (select 1 from public.messages m where m.lead_id = l.id and m.channel = 'call'
                         and coalesce(m.status, '') not in ('no_answer', 'voicemail', 'inbound_missed', 'missed', 'busy', 'failed', 'canceled', 'blocked'))
       and not exists (select 1 from public.suppressed_phones s where s.phone10 = x.phone)
       and exists (select 1 from public.contacts c where c.lead_id = l.id and c.kind = 'phone' and c.value_normalized = x.phone and c.status = 'ok'
                    and not c.dnc_app and not c.suppressed and not c.dnc_vendor and c.dnc_scrub <> 'dnc')
       and public.phone_person_block(x.phone) is null
       and not exists (select 1 from public.planned_openers po where po.lead_id = l.id and po.send_status in ('planned', 'would_send', 'sending'))),
  -- the owner's next number (0079): the texted number was someone else's, and another usable mobile is on the card
  next_numbers as (
    select l.id, ph.value_normalized as phone, l.updated_at, coalesce(f.tier, m.tier) as tier, coalesce(f.need_why, m.family_list) as need_why,
           coalesce(public.card_hold_block(l.id, p_now), public.card_record_block(l.id, d.day)) as block
      from d, public.leads l
      left join public.text_fitness f on f.wpie_owner_id = l.wpie_owner_id and l.wpie_owner_id > 0
      left join public.lead_motivation m on m.lead_id = l.id
      cross join lateral (
        select c.value_normalized from public.contacts c
         where c.lead_id = l.id and c.kind = 'phone' and c.status = 'ok' and not c.dnc_app and not c.suppressed and not c.dnc_vendor
           and c.dnc_scrub <> 'dnc' and public.agent_phone_ok(c.value_normalized, c.line_type)
           and public.phone_person_block(c.value_normalized) is null
           and public.next_phone_problem(l.id, c.value_normalized) is null
         order by c.created_at, c.value_normalized limit 1) ph
     where l.stage = 'data_fix'
       and not exists (select 1 from public.planned_openers po where po.lead_id = l.id and po.send_status in ('planned', 'would_send', 'sending')))
  select f.id, 'first', 1, f.phone, f.tier, f.need_why, null::date, f.block,
         row_number() over (order by (f.block is null) desc,
                                     case f.tier when 'A' then 1 when 'B' then 2 when 'C' then 3 when 'D' then 4 else 5 end,
                                     f.sale_date nulls last, (coalesce(f.equity, '') in ('clear', 'likely')) desc,
                                     f.stacked_at desc nulls last, f.created_at desc, f.id)
    from firsts f
  union all
  select w.id, 'followup', w.step, w.phone, w.tier, w.need_why, w.due_day, w.block,
         row_number() over (order by (w.block is null) desc, w.step, w.due_day, w.id)
    from follow w
  union all
  select n.id, 'next_number', 1, n.phone, n.tier, n.need_why, null::date, n.block,
         row_number() over (order by (n.block is null) desc,
                                     case n.tier when 'A' then 1 when 'B' then 2 when 'C' then 3 when 'D' then 4 else 5 end, n.updated_at, n.id)
    from next_numbers n
$$;

-- What a queued text must also pass (agent_queue_text calls this): the records, the thread's one name, the STOP rule.
-- p_step 0 is a reply inside a conversation: only the name is checked.
create or replace function public.text_rule_problem(p_lead_id uuid, p_body text, p_step integer, p_now timestamptz default now())
returns text language plpgsql stable security definer set search_path = public as $$
declare
  voice text := public.card_voice(p_lead_id);
  other text;
  rb    text;
begin
  if not coalesce((select cc.day_rules_on from public.campaign_control cc where cc.id = 1), true) then return null; end if;
  select k.name into other from public.text_voices() k(name)
   where lower(k.name) <> lower(voice)
     and (coalesce(p_body, '') ~* ('(this is|this|my name is|it''s|its)\s+' || k.name || '\M')
          or coalesce(p_body, '') ~* ('\m' || k.name || '\s+(here|again)\M'))
   limit 1;
  if other is not null then
    return 'this thread speaks as ' || voice || ', not ' || other || ': one name per thread (sellers asked "is this Colin or Thalia?")';
  end if;
  if coalesce(p_step, 1) = 0 then return null; end if;
  if coalesce(p_step, 1) = 1 and public.text_speaker(p_body) is null then
    return 'a first text says who is writing: this card speaks as ' || voice;
  end if;
  if coalesce(p_step, 1) > 1 and position('STOP' in coalesce(p_body, '')) > 0 then
    return 'a follow-up carries no STOP line: only the first text does (Colin 2026-11-10)';
  end if;
  rb := public.card_record_block(p_lead_id, (p_now at time zone 'America/Chicago')::date);
  if rb is not null then
    return 'the records say no text for this card: ' || rb
           || case rb when 'want_not_need' then ' (a want is not a need: Colin 2026-11-07)'
                      when 'actively_listed' then ' (a listed property is not a lead)'
                      when 'sheriff_sale_inside_14d' then ' (a sale inside 14 days is not a lead)'
                      when 'record_verdict_stale' then ' (the laptop has not judged this card in a week)'
                      when 'no_record_verdict' then ' (the laptop has no record verdict for this owner)'
                      else '' end;
  end if;
  return null;
end $$;

-- ------------------------------------------------------------------ the day's list
-- Idempotent: run it as often as you like. A row already written (queued by the agent) stays; a row not written that
-- is no longer ready leaves; the list is topped up to the day's cap in this order:
--   1. new people, up to the floor (campaign_control.day_first_floor)
--   2. follow-ups 2 and 3 that are due       3. the owner's next number
--   4. follow-ups 4 and 5 that are due       5. more new people
-- A follow-up that does not fit today is still due tomorrow; nothing is dropped.
create or replace function public.text_day_build(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public as $$
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
     and not exists (select 1 from public.planned_openers po where po.lead_id = t.lead_id and po.step = t.step and po.plan_date = d and po.lane = 'agent')
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
end $$;

-- The day in numbers: the list and how far it got, the pool behind it, and why the rest of the store is not in it.
create or replace function public.text_day_report(p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public as $$
  with d as (select (p_now at time zone 'America/Chicago')::date as day),
  lst as (
    select t.*, (select po.send_status::text from public.planned_openers po
                  where po.lead_id = t.lead_id and po.step = t.step and po.plan_date = t.day and po.lane = 'agent'
                  order by po.send_updated_at desc nulls last limit 1) as st
      from public.text_day t, d where t.day = d.day),
  pool as (select * from public.text_pool(p_now)),
  flr as (select greatest(1, coalesce((select day_first_floor from public.campaign_control where id = 1), 140)) as n)
  select jsonb_build_object(
    'day', (select day from d),
    'listed', (select count(*) from lst),
    'by_kind', (select coalesce(jsonb_object_agg(k, v), '{}'::jsonb) from (
        select case when kind = 'followup' then 'step_' || step else kind end as k,
               jsonb_build_object('listed', count(*), 'written', count(*) filter (where st is not null),
                                  'sent', count(*) filter (where st in ('sent', 'delivered', 'undelivered', 'failed', 'uncertain')),
                                  'delivered', count(*) filter (where st = 'delivered')) as v
          from lst group by 1) x),
    'not_written', (select count(*) from lst where st is null),
    'off_list_today', (select count(*) from public.planned_openers po, d
                        where po.plan_date = d.day and po.lane = 'agent' and po.send_status not in ('withdrawn', 'skipped')
                          and not exists (select 1 from public.text_day t where t.day = d.day and t.lead_id = po.lead_id and t.step = po.step)),
    'first_ready', (select count(*) from pool where kind = 'first' and block is null),
    'first_ready_by_tier', (select coalesce(jsonb_object_agg(coalesce(tier, '-'), n), '{}'::jsonb) from (
        select tier, count(*) n from pool where kind = 'first' and block is null group by 1) x),
    'days_of_new_people', (select round((select count(*) from pool where kind = 'first' and block is null)::numeric / (select n from flr), 1)),
    'followups_ready_by_step', (select coalesce(jsonb_object_agg(step, n), '{}'::jsonb) from (
        select step, count(*) n from pool where kind = 'followup' and block is null group by 1) x),
    'next_numbers_ready', (select count(*) from pool where kind = 'next_number' and block is null),
    'first_blocked', (select coalesce(jsonb_object_agg(block, n), '{}'::jsonb) from (
        select block, count(*) n from pool where kind = 'first' and block is not null group by 1) x),
    'followups_blocked', (select coalesce(jsonb_object_agg(block, n), '{}'::jsonb) from (
        select block, count(*) n from pool where kind = 'followup' and block is not null group by 1) x),
    'replies_today', (select count(*) from public.twilio_inbound ti, d where (ti.received_at at time zone 'America/Chicago')::date = d.day and not ti.is_opt_out),
    'stops_today', (select count(*) from public.twilio_inbound ti, d where (ti.received_at at time zone 'America/Chicago')::date = d.day and ti.is_opt_out),
    'hot_today', (select count(*) from public.hot_alerts h, d where (h.created_at at time zone 'America/Chicago')::date = d.day and not coalesce(h.is_test, false)),
    'verdicts_as_of', (select max(as_of) from public.text_fitness),
    'floor', (select n from flr),
    'cap', (select daily_cap from public.campaign_control where id = 1))
$$;

-- A first name fit to greet with, or 'there': "SMITH, JOHN A" and "JOHN A SMITH" give John; a company, a trust or an
-- estate gives 'there'.
create or replace function public.text_first_name(p_name text) returns text language sql immutable as $$
  select case
    when coalesce(p_name, '') ~* '\m(llc|l l c|inc|corp|corporation|ltd|lp|llp|trust|trustee|trustees|estate|est of|company|properties|holdings|investments?|group|partners|partnership|enterprises|realty|management|ventures|church|bank|association|assn|et al|etal)\M' then 'there'
    when w ~ '^[A-Za-z][A-Za-z''-]{1,19}$' and lower(w) not in ('mr', 'mrs', 'ms', 'dr', 'the', 'and', 'jr', 'sr') then initcap(lower(w))
    else 'there' end
  from (select case when position(',' in coalesce(p_name, '')) > 0
                    then split_part(btrim(split_part(p_name, ',', 2)), ' ', 1)
                    else split_part(btrim(coalesce(p_name, '')), ' ', 1) end as w) x
$$;

-- The backstop (off until Colin turns campaign_control.day_backstop on): after day_backstop_after, a row of the day's
-- list nobody has written goes out in the settled wording, through agent_queue_text and every check it makes. Texts 4
-- and 5 have no settled wording and are never written here.
create or replace function public.text_day_backstop(p_now timestamptz default now(), p_limit integer default 150) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  c    public.campaign_control;
  d    date := (p_now at time zone 'America/Chicago')::date;
  r    record;
  body text;
  nm   text;
  res  jsonb;
  ok   integer := 0;
  no   jsonb := '{}'::jsonb;
  why  text;
begin
  select * into c from public.campaign_control where id = 1;
  if not coalesce(c.day_backstop, false) then return jsonb_build_object('ran', false, 'why', 'the backstop is off'); end if;
  if (p_now at time zone 'America/Chicago')::time < c.day_backstop_after then return jsonb_build_object('ran', false, 'why', 'before the backstop hour'); end if;
  for r in
    select t.*, l.property_address, l.owner_name,
           (select ct.person_name from public.contacts ct where ct.lead_id = t.lead_id and ct.value_normalized = t.phone limit 1) as person_name
      from public.text_day t join public.leads l on l.id = t.lead_id
     where t.day = d and t.step <= 3 and coalesce(btrim(l.property_address), '') <> ''
       and not exists (select 1 from public.planned_openers po where po.lead_id = t.lead_id and po.step = t.step
                        and po.send_status in ('planned', 'would_send', 'sending', 'sent', 'delivered', 'undelivered', 'failed', 'uncertain'))
     order by t.ord limit greatest(1, least(p_limit, 400))
  loop
    nm := public.text_first_name(coalesce(r.person_name, r.owner_name));
    body := case
      when r.step = 1 and nm = 'there' then 'Hi there, this is ' || r.voice || '. Are you the right person to ask about ' || btrim(r.property_address) || '? Reply STOP to opt out.'
      when r.step = 1 then 'Hi ' || nm || ', this is ' || r.voice || '. Are you the current owner of ' || btrim(r.property_address) || '? Reply STOP to opt out.'
      when r.step = 2 then 'Hi ' || nm || ', ' || r.voice || ' again about ' || btrim(r.property_address) || '. Still the owner there? Just checking I have the right place.'
      else 'Hi ' || nm || ', ' || r.voice || ' again, following up on ' || btrim(r.property_address) || '. Is this still the best number to reach you at?' end;
    res := public.agent_queue_text(r.lead_id, r.phone, body, r.step, null, 'the day', p_now,
                                   case r.step when 1 then 'V4' when 2 then 'G' else 'F3' end, 'day_backstop', null, null);
    if res ->> 'status' = 'queued' then ok := ok + 1;
    else
      why := left(coalesce(res ->> 'reason', 'refused'), 60);
      no := no || jsonb_build_object(why, coalesce((no ->> why)::int, 0) + 1);
    end if;
  end loop;
  insert into public.text_day_runs (day, at, kind, summary) values (d, p_now, 'backstop', jsonb_build_object('queued', ok, 'refused', no));
  return jsonb_build_object('ran', true, 'queued', ok, 'refused', no);
end $$;

-- The clock. pg_cron calls this every 15 minutes; it decides what the hour calls for.
--   7:00 to 18:30 Central, Monday to Saturday: build, then top up once an hour
--   noon: if most of the list is still unwritten, say so on the desk (once)
--   the backstop, when it is on
--   19:15: the day's report on the desk (once), flagged when the new people run out inside five days
create or replace function public.text_day_tick(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  c    public.campaign_control;
  d    date := (p_now at time zone 'America/Chicago')::date;
  t    time := (p_now at time zone 'America/Chicago')::time;
  out  jsonb := '{}'::jsonb;
  r    jsonb;
  low  boolean;
  txt  text;
begin
  select * into c from public.campaign_control where id = 1;
  if coalesce(c.no_sundays, true) and extract(isodow from d) = 7 then return jsonb_build_object('day', d, 'why', 'Sunday'); end if;
  if t >= time '07:00' and t < time '18:30'
     and (c.day_last_build_at is null or (c.day_last_build_at at time zone 'America/Chicago')::date < d or c.day_last_build_at < p_now - interval '55 minutes') then
    out := out || jsonb_build_object('build', public.text_day_build(p_now));
  end if;
  if t >= time '12:00' and t < time '18:30' and c.day_noon_checked is distinct from d then
    r := public.text_day_report(p_now);
    update public.campaign_control set day_noon_checked = d where id = 1;
    if (r ->> 'listed')::int >= 20 and (r ->> 'not_written')::int * 2 > (r ->> 'listed')::int then
      perform public.desk_post('desk', 'all', 'note', 'The day ' || d || ': at noon ' || (r ->> 'not_written') || ' of ' || (r ->> 'listed') || ' texts are not written',
        'The day''s list (text_day) has ' || (r ->> 'listed') || ' texts on it and ' || (r ->> 'not_written') || ' have not been written and queued yet. '
        || 'The list is in ready_to_text, need first. ' || case when coalesce(c.day_backstop, false) then 'The backstop is on and will write the rest in the settled wording.'
           else 'The backstop is off, so nothing goes out for those rows unless they are queued.' end);
      out := out || jsonb_build_object('noon', 'posted');
    end if;
  end if;
  if coalesce(c.day_backstop, false) and t >= c.day_backstop_after and t < time '18:30' then
    out := out || jsonb_build_object('backstop', public.text_day_backstop(p_now));
  end if;
  if t >= time '19:15' and c.day_reported is distinct from d then
    r := public.text_day_report(p_now);
    update public.campaign_control set day_reported = d where id = 1;
    insert into public.text_day_runs (day, at, kind, summary) values (d, p_now, 'report', r);
    low := (r ->> 'days_of_new_people')::numeric < 5;
    txt := 'Listed ' || (r ->> 'listed') || ' (cap ' || coalesce(r ->> 'cap', '?') || ', floor of new people ' || (r ->> 'floor') || '); not written ' || (r ->> 'not_written')
        || '; off the list ' || (r ->> 'off_list_today') || E'.\nBy kind: ' || (r -> 'by_kind')::text
        || E'\nReplies today ' || (r ->> 'replies_today') || ', STOPs ' || (r ->> 'stops_today') || ', hot ' || (r ->> 'hot_today')
        || E'.\nNew people still ready: ' || (r ->> 'first_ready') || ' by tier ' || (r -> 'first_ready_by_tier')::text || ', about ' || (r ->> 'days_of_new_people') || ' days at the floor.'
        || E'\nFollow-ups ready by step: ' || (r -> 'followups_ready_by_step')::text || '; next numbers ' || (r ->> 'next_numbers_ready')
        || E'.\nWhy the rest of the first-text store is not ready: ' || (r -> 'first_blocked')::text
        || E'\nFollow-ups held back: ' || (r -> 'followups_blocked')::text
        || E'\nRecord verdicts as of ' || coalesce(r ->> 'verdicts_as_of', 'never') || '.';
    perform public.desk_post('desk', 'all', 'report',
      'The day ' || d || case when low then ': NEW PEOPLE RUN OUT IN ' || (r ->> 'days_of_new_people') || ' DAYS' else ': report' end, left(txt, 11000));
    out := out || jsonb_build_object('report', 'posted', 'low_supply', low);
  end if;
  return out;
end $$;

-- the team's read of the day (the app, later a page): the same numbers the desk gets
create or replace function public.the_day() returns jsonb language sql stable security definer set search_path = public as $$
  select case when public.is_team() then public.text_day_report(now()) else jsonb_build_object('ok', false, 'reason', 'not on the team') end
$$;

-- ------------------------------------------------------------------ ready_to_text serves the day's list
-- Same shape as 0208, so the texting agent's job reads it as before. What changed: new_cards, followups_due and
-- next_numbers are today's list in its order (need first), each with the phone to use and the name to sign (voice);
-- all_sources no longer matters (the list is drawn from the whole store); laptop_text is the laptop's wording when it planned the same text.
-- Before the first build of the day, the pool itself is shown in the same order.
create or replace function public.agent_ready_to_text(p_limit integer, p_followups boolean, p_all boolean, p_now timestamptz default now())
returns jsonb language sql stable security definer set search_path = public as $$
  with d as (select (p_now at time zone 'America/Chicago')::date as day),
  handed as (
    select distinct on (p.lead_id, p.step) p.lead_id, p.step, p.body as laptop_text
      from public.planned_openers p
     where p.lane <> 'agent' and p.send_reason = 'handed to the sender agent' and p.send_status = 'withdrawn'
       and p.plan_date >= ((p_now at time zone 'America/Chicago')::date - 7)
     order by p.lead_id, p.step, p.plan_date desc),
  listed as (
    select t.lead_id, t.kind, t.step, t.phone, t.voice, t.tier, t.need_why, t.due_day, t.ord from public.text_day t, d
     where t.day = d.day
       and not exists (select 1 from public.planned_openers po where po.lead_id = t.lead_id and po.step = t.step
                        and po.send_status in ('planned', 'would_send', 'sending', 'sent', 'delivered'))),
  pool as (
    select p.lead_id, p.kind, p.step, p.phone, public.card_voice(p.lead_id) as voice, p.tier, p.need_why, p.due_day, p.ord::int as ord
      from public.text_pool(p_now) p
     where p.block is null and p.ord <= 300
       and not exists (select 1 from public.text_day t where t.day = (p_now at time zone 'America/Chicago')::date)),
  todo as (select * from listed union all select * from pool),
  shown as (
    select x.*, h.laptop_text, row_number() over (partition by x.kind order by x.ord) as rn from todo x
      left join handed h on h.lead_id = x.lead_id and h.step = x.step
     where x.kind <> 'followup' or p_followups)
  select jsonb_build_object(
    'new_cards', (select coalesce(jsonb_agg(public.agent_card(s.lead_id) || jsonb_build_object('next_step', 1, 'phone', s.phone, 'voice', s.voice,
                    'tier', s.tier, 'need', s.need_why, 'laptop_text', s.laptop_text, 'laptop_phone', s.phone,
                    'reasons_count', cardinality(l.reasons_to_sell), 'stacked_at', l.stacked_at, 'laptop_card', l.wpie_owner_id > 0) order by s.ord), '[]'::jsonb)
                    from shown s join public.leads l on l.id = s.lead_id where s.kind = 'first' and s.rn <= greatest(1, least(p_limit, 300))),
    'followups_due', (select coalesce(jsonb_agg(public.agent_card(s.lead_id) || jsonb_build_object('next_step', s.step, 'due_since', s.due_day,
                    'phone', s.phone, 'voice', s.voice, 'tier', s.tier, 'need', s.need_why, 'laptop_text', s.laptop_text, 'laptop_phone', s.phone,
                    'reasons_count', cardinality(l.reasons_to_sell), 'stacked_at', l.stacked_at) order by s.ord), '[]'::jsonb)
                    from shown s join public.leads l on l.id = s.lead_id where s.kind = 'followup' and s.rn <= greatest(1, least(p_limit, 300))),
    'next_numbers', (select coalesce(jsonb_agg(public.agent_card(s.lead_id) || jsonb_build_object('next_step', 1, 'phone', s.phone, 'voice', s.voice,
                    'why', 'the number we texted reached someone else; this is the owner''s next number',
                    'reasons_count', cardinality(l.reasons_to_sell)) order by s.ord), '[]'::jsonb)
                    from shown s join public.leads l on l.id = s.lead_id where s.kind = 'next_number' and s.rn <= greatest(1, least(p_limit, 300))),
    'followups_due_total', (select count(*) from todo where kind = 'followup'),
    'followups_due_by_step', (select coalesce(jsonb_object_agg(step, n), '{}'::jsonb) from (select step, count(*) n from todo where kind = 'followup' group by step) x),
    'the_day', jsonb_build_object(
       'day', (select day from d),
       'list_built', exists (select 1 from public.text_day t, d where t.day = d.day),
       'left_to_write', (select count(*) from todo),
       'left_by_kind', (select coalesce(jsonb_object_agg(k, n), '{}'::jsonb) from (
           select case when kind = 'followup' then 'step_' || step else kind end as k, count(*) n from todo group by 1) x),
       'how', 'This is today''s list, built by the server from the whole store, real need first. Write each text to the phone given, signed with the name in voice. One name per thread; a first text carries the STOP line, a follow-up does not.'))
$$;

-- ------------------------------------------------------------------ the queue asks the rules
-- agent_queue_text as in 0210, plus one call: text_rule_problem (the records, the thread's name, the STOP rule).
create or replace function public.agent_queue_text(p_lead_id uuid, p_phone text, p_body text, p_step integer, p_send_after timestamp with time zone, p_agent text, p_now timestamp with time zone DEFAULT now(), p_variant text DEFAULT NULL::text, p_template text DEFAULT NULL::text, p_slot text DEFAULT NULL::text, p_interest_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c     public.campaign_control;
  l     public.leads;
  num   text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10);
  tz    text;
  t     timestamptz;
  d     date;
  ws    timestamptz;
  we    timestamptz;
  i     integer;
  att   integer := case when coalesce(p_step, 1) = 1 then 1 else 10 + p_step end;
  v_id  uuid;
  b     text := btrim(coalesce(p_body, ''));
  v     text := nullif(upper(left(btrim(coalesce(p_variant, '')), 20)), '');
  sl    text := nullif(lower(btrim(coalesce(p_slot, ''))), '');
  sh    time;
  rp    text;
  k     integer;
  reopen boolean := false;
  codes text;
  iv    public.interests;
  pid   uuid;
  iid   uuid;
begin
  select * into c from public.campaign_control where id = 1;
  select * into l from public.leads where leads.id = p_lead_id;
  if not found then return jsonb_build_object('status', 'refused', 'reason', 'no such card'); end if;
  if public.caller_texting(p_lead_id) is not null then
    return jsonb_build_object('status', 'refused', 'reason', public.caller_texting(p_lead_id) || ' has texted this card themselves: the card is theirs now, no more texts from the system');
  end if;
  if coalesce(p_step, 1) not between 1 and 5 then return jsonb_build_object('status', 'refused', 'reason', 'step is 1 to 5'); end if;
  if l.stage in ('dnc', 'dead', 'closed_no_contact', 'closed_won', 'under_contract') then
    -- a card the laptop closed only because its phones were dead comes back for the next phone (0080)
    if coalesce(p_step, 1) = 1 and l.stage in ('dead', 'closed_no_contact') then
      rp := public.dead_reopen_problem(p_lead_id, num);
      if rp is not null then return jsonb_build_object('status', 'refused', 'reason', rp); end if;
      reopen := true;
    else
      return jsonb_build_object('status', 'refused', 'reason', 'card is closed (' || l.stage::text || ')');
    end if;
  end if;
  if coalesce(p_step, 1) = 1 and (reopen or l.stage not in ('postcard_mailed', 'opener_queued')
       or exists (select 1 from public.planned_openers po where po.wpie_owner_id = l.wpie_owner_id and po.attempt between 1 and 9
                    and po.send_status = any(public.opener_live_statuses()))
       or exists (select 1 from public.messages m where m.lead_id = p_lead_id and m.direction = 'out' and m.is_opener and m.provider_sid is not null)) then
    -- the next phone on the card (0079): allowed when every earlier first text bounced or reached a wrong number
    if not reopen then
      rp := public.next_phone_problem(p_lead_id, num);
      if rp is not null then
        return jsonb_build_object('status', 'refused', 'reason', 'already texted or talking (' || l.stage::text || '): ' || rp);
      end if;
    end if;
    select coalesce(max(po.attempt), 1) + 1 into att from public.planned_openers po
     where po.wpie_owner_id = l.wpie_owner_id and po.attempt between 1 and 9;
    if att > 9 then return jsonb_build_object('status', 'refused', 'reason', 'nine first texts already: this card needs a skip trace'); end if;
  elsif coalesce(p_step, 1) > 1 then
    -- a follow-up belongs to the first text that reached this phone (attempt = that first text's attempt * 10 + step)
    select po.attempt into k from public.planned_openers po
     where po.wpie_owner_id = l.wpie_owner_id and po.attempt between 1 and 9 and right(regexp_replace(po.phone, '\D', '', 'g'), 10) = num
       and po.send_status = 'delivered' order by po.attempt desc limit 1;
    att := coalesce(k, 1) * 10 + p_step;
  end if;
  if not exists (select 1 from public.contacts ct where ct.lead_id = p_lead_id and ct.kind = 'phone' and ct.value_normalized = num
                  and ct.status = 'ok' and not ct.dnc_app and not ct.suppressed and not ct.dnc_vendor and ct.dnc_scrub <> 'dnc') then
    return jsonb_build_object('status', 'refused', 'reason', 'that phone is not a usable phone on this card');
  end if;
  if exists (select 1 from public.suppressed_phones s where s.phone10 = num) then
    return jsonb_build_object('status', 'refused', 'reason', 'this phone opted out');
  end if;
  -- the person the text is for (0083): a do-not-contact or deceased person's number is never texted, on any card
  rp := public.phone_person_block(num);
  if rp is not null then return jsonb_build_object('status', 'refused', 'reason', rp); end if;
  if p_interest_id is not null then
    select * into iv from public.interests i where i.id = p_interest_id and i.lead_id = p_lead_id;
    if not found then return jsonb_build_object('status', 'refused', 'reason', 'no such person on this card (interest_id)'); end if;
    if iv.status <> 'active' or (select pe.status from public.people pe where pe.id = iv.person_id) <> 'active' then
      return jsonb_build_object('status', 'refused', 'reason', 'that person is closed on this card (' || iv.status || ')');
    end if;
    if not exists (select 1 from public.contacts ct where ct.lead_id = p_lead_id and ct.value_normalized = num and ct.person_id = iv.person_id) then
      return jsonb_build_object('status', 'refused', 'reason', 'that phone is not that person''s on this card (add it to them with add_prospects)');
    end if;
    pid := iv.person_id; iid := iv.id;
  else
    select i.person_id, i.id into pid, iid from public.contacts ct join public.interests i on i.person_id = ct.person_id and i.lead_id = p_lead_id
      join public.people pe on pe.id = i.person_id
     where ct.lead_id = p_lead_id and ct.value_normalized = num and i.status = 'active' and pe.status = 'active'
     order by array_position(array['personal_representative', 'special_administrator', 'owner_of_record', 'co_owner', 'trustee', 'heir', 'spouse', 'occupant', 'other'], i.role)
     limit 1;
    if pid is null and exists (select 1 from public.contacts ct where ct.lead_id = p_lead_id and ct.value_normalized = num and ct.person_id is not null) then
      return jsonb_build_object('status', 'refused', 'reason', 'everyone this phone belongs to on this card is closed (deceased, do not contact or not the contact)');
    end if;
  end if;
  if exists (select 1 from public.twilio_inbound ti where ti.from10 = num) then
    return jsonb_build_object('status', 'refused', 'reason', 'they already texted back: replies go to the reply agent and the team');
  end if;
  if b = '' or (coalesce(p_step, 1) = 1 and position('STOP' in b) = 0) then return jsonb_build_object('status', 'refused', 'reason', 'a first text needs a STOP line (a follow-up carries none)'); end if;
  if length(b) > 320 then return jsonb_build_object('status', 'refused', 'reason', 'over 320 characters'); end if;
  -- 0219: the records' verdict, one name per thread, no STOP line on a follow-up
  rp := public.text_rule_problem(p_lead_id, b, coalesce(p_step, 1), p_now);
  if rp is not null then return jsonb_build_object('status', 'refused', 'reason', rp); end if;
  if exists (select 1 from unnest(c.banned_words) w where w <> '' and position(lower(w) in lower(b)) > 0) then
    return jsonb_build_object('status', 'refused', 'reason', 'names the business');
  end if;
  if exists (select 1 from public.planned_openers po where po.lead_id = p_lead_id and po.step = coalesce(p_step, 1)
              and po.send_status in ('planned', 'would_send', 'sending')) then
    return jsonb_build_object('status', 'refused', 'reason', 'a text for this step is already waiting: withdraw it first');
  end if;
  if sl is not null and sl not in ('am', 'pm') then return jsonb_build_object('status', 'refused', 'reason', 'slot is am or pm'); end if;
  tz := public.agent_tz(coalesce(l.mailing_state, 'WI'));
  t := greatest(p_now, coalesce(p_send_after, p_now));
  -- the time-of-day test (Colin 2026-10-26: "200 daily in morning and 200 at 5", "9 is fine"): am goes from 9 AM, pm from 5 PM,
  -- their time; an am text queued after noon waits for the next morning
  if sl is not null then
    sh := case sl when 'am' then time '09:00' else time '17:00' end;
    if sl = 'am' and (t at time zone tz)::time >= time '12:00' then
      t := (((t at time zone tz)::date + 1) + sh) at time zone tz;
    else
      t := greatest(t, (((t at time zone tz)::date) + sh) at time zone tz);
    end if;
  end if;
  for i in 0..8 loop
    d := ((t at time zone tz)::date) + i;
    if c.no_sundays and extract(isodow from d) = 7 then continue; end if;
    ws := (d + c.window_start) at time zone tz;
    we := (d + c.window_end) at time zone tz;
    if we > t then t := greatest(t, ws); exit; end if;
  end loop;
  insert into public.planned_openers (plan_date, wpie_owner_id, attempt, lead_id, lane, template_lane, variant, send_slot, per_hour, phone, body,
         segments, scheduled_at, owner_name, property_address, decision, decided_by_name, decided_at, decision_note,
         send_status, window_start_utc, window_end_utc, governing_state, dnc_state, body_sha256, plan_created_at, step)
  values ((t at time zone c.timezone)::date, l.wpie_owner_id, att, l.id, 'agent', coalesce(nullif(left(btrim(coalesce(p_template, '')), 40), ''), 'agent'),
          coalesce(v, '-'), sl, case when sl = 'am' then 270 else 100 end, '+1' || num, b, case when length(b) <= 160 then 1 else 2 end, t, l.owner_name, l.property_address,
          'approved', 'Muse (' || coalesce(p_agent, 'agent') || ')', p_now, 'written and queued by the sender agent',
          'planned', ws, we, upper(coalesce(l.mailing_state, 'WI')), 'unknown', encode(sha256(convert_to(b, 'UTF8')), 'hex'), p_now,
          coalesce(p_step, 1))
  -- the laptop's copy of the same text, handed over to the agent, is taken over by the agent's wording
  on conflict (plan_date, wpie_owner_id, attempt) do update set
    lane = 'agent', template_lane = excluded.template_lane, variant = excluded.variant, send_slot = excluded.send_slot, phone = excluded.phone, body = excluded.body,
    segments = excluded.segments, scheduled_at = excluded.scheduled_at, decision = 'approved', decided_by_name = excluded.decided_by_name,
    decided_at = excluded.decided_at, decision_note = excluded.decision_note, send_status = 'planned', send_reason = null,
    send_updated_at = p_now, window_start_utc = excluded.window_start_utc, window_end_utc = excluded.window_end_utc,
    governing_state = excluded.governing_state, body_sha256 = excluded.body_sha256, per_hour = excluded.per_hour, step = excluded.step,
    claim_mode = null, claimed_at = null, provider_sid = null, error_code = null
    where planned_openers.send_status = 'withdrawn'
  returning planned_openers.id into v_id;
  if v_id is null then return jsonb_build_object('status', 'refused', 'reason', 'this card already has that text planned for that day'); end if;
  if iid is not null then update public.planned_openers set interest_id = iid where id = v_id; end if;
  if reopen then
    select string_agg(distinct po.error_code, ', ') into codes from public.planned_openers po
     where po.wpie_owner_id = l.wpie_owner_id and po.step = 1 and po.error_code is not null;
    update public.leads set stage = 'opener_queued', belt = null, belt_step = 0, next_stop_at = null, next_stop_who = null,
           dead_reason = null, reopened_at = p_now,
           reopened_reason = 'delivery-failure cascade: every first text bounced' || coalesce(' (' || codes || ')', '') || '; next phone ' || num,
           notes = concat_ws(' | ', notes, to_char(p_now at time zone 'America/Chicago', 'YYYY-MM-DD') || ' reopened by Muse (' || coalesce(p_agent, 'agent')
                   || '): closed as ' || l.stage::text || ' only because every first text bounced' || coalesce(' (' || codes || ')', '') || '; texting the next phone ' || num)
     where id = p_lead_id;
    update public.lead_stage_events set source = 'agent: delivery-failure reopen'
     where id = (select max(e.id) from public.lead_stage_events e where e.lead_id = p_lead_id and e.to_stage = 'opener_queued');
    insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
    values (p_lead_id, 'reopened', l.belt, null, null, jsonb_build_object('from_stage', l.stage::text, 'why', 'every first text bounced', 'codes', codes, 'next_phone', num), p_now,
            'Muse (' || coalesce(p_agent, 'agent') || ')');
  end if;
  return jsonb_build_object('status', 'queued', 'text_id', v_id, 'goes_after', t, 'window_ends', we, 'variant', coalesce(v, '-'), 'slot', sl,
    'next_phone', coalesce(p_step, 1) = 1 and att > 1, 'reopened', reopen,
    'interest_id', iid, 'person', (select pe.name from public.people pe where pe.id = pid));
end $function$;
revoke all on function public.agent_queue_text(uuid, text, text, integer, timestamptz, text, timestamptz, text, text, text, uuid) from public, anon, authenticated;
grant execute on function public.agent_queue_text(uuid, text, text, integer, timestamptz, text, timestamptz, text, text, text, uuid) to service_role;

revoke all on function public.text_voices(), public.text_speaker(text), public.card_voice(uuid), public.card_record_block(uuid, date),
  public.card_hold_block(uuid, timestamptz), public.text_pool(timestamptz), public.text_rule_problem(uuid, text, integer, timestamptz),
  public.text_day_build(timestamptz), public.text_day_report(timestamptz), public.text_day_backstop(timestamptz, integer),
  public.text_day_tick(timestamptz) from public, anon, authenticated;
grant execute on function public.text_voices(), public.text_speaker(text), public.card_voice(uuid), public.card_record_block(uuid, date),
  public.card_hold_block(uuid, timestamptz), public.text_pool(timestamptz), public.text_rule_problem(uuid, text, integer, timestamptz),
  public.text_day_build(timestamptz), public.text_day_report(timestamptz), public.text_day_backstop(timestamptz, integer),
  public.text_day_tick(timestamptz) to service_role;
revoke all on function public.the_day() from public, anon;
grant execute on function public.the_day() to authenticated, service_role;
grant execute on function public.card_voice(uuid) to authenticated;
revoke all on function public.agent_ready_to_text(integer, boolean, boolean, timestamptz) from public, anon, authenticated;
grant execute on function public.agent_ready_to_text(integer, boolean, boolean, timestamptz) to service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if exists (select 1 from cron.job where jobname = 'wpie-the-day') then
      perform cron.unschedule('wpie-the-day');
    end if;
    perform cron.schedule('wpie-the-day', '4,19,34,49 * * * *', 'select public.text_day_tick()');
  end if;
end $$;

