-- 0281: comps, angles and a number on any card, by whichever agent claims it first. Colin 2026-11-22: "My goal is
-- for grok to be able to set those numbers and then also fully realize the situation, like if the sale is coming up
-- soon it's a need. Estate owes more than house is worth but mortgage is much lower then price just has to clear
-- mortgage and fees. Mortgage high then no go deal", and the button a caller presses for it.
--
--   * card_work_ask (the card's button): opens a comp that is never texted to the seller (trigger caller_asked:
--     comps, then the prices for the call, then it is the caller's) and asks for the story, the angles and the script,
--     due in 30 minutes. A seller's own yes later turns it into the yes path, keeping the comps.
--   * live_work lists those cards to Muse AND Grok (attention.live for both). agent_work_claim: the first to claim a
--     card has it for 45 minutes; the other is told who has it.
--   * call_brief_set takes angles [{angle, why}] (what we can give that is not money, ranked) and situation.
--   * agent_deal_price: an agent's opening and top on the deal sheet. Refused without a value on the card, above the
--     sheet's ceiling (the rule's most), or under what follows the house (a number that cannot clear the mortgage,
--     tax and liens cannot close: pass on it instead). Claims that do not follow the house (an estate's creditors) do
--     not count, which is the Howard St case. Colin's own number is still above it. Callers see the sheet only when
--     deal_sheet_mode is 'on'.

alter table public.text_offers drop constraint if exists text_offers_trigger_check;
alter table public.text_offers add constraint text_offers_trigger_check
  check (trigger = any (array['asked_number', 'yes_to_selling', 'other', 'caller_asked']));

alter table public.call_briefs add column if not exists angles jsonb not null default '[]'::jsonb;
alter table public.call_briefs add column if not exists situation text;
alter table public.call_briefs add column if not exists claimed_by text;
alter table public.call_briefs add column if not exists claimed_at timestamptz;

alter table public.deal_sheets add column if not exists agent_open numeric;
alter table public.deal_sheets add column if not exists agent_top numeric;
alter table public.deal_sheets add column if not exists agent_note text;
alter table public.deal_sheets add column if not exists agent_by text;
alter table public.deal_sheets add column if not exists agent_at timestamptz;


-- ---------------------------------------------------------------- a caller's comp becomes the seller's own when they ask
CREATE OR REPLACE FUNCTION public.agent_offer_open(p_lead_id uuid, p_trigger text, p_words text, p_phone text, p_agent text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare l public.leads; o public.text_offers; r public.text_offer_rules; d text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10);
begin
  select * into r from public.text_offer_rules where id = 1;
  select * into l from public.leads where id = p_lead_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card'); end if;
  if l.stage::text in ('dnc', 'dead') then return jsonb_build_object('ok', false, 'reason', 'the card is ' || l.stage::text || ': no offer'); end if;
  select * into o from public.text_offers where lead_id = p_lead_id and status = 'open';
  if found then
    -- 0281: a comp a caller asked for becomes the seller's own yes or number ask when one comes in, keeping its comps
    if o.trigger = 'caller_asked' and p_trigger in ('yes_to_selling', 'asked_number') then
      update public.text_offers set trigger = p_trigger, trigger_text = coalesce(nullif(btrim(p_words), ''), trigger_text), updated_at = now()
       where id = o.id returning * into o;
      return jsonb_build_object('ok', true, 'upgraded', true, 'offer', public.agent_offer_row(o));
    end if;
    return jsonb_build_object('ok', true, 'already', true, 'offer', public.agent_offer_row(o));
  end if;
  if coalesce(btrim(p_words), '') = '' then return jsonb_build_object('ok', false, 'reason', 'say what the seller wrote that opens this (words)'); end if;
  insert into public.text_offers (lead_id, opened_by, trigger, trigger_text, phone, comp_due_at)
  values (p_lead_id, coalesce(nullif(lower(p_agent), ''), 'muse'),
          case when p_trigger in ('asked_number', 'yes_to_selling', 'other', 'caller_asked') then p_trigger else 'yes_to_selling' end,
          btrim(p_words), nullif(d, ''), public.text_offer_due(now(), r.comp_hours))
  returning * into o;
  return jsonb_build_object('ok', true, 'offer', public.agent_offer_row(o));
end $function$;

-- ---------------------------------------------------------------- a caller's comp: comps, prices, then the caller's
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
  elsif o.trigger in ('yes_to_selling', 'caller_asked') and (o.arv is null or n < r.min_comps) then
    -- 0266: they said yes and a caller is being told to phone them. The comp comes first and in minutes, not after
    -- the condition question: the caller's opening and top number are worked from it.
    step := 'comp'; who := 'muse'; due := coalesce(o.comp_due_at, o.opened_at + make_interval(mins => r.yes_comp_minutes)); gate := 'a comp for the caller';
    say := case when o.arv is not null then 'Only ' || n::text || ' sold comp(s) with a price and a date: ' || r.min_comps::text
                  || ' are needed. Add them now, or close the offer as no_comp_set: the caller is told to give no number.'
                else 'They said YES and a caller is being told to phone them. Comp it NOW, inside ' || r.yes_comp_minutes::text
                  || ' minutes: sold comps near the house, then offer_update {arv, arv_basis, comps, sqft}. Send sqft with it. The caller has no number until your street look and your prices are on the card too: that is the next step, or send street and call_prices in the same offer_update. Fewer than '
                  || r.min_comps::text || ' sold comps is not a set to offer from: close as no_comp_set and the caller is told to give no number. Ask the condition question by text AFTER the comp is in, not before.' end;
  elsif o.trigger in ('yes_to_selling', 'caller_asked') and o.call_prices is null and o.ok_at is null then
    -- 0268 (Colin 2026-11-21: "I want muse to do it not the server"): the caller's prices are Muse's, worked from a
    -- look at the house, with what shows from the street in every row
    step := 'call_prices'; who := 'muse'; due := coalesce(o.valued_at, o.opened_at) + make_interval(mins => r.yes_comp_minutes); gate := 'the prices for the call';
    say := 'The value is in. Now YOUR prices for the caller, not the server''s. Look at the house on Street View: roof, siding, windows, porch, garage, yard, signs nobody lives there. Then offer_update {street: {image_date, seen: [{item, cost, note}], notes}, call_prices: [{inside, repairs, repairs_basis, open, top}, ...]}: two to five rows, one for each shape the inside could be in (for example "inside light", "inside medium", "inside heavy"), each row''s repairs holding everything in street.seen plus the inside work at that level. A roof you can see is in every row. open is '
           || round(r.lao_pct * 100)::text || '% of the value minus that row''s repairs and top is ' || round(r.mao_pct * 100)::text
           || '%, to the nearest $' || r.round_to::text || '; a row where the repairs eat it is {inside, repairs, repairs_basis, no_offer: true}. No Street View picture of the house: street {no_view: true, why}. Until this is in, the caller is told to give no number.';
  elsif o.trigger = 'caller_asked' then
    -- 0281: a caller asked for the comps from the card. Nothing on this offer is ever texted to the seller: when the
    -- comps and the prices are in, it is the caller's (and the deal sheet's)
    step := 'caller_has_it'; who := 'caller'; gate := 'asked from the card';
    say := 'A caller asked for this from the card: the comps and the prices are on it. Nothing here is texted to the seller.';
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

