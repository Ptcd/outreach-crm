-- 0277: the no-texts-on-Sunday rule is gone. Colin 2026-11-22, a Sunday morning: "Get rid of the no testing rule
-- for sundays". It was our own rule, never the law's (0240 let him open one Sunday at a time, each on his word).
--
--   * Sunday builds a list and sends it like any other day: the build, the queue, the send check and the release
--     of stale texts all read campaign_control.no_sundays, which is now false and is kept false.
--   * A follow-up due on a Sunday is due that Sunday, and a belt text no longer slides to Monday.
--   * The agents are told nothing special on a Sunday; their rules text says Sunday is a day like any other, and a
--     reply that waits on a Sunday is owed as on a weekday.
--   * What still holds on a Sunday, because it is not our rule: a number in a state that bars or limits Sunday
--     texts waits for Monday (card_record_block, state_bars_sunday). And a card whose caller is off that day, or a
--     thread in that caller's name, is not texted (0237, 0272): Thalia is off Sundays.
--   * Calls are untouched: a belt call still does not land on a Sunday.
-- sundays_closed is the standing rule's switch, should it ever come back; sunday_open and sunday_close still work
-- under it and do nothing while it is off.

alter table public.campaign_control add column if not exists sundays_closed boolean not null default false;
update public.campaign_control set no_sundays = false, sunday_open_day = null, sunday_open_why = null where id = 1;

