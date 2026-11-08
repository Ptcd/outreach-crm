-- 0204: a caller the assistant did not recognise (Colin 2026-11-07: "if not it should add that number to our system
-- during or post call somehow attached to the card"). The assistant asks an unknown caller for the house number,
-- street and town and their name; after the call, the address is matched to a card: one match -> the phone goes on
-- that card as a contact and the call is written up there; no match -> a new card is made for that house with the
-- caller as owner of record and the phone on it (the 0168 split gives it a caller); several matches -> the callback
-- task is made with no card and names the candidates for the caller to pick. voice_agent_result is otherwise 0202.

-- the house number and the first street word, so "N7073 Hwy 12" matches "N7073 HWY 12" and "n7073 highway 12"
create or replace function public.voice_address_key(p text) returns text language sql immutable as $$
  select nullif(regexp_replace(lower(coalesce(p, '')), '[^a-z0-9 ]', '', 'g'), '')
$$;

create or replace function public.voice_match_card(p_address text, p_municipality text default null)
returns table (lead_id uuid, owner_name text, property_address text, municipality text) language sql stable security definer set search_path = public as $$
  with k as (
    select regexp_replace(public.voice_address_key(p_address), '^([a-z]?[0-9]+[a-z]?)\s+.*$', '\1') as num,
           split_part(regexp_replace(public.voice_address_key(p_address), '^[a-z]?[0-9]+[a-z]?\s+', ''), ' ', 1) as street,
           public.voice_address_key(p_municipality) as town)
  select l.id, l.owner_name, l.property_address, l.municipality
    from public.leads l, k
   where k.num <> '' and k.num ~ '[0-9]'
     and public.voice_address_key(l.property_address) like k.num || ' %'
     and (k.street = '' or public.voice_address_key(l.property_address) like '% ' || left(k.street, 4) || '%')
     and (k.town is null or k.town = '' or public.voice_address_key(l.municipality) like '%' || regexp_replace(k.town, '^(city|town|village) of ', '') || '%')
     and l.stage not in ('dnc')
   order by (l.locked_to is not null) desc, l.updated_at desc
   limit 5
$$;
revoke all on function public.voice_match_card(text, text) from public, anon;
grant execute on function public.voice_match_card(text, text) to authenticated, service_role;

create or replace function public.voice_agent_result(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  sid text := p->>'call_sid';
  ph text := right(regexp_replace(coalesce(p->>'from', ''), '\D', '', 'g'), 10);
  x jsonb := p->'extraction';
  l public.leads;
  who public.team_person;
  due timestamptz;
  tid uuid;
  outcome text;
  lane text := coalesce(x->>'lane', 'unclear');
  words text;
  body text;
  secs integer := nullif(p->>'seconds', '')::integer;
  tz text := 'America/Chicago';
  wa text;
  matched integer := 0;
  attached text := null;          -- how the phone reached a card: 'on the card' | 'matched the address' | 'new card' | 'several cards'
  cands text := null;
begin
  if sid is null or sid = '' then return jsonb_build_object('ok', false, 'reason', 'call_sid is required'); end if;
  if nullif(p->>'lead_id', '') is not null then select * into l from public.leads where id = (p->>'lead_id')::uuid; end if;
  if l.id is null and ph <> '' then
    select l2.* into l from public.contacts c join public.leads l2 on l2.id = c.lead_id
     where c.kind = 'phone' and c.value_normalized = ph
     order by (l2.locked_to is not null) desc, l2.locked_at desc nulls last limit 1;
  end if;
  if l.id is not null then attached := 'on the card'; end if;

  if x is null or jsonb_typeof(x) <> 'object' then
    perform public.inbound_call_log(sid, coalesce(p->>'from', ''), coalesce(p->>'to', ''), 'missed', secs, null);
    insert into public.voice_calls (call_sid, lead_id, from10, to_number, ended_at, seconds, transcript, extraction, outcome)
    values (sid, l.id, ph, p->>'to', now(), secs, p->'transcript', null, coalesce(p->>'outcome', 'no_agent'))
    on conflict (call_sid) do update set ended_at = now(), seconds = excluded.seconds, transcript = excluded.transcript, outcome = excluded.outcome;
    return jsonb_build_object('ok', true, 'lead_id', l.id, 'outcome', coalesce(p->>'outcome', 'no_agent'), 'logged', 'missed call');
  end if;

  -- an unknown number with an address: the card that house is on, or a new card for it
  if l.id is null and nullif(btrim(coalesce(x->>'property_address', '')), '') is not null and not coalesce((x->>'stop')::boolean, false)
     and not coalesce((x->>'wrong_person')::boolean, false) then
    select count(*), string_agg(m.owner_name || ' at ' || m.property_address || coalesce(', ' || m.municipality, ''), ' | ')
      into matched, cands from public.voice_match_card(x->>'property_address', x->>'municipality') m;
    if matched = 1 then
      select l2.* into l from public.leads l2 where l2.id = (select m.lead_id from public.voice_match_card(x->>'property_address', x->>'municipality') m limit 1);
      attached := 'matched the address';
    elsif matched = 0 then
      insert into public.leads (owner_name, owner_type, property_address, municipality, stage, source, reasons_to_sell, notes)
      values (coalesce(nullif(btrim(x->>'caller_name'), ''), 'Caller (name not given)'), 'individual', btrim(x->>'property_address'), nullif(btrim(x->>'municipality'), ''),
              'reply_received', 'voice_agent', array['called us'],
              'Made by the assistant from an inbound call on ' || to_char(now() at time zone tz, 'Mon DD') || ': the caller gave this address; the number was not on any card.')
      returning * into l;
      attached := 'new card';
    else
      attached := 'several cards';
    end if;
    if l.id is not null and ph ~ '^[0-9]{10}$' and not exists (select 1 from public.contacts c where c.lead_id = l.id and c.kind = 'phone' and coalesce(c.value_normalized, c.value) = ph) then
      insert into public.contacts (lead_id, kind, value, value_normalized, person_name, source, status, note, created_at, updated_at)
      values (l.id, 'phone', ph, ph, nullif(btrim(x->>'caller_name'), ''), 'voice agent', 'ok',
              'They called the seller line from this number and gave the address (assistant, ' || to_char(now() at time zone tz, 'Mon DD') || ')', now(), now());
    end if;
  end if;

  words := concat_ws(E'\n',
    case when nullif(x->>'caller_name', '') is not null then 'Who: ' || (x->>'caller_name') end,
    case when attached in ('matched the address', 'new card') then 'Number ' || ph || ' ' || attached || ' (' || coalesce(x->>'property_address', '') || coalesce(', ' || nullif(x->>'municipality', ''), '') || ')' end,
    case when attached = 'several cards' then 'Their address matches several cards, pick the right one and add the number: ' || coalesce(cands, '') end,
    case when nullif(x->>'why', '') is not null then 'Why: ' || (x->>'why') end,
    case when nullif(x->>'condition', '') is not null then 'House: ' || (x->>'condition') end,
    case when nullif(x->>'who_there', '') is not null then 'Who is there / timeline: ' || (x->>'who_there') || coalesce(' / ' || nullif(x->>'timeline', ''), '') end,
    case when nullif(x->>'their_number', '') is not null then 'Their number, their words: ' || (x->>'their_number') end,
    case when nullif(x->>'who_signs', '') is not null then 'On the title: ' || (x->>'who_signs') end,
    case when nullif(x->>'notes', '') is not null then 'Notes: ' || (x->>'notes') end);

  who := coalesce(l.locked_to, public.on_shift_person());
  if who not in ('thalia', 'adil') then who := public.on_shift_person(); end if;

  if l.id is null then
    -- no card: a stop on an unknown number still blocks it; otherwise the on-shift caller gets the callback with what was said
    if coalesce((x->>'stop')::boolean, false) and ph ~ '^[0-9]{10}$' then
      insert into public.suppressed_phones (phone10, reason, source) values (ph, 'dnc_call', 'voice_agent') on conflict (phone10) do nothing;
      outcome := 'stop';
    elsif coalesce((x->>'wrong_person')::boolean, false) or lane = 'never' then
      outcome := case when lane = 'never' then 'never' else 'wrong_person' end;
    else
      due := coalesce(nullif(x->>'callback_at', '')::timestamptz, now() + interval '30 minutes');
      if due < now() then due := now() + interval '30 minutes'; end if;
      insert into public.tasks (lead_id, due_at, kind, owner, note, source, source_key, title, phone10)
      values (null, due, 'call', who, left(concat_ws(E'\n', 'They called the seller line and talked to the assistant; no card yet.', words), 1500),
              'voice_agent', 'voice:' || sid, 'Call back: they talked to the assistant (no card)', ph)
      on conflict (source_key) do update set due_at = excluded.due_at, note = excluded.note, done_at = null, updated_at = now()
      returning id into tid;
      outcome := case when attached = 'several cards' then 'callback_booked' else 'no_card' end;
    end if;
    insert into public.voice_calls (call_sid, lead_id, from10, to_number, ended_at, seconds, transcript, extraction, outcome, task_id)
    values (sid, null, ph, p->>'to', now(), secs, p->'transcript', x, outcome, tid)
    on conflict (call_sid) do update set ended_at = now(), seconds = excluded.seconds, transcript = excluded.transcript, extraction = excluded.extraction, outcome = excluded.outcome, task_id = excluded.task_id;
    select m.alert_whatsapp into wa from public.team_members m where m.person = who;
    return jsonb_build_object('ok', true, 'lead_id', null, 'outcome', outcome, 'owner', who::text, 'owner_whatsapp', wa, 'task_id', tid, 'due_at', due,
                              'owner_name', x->>'caller_name', 'address', x->>'property_address', 'municipality', x->>'municipality', 'attached', attached);
  end if;

  if coalesce((x->>'stop')::boolean, false) then
    outcome := 'stop';
    if coalesce((x->>'wrong_person')::boolean, false) then
      perform public.block_wrong_person_phone(l.id, ph, 'voice_agent');
      outcome := 'wrong_person';
    else
      insert into public.suppressed_phones (phone10, reason, source) values (ph, 'dnc_call', 'voice_agent') on conflict (phone10) do nothing;
      update public.contacts set suppressed = true where kind = 'phone' and value_normalized = ph and suppressed is distinct from true;
      update public.leads set stage = 'dnc' where id = l.id and stage not in ('closed_won', 'under_contract');
    end if;
  elsif coalesce((x->>'wrong_person')::boolean, false) then
    perform public.block_wrong_person_phone(l.id, ph, 'voice_agent');
    outcome := 'wrong_person';
  elsif lane = 'never' then
    outcome := 'never';
    update public.leads set stage = 'dead', dead_reason = left(coalesce(nullif(x->>'notes', ''), 'not a fit (assistant call)'), 200)
     where id = l.id and stage in ('postcard_mailed', 'opener_queued', 'opener_sent', 'reply_received', 'ai_qualifying', 'colin_call', 'follow_up');
  else
    due := nullif(x->>'callback_at', '')::timestamptz;
    if due is null or due < now() then
      due := now() + interval '30 minutes';
      if (due at time zone tz)::time >= time '19:00' or (due at time zone tz)::time < time '09:00' then
        due := ((due at time zone tz)::date + case when (due at time zone tz)::time >= time '19:00' then 1 else 0 end)::timestamp + time '09:30';
        due := due at time zone tz;
      end if;
    end if;
    outcome := case when lane = '3' then 'not_now' else 'callback_booked' end;
    insert into public.tasks (lead_id, due_at, kind, owner, note, source, source_key, title, phone10)
    values (l.id, due, 'call', who, left(concat_ws(E'\n', 'They spoke with the assistant' || coalesce(' (lane ' || nullif(lane, 'unclear') || ')', '') || '.', words,
                                                   case when nullif(x->>'callback_window', '') is not null then 'They asked for: ' || (x->>'callback_window') end), 1500),
            'voice_agent', 'voice:' || l.id::text, 'Call back: they talked to the assistant', ph)
    on conflict (source_key) do update set due_at = excluded.due_at, owner = excluded.owner, note = excluded.note, done_at = null, phone10 = excluded.phone10, updated_at = now()
    returning id into tid;
    update public.leads set say_next = left('They called and talked to the assistant' || coalesce(' about ' || nullif(x->>'why', ''), '') || '. Pick up from there.', 300),
           next_action = 'Call back (' || initcap(who::text) || ')', next_action_at = due,
           stage = case when stage in ('postcard_mailed', 'opener_queued', 'opener_sent') then 'reply_received'::public.lead_stage else stage end,
           last_inbound_at = greatest(coalesce(last_inbound_at, now()), now())
     where id = l.id;
  end if;

  body := 'The assistant answered their call' || coalesce(' (' || secs::text || ' s)', '') || E'.\n' || coalesce(words, '(nothing gathered)') ||
          case when outcome in ('callback_booked', 'not_now') then E'\nCallback set for ' || to_char(due at time zone tz, 'Dy Mon DD HH12:MI AM') || ' (' || initcap(who::text) || ')' else E'\nOutcome: ' || outcome end;
  insert into public.messages (lead_id, direction, channel, body, from_number, to_number, source_key, status, sent_at)
  values (l.id, 'in', 'call', left(body, 2000), coalesce(p->>'from', '+1' || ph), p->>'to', 'voice:' || sid, 'ai_answered', now())
  on conflict (source_key) do nothing;
  update public.inbound_calls set status = 'ai_answered', task_id = coalesce(tid, task_id), updated_at = now() where call_sid = sid;
  perform public.belt_event(l.id, 'inbound_call', jsonb_build_object('key', 'voice:' || sid, 'kind', 'assistant', 'outcome', outcome, 'lane', lane,
                                                                      'attached', attached, 'said', left(coalesce(words, ''), 300)), 'voice agent', now());

  insert into public.voice_calls (call_sid, lead_id, from10, to_number, ended_at, seconds, transcript, extraction, outcome, task_id)
  values (sid, l.id, ph, p->>'to', now(), secs, p->'transcript', x, outcome, tid)
  on conflict (call_sid) do update set lead_id = excluded.lead_id, ended_at = now(), seconds = excluded.seconds, transcript = excluded.transcript,
    extraction = excluded.extraction, outcome = excluded.outcome, task_id = excluded.task_id;

  select m.alert_whatsapp into wa from public.team_members m where m.person = who;
  return jsonb_build_object('ok', true, 'lead_id', l.id, 'outcome', outcome, 'owner', who::text, 'owner_whatsapp', wa, 'task_id', tid, 'due_at', due,
                            'owner_name', l.owner_name, 'address', l.property_address, 'municipality', l.municipality, 'attached', attached);
end $$;
