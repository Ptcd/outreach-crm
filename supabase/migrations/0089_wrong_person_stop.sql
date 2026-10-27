-- Someone else's stop on the owner's phone (Colin 2026-10-27, on a voicemail "Please erase my number out of your
-- system ... There is no Nora at this number. Please stop calling me": "System should automatically add these ones to do
-- not contact for that phone number, keep card open").
--
-- Before: a removal text was always the owner's STOP. "Wrong number, STOP" (10-22), "this isn't Nora number ... leave
-- me alone" (10-27) and "the number you found ... doesn't belong to her. please remove" each closed the owner's card
-- and blocked every one of the owner's phones, and a voicemail's words did nothing at all.
-- Now:
--   * a removal text that says the owner is not on this phone (the reply agent's outcome wrong_number with removal):
--     that phone is blocked for good on every card (suppressed_phones reason 'wrong_person_stop', which closes nothing)
--     and marked bad on this card; the card stays open and goes the wrong-number way (data_fix: WPIE plans the owner's
--     next number). A plain STOP from the owner still closes the card, as before.
--   * a voicemail's words, once transcribed: asking us to stop AND saying the owner is not at this number is the same
--     phone-only block (card open, the wrong-number way, the call-back task closed). Asking to stop without saying so is
--     the owner's stop: the number is blocked as a do-not-contact call, which closes the card like a texted STOP.
--   * Today's missed calls tell "Number blocked" (card still open) apart from "Card closed".

create or replace function public.block_wrong_person_phone(p_lead_id uuid, p_phone10 text, p_source text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_phone10 !~ '^[0-9]{10}$' then return; end if;
  insert into public.suppressed_phones (phone10, reason, source) values (p_phone10, 'wrong_person_stop', p_source)
  on conflict (phone10) do nothing;
  update public.contacts set suppressed = true where kind = 'phone' and value_normalized = p_phone10 and suppressed is distinct from true;
  update public.contacts set status = 'bad', note = concat_ws('; ', note, format('not the owner, asked us to stop (%s)', p_source))
   where lead_id = p_lead_id and kind = 'phone' and value_normalized = p_phone10 and status is distinct from 'bad';
end $$;
revoke all on function public.block_wrong_person_phone(uuid, text, text) from public, anon, authenticated;
grant execute on function public.block_wrong_person_phone(uuid, text, text) to service_role;

-- a wrong person's stop is not the card's removal: the belt goes the wrong-number way
create or replace function public.belt_on_reply_draft() returns trigger
language plpgsql security definer set search_path = public as $$
declare pl jsonb;
begin
  if new.lead_id is null or new.kind in ('belt', 'team') or new.is_test then return new; end if;
  pl := jsonb_build_object('key', 'draft:' || new.id::text, 'intent', new.intent, 'kind', new.kind, 'outcome', new.outcome,
          'removal', new.kind = 'removal' and coalesce(new.outcome, '') <> 'wrong_number',
          'said', left(coalesce(new.inbound_body, ''), 300), 'at', new.inbound_at,
          'facts', coalesce(new.facts, '{}'::jsonb), 'callback_slot', new.facts->>'callback_slot', 'reply', left(coalesce(new.body, ''), 300));
  perform public.belt_event(new.lead_id, 'inbound_text', pl, 'reply agent', coalesce(new.created_at, now()));
  return new;
end $$;

create or replace function public.reply_record_decision(p_sid text, p_intent text, p_kind text, p_removal boolean, p_outcome text, p_body text, p_draft_source text, p_note text, p_rules_version text, p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  t public.twilio_inbound;
  c public.campaign_control;
  st text;
  did uuid;
  owner_phones text[];
  oid bigint;
begin
  select * into t from public.twilio_inbound where sid = p_sid;
  if not found then return jsonb_build_object('ok', false, 'reason', 'unknown_inbound'); end if;
  select * into c from public.campaign_control where id = 1;
  update public.reply_drafts set status = 'superseded', updated_at = p_now
   where phone10 = t.from10 and status in ('awaiting_approval', 'would_send', 'queued') and inbound_at < t.received_at;

  st := case
    -- the sender agent answers (agent_runs_texting): read, recorded, nothing queued and nothing for the team to approve
    when c.agent_runs_texting then 'no_reply'
    when p_body is null or btrim(p_body) = '' then case when p_kind = 'candidate' then 'awaiting_approval' else 'no_reply' end
    when p_kind = 'candidate' then 'awaiting_approval'
    when c.routine_enabled then 'queued'
    else 'would_send' end;
  insert into public.reply_drafts (inbound_sid, phone10, our_number, lead_id, inbound_body, inbound_at, intent, kind, outcome,
                                   note, body, draft_source, status, send_after, rules_version, created_at, updated_at)
  values (t.sid, t.from10, t.to_number, t.lead_id, t.body, t.received_at, p_intent, p_kind, p_outcome, p_note,
          nullif(btrim(coalesce(p_body, '')), ''), p_draft_source, st,
          case when st = 'queued' then public.auto_reply_at(p_now) else null end,
          p_rules_version, p_now, p_now)
  on conflict (inbound_sid) do nothing
  returning id into did;
  if did is null then return jsonb_build_object('ok', false, 'reason', 'already_decided'); end if;

  oid := (select l.wpie_owner_id from public.leads l where l.id = t.lead_id);
  if p_removal and p_outcome = 'wrong_number' then
    -- not the owner, asked to stop: this phone only; the card stays open for the owner's other numbers
    perform public.block_wrong_person_phone(t.lead_id, t.from10, 'reply_agent');
    update public.leads set stage = 'data_fix' where id = t.lead_id and stage in ('postcard_mailed', 'opener_queued', 'opener_sent', 'reply_received');
  elsif p_removal then
    select coalesce(array_agg(distinct ct.value_normalized), '{}') into owner_phones
      from public.contacts ct join public.leads l on l.id = ct.lead_id
     where ct.kind = 'phone' and ct.value_normalized is not null and (ct.value_normalized = t.from10 or l.wpie_owner_id = oid);
    owner_phones := array_append(owner_phones, t.from10);
    insert into public.suppressed_phones (phone10, reason, source)
      select distinct p, case when p = t.from10 then 'removal_reply' else 'removal_reply_other_phone' end, 'reply_agent'
        from unnest(owner_phones) p where p ~ '^[0-9]{10}$'
    on conflict (phone10) do nothing;
    update public.contacts set suppressed = true where value_normalized = any(owner_phones);
    update public.leads set stage = 'dnc' where id = t.lead_id;
  elsif p_outcome = 'wrong_number' then
    update public.contacts set status = 'bad', note = coalesce(note || '; ', '') || 'wrong number (reply agent)'
     where value_normalized = t.from10 and lead_id = t.lead_id;
    update public.leads set stage = 'data_fix' where id = t.lead_id and stage in ('postcard_mailed', 'opener_queued', 'opener_sent', 'reply_received');
  elsif p_outcome = 'not_interested' then
    update public.leads set stage = 'dead', dead_reason = coalesce(nullif(p_note, ''), 'not interested')
     where id = t.lead_id and stage in ('postcard_mailed', 'opener_queued', 'opener_sent', 'reply_received', 'ai_qualifying');
  else
    update public.leads set stage = case when p_kind = 'candidate' then 'reply_received'::public.lead_stage else 'ai_qualifying'::public.lead_stage end
     where id = t.lead_id and stage in ('postcard_mailed', 'opener_queued', 'opener_sent');
  end if;
  update public.leads set last_inbound_at = greatest(coalesce(last_inbound_at, t.received_at), t.received_at) where id = t.lead_id;
  return jsonb_build_object('ok', true, 'id', did, 'status', st);
end $function$;

-- a voicemail's words: a stop, and whether it says the owner is not at this number
create or replace function public.voicemail_asks_to_stop(p_words text) returns boolean language sql immutable as $$
  select coalesce(p_words, '') ~* '(erase|remove|delete|take|lose|drop) (my|this|the) (phone |cell )?(number|#)|(take|get) (me|my number|this number) off|off (of )?your (list|system|database|records)|stop (calling|texting|contacting|messaging)|(do not|don''t|dont|quit|never|no more) (call|text|contact|bother)|leave me alone'
$$;
create or replace function public.words_say_wrong_person(p_words text) returns boolean language sql immutable as $$
  select coalesce(p_words, '') ~* 'wrong (number|person|guy|lady)|not the (owner|right (number|person))|(is ?n[o'']?t|aint|ain''t) (?!my\M)[a-z]+(''?s)? (number|phone|cell)|(does ?n[o'']?t|don''t|do not) belong to|\mno (?!more\M|longer\M)[a-z]+ (at|on) this (number|phone|cell)|there is no (?!need\M|way\M|interest\M)[a-z]+ (at|here|on)|(no ?one|nobody) (here )?(by|named|with) (that|the name)|(don''t|do not|dont) know (any ?(one|body)|who)|never (owned|lived)'
$$;

create or replace function public.voicemail_stop() returns trigger
language plpgsql security definer set search_path = public as $$
declare words text; ph text; tid uuid; l public.leads;
begin
  words := substring(new.body from 'Voicemail: "(.*)"');
  if words is null or not public.voicemail_asks_to_stop(words) then return new; end if;
  ph := right(regexp_replace(coalesce(new.from_number, ''), '\D', '', 'g'), 10);
  if ph !~ '^[0-9]{10}$' or new.lead_id is null then return new; end if;
  -- Colin's test phone plays a sample owner: never blocked by its own test voicemails
  if exists (select 1 from public.campaign_control where id = 1 and ph = any(coalesce(test_phones, '{}'))) then return new; end if;
  select task_id into tid from public.inbound_calls where message_id = new.id limit 1;
  update public.tasks set done_at = now(),
         note = concat_ws(E'\n', note, 'They asked us to stop calling this number: blocked, no call back.')
   where id = tid and done_at is null;
  if public.words_say_wrong_person(words) then
    perform public.block_wrong_person_phone(new.lead_id, ph, 'voicemail');
    select * into l from public.leads where id = new.lead_id;
    if l.stage::text not in ('dnc', 'closed_won', 'under_contract') then
      perform public.belt_event(new.lead_id, 'inbound_text', jsonb_build_object('key', 'vmstop:' || new.id::text, 'kind', 'voicemail',
        'intent', 'wrong_number', 'outcome', 'wrong_number', 'removal', false, 'said', left(words, 300)), 'voicemail', now());
    end if;
    update public.messages set body = body || E'\nBlocked: not the owner, asked us to stop calling this number. The card stays open for the owner''s other numbers.'
     where id = new.id;
  else
    insert into public.suppressed_phones (phone10, reason, source) values (ph, 'dnc_call', 'voicemail') on conflict (phone10) do nothing;
    update public.contacts set suppressed = true where kind = 'phone' and value_normalized = ph and suppressed is distinct from true;
    update public.messages set body = body || E'\nBlocked: they asked us to stop calling. Do not call.' where id = new.id;
  end if;
  return new;
end $$;
drop trigger if exists voicemail_stop on public.messages;
create trigger voicemail_stop after update of body on public.messages
  for each row when (new.channel = 'call' and new.direction = 'in' and position('Voicemail: "' in coalesce(new.body, '')) > 0
                     and position('Voicemail: "' in coalesce(old.body, '')) = 0)
  execute function public.voicemail_stop();

-- Today's missed calls: a blocked number apart from a closed card
create or replace function public.missed_calls_recent(p_hours integer default 48) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'call_sid', ic.call_sid, 'at', ic.created_at, 'phone', ic.from10, 'status', ic.status, 'voicemail', ic.voicemail,
      'words', nullif(substring(m.body from 'Voicemail: "(.*)"'), ''),
      'lead_id', l.id, 'owner_name', l.owner_name, 'property_address', l.property_address, 'municipality', l.municipality, 'stage', l.stage,
      'closed', l.stage::text in ('dnc', 'dead', 'closed_no_contact') or exists (select 1 from public.suppressed_phones s where s.phone10 = ic.from10),
      'card_closed', l.stage::text in ('dnc', 'dead', 'closed_no_contact'),
      'phone_blocked', exists (select 1 from public.suppressed_phones s where s.phone10 = ic.from10),
      'called_back', exists (select 1 from public.messages o where o.lead_id = ic.lead_id and o.channel = 'call' and o.sent_at > ic.created_at
                               and coalesce(o.status, '') not like 'inbound%'))
    order by ic.created_at desc), '[]'::jsonb)
    from public.inbound_calls ic
    left join public.leads l on l.id = ic.lead_id
    left join public.messages m on m.id = ic.message_id
   where (public.is_team() or auth.uid() is null)
     and ic.created_at > now() - make_interval(hours => greatest(1, least(p_hours, 336)))
     and (ic.status in ('missed', 'blocked', 'no_answer', 'busy', 'failed') or ic.voicemail)
$$;
revoke all on function public.missed_calls_recent(integer) from public, anon;
grant execute on function public.missed_calls_recent(integer) to authenticated, service_role;
