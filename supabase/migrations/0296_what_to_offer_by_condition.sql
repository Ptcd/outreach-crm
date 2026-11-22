-- 0296: the Deal sheet shows what to offer for each shape of the inside, as soon as the comp is on the card.
-- Colin 2026-11-22, on 226 60th Ave, Somers: "Why didn't it show what to offer depending on condition, that's the entire
-- value of running the comp check". Grok's comp had three rows (cosmetic only, dated, rough), each with an opening and a
-- top. The sheet kept only the repair figure from each row and gave no number at all until what is owed was known; with
-- the sheet on for callers the yes sheet stopped printing the rows too (0270), and 0295 took them out of the script. So
-- the one thing the comp check is for was nowhere on the card.
--
--   * A card with a value and rows always has a number for each row: the rule's opening for that row's repairs.
--     What is owed, their own number and their floor only bring it down (debts bigger than the house leaves still set it
--     at what clears them). 'needs_owed', 'no_number' and 'apart' are no longer places where a caller has nothing.
--   * by_condition: the number for every row, worked the same way, so the caller sees them side by side and taps one.
--   * heads_up: what to expect (what is owed not asked yet; they want more than it sells for finished).
--   * Never open above the number the seller asked for.
--   * Still Colin's: a property the formula does not fit, his own number, his pass. Still no number: no value yet.

drop function if exists public.deal_sheet_work(uuid, timestamp with time zone);