-- ---------------------------------------------------------------- live work lists caller asks, and who has each card
CREATE OR REPLACE FUNCTION public.agent_live_work(p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare cards jsonb; n integer; n_late integer; body text;
begin
  with y as (
    select o.lead_id, o.opened_at, o.trigger_text, public.text_offer_view(o, p_now) as v
      from public.text_offers o where o.status = 'open' and o.trigger in ('yes_to_selling', 'caller_asked')
  ), w as (
    select l.id as lead_id, l.owner_name, l.property_address, l.municipality, l.county,
           coalesce(y.opened_at, b.wanted_at) as since, y.trigger_text,
           case when y.v->>'who' = 'muse' and y.v->>'step' in ('comp', 'call_prices') then y.v end as step,
           coalesce(b.status = 'wanted', false) as brief_wanted, b.due_at as brief_due,
           case when b.claimed_at > p_now - interval '45 minutes' then b.claimed_by end as claimed_by
      from public.leads l
      left join y on y.lead_id = l.id
      left join public.call_briefs b on b.lead_id = l.id
     where not public.card_is_closed(l.stage) and l.stage::text <> 'under_contract'
  ), t as (
    select w.*, (w.step is not null and coalesce((w.step->>'late')::boolean, false)) or (w.brief_wanted and w.brief_due < p_now) as late
      from w where w.step is not null or w.brief_wanted
  )
  select coalesce(jsonb_agg(jsonb_build_object('lead_id', t.lead_id, 'owner_name', t.owner_name, 'address', t.property_address, 'city', t.municipality,
           'county', t.county, 'caller', public.room_name(public.card_caller(t.lead_id)::text), 'said_yes_at', t.since, 'their_words', left(t.trigger_text, 300), 'late', t.late, 'claimed_by', t.claimed_by,
           'todo', (case when t.step is null then '[]'::jsonb
                         else jsonb_build_array(jsonb_build_object('what', t.step->>'step', 'due_at', t.step->>'due_at', 'late', (t.step->>'late')::boolean, 'do', t.step->>'say')) end)
                || (case when t.step->>'step' = 'comp'
                         then jsonb_build_array(jsonb_build_object('what', 'call_prices', 'do', 'Right after the comp: the street look and your prices (packet, part 2).')) else '[]'::jsonb end)
                || (case when not t.brief_wanted then '[]'::jsonb
                         else jsonb_build_array(jsonb_build_object('what', 'brief', 'due_at', t.brief_due, 'late', coalesce(t.brief_due < p_now, false),
                                'do', 'The story, what is owed, the unknowns and the script: call_briefs_wanted has this card''s records, then call_brief_set.')) end))
           order by t.since desc nulls last), '[]'::jsonb), count(*), count(*) filter (where t.late)
    into cards, n, n_late
    from (select * from t order by since desc nulls last limit 15) t;
  if n = 0 then
    return jsonb_build_object('live', 0, 'say', 'Nothing live: no seller who said yes is waiting on you. Carry on with this run.');
  end if;
  select p.body into body from public.live_work_packet p where p.id = 1;
  return jsonb_build_object('live', n, 'late', n_late,
    'say', n::text || ' seller' || case when n = 1 then '' else 's' end || ' said yes and ' || case when n = 1 then 'is' else 'are' end
           || ' waiting on you' || case when n_late > 0 then ' (' || n_late::text || ' late)' else '' end
           || ': a caller cannot give a number until you are done. Call live_work, read the packet, and work the cards before anything else in this run, the newest yes first.',
    'packet', body, 'cards', cards);
end $function$;

-- ---------------------------------------------------------------- Grok is told too
CREATE OR REPLACE FUNCTION public.agent_attention(p_agent text, p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  who text := case when lower(coalesce(p_agent, '')) like 'muse 2%' then 'muse 2' when lower(coalesce(p_agent, '')) like 'muse%' then 'muse' when lower(coalesce(p_agent, '')) like 'grok%' then 'grok' else lower(coalesce(p_agent, '')) end;
  last_read timestamptz; unread integer := 0; latest text; steps jsonb := '[]'::jsonb; n_late integer := 0; out jsonb := '{}'::jsonb;
  d date := (p_now at time zone 'America/Chicago')::date;
  is_sunday boolean := extract(isodow from (p_now at time zone 'America/Chicago')::date) = 7;
  c public.campaign_control; opened boolean := false; n_replies integer := 0; oldest timestamptz; behind jsonb; room jsonb; n_briefs integer := 0; n_briefs_late integer := 0; brief_due timestamptz; live jsonb;
begin
  -- the desk: posts for this agent (or everyone) by someone else since it last read the desk
  select max(c2.at) into last_read from public.agent_calls c2 join public.agent_keys k on k.id = c2.key_id
   where lower(k.name) = lower(p_agent) and c2.tool = 'desk_inbox' and c2.ok;
  select count(*), (array_agg(m.topic order by m.id desc))[1] into unread, latest from public.desk_messages m
   where m.for_whom in (who, 'all') and m.author <> who and m.at > coalesce(last_read, p_now - interval '2 days') and m.at > p_now - interval '7 days';
  if unread > 0 then
    out := out || jsonb_build_object('desk', unread::text || ' post' || case when unread = 1 then '' else 's' end || ' for you on the desk since you last read it'
      || coalesce(' (' || to_char(last_read at time zone 'America/Chicago', 'Dy HH12:MI AM') || ' Central)', '') || ', the newest: "' || left(coalesce(latest, ''), 140) || '". Read desk_inbox now.');
  end if;
  -- the room (0259): lines from the desk, the other agent or Colin since this agent last read it
  if who in ('muse', 'muse 2', 'grok') then
    room := public.room_unread(who);
    if (room ->> 'unread')::int > 0 then
      out := out || jsonb_build_object('room', (room ->> 'unread') || case when (room ->> 'unread')::int = 1 then ' new line' else ' new lines' end
        || ' in the room' || case when (room ->> 'for_you')::int > 0 then ' (' || (room ->> 'for_you') || ' to you by name)' else '' end
        || ', the newest from ' || coalesce(room ->> 'latest_by', '?') || ': "' || left(coalesce(room ->> 'latest', ''), 160) || '". Read chat_read now and answer with chat_post.');
    end if;
  end if;
  -- a seller who said yes and is waiting on this agent (0269): the first thing every run does
  if who in ('muse', 'grok') then   -- 0281: Grok takes these too, whoever claims first
    live := public.agent_live_work(p_now);
    if coalesce((live->>'live')::int, 0) > 0 then
      out := out || jsonb_build_object('live', live->>'say');
    end if;
  end if;
  -- the story and script before a call (0267): cards a caller is about to phone with nothing written yet
  if who = 'muse' then
    select count(*), count(*) filter (where b.due_at < p_now), min(b.due_at) into n_briefs, n_briefs_late, brief_due
      from public.call_briefs b where b.status = 'wanted';
    if n_briefs > 0 then
      out := out || jsonb_build_object('briefs', n_briefs::text || ' card' || case when n_briefs = 1 then '' else 's' end
        || ' about to be called need the story and a script' || case when n_briefs_late > 0 then ' (' || n_briefs_late::text || ' late)' else '' end
        || ', the first due ' || to_char(brief_due at time zone 'America/Chicago', 'Dy FMHH12:MI AM')
        || ' Central. Read call_briefs_wanted, work out what is going on with each house and what the seller has to clear, and write it with call_brief_set.');
    end if;
  end if;
  if who = 'muse' then
    -- a Sunday that was opened (0240) says so here: the rules text says "never on Sunday" and nothing else tells the agent
    select * into c from public.campaign_control where id = 1;
    opened := is_sunday and (c.sunday_open_day is not distinct from d or not coalesce(c.sundays_closed, false));
    if opened and coalesce(c.sundays_closed, false) then
      out := out || jsonb_build_object('sunday', 'Today is a Sunday that was opened for texting'
        || coalesce(' by ' || nullif(trim(c.sunday_open_by), ''), '') || coalesce(' (' || nullif(trim(c.sunday_open_why), '') || ')', '')
        || '. For today only the "never on Sunday" rule is off: work the day''s list and answer replies (replies_waiting, send_reply) as on a weekday, 10 AM to 7 PM in the owner''s time zone, under every other rule as it stands. It closes itself on Monday; a Sunday with no line like this one is shut.');
    end if;
    -- people who wrote back and have had no answer (not on a Sunday that is shut: nothing sends then)
    if not is_sunday or opened then
      select count(*), min(r.received_at) into n_replies, oldest from public.replies_waiting_rows(1) r
       where r.received_at < p_now - interval '20 minutes';
      if n_replies > 0 then
        out := out || jsonb_build_object('replies', n_replies::text || case when n_replies = 1 then ' person' else ' people' end
          || ' texted back in the last day and ' || case when n_replies = 1 then 'has' else 'have' end || ' had no answer, the oldest since '
          || to_char(oldest at time zone 'America/Chicago', 'Dy HH12:MI AM') || ' Central. Read replies_waiting now and answer each with send_reply; one that needs no answer (a wrong number, a house already sold) is closed with mark_card.');
      end if;
    end if;
    -- the offer path: steps that are this agent's (only the texting agent has them)
    select coalesce(jsonb_agg(jsonb_build_object('offer_id', o.id, 'lead_id', o.lead_id, 'address', l.property_address, 'step', v.j->>'step',
             'due_at', v.j->>'due_at', 'late', (v.j->>'late')::boolean, 'do', v.j->>'say') order by v.j->>'due_at'), '[]'::jsonb),
           count(*) filter (where (v.j->>'late')::boolean)
      into steps, n_late
      from public.text_offers o join public.leads l on l.id = o.lead_id cross join lateral (select public.text_offer_view(o, p_now) as j) v
     where o.status = 'open' and v.j->>'who' = 'muse';
    if jsonb_array_length(steps) > 0 then
      out := out || jsonb_build_object('offers', jsonb_build_object(
        'say', jsonb_array_length(steps)::text || ' seller' || case when jsonb_array_length(steps) = 1 then '' else 's' end || ' asked for a number and the next step is yours'
               || case when n_late > 0 then ' (' || n_late::text || ' late)' else '' end
               || '. Each row says what to do; record it with offer_update, and read offer_worklist for the whole list. If those tools are not in your tool list, list the tools again or start a new session: they were added on 2026-11-13. The how is in texting_rules ("The offer by text") and desk post 254.',
        'steps', steps));
    end if;
    -- the Research Board (0248): jobs with no tick for two whole weeks
    select public.research_behind(p_now) into behind;
    if jsonb_array_length(behind) > 0 then
      out := out || jsonb_build_object('research', jsonb_build_object(
        'say', jsonb_array_length(behind)::text || ' research job' || case when jsonb_array_length(behind) = 1 then ' has' else 's have' end
               || ' had no tick on the Research Board for more than two weeks. The board is weekly now: run each one end to end (pull, verification, cards in WPIE) and tick the week with research_board_set (job, done true, a note saying what ran; leave week out for this week). A job that cannot run gets a status saying what blocks it, not a tick. Colin is told about this list every Monday.',
        'behind', behind));
    end if;
  end if;
  return case when out = '{}'::jsonb then null else out end;
end $function$;

-- ---------------------------------------------------------------- the brief takes angles and the situation
CREATE OR REPLACE FUNCTION public.agent_call_brief_set(p jsonb, p_agent text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare lid uuid; l public.leads; b public.call_briefs; e jsonb; owed jsonb := '[]'::jsonb; amt numeric; kind text; f text; i integer := 0; v integer;
        story text := btrim(coalesce(p->>'story', '')); script text := btrim(coalesce(p->>'script', '')); unk jsonb;
        angles jsonb := case when jsonb_typeof(p->'angles') = 'array' then p->'angles' else '[]'::jsonb end;
        situation text := nullif(btrim(coalesce(p->>'situation', '')), '');
begin
  begin lid := nullif(p->>'lead_id', '')::uuid; exception when others then lid := null; end;
  if lid is null then return jsonb_build_object('ok', false, 'reason', 'lead_id is the card'); end if;
  select * into l from public.leads where id = lid;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card'); end if;
  if length(story) < 60 then return jsonb_build_object('ok', false, 'reason', 'story: say what is going on with the house and the people, in plain words (a few sentences): who owns it, why they might sell, what is pressing'); end if;
  if length(script) < 300 then return jsonb_build_object('ok', false, 'reason', 'script: the words for the call, by section (open, what is owed, the house, who decides, money, and a close for each way the unknowns can turn out)'); end if;
  if length(script) > 20000 or length(story) > 6000 then return jsonb_build_object('ok', false, 'reason', 'too long: a story is 6,000 characters at most and a script 20,000'); end if;
  if jsonb_typeof(p->'owed') is distinct from 'array' then
    return jsonb_build_object('ok', false, 'reason', 'owed is a list, one row for each thing owed: kind, creditor, amount, basis, follows_house. Send an empty list only with nothing_owed_found: true');
  end if;
  if jsonb_array_length(p->'owed') = 0 and coalesce((p->>'nothing_owed_found')::boolean, false) is not true then
    return jsonb_build_object('ok', false, 'reason', 'owed is empty: if you looked (the mortgage records, the tax roll, the court) and found nothing owed, say nothing_owed_found: true and say where you looked in sources');
  end if;
  for e in select * from jsonb_array_elements(p->'owed') loop
    i := i + 1;
    kind := lower(btrim(coalesce(e->>'kind', '')));
    if kind not in ('mortgage', 'tax', 'judgment', 'lien', 'estate_claim', 'utility', 'hoa', 'other') then
      return jsonb_build_object('ok', false, 'reason', 'owed row ' || i || ': kind is mortgage, tax, judgment, lien, estate_claim, utility, hoa or other');
    end if;
    begin amt := nullif(regexp_replace(coalesce(e->>'amount', ''), '[^0-9.]', '', 'g'), '')::numeric; exception when others then amt := null; end;
    f := lower(btrim(coalesce(e->>'follows_house', 'unknown')));
    if f in ('true', 't') then f := 'yes'; elsif f in ('false', 'f') then f := 'no'; end if;
    if f not in ('yes', 'no', 'unknown') then
      return jsonb_build_object('ok', false, 'reason', 'owed row ' || i || ': follows_house is yes (a lien on the house: it is paid at closing), no (owed by the person or the estate but not secured on the house) or unknown');
    end if;
    if coalesce(btrim(e->>'basis'), '') = '' then
      return jsonb_build_object('ok', false, 'reason', 'owed row ' || i || ': basis says where the figure was read (the seller said it, the court record, the register of deeds, the tax roll) or that it is an estimate');
    end if;
    owed := owed || jsonb_build_object('kind', kind, 'creditor', nullif(btrim(coalesce(e->>'creditor', '')), ''), 'amount', amt, 'basis', btrim(e->>'basis'),
                                       'follows_house', f, 'note', nullif(btrim(coalesce(e->>'note', '')), ''));
  end loop;
  unk := case when jsonb_typeof(p->'unknowns') = 'array' then p->'unknowns' else '[]'::jsonb end;
  -- 0281: the angles, ranked: what we can give that is not money, and why it matters to this seller
  i := 0;
  for e in select * from jsonb_array_elements(angles) loop
    i := i + 1;
    if jsonb_typeof(e) <> 'object' or coalesce(btrim(e->>'angle'), '') = '' or coalesce(btrim(e->>'why'), '') = '' then
      return jsonb_build_object('ok', false, 'reason', 'angles row ' || i || ': {angle, why}: what we can give that is not money (close on their date, stay after closing, take what is left in it, pay the back taxes at closing, handle the estate papers, no showings, moving money) and why it matters to THIS seller');
    end if;
  end loop;
  select * into b from public.call_briefs where lead_id = lid for update;
  v := coalesce(b.version, 0) + 1;
  insert into public.call_briefs (lead_id, status, wanted_at, story, owed, unknowns, angles, situation, script, sources, to_clear, owed_total, written_by, written_at, version, updated_at)
  values (lid, 'ready', coalesce(b.wanted_at, now()), story, owed, unk, angles, situation, script, nullif(btrim(coalesce(p->>'sources', '')), ''),
          (select sum((x->>'amount')::numeric) from jsonb_array_elements(owed) x where x->>'follows_house' = 'yes'),
          (select sum((x->>'amount')::numeric) from jsonb_array_elements(owed) x),
          coalesce(nullif(btrim(p_agent), ''), 'agent'), now(), v, now())
  on conflict (lead_id) do update set status = 'ready', story = excluded.story, owed = excluded.owed, unknowns = excluded.unknowns, script = excluded.script,
         angles = excluded.angles, situation = excluded.situation, claimed_by = null, claimed_at = null,
         sources = excluded.sources, to_clear = excluded.to_clear, owed_total = excluded.owed_total, written_by = excluded.written_by,
         written_at = excluded.written_at, version = excluded.version, updated_at = now();
  insert into public.call_brief_versions (lead_id, version, story, owed, unknowns, script, sources, by)
  values (lid, v, story, owed, unk, script, nullif(btrim(coalesce(p->>'sources', '')), ''), coalesce(nullif(btrim(p_agent), ''), 'agent'));
  perform public.yes_sheet_to_task(lid);
  select * into b from public.call_briefs where lead_id = lid;
  return jsonb_build_object('ok', true, 'lead_id', lid, 'version', v, 'to_clear', b.to_clear, 'owed_total', b.owed_total, 'owed_line', public.call_brief_owed_line(b.owed));
end $function$;

-- ---------------------------------------------------------------- the sheet takes an agent's number
CREATE OR REPLACE FUNCTION public.deal_sheet_work(p_lead_id uuid, p_now timestamp with time zone DEFAULT now())
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
    'agent', jsonb_build_object('open', s.agent_open, 'top', s.agent_top, 'note', s.agent_note, 'by', s.agent_by, 'at', s.agent_at),
    'colin', jsonb_build_object('open', s.colin_open, 'top', s.colin_top, 'note', s.colin_note, 'pass', coalesce(s.colin_pass, false), 'at', s.colin_at,
               'asked_at', s.asked_at, 'asked_words', s.asked_words),
    'owner_name', l.owner_name, 'address', l.property_address, 'caller', public.card_caller(p_lead_id)::text);
end $function$;

-- ---------------------------------------------------------------- the card shows the angles and who is on it
CREATE OR REPLACE FUNCTION public.call_brief(p_lead_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare b public.call_briefs;
begin
  perform public.card_guard(p_lead_id);   -- 0250: a card is its caller's
  if not public.is_team() then raise exception 'team only'; end if;
  select * into b from public.call_briefs where lead_id = p_lead_id;
  if not found then return jsonb_build_object('status', 'none'); end if;
  return jsonb_build_object('status', b.status, 'wanted_at', b.wanted_at, 'wanted_by', b.wanted_by, 'due_at', b.due_at,
    'late', b.status = 'wanted' and b.due_at < now(),
    'story', b.story, 'owed', b.owed, 'owed_line', public.call_brief_owed_line(b.owed), 'to_clear', b.to_clear, 'owed_total', b.owed_total,
    'unknowns', b.unknowns, 'angles', coalesce(b.angles, '[]'::jsonb), 'situation', b.situation,
    'claimed_by', case when b.status = 'wanted' and b.claimed_at > now() - interval '45 minutes' then b.claimed_by end,
    'script', b.script, 'sources', b.sources, 'written_by', b.written_by, 'written_at', b.written_at, 'version', b.version);
end $function$;

-- ---------------------------------------------------------------- the agents read them back
CREATE OR REPLACE FUNCTION public.agent_call_brief_get(p_lead_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce((select jsonb_build_object('ok', true, 'lead_id', b.lead_id, 'status', b.status, 'due_at', b.due_at, 'story', b.story, 'owed', b.owed,
      'owed_line', public.call_brief_owed_line(b.owed), 'to_clear', b.to_clear, 'owed_total', b.owed_total, 'unknowns', b.unknowns, 'angles', b.angles, 'situation', b.situation, 'script', b.script,
      'sources', b.sources, 'written_by', b.written_by, 'written_at', b.written_at, 'version', b.version)
    from public.call_briefs b where b.lead_id = p_lead_id), jsonb_build_object('ok', true, 'status', 'none'))
$function$;

-- ---------------------------------------------------------------- the card's button
create or replace function public.card_work_ask(p_lead_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare who text; l public.leads; o public.text_offers; br jsonb; op jsonb;
begin
  perform public.card_guard(p_lead_id);   -- 0250: a card is its caller's
  if not public.is_team() then raise exception 'team only'; end if;
  select * into l from public.leads where id = p_lead_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card'); end if;
  if public.card_is_closed(l.stage) then return jsonb_build_object('ok', false, 'reason', 'the card is closed'); end if;
  select display_name into who from public.team_members where lower(email) = lower(auth.jwt() ->> 'email');
  who := coalesce(who, 'the team');
  -- a value from the last 30 days stands; otherwise a comp is opened that is never texted to the seller
  select * into o from public.text_offers t where t.lead_id = p_lead_id
     and (t.status = 'open' or (t.arv is not null and t.valued_at > now() - interval '30 days'))
   order by (t.status = 'open') desc, t.opened_at desc limit 1;
  if not found then
    op := public.agent_offer_open(p_lead_id, 'caller_asked', 'Asked from the card by ' || who, null, 'card');
  end if;
  br := public.call_brief_want(p_lead_id, who, 'comps, angles and a number, asked from the card', now() + interval '30 minutes');
  update public.call_briefs set claimed_by = null, claimed_at = null where lead_id = p_lead_id and status = 'wanted';
  return jsonb_build_object('ok', true, 'brief', br, 'comp', coalesce(op, jsonb_build_object('already', true)));
end $fn$;
revoke all on function public.card_work_ask(uuid) from public, anon;
grant execute on function public.card_work_ask(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------- first to claim has it
create or replace function public.agent_work_claim(p_lead_id uuid, p_agent text) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare b public.call_briefs; me text := lower(btrim(coalesce(p_agent, '')));
begin
  if me = '' then return jsonb_build_object('ok', false, 'reason', 'no agent'); end if;
  select * into b from public.call_briefs where lead_id = p_lead_id for update;
  if not found then
    insert into public.call_briefs (lead_id, status, wanted_by, wanted_why, due_at) values (p_lead_id, 'wanted', p_agent, 'claimed by an agent', now() + interval '30 minutes')
    returning * into b;
  end if;
  if b.claimed_by is not null and lower(b.claimed_by) <> me and b.claimed_at > now() - interval '45 minutes' then
    return jsonb_build_object('ok', false, 'reason', b.claimed_by || ' has this card since ' || to_char(b.claimed_at at time zone 'America/Chicago', 'HH12:MI AM')
             || ' (45 minutes from the claim). Take the next card.');
  end if;
  update public.call_briefs set claimed_by = p_agent, claimed_at = now(), updated_at = now() where lead_id = p_lead_id;
  return jsonb_build_object('ok', true, 'claimed_by', p_agent, 'until', now() + interval '45 minutes');
end $fn$;
revoke all on function public.agent_work_claim(uuid, text) from public, anon, authenticated;
grant execute on function public.agent_work_claim(uuid, text) to service_role;

-- ---------------------------------------------------------------- an agent's number, checked against the sheet
create or replace function public.agent_deal_price(p_lead_id uuid, p_open numeric, p_top numeric, p_note text, p_agent text) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare l public.leads; w jsonb; cap numeric; clear numeric; cc public.team_person := public.card_caller(p_lead_id); mode text;
        note text := btrim(coalesce(p_note, ''));
begin
  select * into l from public.leads where id = p_lead_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card'); end if;
  if public.card_is_closed(l.stage) then return jsonb_build_object('ok', false, 'reason', 'the card is closed'); end if;
  if p_open is null or p_open <= 0 then return jsonb_build_object('ok', false, 'reason', 'open: the first number to say, in dollars'); end if;
  if p_top is not null and p_top < p_open then return jsonb_build_object('ok', false, 'reason', 'top is at or above open'); end if;
  if length(note) < 80 then
    return jsonb_build_object('ok', false, 'reason', 'note: the situation in plain words, why this number (what is pressing and when, what follows the house and what does not, what they walk away with), at least a couple of sentences');
  end if;
  w := public.deal_sheet_work(p_lead_id);
  cap := nullif(w->>'ceiling', '')::numeric;
  clear := coalesce(nullif(w->'math'->>'to_clear', '')::numeric, 0);
  if cap is null then
    return jsonb_build_object('ok', false, 'reason', 'no value on the card yet: comp it first (offer_update: arv, comps, sqft, then the street look and call_prices), then price it');
  end if;
  if coalesce(p_top, p_open) > cap then
    return jsonb_build_object('ok', false, 'reason', 'over the most we pay: ' || public.text_money(cap) || ' (' || round((select mao_pct from public.text_offer_rules where id = 1) * 100)::text
             || '% of the value minus the repairs). Colin prices anything above it.');
  end if;
  if clear > 0 and coalesce(p_top, p_open) < clear then
    return jsonb_build_object('ok', false, 'reason', 'that cannot close: ' || public.text_money(clear) || ' follows the house (mortgage, tax, liens) and has to be paid at closing. '
             || 'If what follows the house is more than we can pay, it is not a deal: say so in the brief and leave the number off.');
  end if;
  perform public.deal_sheet_touch(p_lead_id);
  update public.deal_sheets set agent_open = p_open, agent_top = p_top, agent_note = note, agent_by = coalesce(nullif(btrim(p_agent), ''), 'agent'),
         agent_at = now(), updated_at = now()
   where lead_id = p_lead_id;
  select r.mode into mode from public.deal_sheet_rules r where r.id = 1;
  if mode = 'on' and cc is not null and cc::text <> 'colin' then
    insert into public.tasks (lead_id, due_at, kind, owner, note, source, title)
    values (p_lead_id, now(), 'nudge', cc, 'A number is on the card for ' || coalesce(l.property_address, 'this card') || ' (' || coalesce(nullif(btrim(p_agent), ''), 'an agent')
            || '). Open the Deal sheet and the brief before you call.', 'nudge', 'Number ready');
  end if;
  return jsonb_build_object('ok', true, 'open', p_open, 'top', p_top, 'ceiling', cap, 'to_clear', clear, 'shown_to_caller', mode = 'on');
end $fn$;
revoke all on function public.agent_deal_price(uuid, numeric, numeric, text, text) from public, anon, authenticated;
grant execute on function public.agent_deal_price(uuid, numeric, numeric, text, text) to service_role;
