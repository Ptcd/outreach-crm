-- 0266: a yes gets a comp, and the caller gets the number.
--
-- Colin, 2026-11-20. What a caller was told when a seller said yes: "Said yes, not booked. Say: You asked for a call
-- about 1208 Racine Street." No value, no number. In four weeks 138 owners said yes and 6 had a number worked out.
-- Asked whether the server should put a number on the card from the comps on file: "Muse can comp and have it done
-- I think in under 10 min. Without that I doubt we can trust anything else."
--
-- So the number is Muse's comp, and it is asked for the moment the yes lands:
--   1. A card that goes to "Said yes, not booked" opens an offer on the offer path (trigger yes_to_selling) with the
--      comp due in 10 minutes (text_offer_rules.yes_comp_minutes). If an offer is already open with no value, its
--      comp is pulled in to the same 10 minutes.
--   2. On that offer the comp comes FIRST: Muse is told on its next tool call, and the step is late after 10 minutes.
--      The condition question by text comes after.
--   3. The caller sees the number on the card and on the call task (yes_call_sheet): while Muse is working, when it
--      is promised by; when the comp is in, the value fixed up and an opening and top number for light, medium and
--      heavy repairs (the rule's 65% and 70%, repairs by the square foot); when the seller has said what is wrong, the
--      one opening and top for that. Fewer sold comps than the rule needs, or a comp that is late: "call for the
--      story and their number, and give none".
-- Nothing here texts a seller or OKs a figure for a text: that is the offer path's own gate, unchanged. A caller
-- phoning the seller takes the thread, as before, and Muse stands back.

alter table public.text_offer_rules add column if not exists yes_comp_minutes integer not null default 10;

-- ---------------------------------------------------------------- the number for the call, in words
create or replace function public.yes_call_sheet(p_lead_id uuid, p_now timestamptz default now()) returns text
language plpgsql stable security definer set search_path = public as $fn$
declare o public.text_offers; r public.text_offer_rules; n integer; lines text[] := '{}'; lvl text; x jsonb; due timestamptz; word text;
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
  word := 'Value fixed up ' || public.text_money(o.arv) || ' (Muse, ' || n::text || ' sold comps).';
  if o.lao is not null then
    return 'NUMBER: ' || word || ' Open at ' || public.text_money(o.lao) || ', top ' || public.text_money(o.mao)
           || coalesce(' (repairs ' || public.text_money(o.repairs) || ': ' || o.repairs_basis || ')', '') || '.';
  end if;
  if coalesce(o.sqft, 0) <= 0 then
    return 'NUMBER: ' || word || ' No size on file, so no repair figure yet: get the condition and the size on the call, and give no number.';
  end if;
  foreach lvl in array array['light', 'medium', 'heavy'] loop
    x := public.text_offer_numbers(o.arv, o.sqft, null, lvl);
    lines := lines || case when coalesce((x->>'ok')::boolean, false)
      then initcap(lvl) || ' repairs: open ' || public.text_money((x->>'lao')::numeric) || ', top ' || public.text_money((x->>'mao')::numeric)
      else initcap(lvl) || ' repairs: no offer (the repairs eat it)' end;
  end loop;
  return 'NUMBER: ' || word || ' Ask what shape it is in, then use that row. ' || array_to_string(lines, '. ') || '.';
end $fn$;
-- not for a login to call: a caller reads it through card_brief, which checks the card is theirs (0250)
revoke all on function public.yes_call_sheet(uuid, timestamptz) from public, anon, authenticated;
grant execute on function public.yes_call_sheet(uuid, timestamptz) to service_role;

-- the sheet as the first line of the caller's open "Said yes" call task; the task's own words follow it
create or replace function public.yes_sheet_to_task(p_lead_id uuid) returns integer
language plpgsql security definer set search_path = public as $fn$
declare sheet text := public.yes_call_sheet(p_lead_id); n integer;
begin
  update public.tasks t
     set note = case when sheet is null then regexp_replace(coalesce(t.note, ''), '^NUMBER: [^\n]*\n', '')
                     else sheet || E'\n' || regexp_replace(coalesce(t.note, ''), '^NUMBER: [^\n]*\n', '') end,
         updated_at = now()
   where t.lead_id = p_lead_id and t.done_at is null and t.source = 'belt' and t.title like 'Said yes%'
     and t.note is distinct from (case when sheet is null then regexp_replace(coalesce(t.note, ''), '^NUMBER: [^\n]*\n', '')
                                       else sheet || E'\n' || regexp_replace(coalesce(t.note, ''), '^NUMBER: [^\n]*\n', '') end);
  get diagnostics n = row_count;
  return n;
end $fn$;
revoke all on function public.yes_sheet_to_task(uuid) from public, anon, authenticated;
grant execute on function public.yes_sheet_to_task(uuid) to service_role;

-- ---------------------------------------------------------------- a yes opens the comp
create or replace function public.yes_opens_comp() returns trigger
language plpgsql security definer set search_path = public as $fn$
declare r public.text_offer_rules; o public.text_offers; words text; ph text; due timestamptz;
begin
  begin
    if new.belt is distinct from 'yes_unbooked' or old.belt is not distinct from 'yes_unbooked' then return null; end if;
    if new.stage::text in ('dnc', 'dead', 'under_contract', 'closed_won') then return null; end if;
    select * into r from public.text_offer_rules where id = 1;
    due := now() + make_interval(mins => coalesce(r.yes_comp_minutes, 10));
    select * into o from public.text_offers where lead_id = new.id and status = 'open' order by opened_at desc limit 1;
    if found then
      -- an offer is already open (they asked for a number earlier): with no value yet, its comp is wanted now too
      if o.arv is null and (o.comp_due_at is null or o.comp_due_at > due) then
        update public.text_offers set comp_due_at = due, trigger = 'yes_to_selling' where id = o.id;
      end if;
    else
      select t.body, t.from10 into words, ph from public.twilio_inbound t
       where t.lead_id = new.id and not coalesce(t.is_opt_out, false) order by t.received_at desc limit 1;
      insert into public.text_offers (lead_id, opened_by, trigger, trigger_text, phone, comp_due_at)
      values (new.id, 'system', 'yes_to_selling', left(coalesce(nullif(btrim(words), ''), 'said yes'), 600), ph, due);
    end if;
    perform public.yes_sheet_to_task(new.id);
  exception when others then
    null;                                          -- a card's move to "said yes" is never lost to this
  end;
  return null;
end $fn$;
drop trigger if exists leads_yes_opens_comp on public.leads;
create trigger leads_yes_opens_comp after update of belt on public.leads
  for each row execute function public.yes_opens_comp();

-- the caller's call task is written by the belt, before or after the offer opens: either way it starts with the sheet
create or replace function public.yes_task_gets_sheet() returns trigger
language plpgsql security definer set search_path = public as $fn$
declare sheet text;
begin
  if new.lead_id is null or new.source is distinct from 'belt' or coalesce(new.title, '') not like 'Said yes%' then return new; end if;
  begin
    sheet := public.yes_call_sheet(new.lead_id);
    if sheet is not null and coalesce(new.note, '') not like 'NUMBER: %' then new.note := sheet || E'\n' || coalesce(new.note, ''); end if;
  exception when others then
    null;
  end;
  return new;
end $fn$;
drop trigger if exists tasks_yes_gets_sheet on public.tasks;
create trigger tasks_yes_gets_sheet before insert on public.tasks
  for each row execute function public.yes_task_gets_sheet();

-- when the comp lands or changes, the task says so
create or replace function public.yes_offer_refreshes_task() returns trigger
language plpgsql security definer set search_path = public as $fn$
begin
  begin
    perform public.yes_sheet_to_task(new.lead_id);
  exception when others then
    null;
  end;
  return null;
end $fn$;
drop trigger if exists text_offers_yes_sheet on public.text_offers;
create trigger text_offers_yes_sheet after update of arv, comps, sqft, lao, mao, repairs, status, comp_due_at on public.text_offers
  for each row execute function public.yes_offer_refreshes_task();

-- ---------------------------------------------------------------- the offer's next step (recreated from live): on a yes, the comp first
CREATE OR REPLACE FUNCTION public.text_offer_view(o text_offers, p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
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
                  || ' minutes: sold comps near the house, then offer_update {arv, arv_basis, comps, sqft}. Send sqft: the caller gets an opening and a top number for light, medium and heavy repairs, worked from your value and the size, and has nothing to say without it. Fewer than '
                  || r.min_comps::text || ' sold comps is not a set to offer from: close as no_comp_set and the caller is told to give no number. Ask the condition question by text AFTER the comp is in, not before.' end;
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
end $fn$;

-- ---------------------------------------------------------------- the card's brief (recreated from live): the number for the call
CREATE OR REPLACE FUNCTION public.card_brief(p_lead_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
declare l public.leads; me team_person; res jsonb;
begin
  perform public.card_guard(p_lead_id);   -- 0250: a card is its caller's
  if not public.is_team() then raise exception 'team only'; end if;
  me := public.wpie_person();
  select * into l from public.leads where id = p_lead_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card'); end if;
  select jsonb_build_object(
    'ok', true,
    'lane', l.lane,
    'say_next', l.say_next,
    -- 0266: the number for the call, from Muse's comp, the moment a seller says yes
    'call_sheet', public.yes_call_sheet(l.id),
    -- 0254: a card under contract is off the belt; what is next is the closing track's next step
    'next_plain', case when l.stage = 'under_contract' then public.closing_plain(l.id)
                       when l.stage = 'closed_won' then 'Closed. Nothing more to do on this card.'
                       else public.next_plain(l.belt, l.next_stop_at, l.next_stop_who, l.next_stop_say, l.named_date, l.named_event, me,
                     (select tm.display_name from public.team_members tm where tm.person = public.card_caller(l.id))) end,
    'mine_next', (select jsonb_build_object('task_id', t.id, 'due_at', t.due_at, 'kind', t.kind, 'note', t.note, 'owner', t.owner, 'source', t.source)
                    from public.tasks t where t.lead_id = l.id and t.done_at is null and t.kind in ('call', 'callback', 'visit', 'text', 'other')
                     and coalesce(t.source, '') <> 'closing'   -- 0254: the closing step is said once, in next_plain
                   order by t.due_at nulls last limit 1),
    'why', jsonb_build_object(
       'reasons', l.reasons_to_sell,
       'motivation', (select lm.lines from public.lead_motivation lm where lm.lead_id = l.id),
       'last_words', (select left(mi.body, 240) from public.messages mi where mi.lead_id = l.id and mi.direction = 'in' and mi.channel = 'sms' order by mi.sent_at desc limit 1),
       'last_call', (select left(regexp_replace(coalesce(lc.body, ''), '^Call \([^)]*\) from \d+:\s*', ''), 240) from public.messages lc
                       where lc.lead_id = l.id and lc.channel = 'call' and lc.status is distinct from 'inbound_missed' order by lc.sent_at desc limit 1),
       'promise', (select pm.note from public.tasks pm where pm.lead_id = l.id and pm.source = 'mine' and pm.done_at is null order by pm.due_at limit 1)),
    'touches', (select coalesce(jsonb_agg(x order by x.at desc), '[]'::jsonb) from (
                  select m.sent_at at, m.channel, m.direction, coalesce(m.status, '') status, left(m.body, 140) body
                    from public.messages m where m.lead_id = l.id and m.channel in ('call', 'sms', 'note') order by m.sent_at desc limit 3) x),
    'touches_total', (select count(*) from public.messages m where m.lead_id = l.id and m.channel in ('call', 'sms')),
    'planned', (select coalesce(jsonb_agg(y order by y.at), '[]'::jsonb) from (
                  select t.due_at at, t.kind what, coalesce(t.title, t.note) words, t.owner::text who from public.tasks t
                   where t.lead_id = l.id and t.done_at is null and t.due_at is not null and t.kind <> 'nudge'
                  union all
                  select l.next_stop_at, 'belt', l.next_stop_say, l.next_stop_who where l.next_stop_at is not null and l.next_stop_at > now()
                  order by 1 limit 2) y),
    'rest', case when l.parked_at is not null then jsonb_build_object('until', l.rest_until, 'why', l.parked_why, 'by_colin', l.rest_until is null) end,
    'nudges', (select coalesce(jsonb_agg(jsonb_build_object('task_id', n.id, 'from', n.title, 'text', n.note, 'at', n.created_at, 'to', n.owner) order by n.created_at desc), '[]'::jsonb)
                 from public.tasks n where n.lead_id = l.id and n.kind = 'nudge' and n.done_at is null),
    'locked_to', l.locked_to, 'belt', l.belt, 'stage', l.stage)
  into res;
  return res;
end $fn$;

-- ---------------------------------------------------------------- the cards already sitting on a yes
-- 14 cards were on "Said yes, not booked" with no comp when this was built. Each gets its comp asked for, ten minutes
-- apart so Muse is handed a queue and not fourteen late jobs at once: Tyler's first (he works alone on 2026-11-21),
-- the newest yes first.
do $$
declare c record; k integer := 0; r public.text_offer_rules; words text; ph text;
begin
  select * into r from public.text_offer_rules where id = 1;
  for c in
    select l.id from public.leads l
     where l.belt = 'yes_unbooked' and not public.card_is_closed(l.stage) and l.stage::text not in ('under_contract')
       and l.owner_name not ilike 'TEST %'
       and not exists (select 1 from public.text_offers o where o.lead_id = l.id and o.status = 'open')
     order by (public.card_caller(l.id) is distinct from 'adil'), l.updated_at desc
  loop
    k := k + 1;
    select t.body, t.from10 into words, ph from public.twilio_inbound t
     where t.lead_id = c.id and not coalesce(t.is_opt_out, false) order by t.received_at desc limit 1;
    insert into public.text_offers (lead_id, opened_by, trigger, trigger_text, phone, comp_due_at)
    values (c.id, 'system', 'yes_to_selling', left(coalesce(nullif(btrim(words), ''), 'said yes'), 600), ph,
            now() + make_interval(mins => coalesce(r.yes_comp_minutes, 10) * k));
    perform public.yes_sheet_to_task(c.id);
  end loop;
  raise notice 'comps asked for % card(s) already on a yes', k;
end $$;

