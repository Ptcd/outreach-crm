-- 0299: the call offer works from the tools a texting run already has.
-- Muse, 2026-11-22, after its first pass under the new rules: "can't actually be booked from the texting checks yet.
-- The helper doesn't expose the call-booking tools." The door does offer call_times and book_call to Muse's key (they
-- are in its texting scope and its key has no narrowed list); Muse's own run has a fixed list of tools it calls, and
-- in two weeks it never called a call tool of any kind, call_next included. Rather than wait on that list:
--   * replies_waiting carries `call` on every row: the card's caller, on now or not, and the times to offer.
--   * send_reply takes book_call_at (the time they agreed to) or call_now (true): the door books the call first and
--     sends the reply only when the booking stood. The words that agree are the seller's latest text when none are given.

create or replace function public.latest_inbound_text(p_lead_id uuid, p_phone10 text) returns text
language sql stable security definer set search_path = public as $fn$
  select left(btrim(t.body), 500) from public.twilio_inbound t
   where t.lead_id = p_lead_id and (coalesce(p_phone10, '') = '' or t.from10 = p_phone10) and coalesce(btrim(t.body), '') <> ''
   order by t.received_at desc limit 1
$fn$;
revoke all on function public.latest_inbound_text(uuid, text) from public, anon, authenticated;
grant execute on function public.latest_inbound_text(uuid, text) to service_role;

CREATE OR REPLACE FUNCTION public.agent_replies_waiting(p_days integer DEFAULT 7)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(jsonb_agg(public.agent_card(li.lead_id) || jsonb_build_object(
           'reply_to', jsonb_build_object('phone', li.from10, 'our_number', li.to_number, 'text', li.body, 'at', li.received_at),
           'reply_agent_read', (select jsonb_build_object('intent', d.intent, 'outcome', d.outcome, 'suggested_reply', d.body, 'note', d.note)
                                  from public.reply_drafts d where d.inbound_sid = li.sid),
           'hot', exists (select 1 from public.hot_alerts h where h.lead_id = li.lead_id and h.created_at > now() - interval '3 days'),
           -- 0299: the call offer rides on the row, so a run that only has replies_waiting and send_reply can make it
           'call', public.agent_call_times(li.lead_id))
         order by li.received_at), '[]'::jsonb)
    from public.replies_waiting_rows(p_days) li
$function$;

CREATE OR REPLACE FUNCTION public.agent_call_next(p_lead_id uuid, p_phone text, p_words text, p_agent text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare l public.leads; ph text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10); tz text := 'America/Chicago';
        t_now timestamp := now() at time zone 'America/Chicago'; who public.team_person; tid uuid;
        ph_hour boolean;
begin
  select * into l from public.leads where id = p_lead_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card'); end if;
  if l.stage in ('dnc', 'dead', 'closed_no_contact', 'closed_won', 'under_contract', 'walkthrough_booked', 'offer') then
    return jsonb_build_object('ok', false, 'reason', 'this card is ' || l.stage || ': nothing to call');
  end if;
  if coalesce(l.elderly_or_ill, false) or coalesce(l.grief, false) then
    return jsonb_build_object('ok', false, 'reason', 'an older, ill or grieving owner: answer by text, gently, or tell Colin');
  end if;
  if l.human_takeover_at is not null then return jsonb_build_object('ok', false, 'reason', 'Colin has this one'); end if;
  if length(ph) <> 10 then return jsonb_build_object('ok', false, 'reason', 'phone = the number that texted us'); end if;
  if exists (select 1 from public.suppressed_phones s where s.phone10 = ph) then return jsonb_build_object('ok', false, 'reason', 'that phone opted out'); end if;
  if coalesce(btrim(p_words), '') = '' then p_words := public.latest_inbound_text(p_lead_id, ph); end if;      -- 0299
  if coalesce(btrim(p_words), '') = '' then return jsonb_build_object('ok', false, 'reason', 'words = what they texted, word for word'); end if;
  who := case when extract(isodow from t_now) in (6, 7) then 'adil' else 'thalia' end;
  ph_hour := extract(isodow from t_now) between 1 and 5 and t_now::time between time '15:45' and time '18:15';
  select id into tid from public.tasks where lead_id = p_lead_id and source = 'call_next' and done_at is null limit 1;
  if tid is not null then
    update public.tasks set quote = left(btrim(p_words), 500), phone10 = ph, due_at = least(due_at, now()) where id = tid;
  else
    insert into public.tasks (lead_id, due_at, kind, owner, source, title, quote, phone10, note)
    values (p_lead_id, now(), 'call', who, 'call_next', 'Texted back: call next', left(btrim(p_words), 500), ph,
            'Call next: they texted back with a bit of interest (' || coalesce(nullif(btrim(p_agent), ''), 'Muse') || ')')
    returning id into tid;
  end if;
  return jsonb_build_object('ok', true, 'task_id', tid, 'caller', who, 'power_hour_now', ph_hour,
    'note', case when ph_hour then 'next on Power hour: do not text them back unless the call does not reach them'
                 else 'Power hour is weekdays 4-6 PM: until then it waits on the caller''s list; a short reply by text may be kinder' end);
end $function$;

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
  if coalesce(btrim(p_words), '') = '' then p_words := public.latest_inbound_text(p_lead_id, ph); end if;      -- 0299
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
