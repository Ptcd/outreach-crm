-- 0242: an opened Sunday tells the agent, and replies nobody answered are put where the agent looks.
--
-- Colin 2026-11-15, a Sunday he had opened that morning (0240): "Wait so muse stopped replying? Why?" ... "Fix it".
-- The server sent texts all day and six owners wrote back (three said yes, one named $150,000). Muse read the replies
-- list 23 times and answered nobody: its rules say "never on Sunday", sunday_open changed the server's switch and told
-- no agent, and it has sent no reply on any Sunday (Nov 1, 8, 15). A desk post is read twice a day; the answers the
-- agent reads every few minutes (sending_status, text_results) said nothing.
--
--   replies_waiting_rows   the one definition of "texted back and has no answer from us yet" (it was inline in
--                          agent_replies_waiting, which now reads it).
--   agent_attention        for the texting agent, two more lines:
--                            sunday   on a Sunday that was opened: the rule is off for today only, work as a weekday.
--                            replies  people who wrote in the last day and have waited over 20 minutes. Not on a
--                                     Sunday that is shut: nothing sends then, and they are answered on Monday.

create or replace function public.replies_waiting_rows(p_days integer default 7)
returns table (from10 text, lead_id uuid, sid text, body text, received_at timestamptz, to_number text)
language sql stable security definer set search_path = public as $$
  with last_in as (
    select distinct on (t.from10) t.from10, t.lead_id, t.sid, t.body, t.received_at, t.to_number
      from public.twilio_inbound t
     where t.received_at > now() - make_interval(days => greatest(1, least(p_days, 30))) and t.lead_id is not null
     order by t.from10, t.received_at desc)
  select li.from10, li.lead_id, li.sid, li.body, li.received_at, li.to_number
    from last_in li join public.leads l on l.id = li.lead_id
   where l.stage not in ('dnc', 'dead', 'closed_no_contact', 'closed_won')
     and not exists (select 1 from public.suppressed_phones s where s.phone10 = li.from10)
     and public.caller_texting(li.lead_id) is null                     -- a caller's card is the caller's
     and not exists (select 1 from public.messages m where m.direction = 'out' and m.channel = 'sms' and m.sent_at > li.received_at
                      and right(regexp_replace(coalesce(m.to_number, ''), '\D', '', 'g'), 10) = li.from10)
     and not exists (select 1 from public.reply_drafts d where d.phone10 = li.from10 and d.inbound_at >= li.received_at
                      and d.status in ('queued', 'sending', 'sent'))
$$;
revoke all on function public.replies_waiting_rows(integer) from public, anon, authenticated;
grant execute on function public.replies_waiting_rows(integer) to service_role;

create or replace function public.agent_replies_waiting(p_days integer default 7) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(public.agent_card(li.lead_id) || jsonb_build_object(
           'reply_to', jsonb_build_object('phone', li.from10, 'our_number', li.to_number, 'text', li.body, 'at', li.received_at),
           'reply_agent_read', (select jsonb_build_object('intent', d.intent, 'outcome', d.outcome, 'suggested_reply', d.body, 'note', d.note)
                                  from public.reply_drafts d where d.inbound_sid = li.sid),
           'hot', exists (select 1 from public.hot_alerts h where h.lead_id = li.lead_id and h.created_at > now() - interval '3 days'))
         order by li.received_at), '[]'::jsonb)
    from public.replies_waiting_rows(p_days) li
$$;
revoke all on function public.agent_replies_waiting(integer) from public, anon, authenticated;
grant execute on function public.agent_replies_waiting(integer) to service_role;

create or replace function public.agent_attention(p_agent text, p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  who text := case when lower(coalesce(p_agent, '')) like 'muse 2%' then 'muse 2' when lower(coalesce(p_agent, '')) like 'muse%' then 'muse' else lower(coalesce(p_agent, '')) end;
  last_read timestamptz; unread integer := 0; latest text; steps jsonb := '[]'::jsonb; n_late integer := 0; out jsonb := '{}'::jsonb;
  d date := (p_now at time zone 'America/Chicago')::date;
  is_sunday boolean := extract(isodow from (p_now at time zone 'America/Chicago')::date) = 7;
  c public.campaign_control; opened boolean := false; n_replies integer := 0; oldest timestamptz;
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
  end if;
  return case when out = '{}'::jsonb then null else out end;
end $$;
revoke all on function public.agent_attention(text, timestamptz) from public, anon, authenticated;
grant execute on function public.agent_attention(text, timestamptz) to service_role;