CREATE FUNCTION public.deal_sheet_work(p_lead_id uuid, p_now timestamp with time zone DEFAULT now(), p_inside integer DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r public.deal_sheet_rules; tr public.text_offer_rules; l public.leads; o public.text_offers; b public.call_briefs; e public.equity_inputs;
  s public.deal_sheets; f jsonb; x jsonb; row_ jsonb; idx integer; i integer := 0;
  v_val numeric; needs numeric; needs_label text; needs_assumed boolean := false; costs numeric; clear numeric; other numeric := 0; owed_known boolean;
  usual numeric; v_cap numeric; opening numeric; num numeric; lim numeric; kind text; stage text; src text := 'math'; why text;
  gate text[] := '{}'; missing jsonb := '[]'::jsonb; v_comps jsonb := '[]'::jsonb; rows_ jsonb := '[]'::jsonb; steps jsonb := '[]'::jsonb;
  n_comps integer := 0; lo numeric; hi numeric; pkind text; yr integer; county numeric; their numeric; floor_ numeric; owed_said numeric;
  open_owed jsonb := '[]'::jsonb; allowed numeric[] := '{}'; blob text; tf jsonb; their_from text; say text; next_ text;
  apart boolean := false; heads text[] := '{}'; by_cond jsonb := '[]'::jsonb; w jsonb; j integer;
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
  select d.facts into tf from public.reply_drafts d where d.lead_id = p_lead_id and d.facts is not null order by d.inbound_at desc limit 1;
  their := coalesce(public.text_offer_num(f->'their_number'), public.text_offer_num(l.call_facts->'price'->'value'->'number'), o.their_number);
  their_from := case when their is not null then 'call' end;
  if their is null then
    their := public.money_said(tf->>'price_expectation');
    if their is not null then their_from := 'text'; end if;
  end if;
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
    idx := coalesce(p_inside, s.inside);        -- 0296: p_inside works the sheet for one row, whatever is tapped
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
  elsif s.agent_open is not null then
    -- 0281: an agent's number (Colin 2026-11-22: "My goal is for grok to be able to set those numbers"), checked when it
    -- was set against this sheet; Colin's own number is above it
    stage := 'ready'; src := 'agent'; num := s.agent_open; lim := greatest(coalesce(s.agent_top, s.agent_open), s.agent_open);
    why := nullif(btrim(s.agent_note), '');
  elsif v_val is null or needs is null then
    stage := 'needs_value';
    missing := missing || jsonb_build_object('what', case when v_val is null then 'what it sells for finished, with the sold houses behind it'
                                                          else 'what it needs, by the shape of the inside' end, 'who', 'muse');
  elsif coalesce(array_length(gate, 1), 0) > 0 then
    stage := 'colin_prices'; why := 'No formula number: ' || array_to_string(gate, '; ') || '.';
    missing := missing || jsonb_build_object('what', 'a number for this one', 'who', 'colin');
  elsif v_cap <= 0 or coalesce(opening, 0) <= 0 or coalesce((row_->>'no_offer')::boolean, false) then
    stage := 'no_fit'; why := 'What it needs is more than the rule can pay for it.';
  else
    -- 0296 (Colin 2026-11-22: "Why didn't it show what to offer depending on condition, that's the entire value of
    -- running the comp check"): once the comp is on the card there is always a number for each shape of the inside,
    -- the rule's opening for that row's repairs. What is owed, their own number and their floor can only bring it down
    -- (or, when the debts are more than the house leaves, set it at what clears them). Before, the sheet gave no number
    -- until what is owed was known, and none to a seller who keeps the difference.
    apart := their is not null and their >= v_val and (floor_ is null or floor_ >= v_val);
    if owed_known then
      kind := case when usual <= r.walk_money then 'nothing_left' when usual <= v_cap then 'some_left' else 'a_lot' end;
      if kind = 'nothing_left' then
        num := greatest(public.deal_round(clear + r.walk_money, r.round_to, true), r.min_number);
      elsif kind = 'some_left' then
        num := greatest(least(public.deal_round(usual * r.net_share, r.round_to), opening), r.min_number);
      else
        num := opening; src := 'rule';
      end if;
    else
      num := opening; src := 'rule';
      missing := missing || jsonb_build_object('what', 'what is owed: ask them on the call, then tap the answer', 'who', 'caller');
    end if;
    if kind is distinct from 'nothing_left' then
      if their is not null and their < num then num := their; src := 'their_number'; end if;      -- never open above what they asked for
      if floor_ is not null and floor_ < num then num := floor_; src := 'their_floor'; end if;
    end if;
    if num > v_cap then
      stage := 'no_fit'; why := 'What has to be cleared (' || public.text_money(clear) || ') is more than the most we can pay.';
      missing := missing || jsonb_build_object('what', 'whether there is another way to do this one', 'who', 'colin');
      num := null;
    elsif num > opening and v_cap - num < r.min_gap then
      stage := 'colin_prices'; why := 'Thin: the number would be only ' || public.text_money(v_cap - num) || ' under the most we can pay.';
      missing := missing || jsonb_build_object('what', 'a number for this one', 'who', 'colin');
      num := null;
    else
      stage := 'ready'; lim := public.deal_round(num + (v_cap - num) * r.caller_share, r.round_to);
      if not owed_known then heads := heads || 'What they owe is not known yet. Ask it (step 3) before you say the number: it can come down.'::text; end if;
      if apart then
        heads := heads || ('They want ' || public.text_money(their) || '. Finished, houses like it sell for about ' || public.text_money(v_val)
                 || ', so expect a no. Say your number once, then ask why they would sell and by when.');
      elsif kind = 'a_lot' and src = 'rule' then
        heads := heads || 'Selling it with an agent could leave them more than we pay, so expect a no. Ask the number they would not go under (step 5).'::text;
      end if;
    end if;
  end if;

  -- 0296: the number for every shape of the inside, so the caller sees what to offer before the seller has said which
  if p_inside is null and stage in ('ready', 'no_fit') and src not in ('colin', 'agent') and jsonb_array_length(rows_) > 0 then
    for j in 0 .. jsonb_array_length(rows_) - 1 loop
      w := case when j = idx then jsonb_build_object('number', num, 'stage', stage) else public.deal_sheet_work(p_lead_id, p_now, j) end;
      by_cond := by_cond || jsonb_build_object('i', j, 'inside', rows_->j->>'inside', 'number', w->'number', 'stage', w->>'stage',
                                               'picked', j = idx and not needs_assumed);
    end loop;
  end if;

  if num is not null then
    allowed := array[num];
    if lim is not null and lim > num then
      allowed := allowed || public.deal_round(num + (lim - num) / 2, r.round_to) || lim;
      allowed := array(select distinct a from unnest(allowed) a order by a);
    end if;
    select jsonb_agg(a order by a) into steps from unnest(allowed) a;
  end if;

  say := case stage
    when 'ready' then 'Your number is ' || public.text_money(num) || '. Say it once, on a call, after step 5.'
    when 'passed' then 'No number. Colin passed on this one.'
    else 'You have no number for this house. Do not say or text any price.' end;
  next_ := case stage
    when 'ready' then 'Walk steps 1 to 5 with them first. One number, one reason, then wait.'
    when 'needs_value' then 'We are still working out what it sells for. Call for their story and their number, and give none.'
    when 'needs_owed' then 'Call them. Ask what is owed (step 3) and tap the answer. The number comes after that.'
    when 'colin_prices' then 'Colin prices this one. Use Ask Colin at the bottom of this sheet, then book a time to call them back.'
    when 'no_fit' then coalesce(why, '') || ' Use Ask Colin at the bottom of this sheet.'
    when 'passed' then coalesce(why, '') || ' Close it kindly.'
    else null end;

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
    'theirs', jsonb_build_object('number', their, 'floor', floor_, 'owed_said', owed_said, 'number_from', their_from),
    'verdict', jsonb_build_object('say', say, 'next', next_), 'heads_up', to_jsonb(heads), 'by_condition', by_cond, 'apart', apart,
    'texted', jsonb_build_object('condition', tf->>'condition', 'who_signs', tf->>'decision_makers', 'lives_there', tf->>'occupancy'),
    'facts', f, 'said', coalesce(s.said, '[]'::jsonb),
    'agent', jsonb_build_object('open', s.agent_open, 'top', s.agent_top, 'note', s.agent_note, 'by', s.agent_by, 'at', s.agent_at),
    'colin', jsonb_build_object('open', s.colin_open, 'top', s.colin_top, 'note', s.colin_note, 'pass', coalesce(s.colin_pass, false), 'at', s.colin_at,
               'asked_at', s.asked_at, 'asked_words', s.asked_words),
    'owner_name', l.owner_name, 'address', l.property_address, 'caller', public.card_caller(p_lead_id)::text);
end $function$;

revoke all on function public.deal_sheet_work(uuid, timestamp with time zone, integer) from public, anon, authenticated;
grant execute on function public.deal_sheet_work(uuid, timestamp with time zone, integer) to service_role;
