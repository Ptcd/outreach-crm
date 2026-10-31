-- 0157: what Colin's Adil walkthrough found (2026-10-31, Power hour -> Quick number -> script -> package):
-- 1. the package's condition was empty when the caller only used the Quick number: package_submit now carries the four
--    quick answers into the package's condition (anything the caller typed in the form wins);
-- 2. the buyer's price (mao, lao, pct) left the database for callers even though the screen hides it: offer_shoot now
--    returns those to Colin only;
-- 3. a card locked to Adil got its next belt call labelled "Thalia calls", and on a weekday the call task went to
--    Thalia, whose list skips cards locked to Adil (0148): the belt's caller step goes to the caller the card is locked
--    to, and the label names them.


-- package_submit: from 0149_exit_anchor_number.sql
create or replace function public.package_submit(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid; login public.team_person := public.wpie_person();
        -- who is on the phone: the shared login is Colin's, so the app sends the person picked on this phone
        -- (a caller with a login of their own is always themself)
        who public.team_person := case
          when p->>'caller' in ('thalia', 'adil', 'colin') and (login is null or login = 'colin') then (p->>'caller')::public.team_person
          else login end; lid uuid := nullif(p->>'lead_id', '')::uuid; cb timestamptz := nullif(p->>'callback_at', '')::timestamptz;
        walk boolean := coalesce((p->>'walk_booked_on_call')::boolean, false); l public.leads;
begin
  if not public.is_team() then raise exception 'only the team sends packages'; end if;
  select * into l from public.leads where id = lid;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card'); end if;
  if coalesce(btrim(p->>'need'), '') = '' and coalesce(p->'condition', '{}'::jsonb) = '{}'::jsonb then
    return jsonb_build_object('ok', false, 'reason', 'a package needs their reason or the condition, in their words');
  end if;
  if cb is null and not walk then return jsonb_build_object('ok', false, 'reason', 'set the callback time you promised (or say the walk is booked)'); end if;
  if exists (select 1 from public.deal_packages d where d.lead_id = lid and d.status in ('waiting_value', 'waiting_number', 'go_walk', 'number_ready', 'counter', 'agreed')) then
    return jsonb_build_object('ok', false, 'reason', 'this card already has an open package');
  end if;
  insert into public.deal_packages (lead_id, interest_id, source, hot, need, condition, timeline, their_number, their_basis, on_title, owed,
         occupancy, photos, other_buyers, concerns, motivation, callback_at, walk_booked_on_call, created_by)
  values (lid, nullif(p->>'interest_id', '')::uuid, coalesce(nullif(p->>'source', ''), public.lead_source_kind(lid)), coalesce((p->>'hot')::boolean, false),
          nullif(btrim(p->>'need'), ''), coalesce(p->'condition', '{}'::jsonb), nullif(btrim(p->>'timeline'), ''), nullif(btrim(p->>'their_number'), ''),
          nullif(btrim(p->>'their_basis'), ''), nullif(btrim(p->>'on_title'), ''), nullif(btrim(p->>'owed'), ''), nullif(btrim(p->>'occupancy'), ''),
          nullif(btrim(p->>'photos'), ''), nullif(btrim(p->>'other_buyers'), ''), nullif(btrim(p->>'concerns'), ''), nullif(btrim(p->>'motivation'), ''),
          cb, walk, who)
  returning id into v_id;
  if cb is not null then
    insert into public.tasks (lead_id, due_at, kind, owner, note)
    values (lid, cb, 'callback', coalesce(who, 'thalia'), 'Callback promised: waiting on Colin (walk it or pass) (package ' || left(v_id::text, 8) || ')');
  end if;
  update public.leads set next_action = case when walk then 'Package with Colin: walk booked on the call' else 'Package with Colin: callback ' || to_char(cb at time zone 'America/Chicago', 'Dy Mon DD HH12:MI AM') end,
         next_action_at = coalesce(cb, next_action_at),
         notes = concat_ws(' | ', notes, to_char(now() at time zone 'America/Chicago', 'YYYY-MM-DD') || ' package sent to Colin by ' || coalesce(who::text, 'the team')
                 || coalesce(': ' || nullif(btrim(p->>'motivation'), ''), ''))
   where id = lid;
  -- the anchor said on the first call (0149) and what they said back, so Colin sees it with the package
  if l.call_facts ? 'our_number' then
    update public.deal_packages set said_number = nullif(l.call_facts->'our_number'->'value'->>'number', '')::numeric,
           number_note = 'non-firm anchor said on the first call, they ' || coalesce(l.call_facts->'our_number'->'value'->'choices'->>0, '?')
             || coalesce(' ' || nullif(l.call_facts->'our_number'->'value'->>'counter', ''), '')
     where id = v_id;
  end if;
  -- the Quick number's four answers (0154) carry into the package's condition; the caller's typed words win (0157)
  update public.deal_packages set condition = jsonb_strip_nulls(jsonb_build_object(
      'roof', case l.call_facts->'quick_roof'->'value'->'choices'->>0 when 'old' then 'older or not sure (quick number)' when 'new' then 'done in the last 15 years (quick number)' end,
      'hvac', case l.call_facts->'quick_hvac'->'value'->'choices'->>0 when 'old' then 'original or not sure (quick number)' when 'new' then 'newer (quick number)' end,
      'kitchen_baths', case l.call_facts->'quick_kb'->'value'->'choices'->>0 when 'original' then 'original (quick number)' when 'updated' then 'updated (quick number)' end,
      'foundation', case l.call_facts->'quick_big'->'value'->'choices'->>0 when 'yes' then 'water, foundation, fire or code: yes (quick number)' end))
      || coalesce(condition, '{}'::jsonb)
   where id = v_id;
  return jsonb_build_object('ok', true, 'package_id', v_id);
end $$;

-- offer_shoot: from 0156_rick_repairs_per_square_foot.sql, the buyer's price for Colin only
create or replace function public.offer_shoot(p_lead_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.offer_settings; l public.leads; pv public.property_values; pk public.deal_packages; rh jsonb;
        value numeric; value_basis text; sqft integer; sqft_basis text; units integer; beds integer; baths integer;
        cond text[]; happened text[]; layout text; their text; f jsonb;
        q_roof text; q_hvac text; q_kb text; q_big text; newish boolean := false;
        lines jsonb := '[]'::jsonb; sub numeric := 0; amt numeric; buffer numeric; repairs numeric;
        pct numeric; off numeric; band jsonb; mao numeric; lao numeric; num numeric; asked integer := 0;
        band_key text; tier text; res jsonb;
begin
  if not public.is_team() then raise exception 'only the team'; end if;
  select * into s from public.offer_settings where id = 1;
  rh := s.rehab;
  select * into l from public.leads where id = p_lead_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card', 'mode', s.mode); end if;
  f := coalesce(l.call_facts, '{}'::jsonb);
  select * into pk from public.deal_packages d where d.lead_id = p_lead_id
     and d.status in ('waiting_value', 'waiting_number', 'go_walk', 'number_ready', 'counter', 'agreed') order by created_at desc limit 1;
  if l.wpie_property_id is not null then select * into pv from public.property_values where wpie_property_id = l.wpie_property_id; end if;

  -- the value fixed up: the package's (Muse or Colin), else the county's estimate, else assessed adjusted
  if pk.arv is not null and pk.arv > 0 then value := pk.arv; value_basis := 'the package''s value (' || coalesce(pk.valued_by, 'Muse') || ')';
  elsif pv.est_market_value is not null and pv.est_market_value > 0 then value := pv.est_market_value; value_basis := 'the county''s estimated market value';
  elsif pv.assessed_total is not null and pv.assessed_total > 0 then value := round(pv.assessed_total / 0.95); value_basis := 'assessed value (' || pv.assessed_total::text || ') adjusted';
  end if;
  their := nullif(f->'price'->'value'->>'number', '');
  if value is null then
    return jsonb_build_object('ok', false, 'mode', s.mode, 'their_number', their, 'reason', 'no value on file for this card: ask for their number, or book Colin');
  end if;

  -- size: the county, else the bedrooms they named, else the default
  units := greatest(coalesce(l.units, 1), 1);
  layout := coalesce(f->'layout'->'value'->>'text', '');
  beds := nullif(substring(layout from '(\d+)\s*(?:-\s*)?(?:bed|br\b|bd\b|bdrm)'), '')::integer;
  baths := coalesce(nullif(substring(layout from '(\d+)\s*(?:-\s*)?(?:bath|ba\b)'), '')::integer, 1);
  if pv.building_sqft is not null and pv.building_sqft > 0 then sqft := pv.building_sqft; sqft_basis := 'county records';
  elsif beds is not null then sqft := (case when beds <= 1 then 750 when beds = 2 then 950 when beds = 3 then 1250 when beds = 4 then 1600 else 2000 end) * units;
       sqft_basis := beds::text || ' bedrooms, as they said';
  else sqft := s.default_sqft * units; sqft_basis := 'assumed'; end if;
  newish := pv.year_built is not null and pv.year_built >= extract(year from now())::integer - coalesce((rh->>'new_house_years')::integer, 5);

  -- the four quick answers, else the call script's condition chips, else unknown
  select coalesce(array_agg(x), '{}') into cond from jsonb_array_elements_text(coalesce(f->'condition'->'value'->'choices', '[]'::jsonb)) x;
  select coalesce(array_agg(x), '{}') into happened from jsonb_array_elements_text(coalesce(f->'happened'->'value'->'choices', '[]'::jsonb)) x;
  q_roof := f->'quick_roof'->'value'->'choices'->>0;
  q_hvac := f->'quick_hvac'->'value'->'choices'->>0;
  q_kb   := f->'quick_kb'->'value'->'choices'->>0;
  q_big  := f->'quick_big'->'value'->'choices'->>0;
  if q_roof is null then q_roof := case when 'roof' = any(cond) then 'old' when cond && array['cosmetic', 'perfect'] then 'new' end; end if;
  if q_hvac is null then q_hvac := case when 'furnace' = any(cond) then 'old' when cond && array['cosmetic', 'perfect'] then 'new' end; end if;
  if q_kb is null then q_kb := case when 'kitchen_baths' = any(cond) then 'original' when cond && array['cosmetic', 'perfect'] then 'updated' end; end if;
  if q_big is null then q_big := case when cond && array['foundation', 'water'] or happened && array['fire', 'foundation', 'code', 'leak'] then 'yes'
                                       when 'none' = any(happened) then 'no' end; end if;
  asked := (q_roof is not null)::int + (q_hvac is not null)::int + (q_kb is not null)::int + (q_big is not null)::int;

  if q_big = 'yes' then
    return jsonb_build_object('ok', false, 'mode', s.mode, 'their_number', their, 'value', value, 'value_basis', value_basis, 'walk_first', true,
      'reason', 'water, foundation, fire or a code order: no number on the phone, Colin walks it first');
  end if;

  -- Rick's repairs by the square foot (Flip With Rick, "How to Easily Estimate Repair Costs"): the county's square feet
  -- under air times a rate for the condition. Light (carpet, paint, cleanup) $5-10, medium (new roof, carpets, AC, a
  -- kitchen and a bath) $25-30, heavy (the dumps) $50-70, sometimes 100; the padded end of each range by default. The
  -- medium rate already carries the roof and AC, so nothing is added on top. The taps pick the condition: all three
  -- good = light; any old or not asked = medium; nothing asked at all = heavy (Rick: when unsure, go heavy).
  tier := case
    when q_roof is null and q_hvac is null and q_kb is null and not newish then 'heavy'
    when coalesce(q_roof, case when newish then 'new' end) = 'new' and coalesce(q_hvac, case when newish then 'new' end) = 'new'
         and coalesce(q_kb, case when newish then 'updated' end) = 'updated' then 'light'
    else 'medium' end;
  amt := round((rh->>(tier || '_per_ft'))::numeric * sqft);
  lines := lines || jsonb_build_object('item', 'Rick''s rate: ' || tier, 'amount', amt,
    'why', sqft::text || ' sq ft (' || sqft_basis || ') x $' || (rh->>(tier || '_per_ft')) || ' a sq ft; '
           || case tier when 'light' then 'roof, furnace/AC, kitchen and baths all in good shape'
                        when 'heavy' then 'nothing asked yet: heavy' else 'something old or not asked' end);
  sub := sub + amt;
  repairs := sub;

  -- Rick's math: (value - repairs) x the band's percent = the buyer's most; the anchor opens the band's discount under it
  pct := null; off := null;
  for band in select * from jsonb_array_elements(s.bands) loop
    if band->>'upto' is null or value <= (band->>'upto')::numeric then
      pct := (band->>'pct')::numeric; off := nullif(band->>'off', '')::numeric; exit;
    end if;
  end loop;
  pct := coalesce(pct, 0.70); off := coalesce(off, s.lao_discount);
  mao := (value - repairs) * pct;
  lao := mao * (1 - off);
  num := floor(lao / greatest(s.round_to, 1)) * greatest(s.round_to, 1);
  if num < s.min_number then
    return jsonb_build_object('ok', false, 'mode', s.mode, 'their_number', their, 'value', value, 'value_basis', value_basis,
      'repairs', repairs, 'lines', lines, 'asked', asked,
      'reason', 'too thin to say a number (' || round(lao)::text || '): book Colin instead');
  end if;
  res := jsonb_build_object('ok', true, 'mode', s.mode, 'their_number', their,
    'value', value, 'value_basis', value_basis, 'sqft', sqft, 'sqft_basis', sqft_basis, 'units', units,
    'lines', lines, 'repairs', repairs, 'asked', asked,
    'tier', tier, 'tier_basis', asked::text || ' of 4 quick answers given; not asked counts as needing work',
    'pct', pct, 'off', off, 'mao', round(mao), 'lao', round(lao), 'number', num,
    'say', 'I can''t give you a firm number on a place we haven''t seen. Rough, and going off what you''ve told me and what the county shows, we''d be somewhere around $' || to_char(num, 'FM999,999,999') || '. Is that even in the conversation?');
  -- the buyer's price stays with Colin (Colin 2026-10-31: "don't show buyers price"): callers get the number to say
  return case when public.is_owner() then res else res - 'mao' - 'lao' - 'pct' end;
end $$;

-- belt_enter: from 0052_weekend_calls_to_adil.sql, the locked caller
CREATE OR REPLACE FUNCTION public.belt_enter(p_lead_id uuid, p_belt text, p_step integer, p_event text, p_payload jsonb, p_by text, p_now timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
declare l public.leads; r public.belt_rules; st record; from_belt text; round integer; maxs integer; step integer := greatest(p_step, 1);
  key text; title text; note text; phones text; tkind text; st_stage public.lead_stage; nxt text; who_person public.team_person;
  guard integer := 0;
begin
  select * into l from public.leads where id = p_lead_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such lead'); end if;
  select * into r from public.belt_rules where belt = p_belt;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such belt ' || p_belt); end if;
  from_belt := l.belt;
  -- a DNC card never moves (nothing outbound, ever); a dead card only by an explicit move or a STOP
  if from_belt = 'dnc' and p_belt <> 'dnc' and p_event <> 'move' then
    insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
    values (p_lead_id, p_event, from_belt, from_belt, l.belt_step, p_payload || '{"ignored":"dnc never moves"}', p_now, public.belt_actor(p_by));
    return jsonb_build_object('ok', true, 'belt', 'dnc', 'ignored', true);
  end if;
  if from_belt is distinct from p_belt then
    round := coalesce(l.belt_round, 0) + 1;
    perform public.belt_cancel_pending(p_lead_id, 'moved to ' || p_belt, p_now);
  else
    round := greatest(coalesce(l.belt_round, 0), 1);
    -- the stops before this one are over: close their tasks, drop their drafts
    update public.tasks set done_at = coalesce(done_at, p_now) where lead_id = p_lead_id and source = 'belt' and done_at is null
       and source_key <> format('belt:%s:%s:%s:%s', p_lead_id, p_belt, round, step)
       and not (p_belt in ('call_booked', 'visit_booked') and source_key = format('belt:%s:%s:%s:%s', p_lead_id, p_belt, round, 2));
    update public.reply_drafts set status = 'superseded', updated_at = p_now where lead_id = p_lead_id and kind = 'belt'
       and status in ('queued', 'awaiting_approval', 'would_send') and belt_stop_key <> format('belt:%s:%s:%s:%s', p_lead_id, p_belt, round, step);
  end if;
  maxs := public.belt_max_step(p_belt);
  -- the stops ran out, or the cap is hit: the belt's "then"
  if (step > maxs or (maxs > 0 and l.unanswered_count >= r.max_unanswered and from_belt = p_belt and step > 1)) then
    if r.then_belt is not null and r.then_belt <> p_belt then
      update public.leads set belt = p_belt, belt_step = maxs, belt_round = round, belt_entered_at = coalesce(belt_entered_at, p_now),
             next_stop_at = null, next_stop_who = null where id = p_lead_id;
      insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
      values (p_lead_id, 'stops_ran_out', from_belt, p_belt, maxs, p_payload, p_now, public.belt_actor(p_by));
      return public.belt_enter(p_lead_id, r.then_belt, 1, 'stops_ran_out', jsonb_build_object('from', p_belt), p_by, p_now);
    end if;
    -- a belt with no stops (dead, dnc, too high / listed, dormant after three rounds): the card rests
    st_stage := public.belt_stage(p_belt);
    update public.leads set belt = p_belt, belt_step = least(step, greatest(maxs, 0)), belt_round = round,
           belt_entered_at = case when from_belt is distinct from p_belt then p_now else coalesce(belt_entered_at, p_now) end,
           next_stop_at = null, next_stop_who = null, next_stop_say = null,
           unanswered_count = case when from_belt is distinct from p_belt then 0 else unanswered_count end,
           stage = coalesce(st_stage, stage), next_action = null, next_action_at = null,
           dead_reason = case when p_belt = 'dead' then coalesce(nullif(p_payload->>'reason', ''), dead_reason, p_event) else dead_reason end
     where id = p_lead_id;
    insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
    values (p_lead_id, p_event, from_belt, p_belt, 0, p_payload, p_now, public.belt_actor(p_by));
    return jsonb_build_object('ok', true, 'belt', p_belt, 'step', 0, 'next_stop_at', null);
  end if;
  -- find the first step from here whose stop still lies ahead (a reminder after 8:30 is skipped)
  loop
    select * into st from public.belt_stop_for(l, p_belt, step, p_now);
    exit when found or step > maxs;
    step := step + 1;
    guard := guard + 1;
    exit when guard > 8;
  end loop;
  if st is null or st.at is null then
    return public.belt_enter(p_lead_id, p_belt, maxs + 1, p_event, p_payload, p_by, p_now);
  end if;
  st_stage := public.belt_stage(p_belt);
  -- the caller step goes to the caller the card is locked to (0148, 0157), else Adil on weekends and Thalia on weekdays
  who_person := case st.who when 'thalia_call' then coalesce((select lk.locked_to from public.leads lk where lk.id = p_lead_id and lk.locked_to in ('thalia', 'adil')),
                                                     (case when extract(isodow from st.at at time zone 'America/Chicago') >= 6
                                                     then 'adil' else 'thalia' end)::public.team_person) when 'colin_call' then 'colin' when 'colin_visit' then 'colin'
                            when 'draft_text' then 'colin' else null end;
  nxt := case st.who when 'auto_text' then 'Text goes on its own' when 'draft_text' then 'Draft text for Colin''s tap'
                     when 'thalia_call' then initcap(coalesce(who_person::text, 'thalia')) || ' calls' when 'colin_call' then 'Colin calls' else 'Colin visits' end;
  update public.leads set belt = p_belt, belt_step = step, belt_round = round,
         belt_entered_at = case when from_belt is distinct from p_belt then p_now else coalesce(belt_entered_at, p_now) end,
         next_stop_at = st.at, next_stop_who = st.who, next_stop_say = st.say,
         unanswered_count = case when from_belt is distinct from p_belt then 0 else unanswered_count end,
         stage = case when st_stage is null then stage
                      when stage in ('under_contract', 'closed_won') and p_belt not in ('dead', 'dnc') then stage
                      -- a text in never moves a person's stage; it only lifts an automatic stage to Replied / Qualifying
                      when p_event in ('inbound_text', 'hot_reply', 'human_text', 'cold_text') and p_belt in ('yes_unbooked', 'replied_quiet', 'questions_quiet', 'call_booked')
                           then (case when stage in ('postcard_mailed', 'opener_queued', 'opener_sent', 'mail_only', 'data_fix')
                                      then (case p_belt when 'questions_quiet' then 'ai_qualifying' else 'reply_received' end)::public.lead_stage
                                      else stage end)
                      else st_stage end,
         next_action = case p_belt when 'visit_booked' then 'Walk-through' when 'call_booked' then 'Call booked' else nxt end,
         next_action_at = case when p_belt in ('visit_booked', 'call_booked') then coalesce(l.named_date, st.at) else st.at end,
         assigned_to = coalesce(who_person, assigned_to)
   where id = p_lead_id;
  insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
  values (p_lead_id, p_event, from_belt, p_belt, step,
          p_payload || jsonb_build_object('next_stop_at', st.at, 'next_stop_who', st.who, 'say', st.say), p_now, public.belt_actor(p_by));
  -- a person's stop (or a draft waiting for a tap) is a task on Today, keyed so a re-schedule updates it
  if st.who <> 'auto_text' then
    key := format('belt:%s:%s:%s:%s', p_lead_id, p_belt, round, step);
    select string_agg(format('%s (%s)', public.belt_fmt_phone(c.value_normalized), coalesce(c.line_type, 'phone')), ', ' order by c.created_at)
      into phones from public.contacts c
     where c.lead_id = p_lead_id and c.kind = 'phone' and c.status = 'ok' and not c.suppressed and not c.dnc_app and c.value_normalized ~ '^[0-9]{10}$';
    title := format('%s: stop %s of %s', r.label, step, maxs);
    note := case when st.who = 'draft_text' then 'Tap the draft on Approve. ' else '' end
         || 'Say: ' || st.say || coalesce('. Call ' || phones, '')
         || case when l.elderly_or_ill or l.grief then '. Older, ill or grieving: family on the line, their pace, no deadlines' else '' end;
    tkind := case st.who when 'colin_visit' then 'visit' when 'draft_text' then 'text' else 'call' end;
    insert into public.tasks (lead_id, due_at, kind, owner, note, title, source, source_key, phone10, created_by)
    values (p_lead_id, st.at, tkind, who_person, note, title, 'belt', key, public.belt_phone(p_lead_id), null)
    on conflict (source_key) do update set due_at = excluded.due_at, note = excluded.note, title = excluded.title,
      owner = excluded.owner, done_at = null;
  end if;
  if p_belt in ('call_booked', 'visit_booked') and step = 1 then
    select * into l from public.leads where id = p_lead_id;
    select * into st from public.belt_stop_for(l, p_belt, 2, p_now);
    if found and st.at is not null then
      who_person := case st.who when 'thalia_call' then coalesce((select lk.locked_to from public.leads lk where lk.id = p_lead_id and lk.locked_to in ('thalia', 'adil')),
                                                     (case when extract(isodow from st.at at time zone 'America/Chicago') >= 6
                                                     then 'adil' else 'thalia' end)::public.team_person) else 'colin' end;
      insert into public.tasks (lead_id, due_at, kind, owner, note, title, source, source_key, phone10, created_by)
      values (p_lead_id, st.at, case when st.who = 'colin_visit' then 'visit' else 'call' end, who_person,
              'Say: ' || st.say || coalesce('. Call ' || phones, ''), format('%s: stop 2 of %s', r.label, maxs), 'belt',
              format('belt:%s:%s:%s:%s', p_lead_id, p_belt, round, 2), public.belt_phone(p_lead_id), null)
      on conflict (source_key) do update set due_at = excluded.due_at, note = excluded.note, title = excluded.title, owner = excluded.owner, done_at = null;
    end if;
  end if;
  return jsonb_build_object('ok', true, 'belt', p_belt, 'step', step, 'next_stop_at', st.at, 'next_stop_who', st.who, 'say', st.say);
end $$;
