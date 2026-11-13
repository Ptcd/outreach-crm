-- 0223: the offer by text, on Muse's rule, with Colin's OK before any number is texted.
--
-- Colin 2026-11-13, after the desk meeting (posts 241 to 253): "yes muse ruling". The number a seller gets by text is
-- Muse's rule (her plan 5.7 and 8.2, his words of Nov 8 and Nov 9): 65% of the after-repair value minus repairs, to
-- the nearest $100, no floor; a counter may be taken up to 70% of the value minus repairs. Repairs are what the seller
-- named, by item, else $15 / $30 / $60 a square foot. And, the same day: "Muse needs to check with me first".
--
-- Until now nothing carried a seller from "what's your offer" to a number: 14 sellers asked between Oct 21 and Nov 12
-- and none got one. This makes it a path the server runs, one row per card:
--
--   text_offer_rules   the rule, as numbers Colin can change (never in code)
--   text_offers        one open offer per card: what the seller said, the comp, the numbers, Colin's OK, the answer
--   text_offer_view()  the ONE next step for an offer: what, whose, by when, and the gate that blocks it
--   a seller who asks for a number opens one by themself (trigger on the inbound text)
--   Colin's OK         text_offer_decide: OK the figure (or change it), pass, or ask Muse something
--   the gate           a text from the agent door that carries a dollar figure is refused unless Colin OK'd that
--                      figure for that card
--   text_offer_tick()  the clock: closes what the card closed, asks Colin when a number is ready, tells Muse on the
--                      desk when her step is late, and posts the evening report

-- ------------------------------------------------------------------ the rule
create table if not exists public.text_offer_rules (
  id            integer primary key default 1 check (id = 1),
  lao_pct       numeric not null default 0.65,          -- the offer: this share of the value, minus repairs
  mao_pct       numeric not null default 0.70,          -- the most a counter may be taken at
  wholesale_pct numeric not null default 0.80,          -- what a wholesale buyer would pay, of the most
  round_to      numeric not null default 100,
  per_ft        jsonb not null default '{"light": 15, "medium": 30, "heavy": 60}'::jsonb,
  items         jsonb not null default '{"roof": 10000, "furnace": 9500, "foundation": 12000, "plumbing": 7500, "electrical": 10000, "water": 8000, "fire": 35000, "kitchen": 15000, "bath": 7500, "floors": 7500, "windows": 9000, "sewer": 9000, "cleanout": 5000, "cosmetic": 6500}'::jsonb,
  min_comps     integer not null default 3,             -- fewer sold comps than this is not a set to offer from
  ask_hours     numeric not null default 1,             -- the one condition question, after the offer opens
  comp_hours    numeric not null default 4,             -- the comp
  colin_hours   numeric not null default 4,             -- Colin's OK
  send_hours    numeric not null default 2,             -- texting the number once he has OK'd it
  nudge_hours   numeric not null default 24,            -- a seller who has not answered
  silent_days   integer not null default 7,
  gate_on       boolean not null default true,          -- the dollar-figure gate on the agent door
  report_day    date,
  updated_at    timestamptz not null default now(),
  updated_by    text
);
insert into public.text_offer_rules (id) values (1) on conflict (id) do nothing;
alter table public.text_offer_rules enable row level security;
grant select on public.text_offer_rules to authenticated, service_role;
drop policy if exists text_offer_rules_team_read on public.text_offer_rules;
create policy text_offer_rules_team_read on public.text_offer_rules for select to authenticated using (public.is_team());

-- ------------------------------------------------------------------ the offers
create table if not exists public.text_offers (
  id               uuid primary key default gen_random_uuid(),
  lead_id          uuid not null references public.leads (id) on delete cascade,
  status           text not null default 'open' check (status in ('open', 'closed')),
  opened_at        timestamptz not null default now(),
  opened_by        text not null default 'muse',         -- 'system' when the seller's own text opened it
  trigger          text not null default 'asked_number' check (trigger in ('asked_number', 'yes_to_selling', 'other')),
  trigger_text     text,                                 -- the seller's words
  phone            text,                                 -- the number the thread is on
  -- what the seller has told us, as fields
  need             text,                                 -- why they would sell
  their_number     numeric,
  their_words      text,                                 -- how they said it, and where the figure came from
  flexible         text not null default 'unknown' check (flexible in ('firm', 'flexible', 'unknown')),
  timeline         text,
  signers          text,
  seller_email     text,
  occupancy        text,
  -- the one condition question
  condition_asked_at timestamptz,
  condition_words  text,                                 -- their answer, in their words
  repair_items     text[] not null default '{}',
  repair_level     text check (repair_level in ('light', 'medium', 'heavy')),
  -- the comp
  comp_due_at      timestamptz,
  arv              numeric,
  arv_basis        text,
  comps            jsonb not null default '[]'::jsonb,
  sqft             integer,
  valued_by        text,
  valued_at        timestamptz,
  -- the numbers, by the rule (the server writes these)
  repairs          numeric,
  repairs_basis    text,
  lao              numeric,
  mao              numeric,
  wholesale        numeric,
  -- the ask to Colin and what he said
  ask_number       numeric,
  ask_kind         text check (ask_kind in ('first', 'counter', 'their_number')),
  ask_note         text,
  asked_at         timestamptz,
  colin_pinged_at  timestamptz,
  colin_reminded_at timestamptz,
  colin_said       text check (colin_said in ('ok', 'pass', 'ask')),
  colin_note       text,
  colin_at         timestamptz,
  ok_number        numeric,
  ok_at            timestamptz,
  ok_numbers       numeric[] not null default '{}',      -- every figure Colin has OK'd for this card
  -- the seller's answer to the number
  response         text check (response in ('accepted', 'counter', 'no')),
  response_words   text,
  response_at      timestamptz,
  counter_number   numeric,
  accepted_number  numeric,
  accepted_at      timestamptz,
  written_pinged_at timestamptz,
  rounds           jsonb not null default '[]'::jsonb,   -- every ask, OK and counter, in order
  late_posted      text,
  closed_at        timestamptz,
  closed_why       text,
  closed_by        text,
  closed_note      text,
  updated_at       timestamptz not null default now()
);
create unique index if not exists text_offers_one_open on public.text_offers (lead_id) where status = 'open';
create index if not exists text_offers_lead_idx on public.text_offers (lead_id, opened_at desc);
alter table public.text_offers enable row level security;
grant select on public.text_offers to authenticated, service_role;
drop policy if exists text_offers_team_read on public.text_offers;
create policy text_offers_team_read on public.text_offers for select to authenticated using (public.is_team());

-- ------------------------------------------------------------------ small helpers
-- Every dollar figure of $1,000 or more in a text: "$85,000", "$85000", "$85k", "85k", "85 thousand", "85,000".
create or replace function public.text_amounts(p_body text) returns numeric[]
language sql immutable as $$
  select coalesce(array_agg(distinct v), '{}') from (
    select replace(m[1], ',', '')::numeric * case when coalesce(m[2], '') <> '' then 1000 else 1 end as v
      from regexp_matches(coalesce(p_body, ''), '\$\s?(\d{1,3}(?:,\d{3})+|\d+(?:\.\d+)?)\s?(k\M|thousand\M)?', 'gi') m
    union
    select m[1]::numeric * 1000
      from regexp_matches(coalesce(p_body, ''), '(?<![\d$.,])(\d{2,3}(?:\.\d)?)\s?(?:k|thousand)\M', 'gi') m
    union
    select replace(m[1], ',', '')::numeric
      from regexp_matches(coalesce(p_body, ''), '(?<![\d$.,])(\d{2,3},\d{3})(?![\d,])', 'g') m
  ) x where v >= 1000
$$;

