-- 0269: the live work packet. Colin 2026-11-21, shown that Muse's most frequent scheduled run is a texting check
-- every 5 minutes: "it has this on cron, why don't we give it an instruction packet to read and do when there is a
-- live one then push it to you and then you ping our team member with the card".
--
-- Before this nothing started the comp, the prices or the call brief when a seller said yes: the server wrote the
-- rows and put a note on every tool result, and no loop of Muse's read the note (Muse, room line 42). Last night's
-- briefs came three hours late, from a session that happened to be open.
--
--   * live_work (door tool, agent_live_work): one call for the 5-minute run to make first. Nothing live is one short
--     line. Something live is the cards, newest yes first, each with what is still owed on it (comp, call_prices,
--     brief), and the packet: the instructions, kept in live_work_packet so the words can change without a deploy.
--   * Every other tool result carries attention.live when a card is waiting, for a run that has not been taught yet.
--   * The ping: when Muse's prices land on a said-yes card, and when its story lands, the card's caller is told on
--     their phone and by email (yes_ready_alerts, claimed each minute by the reply agent). One alert per card for
--     each. A card with no caller goes to the owners. Nothing in quiet hours; nothing here touches a seller.

create table if not exists public.live_work_packet (
  id         integer primary key default 1 check (id = 1),
  body       text not null,
  updated_at timestamptz not null default now(),
  updated_by text not null default 'desk'
);
alter table public.live_work_packet enable row level security;
grant select on public.live_work_packet to authenticated, service_role;
drop policy if exists live_work_packet_owner_read on public.live_work_packet;
create policy live_work_packet_owner_read on public.live_work_packet for select to authenticated using (public.is_owner());
insert into public.live_work_packet (id, body) values (1, $packet$WHEN A SELLER HAS SAID YES (the live work packet)

A seller said yes to selling and a caller is about to phone them. The caller has nothing to say until you have done three things. Do them before anything else in this run, the newest yes first, one card at a time.

1. THE COMP (step "comp"), inside 10 minutes of the yes.
   Sold comps near the house. Then offer_update {lead_id, arv, arv_basis, comps, sqft}. Always send sqft.
   Fewer than 3 sold comps is not a set to offer from: offer_close as no_comp_set. The caller is then told to give no number.

2. THE STREET LOOK AND YOUR PRICES (step "call_prices"), in the same sitting.
   Open the house on Street View. Note the month and year on the picture. Look at the roof, siding, windows, porch, garage, yard, and signs nobody lives there.
   Then offer_update {lead_id, street: {image_date, seen: [{item, cost, note}], notes}, call_prices: [{inside, repairs, repairs_basis, open, top}, ...]}.
   Two to five rows, one for each shape the inside could be in. Every row's repairs hold everything in street.seen plus the inside work at that level: a roof you can see is in every row.
   open is 65% of the value minus that row's repairs, top is 70%, to the nearest $100. A row the repairs eat is {inside, repairs, repairs_basis, no_offer: true}.
   No picture of the house: street {no_view: true, why}.
   You may send the comp, the street look and the prices in one offer_update.

3. THE STORY AND THE SCRIPT (step "brief"), inside 30 minutes of the yes.
   call_briefs_wanted has the card's records. Work out what is going on with the house and what the seller has to clear, then call_brief_set.
   In the script's money part use the rows you stored in call_prices, so the card says one thing.

WHAT HAPPENS NEXT: the moment the prices land, and again when the story lands, the server tells the card's caller on their phone. You do not post it or message anyone.

RULES THAT DO NOT CHANGE: these prices are for the caller on the phone. You never text a seller a figure that is not OK'd for that card. A thread a caller has taken over is theirs. No debt is named to a seller as the reason we called.

IF YOU CANNOT FINISH A CARD: store what you have, say what blocks it in the room (chat_post), and go on to the next card.
$packet$)
on conflict (id) do nothing;

