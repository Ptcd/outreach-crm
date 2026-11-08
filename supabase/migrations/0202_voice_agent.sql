-- 0202: the inbound AI assistant for seller calls nobody picked up (Colin 2026-11-07: "Build the agent"). After the
-- app has rung twice and nobody answered, pm-phone hands the call to the voice-agent function, which runs the four
-- steps of the seller call flow (why, the house, who is there and when, their number in their words), never says a
-- number of its own, and books a callback. This is what it writes back, in one call, with the service key.
--
--   voice_calls           the whole call, append-only: transcript, what was extracted, the outcome
--   voice_agent_result(p) one door: the call logged on the card, the callback task for the card's caller (the four
--                         answers in the note, due at the time the seller gave), the card's "when you call back, say"
--                         line, a stop or a wrong person handled the same way the text side does, and who to buzz.
--                         Nothing extracted (the assistant could not run): the plain missed call, as before.

create table if not exists public.voice_calls (
  call_sid text primary key,
  lead_id uuid references public.leads(id) on delete set null,
  from10 text,
  to_number text,
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  seconds integer,
  transcript jsonb,                 -- [{role: agent|caller, text}]
  extraction jsonb,                 -- the four answers, lane, callback, flags
  outcome text,                     -- callback_booked | not_now | never | wrong_person | stop | hung_up | no_agent | error
  task_id uuid,
  created_at timestamptz not null default now()
);
alter table public.voice_calls enable row level security;
drop policy if exists voice_calls_team_read on public.voice_calls;
create policy voice_calls_team_read on public.voice_calls for select to authenticated using (public.is_team());
grant select on public.voice_calls to authenticated;

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
begin
  if sid is null or sid = '' then return jsonb_build_object('ok', false, 'reason', 'call_sid is required'); end if;
  -- the card: the one the hand-off named, else the phone's card (a locked one first)
  if nullif(p->>'lead_id', '') is not null then select * into l from public.leads where id = (p->>'lead_id')::uuid; end if;
  if l.id is null and ph <> '' then
    select l2.* into l from public.contacts c join public.leads l2 on l2.id = c.lead_id
     where c.kind = 'phone' and c.value_normalized = ph
     order by (l2.locked_to is not null) desc, l2.locked_at desc nulls last limit 1;
  end if;

  -- the assistant could not run (no key, a crash before the first word): the plain missed call, as before
  if x is null or jsonb_typeof(x) <> 'object' then
    perform public.inbound_call_log(sid, coalesce(p->>'from', ''), coalesce(p->>'to', ''), 'missed', secs, null);
    insert into public.voice_calls (call_sid, lead_id, from10, to_number, ended_at, seconds, transcript, extraction, outcome)
    values (sid, l.id, ph, p->>'to', now(), secs, p->'transcript', null, coalesce(p->>'outcome', 'no_agent'))
    on conflict (call_sid) do update set ended_at = now(), seconds = excluded.seconds, transcript = excluded.transcript, outcome = excluded.outcome;
    return jsonb_build_object('ok', true, 'lead_id', l.id, 'outcome', coalesce(p->>'outcome', 'no_agent'), 'logged', 'missed call');
  end if;

  words := concat_ws(E'\n',
    case when nullif(x->>'why', '') is not null then 'Why: ' || (x->>'why') end,
    case when nullif(x->>'condition', '') is not null then 'House: ' || (x->>'condition') end,
    case when nullif(x->>'who_there', '') is not null then 'Who is there / timeline: ' || (x->>'who_there') || coalesce(' / ' || nullif(x->>'timeline', ''), '') end,
    case when nullif(x->>'their_number', '') is not null then 'Their number, their words: ' || (x->>'their_number') end,
    case when nullif(x->>'who_signs', '') is not null then 'On the title: ' || (x->>'who_signs') end,
    case when nullif(x->>'notes', '') is not null then 'Notes: ' || (x->>'notes') end);

  if l.id is null then
    -- no card for this phone: keep the call, tell whoever is on shift
    insert into public.voice_calls (call_sid, lead_id, from10, to_number, ended_at, seconds, transcript, extraction, outcome)
    values (sid, null, ph, p->>'to', now(), secs, p->'transcript', x, 'no_card')
    on conflict (call_sid) do update set ended_at = now(), seconds = excluded.seconds, transcript = excluded.transcript, extraction = excluded.extraction, outcome = 'no_card';
    return jsonb_build_object('ok', true, 'lead_id', null, 'outcome', 'no_card', 'owner', public.on_shift_person()::text);
  end if;

  who := coalesce(l.locked_to, public.on_shift_person());
  if who not in ('thalia', 'adil') then who := public.on_shift_person(); end if;

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
    -- a callback for the card's caller: at the time they gave, else the next working half hour
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
                                                                      'said', left(coalesce(words, ''), 300)), 'voice agent', now());

  insert into public.voice_calls (call_sid, lead_id, from10, to_number, ended_at, seconds, transcript, extraction, outcome, task_id)
  values (sid, l.id, ph, p->>'to', now(), secs, p->'transcript', x, outcome, tid)
  on conflict (call_sid) do update set lead_id = excluded.lead_id, ended_at = now(), seconds = excluded.seconds, transcript = excluded.transcript,
    extraction = excluded.extraction, outcome = excluded.outcome, task_id = excluded.task_id;

  select m.alert_whatsapp into wa from public.team_members m where m.person = who;
  return jsonb_build_object('ok', true, 'lead_id', l.id, 'outcome', outcome, 'owner', who::text, 'owner_whatsapp', wa, 'task_id', tid, 'due_at', due,
                            'owner_name', l.owner_name, 'address', l.property_address, 'municipality', l.municipality);
end $$;
revoke all on function public.voice_agent_result(jsonb) from public, anon, authenticated;
grant execute on function public.voice_agent_result(jsonb) to service_role;
