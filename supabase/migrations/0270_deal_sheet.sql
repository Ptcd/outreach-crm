-- 0270: the deal sheet. Colin 2026-11-21: "how can this be designed so thalia and Tyler, people from overseas with
-- no knowledge of our local market, can capture insane value on properties without becoming specialists", and, on
-- how he signed 991 Howard St at $60,000 against a rule figure of $110,000: the sellers had a realtor's $300,000 in
-- their heads, he said what it sells for finished, asked what was owed, added what the records showed, told them he
-- saw no world where they made money selling it, and offered to take it off their hands.
--
-- One sheet a card, worked by the server, the only place a caller's number comes from:
--
--   the seller's math   what it sells for finished - what it needs - what selling it costs - what is owed
--                       = what they would walk away with selling it the usual way
--   the kind of seller  nothing_left (the price cannot reach them) | some_left | a_lot, from that last line
--   the number to say   nothing_left: what clears the debts that follow the house, plus walking money
--                       some_left:    a share of their real take-home, never over the rule's opening
--                       a_lot:        none, unless their own floor is under the rule's opening
--                       always capped by the ceiling (the rule's most); Colin's own number overrides all of it
--   the steps up        two, to a caller's limit part way to the ceiling; past that it is Colin's
--   the gate            a manufactured home, no street picture or an old one, comps far apart, a value far from the
--                       county's, too few comps, a gap too thin: no formula number, Colin prices it
--
-- Values come from Muse (text_offers: arv, comps, street, call_prices, and now property_kind), debts from the call
-- brief (call_briefs.to_clear, owed_total) and from what the seller says on the call (deal_sheets.facts). The server
-- adds nothing of its own but arithmetic. Design: WPIE docs/CALLER_VALUE_SYSTEM.md.
--
-- It ships switched to 'owner': only Colin sees it. deal_sheet_mode('on') shows it to callers, makes it the number
-- line on the yes task, and lets Send offer go out at a number the seller said yes to on the sheet.

alter table public.text_offers add column if not exists property_kind text;

create table if not exists public.deal_sheet_rules (
  id             integer primary key default 1 check (id = 1),
  mode           text not null default 'owner' check (mode in ('off', 'owner', 'on')),
  agent_pct      numeric not null default 0.06,     -- what selling the usual way costs: an agent
  closing_pct    numeric not null default 0.02,     -- closing costs
  hold_months    integer not null default 4,        -- the months it sits
  hold_pct_month numeric not null default 0.005,    -- taxes, insurance and upkeep a month, as a share of the value
  walk_money     numeric not null default 5000,     -- what a seller capped by debt is left with
  net_share      numeric not null default 0.80,     -- the share of their real take-home we open at
  min_number     numeric not null default 15000,
  min_gap        numeric not null default 30000,    -- smallest room under the ceiling worth a contract
  caller_share   numeric not null default 0.5,      -- how far from the number to the ceiling a caller may go
  round_to       numeric not null default 500,
  county_hi      numeric not null default 1.4,      -- Muse's value against the county's: outside this band is Colin's
  county_lo      numeric not null default 0.7,
  comp_spread    numeric not null default 2.0,      -- dearest comp over cheapest
  picture_years  integer not null default 3,
  updated_at     timestamptz not null default now(),
  updated_by     text not null default 'desk'
);
insert into public.deal_sheet_rules (id) values (1) on conflict (id) do nothing;
alter table public.deal_sheet_rules enable row level security;
grant select on public.deal_sheet_rules to authenticated, service_role;
drop policy if exists deal_sheet_rules_owner_read on public.deal_sheet_rules;
create policy deal_sheet_rules_owner_read on public.deal_sheet_rules for select to authenticated using (public.is_owner());

create table if not exists public.deal_sheets (
  lead_id      uuid primary key references public.leads (id) on delete cascade,
  facts        jsonb not null default '{}'::jsonb,   -- what the seller said on the call, by key
  inside       integer,                              -- which of Muse's rows fits what they said about the inside
  colin_open   numeric,                              -- Colin's own number: the only one shown when set
  colin_top    numeric,
  colin_note   text,
  colin_pass   boolean not null default false,
  colin_at     timestamptz,
  asked_at     timestamptz,                          -- a caller tapped "ask Colin"
  asked_words  text,
  said         jsonb not null default '[]'::jsonb,   -- each number said and what came back
  updated_at   timestamptz not null default now()
);
-- no login reads the table: a caller gets their own card's sheet through deal_sheet_get, which checks the card is theirs
alter table public.deal_sheets enable row level security;
revoke all on public.deal_sheets from public, anon, authenticated;
grant select, insert, update on public.deal_sheets to service_role;

create or replace function public.deal_round(p numeric, p_to numeric, p_up boolean default false) returns numeric
language sql immutable as $$
  select case when p is null then null when coalesce(p_to, 0) <= 0 then round(p)
              when p_up then ceil(p / p_to) * p_to else floor(p / p_to) * p_to end
$$;

-- ---------------------------------------------------------------- the whole sheet, worked
create or replace function public.deal_sheet_work(p_lead_id uuid, p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  r public.deal_sheet_rules; tr public.text_offer_rules; l public.leads; o public.text_offers; b public.call_briefs; e public.equity_inputs;
  s public.deal_sheets; f jsonb; x jsonb; row_ jsonb; idx integer; i integer := 0;
  v_val numeric; needs numeric; needs_label text; needs_assumed boolean := false; costs numeric; clear numeric; other numeric := 0; owed_known boolean;
  usual numeric; v_cap numeric; opening numeric; num numeric; lim numeric; kind text; stage text; src text := 'math'; why text;
  gate text[] := '{}'; missing jsonb := '[]'::jsonb; v_comps jsonb := '[]'::jsonb; rows_ jsonb := '[]'::jsonb; steps jsonb := '[]'::jsonb;
  n_comps integer := 0; lo numeric; hi numeric; pkind text; yr integer; county numeric; their numeric; floor_ numeric; owed_said numeric;
  open_owed jsonb := '[]'::jsonb; allowed numeric[] := '{}'; blob text;
begin
  select * into r from public.deal_sheet_rules where id = 1;
  select * into tr from public.text_offer_rules where id = 1;
  select * into l from public.leads where id = p_lead_id;
  if not found then return null; end if;
  select * into o from public.text_offers t where t.lead_id = p_lead_id order by (t.arv is not null) desc, (t.status = 'open') desc, t.opened_at desc limit 1;
  select * into b from public.call_briefs cb where cb.lead_id = p_lead_id;
  select * into e from public.equity_inputs ei where ei.lead_id = p_lead_id limit 1;
  select * into s from public.deal_sheets ds where ds.lead_id = p_lead_id;
  f := coalesce(s.facts, '{}'::jsonb);

  -- what the seller has told us: the sheet's own taps first, then the call script's answers, then the offer row
  their := coalesce(public.text_offer_num(f->'their_number'), public.text_offer_num(l.call_facts->'price'->'value'->'number'), o.their_number);
  floor_ := public.text_offer_num(f->'floor');
  owed_said := coalesce(public.text_offer_num(f->'owed_said'), public.text_offer_num(l.call_facts->'debt'->'value'->'number'));

  -- the value and the comps a caller can name
  v_val := o.arv;
  if jsonb_typeof(o.comps) = 'array' then
    select count(*), min(public.text_offer_num(c->'sold_price')), max(public.text_offer_num(c->'sold_price'))
      into n_comps, lo, hi from jsonb_array_elements(o.comps) c
     where public.text_offer_num(c->'sold_price') > 0 and coalesce(c->>'note', '') !~* '(not blended|as-is market read only)';
    select coalesce(jsonb_agg(jsonb_build_object('address', q.c->>'address', 'sold_price', public.text_offer_num(q.c->'sold_price'),
             'sold_date', q.c->>'sold_date', 'sqft', q.c->'sqft') order by q.d), '[]'::jsonb) into v_comps
      from (select c, abs(public.text_offer_num(c->'sold_price') - coalesce(v_val, 0)) as d from jsonb_array_elements(o.comps) c
             where public.text_offer_num(c->'sold_price') > 0 and coalesce(c->>'address', '') <> ''
               and coalesce(c->>'note', '') !~* '(not blended|as-is market read only)'
             order by 2 limit 3) q;
  end if;

  -- what it needs: the row of Muse's that fits what the seller said about the inside; the heaviest until they say
  if jsonb_typeof(o.call_prices) = 'array' then
    for x in select c from jsonb_array_elements(o.call_prices) c loop
      rows_ := rows_ || jsonb_build_object('i', i, 'inside', x->>'inside', 'repairs', public.text_offer_num(x->'repairs'),
                                           'basis', x->>'repairs_basis', 'no_offer', coalesce((x->>'no_offer')::boolean, false));
      i := i + 1;
    end loop;
    idx := s.inside;
    if idx is null or idx < 0 or idx >= jsonb_array_length(rows_) then
      needs_assumed := true;
      select (q->>'i')::int into idx from jsonb_array_elements(rows_) q order by (q->>'no_offer')::boolean, (q->>'repairs')::numeric desc limit 1;
    end if;
    row_ := rows_->idx;
    needs := (row_->>'repairs')::numeric; needs_label := row_->>'inside';
  end if;

  -- what is owed: what the brief says must be paid at closing, or what the seller said, whichever is more
  if b.lead_id is not null and jsonb_typeof(b.owed) = 'array' then
    select coalesce(jsonb_agg(jsonb_build_object('kind', q->>'kind', 'creditor', q->>'creditor', 'basis', q->>'basis')), '[]'::jsonb) into open_owed
      from jsonb_array_elements(b.owed) q where public.text_offer_num(q->'amount') is null and coalesce(q->>'follows_house', 'unknown') <> 'no';
    other := greatest(coalesce(b.owed_total, 0) - coalesce(b.to_clear, 0), 0);
  end if;
  clear := greatest(coalesce(b.to_clear, 0), coalesce(owed_said, 0));
  owed_known := coalesce((f->>'owed_nothing')::boolean, false) or owed_said is not null
                or (coalesce(b.status, '') = 'ready' and jsonb_array_length(open_owed) = 0);

  -- the gate: no formula number for anything the formula does not fit
  blob := lower(coalesce(o.arv_basis, '') || ' ' || coalesce(o.street->>'notes', '') || ' ' || coalesce(o.street->>'why', ''));
  pkind := coalesce(f->>'property_kind', o.property_kind,
             case when blob ~ '(manufactured|modular|mobile home|double-?wide|single-?wide)' and blob !~ 'not (a )?(manufactured|modular|mobile)' then 'manufactured' end,
             case when coalesce(e.units, l.units, 1) > 4 then 'multi' end, 'site_built');
  if pkind <> 'site_built' then
    gate := gate || ('it is ' || case pkind when 'manufactured' then 'a manufactured home' when 'multi' then 'more than four units'
                                           when 'land' then 'land' when 'condo' then 'a condo' else 'not an ordinary house' end);
  end if;
  if v_val is not null then
    if n_comps < tr.min_comps then gate := gate || ('only ' || n_comps::text || ' sold comps'); end if;
    if lo > 0 and hi / lo > r.comp_spread then gate := gate || ('the comps run from ' || public.text_money(lo) || ' to ' || public.text_money(hi)); end if;
    county := coalesce(nullif(e.est_market_value, 0), nullif(e.value_used, 0), nullif(e.assessed_total, 0));
    if county > 0 and (v_val / county > r.county_hi or v_val / county < r.county_lo) then
      gate := gate || ('Muse has it at ' || public.text_money(v_val) || ' and the county at ' || public.text_money(county));
    end if;
    if coalesce((o.street->>'no_view')::boolean, false) then
      gate := gate || 'there is no street picture of it'::text;
    elsif o.street is not null then
      yr := nullif(substring(coalesce(o.street->>'image_date', '') from '(20[0-9]{2})'), '')::integer;
      if yr is not null and extract(year from p_now)::integer - yr > r.picture_years then gate := gate || ('the street picture is from ' || yr::text); end if;
    end if;
  end if;

  -- the seller's math and our ceiling
  if v_val is not null and needs is not null then
    costs := round(v_val * (r.agent_pct + r.closing_pct + r.hold_pct_month * r.hold_months));
    usual := v_val - needs - costs - clear - other;
    v_cap := public.deal_round(v_val * tr.mao_pct - needs, r.round_to);
    opening := public.deal_round(v_val * tr.lao_pct - needs, r.round_to);
  end if;

  -- the number, and where the card stands
  if coalesce(s.colin_pass, false) then
    stage := 'passed'; why := coalesce(nullif(btrim(s.colin_note), ''), 'Colin passed on this one');
  elsif s.colin_open is not null then
    stage := 'ready'; src := 'colin'; num := s.colin_open; lim := greatest(coalesce(s.colin_top, s.colin_open), s.colin_open);
    why := nullif(btrim(s.colin_note), '');
  elsif v_val is null or needs is null then
    stage := 'needs_value';
    missing := missing || jsonb_build_object('what', case when v_val is null then 'what it sells for finished, with the sold houses behind it'
                                                          else 'what it needs, by the shape of the inside' end, 'who', 'muse');
  elsif coalesce(array_length(gate, 1), 0) > 0 then
    stage := 'colin_prices'; why := 'No formula number: ' || array_to_string(gate, '; ') || '.';
    missing := missing || jsonb_build_object('what', 'a number for this one', 'who', 'colin');
  elsif v_cap <= 0 then
    stage := 'no_fit'; why := 'What it needs is more than the rule can pay for it.';
  elsif not owed_known then
    stage := 'needs_owed';
    missing := missing || jsonb_build_object('what', 'what is owed: ask them on the call, then tap the answer', 'who', 'caller');
  else
    kind := case when usual <= r.walk_money then 'nothing_left' when usual <= v_cap then 'some_left' else 'a_lot' end;
    if kind = 'nothing_left' then
      num := greatest(public.deal_round(clear + r.walk_money, r.round_to, true), r.min_number);
    elsif kind = 'some_left' then
      num := greatest(least(public.deal_round(usual * r.net_share, r.round_to), opening), r.min_number);
    elsif floor_ is not null and floor_ <= opening then
      num := floor_; src := 'their_floor';
    end if;
    if num is not null and kind <> 'nothing_left' and floor_ is not null and floor_ < num then num := floor_; src := 'their_floor'; end if;
    if num is null then
      stage := 'no_number';
      why := 'Selling it the usual way leaves them more than we can pay. Ask the number they would not go under; if it is far under, the card will take it.';
    elsif num > v_cap then
      stage := 'no_fit'; why := 'What has to be cleared (' || public.text_money(clear) || ') is more than the most we can pay.';
      missing := missing || jsonb_build_object('what', 'whether there is another way to do this one', 'who', 'colin');
      num := null;
    elsif v_cap - num < r.min_gap then
      stage := 'colin_prices'; why := 'Thin: the number would be only ' || public.text_money(v_cap - num) || ' under the most we can pay.';
      missing := missing || jsonb_build_object('what', 'a number for this one', 'who', 'colin');
      num := null;
    else
      stage := 'ready'; lim := public.deal_round(num + (v_cap - num) * r.caller_share, r.round_to);
    end if;
  end if;

  if num is not null then
    allowed := array[num];
    if lim is not null and lim > num then
      allowed := allowed || public.deal_round(num + (lim - num) / 2, r.round_to) || lim;
      allowed := array(select distinct a from unnest(allowed) a order by a);
    end if;
    select jsonb_agg(a order by a) into steps from unnest(allowed) a;
  end if;

  return jsonb_build_object(
    'lead_id', p_lead_id, 'mode', r.mode, 'stage', stage, 'kind', kind, 'why', why, 'source', src, 'missing', missing,
    'property_kind', pkind, 'gate', to_jsonb(gate),
    'math', jsonb_build_object('finished', v_val, 'needs', needs, 'needs_for', needs_label, 'needs_assumed', needs_assumed, 'selling_costs', costs,
              'to_clear', clear, 'other_owed', other, 'walk_away', usual, 'owed_known', owed_known, 'open_owed', open_owed,
              'cost_words', round(r.agent_pct * 100)::text || '% to an agent, ' || round(r.closing_pct * 100)::text || '% closing, '
                            || r.hold_months::text || ' months of taxes and upkeep'),
    'rows', rows_, 'inside', idx, 'comps', v_comps, 'sold_comps', n_comps,
    'street', o.street, 'owed', coalesce(b.owed, '[]'::jsonb), 'brief_ready', coalesce(b.status = 'ready', false),
    'number', num, 'steps', coalesce(steps, '[]'::jsonb), 'limit', lim)
    || jsonb_build_object(
    'ceiling', v_cap, 'rule_opening', opening, 'gap', case when num is not null and v_cap is not null then v_cap - num end,
    'theirs', jsonb_build_object('number', their, 'floor', floor_, 'owed_said', owed_said),
    'facts', f, 'said', coalesce(s.said, '[]'::jsonb),
    'colin', jsonb_build_object('open', s.colin_open, 'top', s.colin_top, 'note', s.colin_note, 'pass', coalesce(s.colin_pass, false), 'at', s.colin_at,
               'asked_at', s.asked_at, 'asked_words', s.asked_words),
    'owner_name', l.owner_name, 'address', l.property_address, 'caller', public.card_caller(p_lead_id)::text);
end $$;
revoke all on function public.deal_sheet_work(uuid, timestamptz) from public, anon, authenticated;
grant execute on function public.deal_sheet_work(uuid, timestamptz) to service_role;

-- ---------------------------------------------------------------- what a login gets
-- Colin: all of it. A caller: their own card only, when the sheet is on, and without our ceiling, the rule's opening
-- or the room under it (the card says one number at a time; the limit is the furthest step).
create or replace function public.deal_sheet_get(p_lead_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare w jsonb; m text;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  perform public.card_guard(p_lead_id);
  select mode into m from public.deal_sheet_rules where id = 1;
  if m = 'off' or (m = 'owner' and not public.is_owner()) then return null; end if;
  w := public.deal_sheet_work(p_lead_id);
  if w is null then return null; end if;
  if public.is_owner() then return w || jsonb_build_object('owner', true); end if;
  return (w - 'ceiling' - 'rule_opening' - 'gap' - 'gate') || jsonb_build_object('owner', false);
end $$;
revoke all on function public.deal_sheet_get(uuid) from public, anon;
grant execute on function public.deal_sheet_get(uuid) to authenticated, service_role;

create or replace function public.deal_sheet_touch(p_lead_id uuid) returns void
language sql security definer set search_path = public as $$
  insert into public.deal_sheets (lead_id) values (p_lead_id) on conflict (lead_id) do update set updated_at = now()
$$;
revoke all on function public.deal_sheet_touch(uuid) from public, anon, authenticated;

-- what the seller said, one tap at a time
create or replace function public.deal_sheet_fact(p_lead_id uuid, p_key text, p_value jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare keys text[] := array['their_number', 'their_source', 'decides', 'fixed_value_said', 'needs_said', 'walk_away_said', 'owed_said', 'owed_nothing', 'floor', 'property_kind'];
begin
  if not public.is_team() then raise exception 'team only'; end if;
  perform public.card_guard(p_lead_id);
  if not (p_key = any(keys)) then return jsonb_build_object('ok', false, 'reason', 'not a line on the sheet: ' || coalesce(p_key, '')); end if;
  if p_key = 'property_kind' and not public.is_owner() then
    return jsonb_build_object('ok', false, 'reason', 'what kind of building it is comes from the records or from Colin');
  end if;
  perform public.deal_sheet_touch(p_lead_id);
  update public.deal_sheets set facts = case when p_value is null or jsonb_typeof(p_value) = 'null' then facts - p_key
                                              else facts || jsonb_build_object(p_key, p_value) end, updated_at = now()
   where lead_id = p_lead_id;
  return jsonb_build_object('ok', true, 'sheet', public.deal_sheet_get(p_lead_id));
end $$;

-- which of Muse's rows fits what they said about the inside
create or replace function public.deal_sheet_inside(p_lead_id uuid, p_row integer) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_team() then raise exception 'team only'; end if;
  perform public.card_guard(p_lead_id);
  perform public.deal_sheet_touch(p_lead_id);
  update public.deal_sheets set inside = p_row, updated_at = now() where lead_id = p_lead_id;
  return jsonb_build_object('ok', true, 'sheet', public.deal_sheet_get(p_lead_id));
end $$;

-- a number was said, and what came back. A caller may only have said a number the sheet showed.
create or replace function public.deal_sheet_said(p_lead_id uuid, p_number numeric, p_response text, p_words text default null, p_counter numeric default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w jsonb; me text := public.wpie_person()::text; ok_ boolean;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  perform public.card_guard(p_lead_id);
  if p_response not in ('yes', 'counter', 'no', 'think', 'spouse', 'other_offer') then
    return jsonb_build_object('ok', false, 'reason', 'what came back is yes, counter, no, think, spouse or other_offer');
  end if;
  w := public.deal_sheet_work(p_lead_id);
  select coalesce(bool_or((a #>> '{}')::numeric = p_number), false) into ok_ from jsonb_array_elements(w->'steps') a;
  if not ok_ and not public.is_owner() then
    return jsonb_build_object('ok', false, 'reason', public.text_money(p_number) || ' is not a number this card shows. Say only the number on the sheet; anything else is Colin''s.');
  end if;
  perform public.deal_sheet_touch(p_lead_id);
  update public.deal_sheets set said = said || jsonb_build_object('at', now(), 'by', me, 'number', p_number, 'response', p_response,
           'words', nullif(btrim(coalesce(p_words, '')), ''), 'counter', p_counter), updated_at = now()
   where lead_id = p_lead_id;
  insert into public.messages (lead_id, direction, channel, body, status, created_by, sent_at)
  values (p_lead_id, 'out', 'note', 'Deal sheet: ' || initcap(coalesce(me, 'team')) || ' said ' || public.text_money(p_number) || '. They said: '
          || case p_response when 'yes' then 'yes' when 'counter' then 'they need ' || coalesce(public.text_money(p_counter), 'more') when 'no' then 'no'
                             when 'think' then 'they need to think' when 'spouse' then 'they have to ask someone' else 'someone offered more' end
          || coalesce('. "' || left(nullif(btrim(p_words), ''), 300) || '"', '') || '.', null, auth.uid(), now());
  return jsonb_build_object('ok', true, 'sheet', public.deal_sheet_get(p_lead_id));
end $$;

-- past the caller's limit, or a card with no number: one tap puts it in front of Colin
create or replace function public.deal_sheet_ask_colin(p_lead_id uuid, p_words text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me public.team_person := public.wpie_person(); l public.leads; t public.tasks;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  perform public.card_guard(p_lead_id);
  if nullif(btrim(coalesce(p_words, '')), '') is null then return jsonb_build_object('ok', false, 'reason', 'say what they said and what you need'); end if;
  select * into l from public.leads where id = p_lead_id;
  perform public.deal_sheet_touch(p_lead_id);
  update public.deal_sheets set asked_at = now(), asked_words = btrim(p_words), updated_at = now() where lead_id = p_lead_id;
  insert into public.tasks (lead_id, due_at, kind, owner, note, created_by, source, title)
  values (p_lead_id, now(), 'nudge', 'colin', 'Deal sheet, ' || coalesce(l.property_address, 'a card') || ': ' || btrim(p_words), auth.uid(), 'nudge',
          'Number wanted by ' || initcap(coalesce(me::text, 'a caller')))
  returning * into t;
  insert into public.messages (lead_id, direction, channel, body, status, created_by, sent_at)
  values (p_lead_id, 'out', 'note', 'Deal sheet: ' || initcap(coalesce(me::text, 'team')) || ' asked Colin for a number: ' || btrim(p_words), null, auth.uid(), now());
  return jsonb_build_object('ok', true, 'task_id', t.id, 'sheet', public.deal_sheet_get(p_lead_id));
end $$;

-- Colin's own number: the only one the card then shows. Or a pass. The card's caller is told at once.
create or replace function public.deal_sheet_colin(p_lead_id uuid, p_open numeric, p_top numeric default null, p_note text default null, p_pass boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare cc public.team_person := public.card_caller(p_lead_id); l public.leads;
begin
  if not public.is_owner() then raise exception 'only Colin puts a number on a card'; end if;
  perform public.card_guard(p_lead_id);
  select * into l from public.leads where id = p_lead_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card'); end if;
  if not coalesce(p_pass, false) and p_open is not null and p_open <= 0 then return jsonb_build_object('ok', false, 'reason', 'a number in dollars'); end if;
  if p_top is not null and p_open is not null and p_top < p_open then return jsonb_build_object('ok', false, 'reason', 'the top is at or above the opening'); end if;
  perform public.deal_sheet_touch(p_lead_id);
  update public.deal_sheets set colin_open = case when coalesce(p_pass, false) then null else p_open end,
         colin_top = case when coalesce(p_pass, false) then null else p_top end, colin_note = nullif(btrim(coalesce(p_note, '')), ''),
         colin_pass = coalesce(p_pass, false), colin_at = now(), asked_at = null, updated_at = now()
   where lead_id = p_lead_id;
  if cc is not null and cc::text <> 'colin' and (p_open is not null or coalesce(p_pass, false)) then
    insert into public.tasks (lead_id, due_at, kind, owner, note, created_by, source, title)
    values (p_lead_id, now(), 'nudge', cc,
            case when coalesce(p_pass, false) then 'Colin passed on ' || coalesce(l.property_address, 'this card') || coalesce(': ' || nullif(btrim(p_note), ''), '') || '. Close it kindly.'
                 else 'Colin''s number is on the card for ' || coalesce(l.property_address, 'this card') || '. Open the Deal sheet before you call.' end,
            auth.uid(), 'nudge', 'Heads-up from Colin');
  end if;
  return jsonb_build_object('ok', true, 'sheet', public.deal_sheet_get(p_lead_id));
end $$;

create or replace function public.deal_sheet_mode(p_mode text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not (public.is_owner() or (auth.uid() is null and not public.is_team())) then raise exception 'only Colin switches the deal sheet'; end if;
  if p_mode not in ('off', 'owner', 'on') then return jsonb_build_object('ok', false, 'reason', 'off, owner or on'); end if;
  update public.deal_sheet_rules set mode = p_mode, updated_at = now(), updated_by = coalesce(public.wpie_person()::text, 'desk') where id = 1;
  perform public.yes_sheet_to_task(t.lead_id) from public.text_offers t where t.status = 'open' and t.trigger = 'yes_to_selling';
  return jsonb_build_object('ok', true, 'mode', p_mode);
end $$;

-- Colin's settings: any of the rule's figures
create or replace function public.deal_sheet_rules_set(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare k text; nums text[] := array['agent_pct', 'closing_pct', 'hold_pct_month', 'walk_money', 'net_share', 'min_number', 'min_gap', 'caller_share', 'round_to', 'county_hi', 'county_lo', 'comp_spread'];
begin
  if not (public.is_owner() or (auth.uid() is null and not public.is_team())) then raise exception 'only Colin changes the deal sheet''s figures'; end if;
  for k in select jsonb_object_keys(p) loop
    if k = any(nums) then execute format('update public.deal_sheet_rules set %I = $1, updated_at = now() where id = 1', k) using (p->>k)::numeric;
    elsif k in ('hold_months', 'picture_years') then execute format('update public.deal_sheet_rules set %I = $1, updated_at = now() where id = 1', k) using (p->>k)::integer;
    else return jsonb_build_object('ok', false, 'reason', 'not a setting: ' || k); end if;
  end loop;
  return jsonb_build_object('ok', true, 'rules', (select to_jsonb(x) from public.deal_sheet_rules x where id = 1));
end $$;

revoke all on function public.deal_sheet_fact(uuid, text, jsonb), public.deal_sheet_inside(uuid, integer), public.deal_sheet_said(uuid, numeric, text, text, numeric),
  public.deal_sheet_ask_colin(uuid, text), public.deal_sheet_colin(uuid, numeric, numeric, text, boolean), public.deal_sheet_mode(text), public.deal_sheet_rules_set(jsonb) from public, anon;
grant execute on function public.deal_sheet_fact(uuid, text, jsonb), public.deal_sheet_inside(uuid, integer), public.deal_sheet_said(uuid, numeric, text, text, numeric),
  public.deal_sheet_ask_colin(uuid, text), public.deal_sheet_colin(uuid, numeric, numeric, text, boolean), public.deal_sheet_mode(text), public.deal_sheet_rules_set(jsonb) to authenticated, service_role;

-- ---------------------------------------------------------------- Muse says what kind of building it is (offer_update)
CREATE OR REPLACE FUNCTION public.agent_offer_update(p jsonb, p_agent text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  -- 0270: what kind of building it is; anything but a site-built house goes to Colin for a number
  if p ? 'property_kind' then
    txt := nullif(lower(btrim(coalesce(p->>'property_kind', ''))), '');
    if txt is not null and txt not in ('site_built', 'manufactured', 'condo', 'multi', 'land', 'other') then
      return jsonb_build_object('ok', false, 'reason', 'property_kind is site_built, manufactured (a mobile, modular or double-wide home), condo, multi (five or more units), land or other');
    end if;
    o.property_kind := txt;
  end if;
  if p ? 'sqft' then o.sqft := nullif(regexp_replace(coalesce(p->>'sqft', ''), '[^0-9]', '', 'g'), '')::integer; end if;
  if p ? 'arv' then
    c := nullif(regexp_replace(coalesce(p->>'arv', ''), '[^0-9.]', '', 'g'), '')::numeric;
    if c is null or c <= 0 then return jsonb_build_object('ok', false, 'reason', 'arv is the after-repair value in dollars'); end if;
    if coalesce(btrim(coalesce(p->>'arv_basis', o.arv_basis)), '') = '' then return jsonb_build_object('ok', false, 'reason', 'say how you got the value (arv_basis): which sales, which sources'); end if;
    if jsonb_typeof(coalesce(p->'comps', o.comps)) <> 'array' or jsonb_array_length(coalesce(p->'comps', o.comps)) = 0 then
      return jsonb_build_object('ok', false, 'reason', 'send the comps with the value: address, sold_price, sold_date, sqft, distance, url, note');
    end if;
    -- 0268: prices worked from another value do not stand; Muse sends them again with the new one
    if o.arv is distinct from c and not (p ? 'call_prices') then o.call_prices := null; o.call_prices_by := null; o.call_prices_at := null; end if;
    o.arv := c; o.valued_by := coalesce(p_agent, 'agent'); o.valued_at := now_;
  end if;
  if p ? 'arv_basis' then o.arv_basis := nullif(btrim(p->>'arv_basis'), ''); end if;
  if p ? 'comps' then
    if jsonb_typeof(p->'comps') <> 'array' then return jsonb_build_object('ok', false, 'reason', 'comps is a list'); end if;
    o.comps := p->'comps';
  end if;

  -- 0268: the street look and the prices for the call are Muse's; the server only checks them
  if p ? 'street' or p ? 'call_prices' then
    txt := public.text_offer_call_prices_why(o.arv, o.sqft, coalesce(p->'street', o.street), coalesce(p->'call_prices', o.call_prices));
    if txt is not null then return jsonb_build_object('ok', false, 'reason', txt); end if;
    o.street := coalesce(p->'street', o.street);
    if p ? 'call_prices' then o.call_prices := p->'call_prices'; o.call_prices_by := coalesce(p_agent, 'agent'); o.call_prices_at := now_; end if;
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
         property_kind = o.property_kind, street = o.street, call_prices = o.call_prices, call_prices_by = o.call_prices_by, call_prices_at = o.call_prices_at,
         ask_kind = o.ask_kind, ask_number = o.ask_number, ask_note = o.ask_note, asked_at = o.asked_at, colin_pinged_at = o.colin_pinged_at,
         colin_reminded_at = o.colin_reminded_at, colin_said = o.colin_said, colin_note = o.colin_note,
         response = o.response, response_words = o.response_words, response_at = o.response_at, counter_number = o.counter_number,
         accepted_number = o.accepted_number, accepted_at = o.accepted_at, rounds = o.rounds, updated_at = now_
   where t.id = o.id;
  perform public.text_offer_refresh(o.id, now_);
  select * into o from public.text_offers where id = o.id;
  return jsonb_build_object('ok', true, 'offer', public.agent_offer_row(o, now_));
end $function$;

-- ---------------------------------------------------------------- the yes task points at the sheet when it is on
CREATE OR REPLACE FUNCTION public.yes_call_sheet(p_lead_id uuid, p_now timestamp with time zone DEFAULT now())
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare o public.text_offers; r public.text_offer_rules; n integer; lines text[] := '{}'; x jsonb; due timestamptz; word text; street text; seen text;
begin
  select * into o from public.text_offers where lead_id = p_lead_id and status = 'open' and trigger = 'yes_to_selling' order by opened_at desc limit 1;
  if not found then return null; end if;
  select * into r from public.text_offer_rules where id = 1;
  -- 0270: when the deal sheet is on for callers it is the one place a number comes from
  if (select mode from public.deal_sheet_rules where id = 1) = 'on' then
    return 'NUMBER: the number, the reason and the words are on the card under Deal sheet. Read it before you dial.';
  end if;
  n := public.text_offer_comp_count(o.comps);
  due := coalesce(o.comp_due_at, o.opened_at + make_interval(mins => r.yes_comp_minutes));
  if o.arv is null then
    return case when p_now <= due
      then 'NUMBER: Muse is working out the value now. It will be on this card by ' || to_char(due at time zone 'America/Chicago', 'FMHH12:MI AM')
           || '. Calling before then: get the story and their number, and give none.'
      else 'NUMBER: no value yet (it was due ' || to_char(due at time zone 'America/Chicago', 'FMHH12:MI AM')
           || '). Call for the story and their number, and give none.' end;
  end if;
  if n < r.min_comps then
    return 'NUMBER: only ' || n::text || ' sold comp' || case when n = 1 then '' else 's' end || ' near this house, not enough to offer from. Call for the story and their number, and give none.';
  end if;
  word := 'Value fixed up ' || public.text_money(o.arv) || ' (Muse, ' || n::text || ' sold comps'
          || coalesce(', ' || to_char(nullif(o.sqft, 0), 'FM999,999') || ' sq ft', '') || ').';
  if o.call_prices is not null then
    if coalesce((o.street->>'no_view')::boolean, false) then
      street := 'No street picture of this house (' || coalesce(nullif(btrim(o.street->>'why'), ''), 'none found') || '), so nothing outside is priced in: ask about the roof and the outside too.';
    else
      select string_agg(btrim(e->>'item') || coalesce(' (' || nullif(btrim(e->>'note'), '') || ')', ''), ', ') into seen
        from jsonb_array_elements(coalesce(o.street->'seen', '[]'::jsonb)) e;
      street := 'From the street (picture from ' || btrim(o.street->>'image_date') || '): '
                || case when seen is null then 'nothing outside that needs work.' else seen || '. That is already in every row.' end;
    end if;
    for x in select e from jsonb_array_elements(o.call_prices) e loop
      lines := lines || (btrim(x->>'inside') || ': '
        || case when coalesce((x->>'no_offer')::boolean, false) then 'no offer (repairs ' || public.text_money(public.text_offer_num(x->'repairs')) || ' eat it)'
                else 'open ' || public.text_money(public.text_offer_num(x->'open')) || ', top ' || public.text_money(public.text_offer_num(x->'top'))
                     || ' (repairs ' || public.text_money(public.text_offer_num(x->'repairs')) || ')' end);
    end loop;
    return 'NUMBER: ' || word || ' ' || street || ' Ask what shape the inside is in, then use that row. ' || array_to_string(lines, '. ') || '.';
  end if;
  if o.lao is not null then
    return 'NUMBER: ' || word || ' Open at ' || public.text_money(o.lao) || ', top ' || public.text_money(o.mao)
           || coalesce(' (repairs ' || public.text_money(o.repairs) || ': ' || o.repairs_basis || ')', '') || '.';
  end if;
  return 'NUMBER: ' || word || ' Muse has not put its prices by condition on this card yet. Call for the story, the condition and their number, and give none.';
end $function$;

-- ---------------------------------------------------------------- Send offer: a caller may send at a number the seller said yes to on the sheet
CREATE OR REPLACE FUNCTION public.offer_colin_number(p_lead_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(
    -- 0270: a number the seller said yes to on the deal sheet (only one the sheet itself allowed)
    (select (ev->>'number')::numeric from public.deal_sheets s, jsonb_array_elements(s.said) ev
      where s.lead_id = p_lead_id and ev->>'response' = 'yes' and (select mode from public.deal_sheet_rules where id = 1) = 'on'
      order by ev->>'at' desc limit 1),
    (select d.our_number from public.deal_packages d
      where d.lead_id = p_lead_id and d.our_number is not null and d.status not in ('declined', 'dead')
      order by d.created_at desc limit 1),
    (select d.colin_offer from public.deals d
      where d.lead_id = p_lead_id and d.colin_offer is not null order by d.created_at desc limit 1))
$function$;

-- ---------------------------------------------------------------- the packet tells Muse to say what kind of building it is
update public.live_work_packet set updated_at = now(), body = replace(body,
  'Then offer_update {lead_id, arv, arv_basis, comps, sqft}. Always send sqft.',
  'Then offer_update {lead_id, arv, arv_basis, comps, sqft, property_kind}. Always send sqft. property_kind is site_built, manufactured (a mobile, modular or double-wide home), condo, multi, land or other: anything but site_built goes to Colin for a number, so say it plainly. Give every comp its street address, sold price and sold date: the caller names them to the seller.')
 where id = 1 and body not like '%property_kind%';
