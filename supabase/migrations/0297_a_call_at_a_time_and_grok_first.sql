-- 0297: a seller who opens up is offered a call at a time, the value comes from Grok in minutes, and an agent's reply
-- is checked for the things that lost threads.
--
-- Colin 2026-11-22: "Go review muses texting and tell me it's gonna get us deals". 125 threads, 262 replies in two
-- weeks: one contract (Howard St, where the seller asked to meet). In about 20 real openings Muse asked for a call
-- once. It was following its rules: "a seller who asks what we would pay, or says yes to selling, stays with you by
-- text" and "book a call with Colin only when the seller asks to talk to someone" (2026-11-13), and the booking tool
-- it was pointed at (open_slots, book_slot) needs a Google Calendar that is not connected. Colin, asked whether
-- offering a call at a time would be better: "Go and then tell muse how it should work now".
--
--   * caller_call_hours: when each caller takes booked calls (seeded from when they dialed these two weeks; Colin's
--     to change).
--   * agent_call_times(card): the card's caller, whether they are on now, and two or three times to offer, said in
--     the seller's time zone. agent_book_call(card, time): books it on the belt, the same move as the app's own
--     "book a call"; the card's caller gets the call at that time.
--   * reply_rule_problem: an agent's reply is refused when it names the seller's trouble before anyone in the thread
--     has, asks for a price after a no, repeats itself or answers twice, presses a third time for someone else's
--     number, says someone else is the buyer, or claims to be a person. No refusal says who to write as.
--   * live_work: the comp, the prices and the story are Grok's first; Muse is the fallback. A number asked for by
--     text is in the list too, so its comp is not waiting on the texter.

create table if not exists public.caller_call_hours (
  person     public.team_person primary key,
  days       integer[] not null,                 -- ISO days of the week, 1 = Monday
  t_from     time not null,
  t_to       time not null,                      -- Central time
  updated_at timestamptz not null default now(),
  updated_by text
);
alter table public.caller_call_hours enable row level security;   -- no policies: read through the functions below
insert into public.caller_call_hours (person, days, t_from, t_to, updated_by) values
  ('thalia', '{1,2,3,4,5}', '15:30', '18:00', 'desk: when she dialed, Nov 8 to 22'),
  ('adil', '{1,2,3,4,5,6,7}', '14:00', '19:00', 'desk: when he dialed, Nov 8 to 22')
on conflict (person) do nothing;

