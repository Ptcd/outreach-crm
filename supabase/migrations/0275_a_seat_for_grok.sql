-- 0275: a seat for Grok. Colin 2026-11-21: "Time to get some extra help, bringing in grok bot", to start on data
-- collection. A key named Grok speaks as itself: until now every key that was not Dots or Muse 2 spoke as Muse on the
-- desk and in the room, so a third agent would have written under Muse's name. It reads and posts in the room, is
-- told of new lines on every tool call, and can be written to by name on the desk.

alter table public.room_messages drop constraint if exists room_messages_author_check;
alter table public.room_messages add constraint room_messages_author_check
  check (author = any (array['desk', 'muse', 'muse 2', 'grok', 'colin', 'thalia', 'adil']));
alter table public.desk_messages drop constraint if exists desk_messages_author_check;
alter table public.desk_messages add constraint desk_messages_author_check
  check (author = any (array['desk', 'muse', 'colin', 'dots', 'muse 2', 'grok']));
alter table public.desk_messages drop constraint if exists desk_messages_for_whom_check;
alter table public.desk_messages add constraint desk_messages_for_whom_check
  check (for_whom = any (array['desk', 'muse', 'colin', 'dots', 'all', 'muse 2', 'grok']));

CREATE OR REPLACE FUNCTION public.room_who(p text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select case
    when lower(btrim(coalesce(p, ''))) ~ '^muse\s*2' then 'muse 2'
    when lower(btrim(coalesce(p, ''))) ~ '^muse( |$)' and lower(btrim(coalesce(p, ''))) !~ '^muse (prospects|text|records)' then 'muse'
    when lower(btrim(coalesce(p, ''))) ~ '^grok' then 'grok'
    when lower(btrim(coalesce(p, ''))) in ('desk', 'the desk') then 'desk'
    when lower(btrim(coalesce(p, ''))) = 'colin' then 'colin'
    when lower(btrim(coalesce(p, ''))) = 'thalia' then 'thalia'
    when lower(btrim(coalesce(p, ''))) in ('adil', 'tyler') then 'adil'
  end
$function$;

CREATE OR REPLACE FUNCTION public.room_post(p_author text, p_body text, p_to text[] DEFAULT NULL::text[], p_reply_to bigint DEFAULT NULL::bigint, p_files uuid[] DEFAULT NULL::uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me text := public.room_who(p_author); v_body text := btrim(coalesce(p_body, '')); tos text[] := '{}'; t text; w text; mid bigint; dup bigint;
        parent public.room_messages; fids uuid[] := coalesce(p_files, '{}'); n_files integer; n_att integer;
begin
  if me is null then return jsonb_build_object('ok', false, 'reason', 'the room is the desk, Muse, Muse 2, Colin and the callers'); end if;
  n_files := coalesce(array_length(fids, 1), 0);
  if n_files > 8 then return jsonb_build_object('ok', false, 'reason', 'eight files on one line at most: send the rest on the next line'); end if;
  if n_files > 0 and (select count(*) from public.room_files f where f.id = any (fids) and f.uploaded_by = me and f.message_id is null) <> n_files then
    return jsonb_build_object('ok', false, 'reason', 'a file named in files is not one you put up, or is already on a line');
  end if;
  if v_body = '' and n_files = 0 then return jsonb_build_object('ok', false, 'reason', 'say something: body is empty'); end if;
  if v_body = '' then
    v_body := (select 'Sent ' || string_agg(f.name, ', ' order by f.at, f.id) from public.room_files f where f.id = any (fids));
    v_body := left(v_body, 2000);
  end if;
  if length(v_body) > 2000 then
    return jsonb_build_object('ok', false, 'reason', 'too long for the room (' || length(v_body) || ' characters; a line holds 2,000). Put the report on the desk and say here that it is there.');
  end if;
  foreach t in array coalesce(p_to, '{}') loop
    if lower(btrim(coalesce(t, ''))) in ('', 'all', 'everyone') then continue; end if;
    w := public.room_who(t);
    if w is null then return jsonb_build_object('ok', false, 'reason', 'nobody in the room is called "' || left(t, 40) || '": name desk, muse, muse 2, grok, colin, thalia or tyler, or leave it out'); end if;
    if public.room_is_caller(me) and public.room_is_caller(w) and w <> me then
      return jsonb_build_object('ok', false, 'reason', 'this line is for the desk, Muse or Colin: a caller does not write to the other caller here');
    end if;
    if w <> me and not (w = any (tos)) then tos := array_append(tos, w); end if;
  end loop;
  -- a caller who names nobody is asking whoever can help: Muse and the desk
  if public.room_is_caller(me) and tos = '{}' then tos := array['muse', 'desk']; end if;
  if p_reply_to is not null then
    select * into parent from public.room_messages where id = p_reply_to;
    if not found or not public.room_can_see(parent, me) then
      return jsonb_build_object('ok', false, 'reason', 'reply_to names a line that is not in the room');
    end if;
  end if;
  -- the same words twice inside two minutes is one line (a client that retried); a line with files is always its own
  if n_files = 0 then
    select m.id into dup from public.room_messages m where m.author = me and m.body = v_body and m.at > now() - interval '2 minutes' order by m.id desc limit 1;
    if dup is not null then return jsonb_build_object('ok', true, 'id', dup, 'already', true); end if;
  end if;
  insert into public.room_messages (author, to_whom, body, reply_to) values (me, tos, v_body, p_reply_to) returning id into mid;
  if n_files > 0 then
    update public.room_files set message_id = mid where id = any (fids) and uploaded_by = me and message_id is null;
    get diagnostics n_att = row_count;
  end if;
  return jsonb_build_object('ok', true, 'id', mid, 'files', coalesce(n_att, 0), 'to', case when tos = '{}' then 'everyone'
    else (select string_agg(public.room_name(x), ', ') from unnest(tos) x) end);
end $function$;

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