-- ---------------------------------------------------------------- the tick keeps Sunday open
CREATE OR REPLACE FUNCTION public.text_day_tick(p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c    public.campaign_control;
  d    date := (p_now at time zone 'America/Chicago')::date;
  t    time := (p_now at time zone 'America/Chicago')::time;
  out  jsonb := '{}'::jsonb;
  r    jsonb;
  low  boolean;
  txt  text;
begin
  select * into c from public.campaign_control where id = 1;
  -- a Sunday is opened one day at a time (0240): the rule is off on the Sunday that was opened and on every other day
  if coalesce(c.sundays_closed, false) and coalesce(c.no_sundays, true) is distinct from (c.sunday_open_day is distinct from d) then
    update public.campaign_control set no_sundays = (sunday_open_day is distinct from d) where id = 1;
    select * into c from public.campaign_control where id = 1;
  end if;
  -- 0277: with the standing rule gone, Sunday is never shut, whatever an older setting says
  if not coalesce(c.sundays_closed, false) and coalesce(c.no_sundays, true) then
    update public.campaign_control set no_sundays = false where id = 1;
    select * into c from public.campaign_control where id = 1;
  end if;
  if coalesce(c.no_sundays, true) and extract(isodow from d) = 7 then return jsonb_build_object('day', d, 'why', 'Sunday'); end if;
  if t >= time '07:00' and t < time '18:30'
     and (c.day_last_build_at is null or (c.day_last_build_at at time zone 'America/Chicago')::date < d or c.day_last_build_at < p_now - interval '55 minutes') then
    out := out || jsonb_build_object('build', public.text_day_build(p_now));
  end if;
  -- the noon check is for a day people write; a day the server drips is half unwritten at noon by design (0236)
  if t >= time '12:00' and t < time '18:30' and c.day_noon_checked is distinct from d and not coalesce(c.day_backstop, false) then
    r := public.text_day_report(p_now);
    update public.campaign_control set day_noon_checked = d where id = 1;
    if (r ->> 'listed')::int >= 20 and (r ->> 'not_written')::int * 2 > (r ->> 'listed')::int then
      perform public.desk_post('desk', 'all', 'note', 'The day ' || d || ': at noon ' || (r ->> 'not_written') || ' of ' || (r ->> 'listed') || ' texts are not written',
        'The day''s list (text_day) has ' || (r ->> 'listed') || ' texts on it and ' || (r ->> 'not_written') || ' have not been written and queued yet. '
        || 'The list is in ready_to_text, need first. ' || case when coalesce(c.day_backstop, false) then 'The backstop is on and will write the rest in the settled wording.'
           else 'The backstop is off, so nothing goes out for those rows unless they are queued.' end);
      out := out || jsonb_build_object('noon', 'posted');
    end if;
  end if;
  if coalesce(c.day_backstop, false) and t >= c.day_backstop_after and t < time '18:30' then
    out := out || jsonb_build_object('backstop', public.text_day_backstop(p_now));
  end if;
  if t >= time '19:15' and c.day_reported is distinct from d then
    r := public.text_day_report(p_now);
    update public.campaign_control set day_reported = d where id = 1;
    insert into public.text_day_runs (day, at, kind, summary) values (d, p_now, 'report', r);
    low := (r ->> 'days_of_new_people')::numeric < 5;
    txt := 'Listed ' || (r ->> 'listed') || ' (cap ' || coalesce(r ->> 'cap', '?') || ', floor of new people ' || (r ->> 'floor') || '); not written ' || (r ->> 'not_written')
        || '; off the list ' || (r ->> 'off_list_today') || E'.\nBy kind: ' || (r -> 'by_kind')::text
        || E'\nReplies today ' || (r ->> 'replies_today') || ', STOPs ' || (r ->> 'stops_today') || ', hot ' || (r ->> 'hot_today')
        || E'.\nNew people still ready: ' || (r ->> 'first_ready') || ' by tier ' || (r -> 'first_ready_by_tier')::text || ', about ' || (r ->> 'days_of_new_people') || ' days at the floor.'
        || E'\nFollow-ups ready by step: ' || (r -> 'followups_ready_by_step')::text || '; next numbers ' || (r ->> 'next_numbers_ready')
        || E'.\nWhy the rest of the first-text store is not ready: ' || (r -> 'first_blocked')::text
        || E'\nFollow-ups held back: ' || (r -> 'followups_blocked')::text
        || E'\nRecord verdicts as of ' || coalesce(r ->> 'verdicts_as_of', 'never') || '.';
    perform public.desk_post('desk', 'all', 'report',
      'The day ' || d || case when low then ': NEW PEOPLE RUN OUT IN ' || (r ->> 'days_of_new_people') || ' DAYS' else ': report' end, left(txt, 11000));
    out := out || jsonb_build_object('report', 'posted', 'low_supply', low);
  end if;
  return out;
end $function$;

-- ---------------------------------------------------------------- closing a Sunday only shuts it when the standing rule is on
CREATE OR REPLACE FUNCTION public.sunday_close(p_by text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  update public.campaign_control set sunday_open_day = null, sunday_open_by = p_by, sunday_open_why = null, no_sundays = sundays_closed where id = 1;
  return jsonb_build_object('closed', true, 'by', p_by);
end $function$;

-- ---------------------------------------------------------------- a belt text does not wait for Monday
CREATE OR REPLACE FUNCTION public.belt_slide(p_at timestamp with time zone, p_tz text, p_kind text, p_hour integer DEFAULT NULL::integer)
 RETURNS timestamp with time zone
 LANGUAGE plpgsql
 STABLE
AS $function$
declare l timestamp; open_from time; d date;
begin
  l := p_at at time zone p_tz;
  open_from := case when p_kind = 'text' then time '09:00' else time '08:00' end;
  if p_hour is not null then l := l::date + make_time(p_hour, 0, 0); end if;
  for i in 1..8 loop
    d := l::date;
    if l::time < open_from then l := d + open_from;
    elsif l::time >= time '20:00' then l := d + 1 + open_from;
    end if;
    -- 0277: a text no longer waits for Monday; a call still does
    if extract(isodow from l) = 7 and (p_kind <> 'text' or coalesce((select cc.no_sundays from public.campaign_control cc where cc.id = 1), true)) then
      l := (l::date + 1) + coalesce(case when p_hour is not null then make_time(p_hour, 0, 0) end, open_from);
      continue;
    end if;
    exit;
  end loop;
  return l at time zone p_tz;
end $function$;

-- ---------------------------------------------------------------- a follow-up due on a Sunday is due that Sunday
CREATE OR REPLACE FUNCTION public.text_pool(p_now timestamp with time zone DEFAULT now())
 RETURNS TABLE(lead_id uuid, kind text, step integer, phone text, tier text, need_why text, due_day date, block text, ord bigint)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with d as (select (p_now at time zone 'America/Chicago')::date as day),
  -- 0272: threads that speak in the name of a caller who is off today
  off_name as (select n.lead_id from d, public.text_name_off(d.day) n),
  firsts as (
    select l.id, l.stacked_at, l.created_at, ph.phone,
           coalesce(f.tier, m.tier) as tier, coalesce(f.equity, e.equity_grade) as equity, sd.sale_date,
           coalesce(sd.sale_date >= d.day + 14, false) as sale_ahead,
           coalesce(f.need_why, m.family_list) as need_why,
           coalesce(case when ph.phone is null and exists (select 1 from public.contacts c2 where c2.lead_id = l.id and c2.kind = 'phone' and c2.status = 'ok'
                                                              and public.phone_is_shared(c2.value_normalized)) then 'phone_shared'
                         when ph.phone is null then 'no_textable_phone' end,
                    public.card_hold_block(l.id, p_now), public.card_record_block(l.id, d.day),
                    -- 0257: the owner said STOP on another number of theirs; the send check refuses every card of theirs
                    case when public.owner_opted_out(l.wpie_owner_id) then 'owner_opted_out' end,
                    (select 'name_off_today' from off_name o where o.lead_id = l.id limit 1)) as block
      from d, public.leads l
      left join public.text_fitness f on f.wpie_owner_id = l.wpie_owner_id and l.wpie_owner_id > 0
      left join public.lead_motivation m on m.lead_id = l.id
      left join public.equity_inputs e on e.lead_id = l.id
      left join public.card_sale_dates sd on sd.lead_id = l.id
      left join lateral (
        select c.value_normalized as phone from public.contacts c
         where c.lead_id = l.id and c.kind = 'phone' and c.status = 'ok' and not c.dnc_app and not c.suppressed and not c.dnc_vendor
           and c.dnc_scrub <> 'dnc' and public.agent_phone_ok(c.value_normalized, c.line_type)
           and not exists (select 1 from public.suppressed_phones s where s.phone10 = c.value_normalized)
           and not exists (select 1 from public.twilio_inbound ti where ti.from10 = c.value_normalized)
           and public.phone_person_block(c.value_normalized) is null
           and not public.phone_is_shared(c.value_normalized)   -- 0257: the send check refuses it (phone_shared)
         order by (lower(coalesce(c.line_type, '')) in ('mobile', 'wireless', 'cell', 'cellular')) desc, c.created_at, c.value_normalized
         limit 1) ph on true
     where l.stage in ('opener_queued', 'postcard_mailed')
       and not exists (select 1 from public.planned_openers po where po.lead_id = l.id and po.step = 1
                        and po.send_status in ('planned', 'would_send', 'sending', 'sent', 'delivered'))
       and not exists (select 1 from public.messages mm where mm.lead_id = l.id and mm.direction = 'out' and mm.channel = 'sms')),
  first_text as (
    -- the latest first text that was not a bounce: the phone this thread runs on
    select distinct on (m.lead_id) m.lead_id, right(regexp_replace(m.to_number, '\D', '', 'g'), 10) as phone, m.sent_at as first_at
      from public.messages m join public.leads l on l.id = m.lead_id
     where l.stage = 'opener_sent' and m.direction = 'out' and m.channel = 'sms' and m.is_opener
       and m.provider_sid is not null and coalesce(m.status, '') not in ('undelivered', 'failed')
     order by m.lead_id, m.sent_at desc),
  thread as (
    select f.lead_id, f.phone, f.first_at, count(m.*)::int as n, max(m.sent_at) as last_at
      from first_text f join public.messages m on m.lead_id = f.lead_id and m.direction = 'out' and m.channel = 'sms'
       and m.provider_sid is not null and right(regexp_replace(m.to_number, '\D', '', 'g'), 10) = f.phone and m.sent_at >= f.first_at
     group by 1, 2, 3),
  due as (
    select t.lead_id, t.phone, t.n + 1 as step, t.last_at,
           (t.first_at at time zone 'America/Chicago')::date + (case t.n + 1 when 2 then 2 when 3 then 9 when 4 then 16 else 23 end) as raw_day
      from thread t where t.n between 1 and 4),
  follow as (
    select x.lead_id as id, x.step, x.phone, x.due_day, fm.tier, fm.need_why,
           coalesce(public.card_hold_block(x.lead_id, p_now), public.card_record_block(x.lead_id, d.day),
                    public.followup_send_block(x.lead_id, x.phone, x.step),   -- 0257
                    (select 'name_off_today' from off_name o where o.lead_id = x.lead_id limit 1)) as block
      from d, (select u.*, case when extract(isodow from u.raw_day) = 7 and coalesce((select cc.no_sundays from public.campaign_control cc where cc.id = 1), true) then u.raw_day + 1 else u.raw_day end as due_day from due u) x
      join public.leads l on l.id = x.lead_id
      left join lateral (select coalesce(f.tier, m.tier) as tier, coalesce(f.need_why, m.family_list) as need_why
                           from (select 1) one
                           left join public.text_fitness f on f.wpie_owner_id = l.wpie_owner_id and l.wpie_owner_id > 0
                           left join public.lead_motivation m on m.lead_id = l.id) fm on true
     where x.due_day <= d.day and x.last_at < p_now - interval '1 day'
       -- they wrote back, from any phone on the card (or a phone that belongs to it)
       and not exists (select 1 from public.twilio_inbound ti where ti.lead_id = l.id
                         or ti.from10 in (select c.value_normalized from public.contacts c where c.lead_id = l.id and c.kind = 'phone'))
       and not exists (select 1 from public.messages m where m.lead_id = l.id and m.direction = 'in' and m.channel = 'sms')
       -- a call that REACHED them ends the texting; a dial nobody answered does not
       and not exists (select 1 from public.messages m where m.lead_id = l.id and m.channel = 'call'
                         and coalesce(m.status, '') not in ('no_answer', 'voicemail', 'inbound_missed', 'missed', 'busy', 'failed', 'canceled', 'blocked'))
       and not exists (select 1 from public.suppressed_phones s where s.phone10 = x.phone)
       and exists (select 1 from public.contacts c where c.lead_id = l.id and c.kind = 'phone' and c.value_normalized = x.phone and c.status = 'ok'
                    and not c.dnc_app and not c.suppressed and not c.dnc_vendor and c.dnc_scrub <> 'dnc')
       and public.phone_person_block(x.phone) is null
       and not exists (select 1 from public.planned_openers po where po.lead_id = l.id and po.send_status in ('planned', 'would_send', 'sending'))),
  -- the owner's next number: the texted number was someone else's (0079), or every first text to the card bounced
  -- on a dead number and nobody was reached (0225), and another usable mobile is on the card
  next_numbers as (
    select l.id, ph.value_normalized as phone, l.updated_at, coalesce(f.tier, m.tier) as tier, coalesce(f.need_why, m.family_list) as need_why,
           coalesce(public.card_hold_block(l.id, p_now), public.card_record_block(l.id, d.day),
                    (select 'name_off_today' from off_name o where o.lead_id = l.id limit 1)) as block
      from d, public.leads l
      left join public.text_fitness f on f.wpie_owner_id = l.wpie_owner_id and l.wpie_owner_id > 0
      left join public.lead_motivation m on m.lead_id = l.id
      cross join lateral (
        select c.value_normalized from public.contacts c
         where c.lead_id = l.id and c.kind = 'phone' and c.status = 'ok' and not c.dnc_app and not c.suppressed and not c.dnc_vendor
           and c.dnc_scrub <> 'dnc' and public.agent_phone_ok(c.value_normalized, c.line_type)
           and public.phone_person_block(c.value_normalized) is null
           and public.next_phone_problem(l.id, c.value_normalized) is null
           and not public.phone_is_shared(c.value_normalized)   -- 0257
         order by c.created_at, c.value_normalized limit 1) ph
     where (l.stage = 'data_fix'
            or (l.stage = 'opener_sent'
                and exists (select 1 from public.planned_openers b where b.lead_id = l.id and b.step = 1 and b.send_status in ('undelivered', 'failed'))
                and not exists (select 1 from public.planned_openers g where g.lead_id = l.id and g.send_status in ('sending', 'sent', 'delivered', 'uncertain'))))
       and not exists (select 1 from public.planned_openers po where po.lead_id = l.id and po.send_status in ('planned', 'would_send', 'sending')))
  select f.id, 'first', 1, f.phone, f.tier, f.need_why, null::date, f.block,
         -- a sale ahead is the first text of the day, soonest sale first (0233)
         row_number() over (order by (f.block is null) desc, f.sale_ahead desc, case when f.sale_ahead then f.sale_date end nulls last,
                                     case f.tier when 'A' then 1 when 'B' then 2 when 'C' then 3 when 'D' then 4 else 5 end,
                                     f.sale_date nulls last, (coalesce(f.equity, '') in ('clear', 'likely')) desc,
                                     f.stacked_at desc nulls last, f.created_at desc, f.id)
    from firsts f
  union all
  select w.id, 'followup', w.step, w.phone, w.tier, w.need_why, w.due_day, w.block,
         row_number() over (order by (w.block is null) desc, w.step, w.due_day, w.id)
    from follow w
  union all
  select n.id, 'next_number', 1, n.phone, n.tier, n.need_why, null::date, n.block,
         row_number() over (order by (n.block is null) desc,
                                     case n.tier when 'A' then 1 when 'B' then 2 when 'C' then 3 when 'D' then 4 else 5 end, n.updated_at, n.id)
    from next_numbers n
$function$;

-- ---------------------------------------------------------------- the agents are told Sunday is a texting day
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