create or replace function public.agent_call_times(p_lead_id uuid, p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public as $fn$
declare l public.leads; who public.team_person; h public.caller_call_hours; tz text; t_now timestamp := p_now at time zone 'America/Chicago';
        d date; s timestamp; c timestamp; at_ timestamptz; out_ jsonb := '[]'::jsonb; on_now boolean; first_ timestamp; name_ text; loc timestamp;
begin
  select * into l from public.leads where id = p_lead_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card'); end if;
  who := public.card_caller(p_lead_id);
  select * into h from public.caller_call_hours x where x.person = who;
  if who is null or h.person is null then
    return jsonb_build_object('ok', false, 'reason', 'this card has no caller to take a booked call: say so on the desk and keep the thread warm by text');
  end if;
  name_ := initcap(public.room_name(who::text));
  tz := public.belt_tz(l.mailing_state);
  on_now := extract(isodow from t_now)::int = any (h.days) and not public.caller_is_off(who, t_now::date)
            and t_now::time >= h.t_from and t_now::time <= h.t_to - interval '15 minutes';
  first_ := date_trunc('hour', t_now + interval '20 minutes') + ceil(extract(minute from t_now + interval '20 minutes') / 15.0) * interval '15 minutes';
  for i in 0 .. 5 loop
    d := t_now::date + i;
    continue when not (extract(isodow from d)::int = any (h.days)) or public.caller_is_off(who, d);
    s := greatest(d + h.t_from, first_);
    for k in 0 .. 1 loop
      c := s + k * interval '1 hour';
      exit when c > d + h.t_to - interval '15 minutes';
      at_ := c at time zone 'America/Chicago';
      loc := at_ at time zone tz;
      out_ := out_ || jsonb_build_object('at', at_, 'say',
        case when loc::date = (p_now at time zone tz)::date then 'today' when loc::date = (p_now at time zone tz)::date + 1 then 'tomorrow'
             else btrim(to_char(loc, 'Day')) end || ' at ' || to_char(loc, 'FMHH12:MI AM'));
      exit when jsonb_array_length(out_) >= 3;
    end loop;
    exit when jsonb_array_length(out_) >= 3;
  end loop;
  return jsonb_build_object('ok', true, 'caller', name_, 'on_now', on_now, 'seller_time_zone', tz, 'suggest', out_,
    'say', case when on_now then name_ || ' is on the phones now. Ask "can I give you a quick call in a few minutes?"; on a yes use call_next and send nothing more. Or offer a time from suggest and book_call the one they pick.'
                else 'Offer one or two of these times in your reply, in the words given ("does ' || coalesce(out_->0->>'say', 'tomorrow afternoon') || ' work for a quick call?"). When they pick one or name another, book_call with that time, then confirm it in one short reply.' end);
end $fn$;

create or replace function public.agent_book_call(p_lead_id uuid, p_at timestamptz, p_phone text, p_words text, p_agent text default null,
                                                  p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare l public.leads; who public.team_person; h public.caller_call_hours; ph text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10);
        c timestamp := p_at at time zone 'America/Chicago'; res jsonb; tz text; loc timestamp; times jsonb; by_ text := coalesce(nullif(btrim(p_agent), ''), 'Muse');
begin
  select * into l from public.leads where id = p_lead_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card'); end if;
  if public.card_is_closed(l.stage) or l.stage::text in ('under_contract', 'walkthrough_booked', 'offer') then
    return jsonb_build_object('ok', false, 'reason', 'this card is ' || l.stage::text || ': nothing to book');
  end if;
  if coalesce(l.elderly_or_ill, false) or coalesce(l.grief, false) then
    return jsonb_build_object('ok', false, 'reason', 'an older, ill or grieving owner: no call is booked by text. Answer gently and tell Colin on the desk.');
  end if;
  if length(ph) <> 10 then return jsonb_build_object('ok', false, 'reason', 'phone = the number the thread is on'); end if;
  if exists (select 1 from public.suppressed_phones s where s.phone10 = ph) then return jsonb_build_object('ok', false, 'reason', 'that phone opted out'); end if;
  if coalesce(btrim(p_words), '') = '' then return jsonb_build_object('ok', false, 'reason', 'words = what they wrote that agrees to the call, word for word'); end if;
  times := public.agent_call_times(p_lead_id, p_now);
  if not coalesce((times->>'ok')::boolean, false) then return times; end if;
  who := public.card_caller(p_lead_id);
  select * into h from public.caller_call_hours x where x.person = who;
  if p_at is null or p_at < p_now + interval '5 minutes' or p_at > p_now + interval '7 days' then
    return jsonb_build_object('ok', false, 'reason', 'at = the time they agreed to, at least five minutes from now and inside a week', 'suggest', times->'suggest');
  end if;
  if not (extract(isodow from c)::int = any (h.days)) or public.caller_is_off(who, c::date) or c::time < h.t_from or c::time > h.t_to then
    return jsonb_build_object('ok', false, 'reason', (times->>'caller') || ' does not take calls then. Offer one of these instead.', 'suggest', times->'suggest');
  end if;
  res := public.belt_event(p_lead_id, 'next_step', jsonb_build_object('kind', 'callback', 'at', p_at, 'said', left(btrim(p_words), 300), 'phone', ph, 'booked_by', by_), by_, p_now);
  if not coalesce((res->>'ok')::boolean, false) then return res; end if;
  tz := public.belt_tz(l.mailing_state); loc := p_at at time zone tz;
  insert into public.messages (lead_id, direction, channel, body, status, sent_at)
  values (p_lead_id, 'out', 'note', 'Call booked by text (' || by_ || ') for ' || btrim(to_char(loc, 'Day')) || ' ' || to_char(loc, 'FMMon FMDD') || ' at '
          || to_char(loc, 'FMHH12:MI AM') || ' their time, on ' || public.belt_fmt_phone(ph) || '. They wrote: "' || left(btrim(p_words), 300) || '"', null, p_now);
  return jsonb_build_object('ok', true, 'caller', times->>'caller', 'at', p_at,
    'say', 'Booked: ' || (times->>'caller') || ' calls them ' || btrim(to_char(loc, 'Day')) || ' at ' || to_char(loc, 'FMHH12:MI AM')
           || ' their time. Confirm that time in one short reply, in the name this thread already uses, and say nothing about price.');
end $fn$;

-- does this text ask for a way to reach someone else?
create or replace function public.text_asks_for_a_number(p text) returns boolean
language sql immutable as $fn$
  select lower(coalesce(p, '')) ~ '(\yhis|\yher|\ytheir|your (dad|father|mom|mother|son|daughter|brother|sister|husband|wife|uncle|aunt|parents?)|tu (pap[aá]|mam[aá]|hermano|hermana|t[ií]o)|\ysu) .{0,20}(number|n[uú]mero|contact)'
      or lower(coalesce(p, '')) ~ '(number|n[uú]mero|contacto?) (for|of|de) '
      or lower(coalesce(p, '')) ~ '(me (lo |la )?pasas|me puedes pasar|p[aá]same).{0,40}(n[uú]mero|contacto)'
      or lower(coalesce(p, '')) ~ 'how (do|can|could|would) i (reach|get ahold of|get a hold of|contact|find) (him|her|them|the owner)'
      or lower(coalesce(p, '')) ~ 'know how to (reach|get ahold|get a hold|contact)'
$fn$;

create or replace function public.reply_rule_problem(p_lead_id uuid, p_body text, p_now timestamptz default now()) returns text
language plpgsql stable security definer set search_path = public as $fn$
declare b text := lower(coalesce(p_body, '')); thread text; fam record; last_in timestamptz; last_in_body text; out_at timestamptz; out_body text;
        intent text; interest text; n integer; mins integer;
begin
  -- everything said on this card so far, both ways
  select lower(coalesce(string_agg(x.body, ' | '), '')) into thread from (
    select m.body from public.messages m where m.lead_id = p_lead_id and m.channel = 'sms'
    union all select t.body from public.twilio_inbound t where t.lead_id = p_lead_id) x;

  -- 1. their trouble is never named before someone in the thread has raised it
  for fam in select * from (values
      ('a probate', '\yprobate|\yestate (record|case|court|filing)'),
      ('a foreclosure or a sale date', 'foreclos|sheriff.{0,3} sale|\ysale date|\yauction\y'),
      ('back taxes', 'back tax|behind on .{0,15}tax|tax(es)? .{0,12}(owed|due|behind|delinquen|piling)|delinquen|owe .{0,15}tax'),
      ('a lien or a judgment', '\yliens?\y|\yjudge?ments?\y|\ywarrants?\y'),
      ('an eviction', '\yevict'),
      ('a bankruptcy', 'bankrupt'),
      ('a code violation', 'violation|\ycitation|condemn|\yraze'),
      ('a death', 'passed away|\ydied\y|\ydeath\y|deceased|your loss|loss of your')) v(label, re) loop
    if b ~ fam.re and thread !~ fam.re then
      return 'this names their trouble (' || fam.label || ') and nobody in this thread has raised it. Never say what the records show about them or why they '
          || 'might need to sell (Colin 2026-11-20: no debt is ever named to a seller). Ask about the house and whether they would sell. '
          || 'If they ask how you found them, "public property records" is the whole answer.';
    end if;
  end loop;

  -- 2. someone else is the buyer
  if b ~ '\ymy buyer|\yend buyer|\your buyer|pass (it |them |some |that one |these |those )?(on |along )?to (a|an|my|another|some) |\yassign(ing|ment)?\y' then
    return 'this says someone else is the buyer ("my buyer", "pass it to a partner"). The house is being bought by the person writing: say it that way.';
  end if;

  -- 3. no claim to be a person
  if b ~ 'real person|i.?m (a )?human|i am (a )?human|not a (ro)?bot|not an? (ai|machine|computer)|no bot here' then
    return 'do not claim to be a person or deny being automated. To "is this a scam / a bot": say you buy houses around here, '
        || 'and offer a quick call so they can hear a voice (call_times gives the times).';
  end if;

  select t.received_at, lower(coalesce(t.body, '')) into last_in, last_in_body from public.twilio_inbound t where t.lead_id = p_lead_id order by t.received_at desc limit 1;

  -- 4. no price question after a no
  select d.intent, d.facts->>'interest' into intent, interest from public.reply_drafts d
   where d.lead_id = p_lead_id and d.intent not in ('agent_reply', 'team_text') order by d.inbound_at desc limit 1;
  if (intent = 'not_interested' or interest = 'no'
      or coalesce(last_in_body, '') ~ 'not interested|not for sale|not selling|no interest|don.?t want to sell|won.?t sell|\ykeep(ing)?\y')
     and b ~ '(what|which) (number|price|figure|amount)|how much (would|do|will)|what would (you|it) (need|take|want)|name (a|your) (price|number)|is there a (number|price)' then
    return 'they just said they are not selling: do not ask for a price. Thank them, leave the door open in one line, and mark the card.';
  end if;

  -- 5. one reply per text from them, and never the same text twice
  select x.at, x.body into out_at, out_body from (
    select m.sent_at as at, m.body from public.messages m where m.lead_id = p_lead_id and m.channel = 'sms' and m.direction = 'out' and m.sent_at is not null
    union all
    select d.created_at, coalesce(d.sent_body, d.body) from public.reply_drafts d where d.lead_id = p_lead_id and d.draft_source = 'agent' and d.status in ('sent', 'queued', 'approved')
  ) x where x.at <= p_now order by x.at desc limit 1;
  if out_at is not null and (last_in is null or last_in < out_at) then
    mins := greatest(round(extract(epoch from p_now - out_at) / 60)::integer, 0);
    if out_at > p_now - interval '24 hours' and regexp_replace(lower(coalesce(out_body, '')), '\W', '', 'g') = regexp_replace(b, '\W', '', 'g') then
      return 'you already sent this exact text ' || mins::text || ' minutes ago and they have not written since';
    end if;
    if out_at > p_now - interval '10 minutes' and b !~ '\$\s?[0-9]' then
      return 'you answered their last text ' || mins::text || ' minutes ago and they have not written since: one reply per text from them. Wait for their answer.';
    end if;
  end if;

  -- 6. a relative or a stranger is asked once, maybe twice, for someone else's number, and no more
  if public.text_asks_for_a_number(b) then
    select count(*) into n from public.messages m
     where m.lead_id = p_lead_id and m.channel = 'sms' and m.direction = 'out' and public.text_asks_for_a_number(m.body);
    if n >= 2 then
      return 'you have asked on this thread for someone else''s number ' || n::text || ' times: do not ask again. They are not the owner and owe us nothing. '
          || 'Thank them once, mark the card, and leave the thread.';
    end if;
  end if;
  return null;
end $fn$;

revoke all on function public.agent_call_times(uuid, timestamptz) from public, anon, authenticated;
revoke all on function public.agent_book_call(uuid, timestamptz, text, text, text, timestamptz) from public, anon, authenticated;
revoke all on function public.reply_rule_problem(uuid, text, timestamptz) from public, anon, authenticated;
grant execute on function public.agent_call_times(uuid, timestamptz) to service_role;
grant execute on function public.agent_book_call(uuid, timestamptz, text, text, text, timestamptz) to service_role;
grant execute on function public.reply_rule_problem(uuid, text, timestamptz) to service_role;

CREATE OR REPLACE FUNCTION public.text_rule_problem(p_lead_id uuid, p_body text, p_step integer, p_now timestamp with time zone DEFAULT now())
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
     and (coalesce(p_body, '') ~* (public.text_intro_words() || k.name || '\M')
          or coalesce(p_body, '') ~* ('\m' || k.name || '\s+(here|again)\M'))
   limit 1;
  if other is not null then
    return 'this person hears from ' || voice || ', not ' || other || ': one name per seller, across their cards and numbers (Colin 2026-11-10)';
  end if;
  -- 0297: what an agent may not write in a reply (Colin 2026-11-22, after the review of 125 of Muse's threads)
  if coalesce(p_step, 1) = 0 then return public.reply_rule_problem(p_lead_id, p_body, p_now); end if;
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
end $function$;

CREATE OR REPLACE FUNCTION public.agent_live_work(p_now timestamp with time zone DEFAULT now(), p_who text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare cards jsonb; n integer; n_late integer; body text; n_held integer := 0; grok_on boolean := false;
        is_muse boolean := lower(coalesce(p_who, '')) like 'muse%';
begin
  -- 0297 (Colin 2026-11-22: "Go"): the comp, the prices and the story on a yes are Grok's first. Muse took a median of
  -- ten hours to value a yes while answering texts inside five minutes. Muse sees such a card only when Grok has not
  -- been at the door for ten minutes, or the card has waited twenty.
  select exists (select 1 from public.agent_calls c join public.agent_keys k on k.id = c.key_id
                  where lower(k.name) like 'grok%' and k.revoked_at is null and c.at > p_now - interval '10 minutes') into grok_on;
  with y as (
    select o.lead_id, o.opened_at, o.trigger_text, public.text_offer_view(o, p_now) as v
      from public.text_offers o where o.status = 'open' and o.trigger in ('yes_to_selling', 'caller_asked', 'asked_number')
  ), w as (
    select l.id as lead_id, l.owner_name, l.property_address, l.municipality, l.county,
           coalesce(y.opened_at, b.wanted_at) as since, y.trigger_text,
           case when y.v->>'who' = 'muse' and y.v->>'step' in ('comp', 'call_prices') then y.v end as step,
           coalesce(b.status = 'wanted', false) as brief_wanted, b.due_at as brief_due,
           case when b.claimed_at > p_now - interval '45 minutes' then b.claimed_by end as claimed_by,
           public.card_asked_for_grok(l.id) as asked
      from public.leads l
      left join y on y.lead_id = l.id
      left join public.call_briefs b on b.lead_id = l.id
     where not public.card_is_closed(l.stage) and l.stage::text <> 'under_contract'
  ), t as (
    select w.*, (w.step is not null and coalesce((w.step->>'late')::boolean, false)) or (w.brief_wanted and w.brief_due < p_now) as late,
           (is_muse and grok_on and coalesce(w.since, p_now) > p_now - interval '20 minutes') as held
      from w where (w.step is not null or w.brief_wanted)
       -- 0283: a card a caller asked for from its button is Grok's alone (Colin 2026-11-22)
       and not (w.asked and lower(coalesce(p_who, '')) like 'muse%')
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
           order by t.since desc nulls last), '[]'::jsonb), count(*), count(*) filter (where t.late), (select count(*) from t h where h.held)
    into cards, n, n_late, n_held
    from (select * from t where not held order by since desc nulls last limit 15) t;
  if n = 0 then
    return jsonb_build_object('live', 0, 'with_grok', n_held, 'say', 'Nothing live: no card is waiting on you. Carry on with this run.'
      || case when n_held > 0 then ' (' || n_held::text || ' with Grok first: the comp and the prices on a yes are Grok''s; a card comes to you if Grok is away ten minutes or it has waited twenty.)' else '' end);
  end if;
  select p.body into body from public.live_work_packet p where p.id = 1;
  return jsonb_build_object('live', n, 'late', n_late, 'with_grok', n_held,
    'say', n::text || case when n = 1 then ' card is' else ' cards are' end || ' waiting on you'
           || case when n_late > 0 then ' (' || n_late::text || ' late)' else '' end
           || ': a seller said yes, or a caller asked for comps from the card. A caller cannot give a number until you are done. '
           || 'Call live_work, read the packet, and work the cards before anything else in this run, the newest first.',
    'packet', body, 'cards', cards);
end $function$;