-- the cards a seller said yes on that still wait on Muse, newest yes first, with the packet
create or replace function public.agent_live_work(p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare cards jsonb; n integer; n_late integer; body text;
begin
  with y as (
    select o.lead_id, o.opened_at, o.trigger_text, public.text_offer_view(o, p_now) as v
      from public.text_offers o where o.status = 'open' and o.trigger = 'yes_to_selling'
  ), w as (
    select l.id as lead_id, l.owner_name, l.property_address, l.municipality, l.county,
           coalesce(y.opened_at, b.wanted_at) as since, y.trigger_text,
           case when y.v->>'who' = 'muse' and y.v->>'step' in ('comp', 'call_prices') then y.v end as step,
           coalesce(b.status = 'wanted', false) as brief_wanted, b.due_at as brief_due
      from public.leads l
      left join y on y.lead_id = l.id
      left join public.call_briefs b on b.lead_id = l.id
     where not public.card_is_closed(l.stage) and l.stage::text <> 'under_contract'
  ), t as (
    select w.*, (w.step is not null and coalesce((w.step->>'late')::boolean, false)) or (w.brief_wanted and w.brief_due < p_now) as late
      from w where w.step is not null or w.brief_wanted
  )
  select coalesce(jsonb_agg(jsonb_build_object('lead_id', t.lead_id, 'owner_name', t.owner_name, 'address', t.property_address, 'city', t.municipality,
           'county', t.county, 'caller', public.room_name(public.card_caller(t.lead_id)::text), 'said_yes_at', t.since, 'their_words', left(t.trigger_text, 300), 'late', t.late,
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
end $$;
revoke all on function public.agent_live_work(timestamptz) from public, anon, authenticated;
grant execute on function public.agent_live_work(timestamptz) to service_role;

-- ---------------------------------------------------------------- the ping to the card's caller
create table if not exists public.yes_ready_alerts (
  id         uuid primary key default gen_random_uuid(),
  lead_id    uuid not null references public.leads (id) on delete cascade,
  kind       text not null check (kind in ('prices', 'brief')),
  ref        text not null,                        -- the offer, or the brief's writing: one alert for each
  at         timestamptz not null default now(),
  claimed_at timestamptz,
  people     text,                                 -- who was told
  reached    integer,                              -- pushes plus emails that got through
  note       text,
  unique (lead_id, kind, ref)
);
create index if not exists yes_ready_alerts_open_idx on public.yes_ready_alerts (at) where claimed_at is null;
-- the server's own ledger: no login reads it (a caller must see nothing of another caller's card)
alter table public.yes_ready_alerts enable row level security;
revoke all on public.yes_ready_alerts from public, anon, authenticated;
grant select, insert, update on public.yes_ready_alerts to service_role;

create or replace function public.yes_prices_ready() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.call_prices is not null and new.trigger = 'yes_to_selling' and new.status = 'open' and old.call_prices is null then
    insert into public.yes_ready_alerts (lead_id, kind, ref) values (new.lead_id, 'prices', new.id::text) on conflict do nothing;
  end if;
  return new;
end $$;
drop trigger if exists text_offers_prices_ready on public.text_offers;
create trigger text_offers_prices_ready after update of call_prices on public.text_offers
  for each row execute function public.yes_prices_ready();

create or replace function public.call_brief_ready() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'ready' and (tg_op = 'INSERT' or old.status is distinct from 'ready') then
    insert into public.yes_ready_alerts (lead_id, kind, ref) values (new.lead_id, 'brief', coalesce(new.written_at, now())::text) on conflict do nothing;
  end if;
  return new;
end $$;
drop trigger if exists call_briefs_ready on public.call_briefs;
create trigger call_briefs_ready after insert or update of status on public.call_briefs
  for each row execute function public.call_brief_ready();

-- what is ready to be told, a card at a time; each alert is handed out once
create or replace function public.yes_ready_claim(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public as $$
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
        'landed', to_jsonb(r.kinds), 'prices', has_prices, 'brief', has_brief, 'has_caller', cc is not null);
    end loop;
  end loop;
  return out;
end $$;

create or replace function public.yes_ready_alerted(p_ids uuid[], p_reached integer, p_note text) returns void
language sql security definer set search_path = public as $$
  update public.yes_ready_alerts set reached = coalesce(reached, 0) + coalesce(p_reached, 0),
         note = coalesce(nullif(btrim(coalesce(p_note, '')), ''), note) where id = any(p_ids)
$$;
revoke all on function public.yes_ready_claim(timestamptz), public.yes_ready_alerted(uuid[], integer, text) from public, anon, authenticated;
grant execute on function public.yes_ready_claim(timestamptz), public.yes_ready_alerted(uuid[], integer, text) to service_role;

-- ---------------------------------------------------------------- every tool result says a yes is waiting
CREATE OR REPLACE FUNCTION public.agent_attention(p_agent text, p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  who text := case when lower(coalesce(p_agent, '')) like 'muse 2%' then 'muse 2' when lower(coalesce(p_agent, '')) like 'muse%' then 'muse' else lower(coalesce(p_agent, '')) end;
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
  if who in ('muse', 'muse 2') then
    room := public.room_unread(who);
    if (room ->> 'unread')::int > 0 then
      out := out || jsonb_build_object('room', (room ->> 'unread') || case when (room ->> 'unread')::int = 1 then ' new line' else ' new lines' end
        || ' in the room' || case when (room ->> 'for_you')::int > 0 then ' (' || (room ->> 'for_you') || ' to you by name)' else '' end
        || ', the newest from ' || coalesce(room ->> 'latest_by', '?') || ': "' || left(coalesce(room ->> 'latest', ''), 160) || '". Read chat_read now and answer with chat_post.');
    end if;
  end if;
  -- a seller who said yes and is waiting on this agent (0269): the first thing every run does
  if who = 'muse' then
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
    opened := is_sunday and c.sunday_open_day is not distinct from d;
    if opened then
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
