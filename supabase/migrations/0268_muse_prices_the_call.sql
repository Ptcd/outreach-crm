-- 0268: Muse prices the call, not the server. Colin 2026-11-21, on the caller's number sheet (0266), which took
-- Muse's value and worked three rows from the size alone ($15, $30, $60 a square foot): "I don't know how well right
-- now the offer changes depending on condition, like muse should do a Google maps driveby to check it and then get sq
-- footage and have prices either way but like s 2nd you could see it needs a roof from street view so that should be
-- baked into every scenario", then: "I want muse to do it not the server".
--
--   * Muse looks at the house on Street View and stores what shows (text_offers.street: the picture's date, each
--     thing seen with its cost) and its own prices for the caller (text_offers.call_prices: a row for each shape the
--     inside could be in, with repairs, where they come from, an opening and a top).
--   * The server works out no row any more. It checks three things and refuses with the reason: the value and the
--     size are on the card; every row's repairs hold everything seen from the street; no top is above Colin's
--     standing most (text_offer_rules.mao_pct of the value, minus that row's repairs).
--   * The caller's sheet (yes_call_sheet) shows Muse's rows, what was seen from the street and how old the picture
--     is. A value with no prices yet reads "give none".
--   * After the comp, Muse's next step on a yes is call_prices. A new value clears prices worked from the old one.
-- The offer by text (the seller asked for a number; 0223, 0245) is untouched: that figure is still the rule's.

alter table public.text_offers
  add column if not exists street jsonb,
  add column if not exists call_prices jsonb,
  add column if not exists call_prices_by text,
  add column if not exists call_prices_at timestamptz;

create or replace function public.text_offer_num(p jsonb) returns numeric
language sql immutable as $$
  select case when p is null or jsonb_typeof(p) = 'null' then null
              else nullif(regexp_replace(p #>> '{}', '[^0-9.]', '', 'g'), '')::numeric end
$$;

-- why a street look and a set of call prices cannot be stored; null when they can
create or replace function public.text_offer_call_prices_why(p_arv numeric, p_sqft integer, p_street jsonb, p_prices jsonb) returns text
language plpgsql stable security definer set search_path = public as $$
declare r public.text_offer_rules; x jsonb; seen numeric := 0; seen_words text; c numeric; rp numeric; op numeric; tp numeric; most numeric; n integer; label text;
begin
  select * into r from public.text_offer_rules where id = 1;
  if p_arv is null or p_arv <= 0 then return 'the value comes first: send arv, arv_basis and comps (before this, or in the same call)'; end if;
  if coalesce(p_sqft, 0) <= 0 then return 'send sqft: the size of the house, from the assessor record or a listing'; end if;
  if p_street is null or jsonb_typeof(p_street) <> 'object' then
    return 'send street: what you saw of the house on Street View, {image_date, seen: [{item, cost, note}], notes}; or {no_view: true, why} when there is no picture of it';
  end if;
  if coalesce((p_street->>'no_view')::boolean, false) then
    if coalesce(btrim(p_street->>'why'), '') = '' then return 'street.no_view needs why: what you tried and what came up'; end if;
  elsif coalesce(btrim(p_street->>'image_date'), '') = '' then
    return 'street.image_date: the month and year on the Street View picture you looked at. It can be years old, and the caller is told how old';
  end if;
  if p_street ? 'seen' and jsonb_typeof(p_street->'seen') <> 'array' then return 'street.seen is a list of {item, cost, note}; an empty list when nothing outside needs work'; end if;
  for x in select e from jsonb_array_elements(coalesce(p_street->'seen', '[]'::jsonb)) e loop
    c := public.text_offer_num(x->'cost');
    if coalesce(btrim(x->>'item'), '') = '' or c is null then
      return 'each thing seen from the street is {item, cost, note}: what it is (roof, siding, porch ...), your dollar figure for it, and what you saw';
    end if;
    seen := seen + c;
    seen_words := coalesce(seen_words || ', ', '') || btrim(x->>'item');
  end loop;
  if p_prices is null or jsonb_typeof(p_prices) <> 'array' then
    return 'send call_prices with the street look: two to five rows, one for each shape the inside could be in, each {inside, repairs, repairs_basis, open, top}';
  end if;
  n := jsonb_array_length(p_prices);
  if n < 2 or n > 5 then return 'call_prices is two to five rows (you sent ' || n::text || '): the caller picks the row from what the seller says about the inside'; end if;
  for x in select e from jsonb_array_elements(p_prices) e loop
    label := coalesce(nullif(btrim(x->>'inside'), ''), '');
    rp := public.text_offer_num(x->'repairs'); op := public.text_offer_num(x->'open'); tp := public.text_offer_num(x->'top');
    if label = '' then return 'every row says which shape of the inside it is for (inside: "light", "needs a kitchen and baths", "gutted" ...)'; end if;
    if rp is null or coalesce(btrim(x->>'repairs_basis'), '') = '' then
      return 'the row "' || label || '" needs repairs (dollars) and repairs_basis (what the figure is made of)';
    end if;
    if rp < seen then
      return 'the row "' || label || '" has repairs of ' || public.text_money(rp) || ', less than what you saw from the street (' || public.text_money(seen)
             || ': ' || seen_words || '). What shows from the street is in every row';
    end if;
    most := round((p_arv * r.mao_pct - rp) / r.round_to) * r.round_to;
    if coalesce((x->>'no_offer')::boolean, false) then continue; end if;
    if op is null or tp is null or op <= 0 or tp < op then
      return 'the row "' || label || '" needs open and top in dollars, top at or above open; or no_offer: true when the repairs eat it';
    end if;
    if tp > most then
      return 'the row "' || label || '": a top of ' || public.text_money(tp) || ' is above the most Colin''s rule allows for those repairs ('
             || round(r.mao_pct * 100)::text || '% of ' || public.text_money(p_arv) || ' minus ' || public.text_money(rp) || ' = ' || public.text_money(greatest(most, 0)) || ')';
    end if;
  end loop;
  return null;
end $$;
revoke all on function public.text_offer_call_prices_why(numeric, integer, jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.text_offer_call_prices_why(numeric, integer, jsonb, jsonb) to service_role;

-- ---------------------------------------------------------------- the number for the call, in words: Muse's rows
create or replace function public.yes_call_sheet(p_lead_id uuid, p_now timestamptz default now()) returns text
language plpgsql stable security definer set search_path = public as $fn$
declare o public.text_offers; r public.text_offer_rules; n integer; lines text[] := '{}'; x jsonb; due timestamptz; word text; street text; seen text;
begin
  select * into o from public.text_offers where lead_id = p_lead_id and status = 'open' and trigger = 'yes_to_selling' order by opened_at desc limit 1;
  if not found then return null; end if;
  select * into r from public.text_offer_rules where id = 1;
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
end $fn$;
revoke all on function public.yes_call_sheet(uuid, timestamptz) from public, anon, authenticated;
grant execute on function public.yes_call_sheet(uuid, timestamptz) to service_role;

drop trigger if exists text_offers_yes_sheet on public.text_offers;
create trigger text_offers_yes_sheet after update of arv, comps, sqft, lao, mao, repairs, status, comp_due_at, street, call_prices on public.text_offers
  for each row execute function public.yes_offer_refreshes_task();

-- ---------------------------------------------------------------- Muse records them (offer_update)
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
         street = o.street, call_prices = o.call_prices, call_prices_by = o.call_prices_by, call_prices_at = o.call_prices_at,
         ask_kind = o.ask_kind, ask_number = o.ask_number, ask_note = o.ask_note, asked_at = o.asked_at, colin_pinged_at = o.colin_pinged_at,
         colin_reminded_at = o.colin_reminded_at, colin_said = o.colin_said, colin_note = o.colin_note,
         response = o.response, response_words = o.response_words, response_at = o.response_at, counter_number = o.counter_number,
         accepted_number = o.accepted_number, accepted_at = o.accepted_at, rounds = o.rounds, updated_at = now_
   where t.id = o.id;
  perform public.text_offer_refresh(o.id, now_);
  select * into o from public.text_offers where id = o.id;
  return jsonb_build_object('ok', true, 'offer', public.agent_offer_row(o, now_));
end $function$;

-- ---------------------------------------------------------------- the next step on a yes, after the comp
CREATE OR REPLACE FUNCTION public.text_offer_view(o text_offers, p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  elsif o.trigger = 'yes_to_selling' and (o.arv is null or n < r.min_comps) then
    -- 0266: they said yes and a caller is being told to phone them. The comp comes first and in minutes, not after
    -- the condition question: the caller's opening and top number are worked from it.
    step := 'comp'; who := 'muse'; due := coalesce(o.comp_due_at, o.opened_at + make_interval(mins => r.yes_comp_minutes)); gate := 'a comp for the caller';
    say := case when o.arv is not null then 'Only ' || n::text || ' sold comp(s) with a price and a date: ' || r.min_comps::text
                  || ' are needed. Add them now, or close the offer as no_comp_set: the caller is told to give no number.'
                else 'They said YES and a caller is being told to phone them. Comp it NOW, inside ' || r.yes_comp_minutes::text
                  || ' minutes: sold comps near the house, then offer_update {arv, arv_basis, comps, sqft}. Send sqft with it. The caller has no number until your street look and your prices are on the card too: that is the next step, or send street and call_prices in the same offer_update. Fewer than '
                  || r.min_comps::text || ' sold comps is not a set to offer from: close as no_comp_set and the caller is told to give no number. Ask the condition question by text AFTER the comp is in, not before.' end;
  elsif o.trigger = 'yes_to_selling' and o.call_prices is null and o.ok_at is null then
    -- 0268 (Colin 2026-11-21: "I want muse to do it not the server"): the caller's prices are Muse's, worked from a
    -- look at the house, with what shows from the street in every row
    step := 'call_prices'; who := 'muse'; due := coalesce(o.valued_at, o.opened_at) + make_interval(mins => r.yes_comp_minutes); gate := 'the prices for the call';
    say := 'The value is in. Now YOUR prices for the caller, not the server''s. Look at the house on Street View: roof, siding, windows, porch, garage, yard, signs nobody lives there. Then offer_update {street: {image_date, seen: [{item, cost, note}], notes}, call_prices: [{inside, repairs, repairs_basis, open, top}, ...]}: two to five rows, one for each shape the inside could be in (for example "inside light", "inside medium", "inside heavy"), each row''s repairs holding everything in street.seen plus the inside work at that level. A roof you can see is in every row. open is '
           || round(r.lao_pct * 100)::text || '% of the value minus that row''s repairs and top is ' || round(r.mao_pct * 100)::text
           || '%, to the nearest $' || r.round_to::text || '; a row where the repairs eat it is {inside, repairs, repairs_basis, no_offer: true}. No Street View picture of the house: street {no_view: true, why}. Until this is in, the caller is told to give no number.';
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
end $function$;

-- ---------------------------------------------------------------- what Muse reads back
CREATE OR REPLACE FUNCTION public.agent_offer_row(o text_offers, p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select jsonb_build_object('offer_id', o.id, 'lead_id', o.lead_id, 'owner_name', l.owner_name, 'address', l.property_address, 'city', l.municipality,
    'county', l.county, 'phone', o.phone, 'opened_at', o.opened_at, 'opened_by', o.opened_by, 'their_words_that_opened_it', o.trigger_text,
    'next', public.text_offer_view(o, p_now),
    'seller', jsonb_build_object('need', o.need, 'their_number', o.their_number, 'their_words', o.their_words, 'flexible', o.flexible,
      'timeline', o.timeline, 'signers', o.signers, 'seller_email', o.seller_email, 'occupancy', o.occupancy,
      'condition_asked_at', o.condition_asked_at, 'condition_words', o.condition_words, 'repair_items', o.repair_items, 'repair_level', o.repair_level),
    'comp', jsonb_build_object('arv', o.arv, 'basis', o.arv_basis, 'sold_comps', public.text_offer_comp_count(o.comps), 'sqft', o.sqft, 'due_at', o.comp_due_at, 'valued_at', o.valued_at,
      'street', o.street, 'call_prices', o.call_prices, 'call_prices_at', o.call_prices_at),
    'numbers', jsonb_build_object('repairs', o.repairs, 'repairs_basis', o.repairs_basis, 'offer', o.lao, 'most', o.mao, 'wholesale', o.wholesale,
      'asked_of_colin', o.ask_number, 'asked_at', o.asked_at, 'colin_said', o.colin_said, 'colin_note', o.colin_note,
      'ok_number', o.ok_number, 'ok_at', o.ok_at, 'figures_you_may_text', o.ok_numbers),
    'answer', jsonb_build_object('response', o.response, 'words', o.response_words, 'counter', o.counter_number, 'accepted', o.accepted_number, 'accepted_at', o.accepted_at))
    from public.leads l where l.id = o.lead_id
$function$;

-- the sheets already on callers' tasks were the server's rows: say what is true now
select public.yes_sheet_to_task(o.lead_id) from public.text_offers o where o.status = 'open' and o.trigger = 'yes_to_selling';