create or replace function public.text_money(p numeric) returns text
language sql immutable as $$ select case when p is null then null else '$' || to_char(round(p), 'FM999,999,999') end $$;

-- A deadline: so many hours on, and never at night or on a Sunday (then 10 AM Central the next working day).
create or replace function public.text_offer_due(p_from timestamptz, p_hours numeric) returns timestamptz
language plpgsql stable as $$
declare t timestamptz := p_from + make_interval(secs => coalesce(p_hours, 0) * 3600); loc timestamp; d date;
begin
  loc := t at time zone 'America/Chicago';
  d := loc::date;
  if loc::time < time '09:00' then loc := d + time '10:00';
  elsif loc::time >= time '19:00' then loc := (d + 1) + time '10:00';
  end if;
  if extract(isodow from loc) = 7 then loc := (loc::date + 1) + time '10:00'; end if;
  return loc at time zone 'America/Chicago';
end $$;

-- The numbers, by the rule: repairs from the items the seller named, else by the square foot; the offer and the most.
create or replace function public.text_offer_numbers(p_arv numeric, p_sqft integer, p_items text[], p_level text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r public.text_offer_rules; repairs numeric; basis text; unknown text; lao numeric; mao numeric; ws numeric;
begin
  select * into r from public.text_offer_rules where id = 1;
  if p_arv is null or p_arv <= 0 then return jsonb_build_object('ok', false, 'reason', 'no value yet: the comp comes first'); end if;
  if coalesce(array_length(p_items, 1), 0) > 0 then
    select string_agg(i, ', ') into unknown from unnest(p_items) i where not (r.items ? i);
    if unknown is not null then
      return jsonb_build_object('ok', false, 'reason', 'not a repair item: ' || unknown || '. The items are: '
        || (select string_agg(k, ', ' order by k) from jsonb_object_keys(r.items) k));
    end if;
    select sum((r.items->>i)::numeric), string_agg(i || ' ' || public.text_money((r.items->>i)::numeric), ', ' order by i)
      into repairs, basis from (select distinct unnest(p_items) i) x;
    basis := 'what the seller named: ' || basis;
  elsif p_level is not null then
    if p_sqft is null or p_sqft <= 0 then
      return jsonb_build_object('ok', false, 'reason', 'a ' || p_level || ' repair figure is by the square foot: the size (sqft) is needed');
    end if;
    repairs := round((r.per_ft->>p_level)::numeric * p_sqft);
    basis := p_level || ' work: $' || (r.per_ft->>p_level) || ' a sq ft x ' || to_char(p_sqft, 'FM999,999') || ' sq ft';
  else
    return jsonb_build_object('ok', false, 'reason', 'no repair figure: the items the seller named, or light, medium or heavy from their words');
  end if;
  lao := round((p_arv * r.lao_pct - repairs) / r.round_to) * r.round_to;
  mao := round((p_arv * r.mao_pct - repairs) / r.round_to) * r.round_to;
  ws  := round(mao * r.wholesale_pct / r.round_to) * r.round_to;
  if lao <= 0 then
    return jsonb_build_object('ok', false, 'repairs', repairs, 'repairs_basis', basis,
      'reason', 'the rule leaves nothing to offer: ' || public.text_money(p_arv) || ' x ' || round(r.lao_pct * 100)::text || '% is less than the repairs (' || public.text_money(repairs) || ')');
  end if;
  return jsonb_build_object('ok', true, 'repairs', repairs, 'repairs_basis', basis, 'lao', lao, 'mao', mao, 'wholesale', ws,
    'rule', round(r.lao_pct * 100)::text || '% of ' || public.text_money(p_arv) || ' minus ' || public.text_money(repairs) || ' = ' || public.text_money(lao)
            || '; the most, at ' || round(r.mao_pct * 100)::text || '%: ' || public.text_money(mao));
end $$;

-- How many of the comps are sold comps with a price and a date.
create or replace function public.text_offer_comp_count(p_comps jsonb) returns integer
language sql immutable as $$
  select count(*)::integer from jsonb_array_elements(case when jsonb_typeof(p_comps) = 'array' then p_comps else '[]'::jsonb end) c
   where coalesce(nullif(regexp_replace(coalesce(c->>'sold_price', ''), '[^0-9.]', '', 'g'), '')::numeric, 0) > 0
     and coalesce(c->>'sold_date', '') <> ''
$$;

-- What the records say that stops an offer, or null: a listed property, a sale inside 14 days, underwater, out of area.
create or replace function public.text_offer_record_stop(p_lead_id uuid, p_day date) returns text
language sql stable security definer set search_path = public as $$
  select case public.card_record_block(p_lead_id, p_day)
    when 'actively_listed' then 'the property is listed: a listed property is not a lead'
    when 'sheriff_sale_inside_14d' then 'the sheriff sale is inside 14 days: there is no room left to close'
    when 'equity_underwater' then 'the records say more is owed than it is worth'
    when 'outside_area' then 'the property is outside the area we buy in'
  end
$$;

-- ------------------------------------------------------------------ the one next step
-- step, who (muse | colin | seller | caller), due_at, late, gate (what blocks a number, or null) and say (what to do).
create or replace function public.text_offer_view(o public.text_offers, p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  r      public.text_offer_rules;
  l      public.leads;
  n      integer := public.text_offer_comp_count(o.comps);
  stop   text;
  sent   timestamptz;
  heard  timestamptz;
  con    record;
  step   text; who text; due timestamptz; gate text; say text;
begin
  select * into r from public.text_offer_rules where id = 1;
  select * into l from public.leads where id = o.lead_id;
  if o.status = 'closed' then
    return jsonb_build_object('step', 'closed', 'who', null, 'due_at', null, 'late', false, 'gate', o.closed_why, 'say', 'Closed: ' || coalesce(o.closed_why, ''));
  end if;
  stop := public.text_offer_record_stop(o.lead_id, (p_now at time zone 'America/Chicago')::date);
  if o.ok_at is not null then
    select min(m.created_at) into sent from public.messages m
     where m.lead_id = o.lead_id and m.direction = 'out' and m.channel = 'sms' and m.created_at >= o.ok_at
       and m.status not in ('failed', 'undelivered') and o.ok_number = any (public.text_amounts(m.body));
    if sent is not null then
      select max(t.received_at) into heard from public.twilio_inbound t
       where t.lead_id = o.lead_id and t.received_at > sent and not t.is_opt_out;
    end if;
  end if;

  if l.stage::text in ('dnc', 'dead') then
    step := 'close'; who := 'muse'; due := p_now; gate := 'the card is ' || case l.stage::text when 'dnc' then 'do-not-contact' else 'dead' end;
    say := 'Close this offer (offer_close): ' || gate || '.';
  elsif l.human_takeover_at is not null and o.accepted_at is null then
    step := 'caller_has_it'; who := 'caller'; gate := 'a caller took the thread';
    say := coalesce(initcap(l.human_takeover_by::text), 'A caller') || ' took this thread: it is theirs until it is handed back. The numbers stay on the card for them.';
  elsif o.accepted_at is not null then
    select c.id, c.status, c.created_at into con from public.contracts c
     where c.lead_id = o.lead_id and c.created_at >= o.accepted_at and c.status <> 'void' order by c.created_at desc limit 1;
    if con.id is not null and con.status = 'signed' then
      step := 'close'; who := 'muse'; due := p_now; say := 'Signed. Close the offer as under_contract.';
    elsif con.id is not null then
      step := 'signing'; who := 'seller'; due := public.text_offer_due(con.created_at, r.nudge_hours);
      say := 'The written offer is out for signature. If it sits a day, a short text asking whether the email arrived.';
    elsif coalesce(btrim(o.signers), '') = '' or coalesce(btrim(o.seller_email), '') = '' then
      step := 'signing_details'; who := 'muse'; due := public.text_offer_due(o.accepted_at, r.send_hours);
      say := 'They said yes to ' || public.text_money(o.accepted_number) || '. Ask who signs (everyone on the title) and the email the papers go to, then offer_update {signers, seller_email}. Colin sends the written offer; you never do.';
    else
      step := 'written_offer'; who := 'colin'; due := public.text_offer_due(o.accepted_at, r.colin_hours);
      say := 'The seller said yes to ' || public.text_money(o.accepted_number) || '. Colin sends the written offer from the card (Send offer) to ' || o.seller_email || '.';
    end if;
  elsif stop is not null and o.ok_at is null then
    step := 'stop'; who := 'muse'; due := p_now; gate := stop;
    say := 'No number: ' || stop || '. Close the offer as records and give the card its disposition.';
  elsif o.colin_said = 'pass' then
    step := 'passed'; who := 'muse'; due := public.text_offer_due(o.colin_at, r.send_hours); gate := 'Colin passed';
    say := 'Colin passed' || coalesce(': ' || o.colin_note, '') || '. Answer the seller politely with no number, then close the offer as passed.';
  elsif o.colin_said = 'ask' then
    step := 'answer_colin'; who := 'muse'; due := public.text_offer_due(o.colin_at, r.send_hours); gate := 'Colin asked a question';
    say := 'Colin asks: ' || coalesce(o.colin_note, '') || ' Answer with offer_update {answer}; it goes back to him with the number.';
  elsif o.asked_at is not null and (o.ok_at is null or o.ok_at < o.asked_at) then
    step := 'colin'; who := 'colin'; due := public.text_offer_due(o.asked_at, r.colin_hours); gate := 'Colin''s OK';
    say := 'Waiting for Colin''s OK on ' || public.text_money(o.ask_number)
           || case o.ask_kind when 'counter' then ' (their counter)' when 'their_number' then ' (the seller''s own number, under the rule''s offer)' else '' end
           || '. Text no figure until he has OK''d it.';
  elsif o.ok_at is not null and sent is null then
    step := 'send_number'; who := 'muse'; due := public.text_offer_due(o.ok_at, r.send_hours);
    say := 'Colin OK''d ' || public.text_money(o.ok_number) || coalesce(' (' || o.colin_note || ')', '')
           || '. Text it now, as the one number, in plain words. That figure and no other; never "cash" or "as-is".';
  elsif o.ok_at is not null and o.response is null and heard is not null then
    step := 'read_reply'; who := 'muse'; due := public.text_offer_due(heard, r.ask_hours);
    say := 'They answered the number. Record it: offer_update {response: accepted | counter | no, response_words, counter_number}. A counter goes to Colin before you answer it.';
  elsif o.ok_at is not null and o.response is null then
    step := 'wait_reply'; who := 'seller'; due := public.text_offer_due(sent, r.nudge_hours);
    say := case when p_now > sent + make_interval(days => r.silent_days) then 'No answer to the number in ' || r.silent_days::text || ' days: close the offer as silent.'
                else 'The number is with the seller. If a day passes, one short nudge, no new figure.' end;
    if p_now > sent + make_interval(days => r.silent_days) then who := 'muse'; step := 'close'; end if;
  elsif o.response = 'no' then
    step := 'close'; who := 'muse'; due := public.text_offer_due(o.response_at, r.send_hours);
    say := 'They said no to the number. Close the offer as declined and give the card its disposition (a check-back date if they left a door open).';
  elsif o.condition_asked_at is null and coalesce(btrim(o.condition_words), '') = '' then
    step := 'ask_condition'; who := 'muse'; due := public.text_offer_due(o.opened_at, r.ask_hours); gate := 'the condition, in their words';
    say := 'Text the one condition question now, the big items only (roof, furnace, foundation, water, kitchen and baths), then offer_update {condition_asked: true}. If they already said it in the thread, send condition_words and the items instead. Start the comp in the same sitting.';
  elsif o.arv is null or n < r.min_comps then
    step := 'comp'; who := 'muse'; due := coalesce(o.comp_due_at, public.text_offer_due(o.opened_at, r.comp_hours)); gate := 'a comp set to stand on';
    say := case when o.arv is not null then 'Only ' || n::text || ' sold comp(s) with a price and a date: ' || r.min_comps::text || ' are needed. Add them, or close the offer as no_comp_set.'
                else 'Comp it now: sold comps near the house, then offer_update {arv, arv_basis, comps, sqft}. Fewer than ' || r.min_comps::text || ' sold comps is not a set to offer from: close as no_comp_set.' end;
  elsif coalesce(btrim(o.condition_words), '') = '' then
    step := 'wait_condition'; who := 'seller'; due := public.text_offer_due(o.condition_asked_at, r.nudge_hours); gate := 'the condition, in their words';
    say := case when p_now > o.condition_asked_at + make_interval(days => r.silent_days) then 'No answer to the condition question in ' || r.silent_days::text || ' days: close the offer as silent.'
                else 'Waiting for their answer on the condition. If a day passes, one short nudge.' end;
    if p_now > o.condition_asked_at + make_interval(days => r.silent_days) then who := 'muse'; step := 'close'; end if;
  elsif o.lao is null then
    step := 'read_condition'; who := 'muse'; due := public.text_offer_due(greatest(o.valued_at, o.updated_at), r.ask_hours); gate := 'a repair figure from their words';
    say := coalesce((public.text_offer_numbers(o.arv, o.sqft, o.repair_items, o.repair_level))->>'reason', 'no repair figure') || '. offer_update {repair_items} from what they named, or repair_level if they named no items. A vague answer is no offer: ask once more, or close as vague_condition.';
  elsif o.their_number is not null and o.their_number > o.arv and o.flexible <> 'flexible' then
    step := 'retail'; who := 'muse'; due := public.text_offer_due(greatest(o.valued_at, o.updated_at), r.send_hours); gate := 'their number is above what it is worth fixed up';
    say := 'Their number (' || public.text_money(o.their_number) || ') is above the comp centre (' || public.text_money(o.arv) || '): no number. Close the offer as retail and give the card its disposition, unless they said they would take less (then flexible: flexible).';
  else
    step := 'ask_colin'; who := 'muse'; due := p_now; gate := 'Colin''s OK';
    say := 'Everything is in. The number goes to Colin on the next pass of the clock (inside 15 minutes).';
  end if;
  return jsonb_build_object('step', step, 'who', who, 'due_at', due, 'late', coalesce(due < p_now, false) and who in ('muse', 'colin'),
    'gate', gate, 'say', say, 'number_sent_at', sent, 'comp_count', n);
end $$;

-- ------------------------------------------------------------------ the numbers and the ask
-- Recompute the numbers; when everything is in and nothing blocks it, put the figure in front of Colin.
create or replace function public.text_offer_refresh(p_id uuid, p_now timestamptz default now()) returns void
language plpgsql security definer set search_path = public as $$
declare o public.text_offers; x jsonb; v jsonb; n numeric; kind text;
begin
  select * into o from public.text_offers where id = p_id for update;
  if not found or o.status <> 'open' then return; end if;
  x := public.text_offer_numbers(o.arv, o.sqft, o.repair_items, o.repair_level);
  if coalesce((x->>'ok')::boolean, false) then
    update public.text_offers set repairs = (x->>'repairs')::numeric, repairs_basis = x->>'repairs_basis', lao = (x->>'lao')::numeric,
           mao = (x->>'mao')::numeric, wholesale = (x->>'wholesale')::numeric where id = p_id;
  else
    update public.text_offers set repairs = nullif(x->>'repairs', '')::numeric, repairs_basis = x->>'repairs_basis', lao = null, mao = null, wholesale = null where id = p_id;
  end if;
  select * into o from public.text_offers where id = p_id;
  if o.ok_at is not null then return; end if;                       -- a number is out or OK'd: only a counter asks again
  v := public.text_offer_view(o, p_now);
  if v->>'step' = 'ask_colin' or (v->>'step' = 'colin' and o.ask_kind in ('first', 'their_number')) then
    if o.their_number is not null and o.their_number <= o.lao then n := o.their_number; kind := 'their_number';
    else n := o.lao; kind := 'first'; end if;
    if o.asked_at is null or o.ask_number is distinct from n then
      update public.text_offers set ask_number = n, ask_kind = kind, asked_at = p_now, colin_pinged_at = null, colin_reminded_at = null,
             colin_said = null,
             rounds = rounds || jsonb_build_object('at', p_now, 'what', 'asked', 'kind', kind, 'number', n)
       where id = p_id;
    end if;
  elsif o.asked_at is not null and o.ask_kind in ('first', 'their_number') and v->>'step' not in ('colin', 'passed', 'answer_colin') then
    -- something the ask stood on is gone (the comp set, the repair figure): take the ask back
    update public.text_offers set asked_at = null, ask_number = null, ask_kind = null, colin_pinged_at = null where id = p_id;
  end if;
end $$;

-- ------------------------------------------------------------------ the agent's side
create or replace function public.agent_offer_row(o public.text_offers, p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('offer_id', o.id, 'lead_id', o.lead_id, 'owner_name', l.owner_name, 'address', l.property_address, 'city', l.municipality,
    'county', l.county, 'phone', o.phone, 'opened_at', o.opened_at, 'opened_by', o.opened_by, 'their_words_that_opened_it', o.trigger_text,
    'next', public.text_offer_view(o, p_now),
    'seller', jsonb_build_object('need', o.need, 'their_number', o.their_number, 'their_words', o.their_words, 'flexible', o.flexible,
      'timeline', o.timeline, 'signers', o.signers, 'seller_email', o.seller_email, 'occupancy', o.occupancy,
      'condition_asked_at', o.condition_asked_at, 'condition_words', o.condition_words, 'repair_items', o.repair_items, 'repair_level', o.repair_level),
    'comp', jsonb_build_object('arv', o.arv, 'basis', o.arv_basis, 'sold_comps', public.text_offer_comp_count(o.comps), 'sqft', o.sqft, 'due_at', o.comp_due_at, 'valued_at', o.valued_at),
    'numbers', jsonb_build_object('repairs', o.repairs, 'repairs_basis', o.repairs_basis, 'offer', o.lao, 'most', o.mao, 'wholesale', o.wholesale,
      'asked_of_colin', o.ask_number, 'asked_at', o.asked_at, 'colin_said', o.colin_said, 'colin_note', o.colin_note,
      'ok_number', o.ok_number, 'ok_at', o.ok_at, 'figures_you_may_text', o.ok_numbers),
    'answer', jsonb_build_object('response', o.response, 'words', o.response_words, 'counter', o.counter_number, 'accepted', o.accepted_number, 'accepted_at', o.accepted_at))
    from public.leads l where l.id = o.lead_id
$$;

create or replace function public.agent_offer_open(p_lead_id uuid, p_trigger text, p_words text, p_phone text, p_agent text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare l public.leads; o public.text_offers; r public.text_offer_rules; d text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10);
begin
  select * into r from public.text_offer_rules where id = 1;
  select * into l from public.leads where id = p_lead_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card'); end if;
  if l.stage::text in ('dnc', 'dead') then return jsonb_build_object('ok', false, 'reason', 'the card is ' || l.stage::text || ': no offer'); end if;
  select * into o from public.text_offers where lead_id = p_lead_id and status = 'open';
  if found then return jsonb_build_object('ok', true, 'already', true, 'offer', public.agent_offer_row(o)); end if;
  if coalesce(btrim(p_words), '') = '' then return jsonb_build_object('ok', false, 'reason', 'say what the seller wrote that opens this (words)'); end if;
  insert into public.text_offers (lead_id, opened_by, trigger, trigger_text, phone, comp_due_at)
  values (p_lead_id, coalesce(nullif(lower(p_agent), ''), 'muse'),
          case when p_trigger in ('asked_number', 'yes_to_selling', 'other') then p_trigger else 'yes_to_selling' end,
          btrim(p_words), nullif(d, ''), public.text_offer_due(now(), r.comp_hours))
  returning * into o;
  return jsonb_build_object('ok', true, 'offer', public.agent_offer_row(o));
end $$;

create or replace function public.agent_offer_update(p jsonb, p_agent text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  o public.text_offers; r public.text_offer_rules; items text[]; unknown text; c numeric; lvl text; resp text; now_ timestamptz := now();
  txt text;
begin
  select * into r from public.text_offer_rules where id = 1;
  if nullif(p->>'offer_id', '') is not null then
    select * into o from public.text_offers where id = (p->>'offer_id')::uuid for update;
  else
    select * into o from public.text_offers where lead_id = nullif(p->>'lead_id', '')::uuid and status = 'open' for update;
  end if;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no open offer for that card: offer_open first'); end if;
  if o.status <> 'open' then return jsonb_build_object('ok', false, 'reason', 'this offer is closed (' || coalesce(o.closed_why, '') || ')'); end if;

  -- what the seller said
  if p ? 'need' then o.need := nullif(btrim(p->>'need'), ''); end if;
  if p ? 'their_number' then
    o.their_number := nullif(regexp_replace(coalesce(p->>'their_number', ''), '[^0-9.]', '', 'g'), '')::numeric;
  end if;
  if p ? 'their_words' then o.their_words := nullif(btrim(p->>'their_words'), ''); end if;
  if p ? 'flexible' then
    if p->>'flexible' not in ('firm', 'flexible', 'unknown') then return jsonb_build_object('ok', false, 'reason', 'flexible is firm, flexible or unknown'); end if;
    o.flexible := p->>'flexible';
  end if;
  if p ? 'timeline' then o.timeline := nullif(btrim(p->>'timeline'), ''); end if;
  if p ? 'signers' then o.signers := nullif(btrim(p->>'signers'), ''); end if;
  if p ? 'seller_email' then
    txt := lower(btrim(coalesce(p->>'seller_email', '')));
    if txt <> '' and txt !~ '^[^@\s]+@[^@\s]+\.[a-z]{2,}$' then return jsonb_build_object('ok', false, 'reason', 'that is not an email address'); end if;
    o.seller_email := nullif(txt, '');
  end if;
  if p ? 'occupancy' then o.occupancy := nullif(btrim(p->>'occupancy'), ''); end if;
  if p ? 'phone' then o.phone := nullif(right(regexp_replace(coalesce(p->>'phone', ''), '\D', '', 'g'), 10), ''); end if;

  -- the condition, in their words, and the repair figure that comes from it
  if coalesce((p->>'condition_asked')::boolean, false) and o.condition_asked_at is null then o.condition_asked_at := now_; end if;
  if p ? 'condition_words' then o.condition_words := nullif(btrim(p->>'condition_words'), ''); end if;
  if p ? 'repair_items' then
    if jsonb_typeof(p->'repair_items') <> 'array' then return jsonb_build_object('ok', false, 'reason', 'repair_items is a list'); end if;
    select coalesce(array_agg(distinct lower(btrim(x))), '{}') into items from jsonb_array_elements_text(p->'repair_items') x where btrim(x) <> '';
    select string_agg(i, ', ') into unknown from unnest(items) i where not (r.items ? i);
    if unknown is not null then
      return jsonb_build_object('ok', false, 'reason', 'not a repair item: ' || unknown || '. The items are: '
        || (select string_agg(k || ' ' || public.text_money((r.items->>k)::numeric), ', ' order by k) from jsonb_object_keys(r.items) k));
    end if;
    o.repair_items := items;
  end if;
  if p ? 'repair_level' then
    lvl := nullif(lower(btrim(coalesce(p->>'repair_level', ''))), '');
    if lvl is not null and lvl not in ('light', 'medium', 'heavy') then return jsonb_build_object('ok', false, 'reason', 'repair_level is light, medium or heavy'); end if;
    o.repair_level := lvl;
  end if;
  if (coalesce(array_length(o.repair_items, 1), 0) > 0 or o.repair_level is not null) and coalesce(btrim(o.condition_words), '') = '' then
    return jsonb_build_object('ok', false, 'reason', 'a repair figure comes from the seller''s own words: send condition_words (what they wrote) with it');
  end if;

  -- the comp
  if p ? 'sqft' then o.sqft := nullif(regexp_replace(coalesce(p->>'sqft', ''), '[^0-9]', '', 'g'), '')::integer; end if;
  if p ? 'arv' then
    c := nullif(regexp_replace(coalesce(p->>'arv', ''), '[^0-9.]', '', 'g'), '')::numeric;
    if c is null or c <= 0 then return jsonb_build_object('ok', false, 'reason', 'arv is the after-repair value in dollars'); end if;
    if coalesce(btrim(coalesce(p->>'arv_basis', o.arv_basis)), '') = '' then return jsonb_build_object('ok', false, 'reason', 'say how you got the value (arv_basis): which sales, which sources'); end if;
    if jsonb_typeof(coalesce(p->'comps', o.comps)) <> 'array' or jsonb_array_length(coalesce(p->'comps', o.comps)) = 0 then
      return jsonb_build_object('ok', false, 'reason', 'send the comps with the value: address, sold_price, sold_date, sqft, distance, url, note');
    end if;
    o.arv := c; o.valued_by := coalesce(p_agent, 'agent'); o.valued_at := now_;
  end if;
  if p ? 'arv_basis' then o.arv_basis := nullif(btrim(p->>'arv_basis'), ''); end if;
  if p ? 'comps' then
    if jsonb_typeof(p->'comps') <> 'array' then return jsonb_build_object('ok', false, 'reason', 'comps is a list'); end if;
    o.comps := p->'comps';
  end if;

  -- Colin asked something: the answer goes back to him with the number
  if nullif(btrim(coalesce(p->>'answer', '')), '') is not null then
    if o.colin_said is distinct from 'ask' then return jsonb_build_object('ok', false, 'reason', 'Colin has not asked anything on this offer'); end if;
    o.rounds := o.rounds || jsonb_build_object('at', now_, 'what', 'answered', 'colin_asked', o.colin_note, 'answer', btrim(p->>'answer'));
    o.ask_note := 'You asked: ' || coalesce(o.colin_note, '') || ' Muse: ' || btrim(p->>'answer');
    o.colin_said := null; o.colin_note := null; o.asked_at := now_; o.colin_pinged_at := null; o.colin_reminded_at := null;
  end if;

  -- the seller's answer to the number
  if p ? 'response' then
    resp := lower(btrim(coalesce(p->>'response', '')));
    if resp not in ('accepted', 'counter', 'no') then return jsonb_build_object('ok', false, 'reason', 'response is accepted, counter or no'); end if;
    if o.ok_at is null then return jsonb_build_object('ok', false, 'reason', 'no number has been OK''d and texted yet: there is nothing to answer'); end if;
    if coalesce(btrim(p->>'response_words'), '') = '' then return jsonb_build_object('ok', false, 'reason', 'send what they wrote (response_words)'); end if;
    o.response := resp; o.response_words := btrim(p->>'response_words'); o.response_at := now_;
    if resp = 'counter' then
      c := nullif(regexp_replace(coalesce(p->>'counter_number', ''), '[^0-9.]', '', 'g'), '')::numeric;
      if c is null or c <= 0 then return jsonb_build_object('ok', false, 'reason', 'a counter needs counter_number, in dollars'); end if;
      o.counter_number := c;
      -- every new figure is Colin's: their counter when it is inside the most, else the most itself
      o.ask_kind := 'counter'; o.ask_number := least(c, o.mao); o.asked_at := now_; o.colin_pinged_at := null; o.colin_reminded_at := null; o.colin_said := null;
      o.ask_note := 'They countered ' || public.text_money(c) || ' to our ' || public.text_money(o.ok_number) || ': "' || left(o.response_words, 300) || '". '
                 || case when c <= o.mao then 'That is inside the most the rule allows (' || public.text_money(o.mao) || ').'
                         else 'That is above the most the rule allows (' || public.text_money(o.mao) || '); the figure here is the most.' end;
      o.rounds := o.rounds || jsonb_build_object('at', now_, 'what', 'counter', 'their', c, 'ours', o.ok_number, 'asked', o.ask_number);
    elsif resp = 'accepted' then
      o.accepted_number := o.ok_number; o.accepted_at := now_;
      o.rounds := o.rounds || jsonb_build_object('at', now_, 'what', 'accepted', 'number', o.ok_number);
    else
      o.rounds := o.rounds || jsonb_build_object('at', now_, 'what', 'no', 'number', o.ok_number);
    end if;
  end if;

  update public.text_offers t set need = o.need, their_number = o.their_number, their_words = o.their_words, flexible = o.flexible, timeline = o.timeline,
         signers = o.signers, seller_email = o.seller_email, occupancy = o.occupancy, phone = o.phone,
         condition_asked_at = o.condition_asked_at, condition_words = o.condition_words, repair_items = o.repair_items, repair_level = o.repair_level,
         sqft = o.sqft, arv = o.arv, arv_basis = o.arv_basis, comps = o.comps, valued_by = o.valued_by, valued_at = o.valued_at,
         ask_kind = o.ask_kind, ask_number = o.ask_number, ask_note = o.ask_note, asked_at = o.asked_at, colin_pinged_at = o.colin_pinged_at,
         colin_reminded_at = o.colin_reminded_at, colin_said = o.colin_said, colin_note = o.colin_note,
         response = o.response, response_words = o.response_words, response_at = o.response_at, counter_number = o.counter_number,
         accepted_number = o.accepted_number, accepted_at = o.accepted_at, rounds = o.rounds, updated_at = now_
   where t.id = o.id;
  perform public.text_offer_refresh(o.id, now_);
  select * into o from public.text_offers where id = o.id;
  return jsonb_build_object('ok', true, 'offer', public.agent_offer_row(o, now_));
end $$;

create or replace function public.text_offer_close(p_id uuid, p_why text, p_note text, p_by text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o public.text_offers;
begin
  select * into o from public.text_offers where id = p_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such offer'); end if;
  if o.status = 'closed' then return jsonb_build_object('ok', true, 'already', true, 'why', o.closed_why); end if;
  if p_why not in ('retail', 'no_comp_set', 'vague_condition', 'silent', 'declined', 'passed', 'records', 'dnc', 'card_dead', 'caller_took_it', 'under_contract', 'not_selling', 'other') then
    return jsonb_build_object('ok', false, 'reason', 'why is one of: retail, no_comp_set, vague_condition, silent, declined, passed, records, caller_took_it, under_contract, not_selling, other');
  end if;
  if p_why = 'other' and coalesce(btrim(p_note), '') = '' then return jsonb_build_object('ok', false, 'reason', 'other needs a note'); end if;
  update public.text_offers set status = 'closed', closed_at = now(), closed_why = p_why, closed_note = nullif(btrim(coalesce(p_note, '')), ''),
         closed_by = coalesce(p_by, 'muse'), updated_at = now() where id = p_id;
  update public.leads set notes = concat_ws(' | ', notes, to_char(now() at time zone 'America/Chicago', 'YYYY-MM-DD') || ' offer by text closed: ' || p_why
         || coalesce(' (' || nullif(btrim(coalesce(p_note, '')), '') || ')', '')
         || case when o.ok_number is not null then ', our number was ' || public.text_money(o.ok_number) else ', no number went out' end)
   where id = o.lead_id;
  return jsonb_build_object('ok', true, 'why', p_why);
end $$;

create or replace function public.agent_offer_close(p_offer_id uuid, p_why text, p_note text, p_agent text) returns jsonb
language sql security definer set search_path = public as $$
  select public.text_offer_close(p_offer_id, p_why, p_note, coalesce(nullif(lower(p_agent), ''), 'muse'))
$$;

-- Open call tasks whose time has passed with no call logged since, on cards where the seller has written back.
create or replace function public.text_offer_calls_not_dialed(p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('task_id', t.id, 'lead_id', t.lead_id, 'owner_name', l.owner_name, 'address', l.property_address,
           'caller', t.owner, 'due_at', t.due_at, 'title', coalesce(t.title, t.note),
           'days_late', floor(extract(epoch from p_now - t.due_at) / 86400)::int) order by t.due_at), '[]'::jsonb)
    from (select * from public.tasks t0
           where t0.done_at is null and t0.kind::text in ('call', 'callback') and t0.due_at < p_now - interval '4 hours' and t0.due_at > p_now - interval '21 days'
           order by t0.due_at limit 400) t
    join public.leads l on l.id = t.lead_id
   where l.stage::text not in ('dnc', 'dead', 'closed_no_contact')
     and exists (select 1 from public.twilio_inbound i where i.lead_id = t.lead_id and not i.is_opt_out)
     and not exists (select 1 from public.messages m where m.lead_id = t.lead_id and m.channel = 'call' and m.created_at >= t.due_at - interval '12 hours')
$$;

-- The agent's worklist: one row per open offer with its one next step; hers first, late first.
create or replace function public.agent_offer_worklist(p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public as $$
  with rows as (select public.agent_offer_row(o, p_now) as j from public.text_offers o where o.status = 'open')
  select jsonb_build_object(
    'now', p_now,
    'yours', coalesce((select jsonb_agg(j order by (j->'next'->>'late')::boolean desc, j->'next'->>'due_at') from rows where j->'next'->>'who' = 'muse'), '[]'::jsonb),
    'waiting_on_colin', coalesce((select jsonb_agg(j order by j->'next'->>'due_at') from rows where j->'next'->>'who' = 'colin'), '[]'::jsonb),
    'waiting_on_the_seller', coalesce((select jsonb_agg(j order by j->'next'->>'due_at') from rows where j->'next'->>'who' = 'seller'), '[]'::jsonb),
    'with_a_caller', coalesce((select jsonb_agg(j) from rows where j->'next'->>'who' = 'caller'), '[]'::jsonb),
    'call_tasks_nobody_dialed', public.text_offer_calls_not_dialed(p_now),
    'rule', (select jsonb_build_object('offer', round(r.lao_pct * 100)::text || '% of the after-repair value minus repairs, to the nearest ' || public.text_money(r.round_to),
               'most', round(r.mao_pct * 100)::text || '% of the value minus repairs: a counter above it is not taken',
               'repair_items', r.items, 'repairs_by_the_square_foot', r.per_ft, 'sold_comps_needed', r.min_comps,
               'colin', 'Every figure is Colin''s to OK before it is texted. The door refuses any other dollar figure. Colin sends the written offer; you never do.')
               from public.text_offer_rules r where r.id = 1))
$$;

-- ------------------------------------------------------------------ Colin's side
create or replace function public.text_offers_for_colin() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_team() then raise exception 'only the team'; end if;
  return (
    select coalesce(jsonb_agg(x.j order by (x.j->'next'->>'who' = 'colin') desc, x.j->'next'->>'due_at'), '[]'::jsonb) from (
      select public.agent_offer_row(o) || jsonb_build_object(
               'comps', o.comps, 'ask_kind', o.ask_kind, 'ask_note', o.ask_note, 'rounds', o.rounds,
               'records', (select jsonb_build_object('tier', m.tier, 'why', m.family_list, 'equity', e.equity_grade, 'equity_line', e.equity_line)
                             from public.leads l left join public.lead_motivation m on m.lead_id = l.id left join public.equity_inputs e on e.lead_id = l.id
                            where l.id = o.lead_id)) as j
        from public.text_offers o where o.status = 'open') x);
end $$;

-- Colin's tap: OK the figure (his own if he types one), pass, or ask Muse something first.
create or replace function public.text_offer_decide(p_id uuid, p_say text, p_number numeric default null, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o public.text_offers; n numeric; note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if not (public.is_owner() and public.wpie_person() = 'colin') then raise exception 'only Colin says yes to a number'; end if;
  select * into o from public.text_offers where id = p_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such offer'); end if;
  if o.status <> 'open' then return jsonb_build_object('ok', false, 'reason', 'this offer is closed'); end if;
  if o.asked_at is null or (o.ok_at is not null and o.ok_at >= o.asked_at) then return jsonb_build_object('ok', false, 'reason', 'nothing is waiting for you on this offer'); end if;
  if p_say = 'ok' then
    n := coalesce(p_number, o.ask_number);
    if n is null or n <= 0 then return jsonb_build_object('ok', false, 'reason', 'the number is in dollars'); end if;
    update public.text_offers set ok_number = n, ok_at = now(), ok_numbers = array(select distinct unnest(ok_numbers || n)),
           colin_said = 'ok', colin_note = note, colin_at = now(), response = null, response_words = null, response_at = null, counter_number = null,
           late_posted = null, rounds = rounds || jsonb_build_object('at', now(), 'what', 'ok', 'asked', o.ask_number, 'number', n, 'note', note), updated_at = now()
     where id = p_id;
    update public.leads set notes = concat_ws(' | ', notes, to_char(now() at time zone 'America/Chicago', 'YYYY-MM-DD') || ' Colin OK''d ' || public.text_money(n)
           || ' as the number to text' || coalesce(' (' || note || ')', '')) where id = o.lead_id;
  elsif p_say = 'pass' then
    if note is null then return jsonb_build_object('ok', false, 'reason', 'say why you pass, in a few words: Muse closes with the seller from it'); end if;
    update public.text_offers set colin_said = 'pass', colin_note = note, colin_at = now(), late_posted = null,
           rounds = rounds || jsonb_build_object('at', now(), 'what', 'pass', 'note', note), updated_at = now() where id = p_id;
  elsif p_say = 'ask' then
    if note is null then return jsonb_build_object('ok', false, 'reason', 'type the question for Muse'); end if;
    update public.text_offers set colin_said = 'ask', colin_note = note, colin_at = now(), late_posted = null,
           rounds = rounds || jsonb_build_object('at', now(), 'what', 'colin_asked', 'note', note), updated_at = now() where id = p_id;
  else
    return jsonb_build_object('ok', false, 'reason', 'say is ok, pass or ask');
  end if;
  return jsonb_build_object('ok', true, 'say', p_say, 'number', n);
end $$;

-- What to push to Colin: a number waiting for his OK (once, and once more when it is late), and a yes waiting for the
-- written offer. Quiet hours are respected.
create or replace function public.text_offer_ping_claim(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public as $$
declare out jsonb := '[]'::jsonb; o public.text_offers; v jsonb; l public.leads;
begin
  if public.in_quiet_hours(p_now) then return out; end if;
  for o in select * from public.text_offers where status = 'open' order by asked_at nulls last for update skip locked loop
    v := public.text_offer_view(o, p_now);
    select * into l from public.leads where id = o.lead_id;
    if v->>'step' = 'colin' and o.colin_pinged_at is null then
      update public.text_offers set colin_pinged_at = p_now where id = o.id;
      out := out || jsonb_build_object('kind', 'ask', 'offer_id', o.id, 'lead_id', o.lead_id, 'address', l.property_address, 'owner_name', l.owner_name,
        'number', o.ask_number, 'ask_kind', o.ask_kind, 'note', o.ask_note, 'arv', o.arv, 'repairs', o.repairs, 'repairs_basis', o.repairs_basis,
        'most', o.mao, 'their_number', o.their_number, 'sold_comps', public.text_offer_comp_count(o.comps));
    elsif v->>'step' = 'colin' and (v->>'late')::boolean and o.colin_reminded_at is null then
      update public.text_offers set colin_reminded_at = p_now where id = o.id;
      out := out || jsonb_build_object('kind', 'reminder', 'offer_id', o.id, 'lead_id', o.lead_id, 'address', l.property_address, 'owner_name', l.owner_name, 'number', o.ask_number);
    elsif v->>'step' = 'written_offer' and o.written_pinged_at is null then
      update public.text_offers set written_pinged_at = p_now where id = o.id;
      out := out || jsonb_build_object('kind', 'written', 'offer_id', o.id, 'lead_id', o.lead_id, 'address', l.property_address, 'owner_name', l.owner_name,
        'number', o.accepted_number, 'signers', o.signers, 'seller_email', o.seller_email);
    end if;
  end loop;
  return out;
end $$;

-- ------------------------------------------------------------------ a seller who asks for a number opens one
create or replace function public.text_asks_for_number(p_body text) returns boolean
language sql immutable as $$
  select coalesce(p_body, '') ~* ('(what(''|’)?s|what is|whats)\s+(your|the|ur)\s+(best\s+|top\s+)?(offer|price|number|bid)'
    || '|make\s+(me\s+)?an?\s+offer|send\s+(me\s+)?(an?|your|the)\s+offer|give\s+me\s+(an?|your|the)\s+(offer|number|price)'
    || '|how\s+much\s+(would|will|can|could|are|do|did|r)\s+(you|u|ya)\M'
    || '|what\s+(would|will|can|could|are|do|r)\s+(you|u|ya)\s+(pay|offer|give|offering|paying|thinking)'
    || '|what\s+are\s+you\s+(offering|paying)|what\s+kind\s+of\s+(offer|price|number)|how\s+much\s+(for it|is your offer|you offering|you paying)')
$$;

create or replace function public.text_offer_from_inbound() returns trigger
language plpgsql security definer set search_path = public as $$
declare l public.leads; r public.text_offer_rules;
begin
  begin
    if new.lead_id is null or coalesce(new.is_opt_out, false) or new.received_at < now() - interval '2 days' then return new; end if;
    if not public.text_asks_for_number(new.body) then return new; end if;
    select * into l from public.leads where id = new.lead_id;
    if not found or l.stage::text in ('dnc', 'dead') then return new; end if;
    if exists (select 1 from public.text_offers o where o.lead_id = new.lead_id and o.status = 'open') then return new; end if;
    select * into r from public.text_offer_rules where id = 1;
    insert into public.text_offers (lead_id, opened_by, trigger, trigger_text, phone, comp_due_at)
    values (new.lead_id, 'system', 'asked_number', left(new.body, 600), new.from10, public.text_offer_due(new.received_at, r.comp_hours));
  exception when others then
    null;                                          -- an inbound text is never lost to this
  end;
  return new;
end $$;
drop trigger if exists text_offer_from_inbound on public.twilio_inbound;
create trigger text_offer_from_inbound after insert or update of lead_id on public.twilio_inbound
  for each row execute function public.text_offer_from_inbound();

-- ------------------------------------------------------------------ the gate on the agent door
-- A dollar figure in a text the agent writes must be one Colin OK'd for that card. Null when the text may go.
create or replace function public.text_offer_problem(p_lead_id uuid, p_body text) returns text
language plpgsql stable security definer set search_path = public as $$
declare amts numeric[]; o public.text_offers; bad numeric;
begin
  if not coalesce((select r.gate_on from public.text_offer_rules r where r.id = 1), true) then return null; end if;
  amts := public.text_amounts(p_body);
  if coalesce(array_length(amts, 1), 0) = 0 then return null; end if;
  select * into o from public.text_offers where lead_id = p_lead_id and status = 'open';
  if not found then
    return 'a dollar figure in a text needs Colin''s OK first (Colin 2026-11-13) and this card has no open offer: offer_open, then offer_worklist walks it to his OK';
  end if;
  select a into bad from unnest(amts) a where not (a = any (o.ok_numbers)) limit 1;
  if bad is not null then
    return case when coalesce(array_length(o.ok_numbers, 1), 0) = 0
      then 'Colin has not OK''d a number for this card yet (Colin 2026-11-13: check with me first): ' || coalesce((public.text_offer_view(o))->>'say', 'see offer_worklist')
      else public.text_money(bad) || ' is not a figure Colin OK''d for this card (he OK''d ' || (select string_agg(public.text_money(x), ', ') from unnest(o.ok_numbers) x)
           || '). A new figure goes to him first: record their counter with offer_update' end;
  end if;
  return null;
end $$;

-- text_rule_problem: from 0221_the_day_colins_words.sql, with the dollar-figure gate first
create or replace function public.text_rule_problem(p_lead_id uuid, p_body text, p_step integer, p_now timestamptz default now()) returns text
language plpgsql stable security definer set search_path = public as $$
declare
  voice text;
  other text;
  rb    text;
  op    text;
begin
  op := public.text_offer_problem(p_lead_id, p_body);
  if op is not null then return op; end if;
  if not coalesce((select cc.day_rules_on from public.campaign_control cc where cc.id = 1), true) then return null; end if;
  voice := public.card_voice(p_lead_id);
  select k.name into other from public.text_voices() k(name)
   where lower(k.name) <> lower(voice)
     and (coalesce(p_body, '') ~* ('(this is|this|my name is|it''s|its)\s+' || k.name || '\M')
          or coalesce(p_body, '') ~* ('\m' || k.name || '\s+(here|again)\M'))
   limit 1;
  if other is not null then
    return 'this person hears from ' || voice || ', not ' || other || ': one name per seller, across their cards and numbers (Colin 2026-11-10)';
  end if;
  if coalesce(p_step, 1) = 0 then return null; end if;
  -- the intro belongs on the first text to a person, and only there (Colin 2026-11-10)
  if coalesce(p_step, 1) = 1 and public.text_speaker(p_body) is null and not public.card_texted_before(p_lead_id) then
    return 'the first text to a person says who is writing: this card speaks as ' || voice;
  end if;
  if coalesce(p_step, 1) > 1 and position('STOP' in coalesce(p_body, '')) > 0 then
    return 'a follow-up carries no STOP line: only a first text to a number does (Colin 2026-11-10)';
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

-- ------------------------------------------------------------------ the report and the clock
create or replace function public.text_offer_report(p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public as $$
  with d as (select (p_now at time zone 'America/Chicago')::date as day),
  o as (select t.*, public.text_offer_view(t, p_now) as v from public.text_offers t where t.status = 'open')
  select jsonb_build_object(
    'day', (select day from d),
    'open', (select count(*) from o),
    'by_step', coalesce((select jsonb_object_agg(s, c) from (select v->>'step' s, count(*) c from o group by 1) x), '{}'::jsonb),
    'late', coalesce((select jsonb_agg(jsonb_build_object('address', l.property_address, 'step', o.v->>'step', 'who', o.v->>'who', 'due_at', o.v->>'due_at')
                        order by o.v->>'due_at') from o join public.leads l on l.id = o.lead_id where (o.v->>'late')::boolean), '[]'::jsonb),
    'opened_today', (select count(*) from public.text_offers t, d where (t.opened_at at time zone 'America/Chicago')::date = d.day),
    'numbers_okd_today', (select count(*) from public.text_offers t, d where (t.ok_at at time zone 'America/Chicago')::date = d.day),
    'accepted_today', (select count(*) from public.text_offers t, d where (t.accepted_at at time zone 'America/Chicago')::date = d.day),
    'closed_today', coalesce((select jsonb_object_agg(w, c) from (select t.closed_why w, count(*) c from public.text_offers t, d
                       where t.status = 'closed' and (t.closed_at at time zone 'America/Chicago')::date = d.day group by 1) x), '{}'::jsonb),
    'call_tasks_nobody_dialed', jsonb_array_length(public.text_offer_calls_not_dialed(p_now)))
$$;

-- The clock (pg_cron, every 15 minutes): close what the card closed, keep the numbers and the ask current, tell Muse
-- on the desk when a step of hers is late (once per step), and post the evening report (once a day, when there is one).
create or replace function public.text_offer_tick(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  o public.text_offers; v jsonb; l public.leads; loc timestamp := p_now at time zone 'America/Chicago';
  closed integer := 0; told integer := 0; rep jsonb; key text; body text; reported boolean := false;
begin
  for o in select * from public.text_offers where status = 'open' loop
    select * into l from public.leads where id = o.lead_id;
    if l.stage::text = 'dnc' then perform public.text_offer_close(o.id, 'dnc', 'the card went do-not-contact', 'system'); closed := closed + 1; continue; end if;
    if l.stage::text = 'dead' then perform public.text_offer_close(o.id, 'card_dead', coalesce(l.dead_reason::text, 'the card was closed'), 'system'); closed := closed + 1; continue; end if;
    if o.accepted_at is not null and exists (select 1 from public.contracts c where c.lead_id = o.lead_id and c.status = 'signed' and c.created_at >= o.accepted_at) then
      perform public.text_offer_close(o.id, 'under_contract', 'signed', 'system'); closed := closed + 1; continue;
    end if;
    perform public.text_offer_refresh(o.id, p_now);
  end loop;

  if extract(isodow from loc) <> 7 and loc::time >= time '09:00' and loc::time < time '19:00' then
    for o in select * from public.text_offers where status = 'open' loop
      v := public.text_offer_view(o, p_now);
      key := (v->>'step') || ':' || coalesce(v->>'due_at', '');
      if (v->>'late')::boolean and v->>'who' = 'muse' and o.late_posted is distinct from key then
        select * into l from public.leads where id = o.lead_id;
        perform public.desk_post('desk', 'muse', 'note', 'OFFER STEP LATE: ' || coalesce(l.property_address, 'a card') || ' (' || (v->>'step') || ')',
          'This offer''s next step is yours and its time has passed.' || E'\n\n' || 'Card: ' || coalesce(l.owner_name, '') || ', ' || coalesce(l.property_address, '') || ' (lead ' || o.lead_id::text || ')'
          || E'\n' || 'Step: ' || (v->>'step') || ', due ' || to_char((v->>'due_at')::timestamptz at time zone 'America/Chicago', 'Dy Mon DD HH12:MI AM') || ' Central'
          || E'\n' || 'Do: ' || (v->>'say') || E'\n\n' || 'offer_worklist has every open offer with its one next step.');
        update public.text_offers set late_posted = key where id = o.id;
        told := told + 1;
      end if;
    end loop;
  end if;

  if loc::time >= time '19:00' and extract(isodow from loc) <> 7
     and (select r.report_day from public.text_offer_rules r where r.id = 1) is distinct from loc::date then
    update public.text_offer_rules set report_day = loc::date where id = 1;
    rep := public.text_offer_report(p_now);
    if (rep->>'open')::int > 0 or (rep->>'opened_today')::int > 0 or rep->'closed_today' <> '{}'::jsonb then
      body := 'Offers by text, ' || to_char(loc, 'Dy Mon DD') || E'\n'
        || 'Open: ' || (rep->>'open') || '. Opened today: ' || (rep->>'opened_today') || '. Numbers Colin OK''d today: ' || (rep->>'numbers_okd_today')
        || '. Sellers who said yes today: ' || (rep->>'accepted_today') || '.' || E'\n'
        || 'Where the open ones stand: ' || coalesce((select string_agg(k || ' ' || val, ', ') from jsonb_each_text(rep->'by_step') e(k, val)), 'none') || E'\n'
        || 'Closed today: ' || coalesce((select string_agg(k || ' ' || val, ', ') from jsonb_each_text(rep->'closed_today') e(k, val)), 'none') || E'\n'
        || 'Late right now: ' || coalesce((select string_agg((x->>'address') || ' (' || (x->>'step') || ', ' || (x->>'who') || ')', '; ') from jsonb_array_elements(rep->'late') x), 'nothing') || E'\n'
        || 'Call tasks past their time that nobody dialed, on cards where the seller wrote back: ' || (rep->>'call_tasks_nobody_dialed') || '.';
      perform public.desk_post('desk', 'all', 'report', 'Offers by text: ' || to_char(loc, 'Mon DD'), body);
      reported := true;
    end if;
  end if;
  return jsonb_build_object('closed', closed, 'told_muse', told, 'reported', reported);
end $$;

revoke all on function public.text_offer_numbers(numeric, integer, text[], text), public.text_offer_record_stop(uuid, date),
  public.text_offer_view(public.text_offers, timestamptz), public.text_offer_refresh(uuid, timestamptz),
  public.agent_offer_row(public.text_offers, timestamptz), public.agent_offer_open(uuid, text, text, text, text),
  public.agent_offer_update(jsonb, text), public.text_offer_close(uuid, text, text, text), public.agent_offer_close(uuid, text, text, text),
  public.text_offer_calls_not_dialed(timestamptz), public.agent_offer_worklist(timestamptz), public.text_offer_ping_claim(timestamptz),
  public.text_offer_problem(uuid, text), public.text_offer_report(timestamptz), public.text_offer_tick(timestamptz)
  from public, anon, authenticated;
grant execute on function public.text_offer_numbers(numeric, integer, text[], text), public.text_offer_record_stop(uuid, date),
  public.text_offer_view(public.text_offers, timestamptz), public.text_offer_refresh(uuid, timestamptz),
  public.agent_offer_row(public.text_offers, timestamptz), public.agent_offer_open(uuid, text, text, text, text),
  public.agent_offer_update(jsonb, text), public.text_offer_close(uuid, text, text, text), public.agent_offer_close(uuid, text, text, text),
  public.text_offer_calls_not_dialed(timestamptz), public.agent_offer_worklist(timestamptz), public.text_offer_ping_claim(timestamptz),
  public.text_offer_problem(uuid, text), public.text_offer_report(timestamptz), public.text_offer_tick(timestamptz)
  to service_role;
revoke all on function public.text_offers_for_colin(), public.text_offer_decide(uuid, text, numeric, text) from public, anon;
grant execute on function public.text_offers_for_colin(), public.text_offer_decide(uuid, text, numeric, text) to authenticated, service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if exists (select 1 from cron.job where jobname = 'wpie-offers') then
      perform cron.unschedule('wpie-offers');
    end if;
    perform cron.schedule('wpie-offers', '9,24,39,54 * * * *', 'select public.text_offer_tick()');
  end if;
end $$;
