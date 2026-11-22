-- 0283: the card's "Get comps, angles and a script" goes to Grok only, and the caller is told when it is ready.
-- Colin 2026-11-22, asking Grok "How do we make it so just your underwriter gets the request right away and then notify
-- the caller when it's ready".
--
--   * card_asked_for_grok: a card a caller asked for from its button (an open caller_asked comp, or the brief asked
--     for from the card) and no seller's yes on it. live_work and attention.live leave those cards out for Muse;
--     work_claim refuses Muse on them. A seller's yes later makes the card the yes path again, which both may work.
--   * The caller's "ready" alert (0269) now fires when the prices land on a card asked for from the button too, and
--     says "your comps and script" instead of "they said yes".
--   * The server cannot wake Grok: how fast it picks one up is Grok's own schedule.

create or replace function public.card_asked_for_grok(p_lead_id uuid) returns boolean
language sql stable security definer set search_path = public as $fn$
  select (exists (select 1 from public.text_offers o where o.lead_id = p_lead_id and o.status = 'open' and o.trigger = 'caller_asked')
          or exists (select 1 from public.call_briefs b where b.lead_id = p_lead_id and b.status = 'wanted' and b.wanted_why like 'comps, angles%'))
     and not exists (select 1 from public.text_offers o where o.lead_id = p_lead_id and o.status = 'open' and o.trigger in ('yes_to_selling', 'asked_number'))
$fn$;
revoke all on function public.card_asked_for_grok(uuid) from public, anon, authenticated;
grant execute on function public.card_asked_for_grok(uuid) to service_role;

drop function if exists public.agent_live_work(timestamp with time zone);

CREATE OR REPLACE FUNCTION public.agent_live_work(p_now timestamp with time zone DEFAULT now(), p_who text DEFAULT NULL::text)
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
           case when b.claimed_at > p_now - interval '45 minutes' then b.claimed_by end as claimed_by,
           public.card_asked_for_grok(l.id) as asked
      from public.leads l
      left join y on y.lead_id = l.id
      left join public.call_briefs b on b.lead_id = l.id
     where not public.card_is_closed(l.stage) and l.stage::text <> 'under_contract'
  ), t as (
    select w.*, (w.step is not null and coalesce((w.step->>'late')::boolean, false)) or (w.brief_wanted and w.brief_due < p_now) as late
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

-- ---------------------------------------------------------------- attention says it to the agent it is for
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
    live := public.agent_live_work(p_now, who);
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

-- ---------------------------------------------------------------- the prices alert covers a card asked for from the button
CREATE OR REPLACE FUNCTION public.yes_prices_ready()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if new.call_prices is not null and new.trigger in ('yes_to_selling', 'caller_asked') and new.status = 'open' and old.call_prices is null then
    insert into public.yes_ready_alerts (lead_id, kind, ref) values (new.lead_id, 'prices', new.id::text) on conflict do nothing;
  end if;
  return new;
end $function$;

-- ---------------------------------------------------------------- the alert knows it was asked for
CREATE OR REPLACE FUNCTION public.yes_ready_claim(p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare out jsonb := '[]'::jsonb; r record; l public.leads; cc text; tell text[]; m public.team_members; p text; has_prices boolean; has_brief boolean;
begin
  if public.in_quiet_hours(p_now) then return out; end if;          -- held, and told when the quiet hours end
  update public.yes_ready_alerts set claimed_at = p_now, note = 'too old to tell' where claimed_at is null and at < p_now - interval '18 hours';
  for r in select a.lead_id, array_agg(a.id) as ids, array_agg(a.kind) as kinds from public.yes_ready_alerts a where a.claimed_at is null group by a.lead_id loop
    select * into l from public.leads where id = r.lead_id;
    if public.card_is_closed(l.stage) then
      update public.yes_ready_alerts set claimed_at = p_now, note = 'the card is closed' where id = any(r.ids);
      continue;
    end if;
    cc := public.card_caller(r.lead_id)::text;
    if cc is not null then tell := array[cc];
    else select coalesce(array_agg(t.person::text), '{}') into tell from public.team_members t where t.role = 'owner' and t.person::text <> 'muse';
    end if;
    has_prices := exists (select 1 from public.text_offers o where o.lead_id = r.lead_id and o.status = 'open' and o.call_prices is not null);
    has_brief := exists (select 1 from public.call_briefs b where b.lead_id = r.lead_id and b.status = 'ready');
    update public.yes_ready_alerts set claimed_at = p_now, people = array_to_string(tell, ', ') where id = any(r.ids);
    foreach p in array tell loop
      select * into m from public.team_members where person::text = p limit 1;
      out := out || jsonb_build_object('alert_ids', to_jsonb(r.ids), 'lead_id', r.lead_id, 'person', p, 'email', nullif(btrim(m.alert_email), ''),
        'owner_name', l.owner_name, 'address', l.property_address, 'municipality', l.municipality,
        'landed', to_jsonb(r.kinds), 'prices', has_prices, 'brief', has_brief, 'has_caller', cc is not null,
        'asked', public.card_asked_for_grok(r.lead_id));
    end loop;
  end loop;
  return out;
end $function$;

-- ---------------------------------------------------------------- Muse cannot claim a card that is Grok's
CREATE OR REPLACE FUNCTION public.agent_work_claim(p_lead_id uuid, p_agent text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare b public.call_briefs; me text := lower(btrim(coalesce(p_agent, '')));
begin
  if me = '' then return jsonb_build_object('ok', false, 'reason', 'no agent'); end if;
  -- 0283: a card a caller asked for from its button is Grok's alone
  if me like 'muse%' and public.card_asked_for_grok(p_lead_id) then
    return jsonb_build_object('ok', false, 'reason', 'A caller asked for this card from its button: it is Grok''s (Colin 2026-11-22). Take the next card.');
  end if;
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
end $function$;
