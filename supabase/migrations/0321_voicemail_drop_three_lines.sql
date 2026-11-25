-- 0321: the recorded voicemail on a three-line round.
--
-- Colin 2026-11-25: "Can you go e2e test it so it works for normal calls and triple line calls so they can drop a VM
-- for each?" On one line the caller hears the beep and taps (0319). On a three-line round nobody is listening to a
-- line a voicemail answered: the phone server screens each line for a machine and, until now, hung every machine up.
-- Now it asks voicemail_drop_auto (below) whether that number may get the recorded message; a yes and the seller's
-- leg waits out the greeting and is left the message (pm-phone lib/voicemailAuto, voice/amd, voice/vm-say), a no and
-- the line is hung up as before. The rule is the one the button uses: voicemail_drop_rules.mode ('engaged' as
-- shipped: only a number that called us or wrote back interested), do-not-contact, one message per number in three
-- days, no name on an estate card. Three lines rings the cold list, so under 'engaged' very few lines will get one.
--
-- The rule moves into voicemail_drop_verdict so the button (a signed-in caller) and the phone server (the service
-- key, naming the caller whose line it is) read the same lines.

create or replace function public.voicemail_drop_verdict(p_lead_id uuid, p_phone text, p_person text) returns jsonb
language plpgsql stable security definer set search_path = public as $fn$
declare me text := p_person; me_name text; r public.voicemail_drop_rules; l public.leads; c public.contacts;
  d text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10);
  blocked jsonb; engaged boolean; last_drop timestamptz; first text; street text; hi text; place text; say text;
begin
  select display_name into me_name from public.team_members where person::text = me limit 1;
  select * into r from public.voicemail_drop_rules where id = 1;
  if not found or r.mode = 'off' then return jsonb_build_object('ok', false, 'code', 'off', 'reason', 'The recorded voicemail is switched off.'); end if;
  if d !~ '^[2-9][0-9]{9}$' then return jsonb_build_object('ok', false, 'code', 'number', 'reason', 'No number on this call.'); end if;
  select * into l from public.leads where id = p_lead_id;
  if not found then return jsonb_build_object('ok', false, 'code', 'card', 'reason', 'No such card.'); end if;
  if l.stage::text in ('dnc', 'dead') or coalesce(l.belt, '') in ('dnc', 'dead') then
    return jsonb_build_object('ok', false, 'code', 'closed', 'reason', 'This card is closed.');
  end if;
  select * into c from public.contacts where lead_id = p_lead_id and kind = 'phone' and value_normalized = d order by created_at limit 1;
  if not found then return jsonb_build_object('ok', false, 'code', 'number', 'reason', 'That number is not on this card.'); end if;
  blocked := public.phone_is_blocked(d);
  if coalesce((blocked->>'blocked')::boolean, false) or c.suppressed or c.dnc_app or public.phone_person_block(d) is not null then
    return jsonb_build_object('ok', false, 'code', 'blocked', 'reason', 'This number is do-not-contact.');
  end if;
  -- they called us, or wrote back interested, from this number
  engaged := exists (select 1 from public.inbound_calls i where i.from10 = d and i.status <> 'blocked'
                        and i.created_at > now() - make_interval(days => r.engaged_days))
          or exists (select 1 from public.reply_drafts x where x.phone10 = d and not coalesce(x.is_test, false)
                        and x.intent = any (public.warm_intents()) and x.inbound_at > now() - make_interval(days => r.engaged_days));
  if r.mode = 'engaged' and not engaged then
    return jsonb_build_object('ok', false, 'code', 'cold', 'reason', 'They have not called or written back from this number: leave this one in your own voice.');
  end if;
  select max(v.at) into last_drop from public.voicemail_drops v where v.phone10 = d and v.at > now() - make_interval(days => r.per_number_days);
  if last_drop is not null then
    return jsonb_build_object('ok', false, 'code', 'recent', 'reason', 'This number got the recorded message on '
      || to_char(last_drop at time zone 'America/Chicago', 'Dy Mon DD') || ': leave your own this time, or none.');
  end if;
  -- an estate card is never greeted by name: the name on it may be the person who died (0289)
  first := case when public.card_is_estate(p_lead_id) then 'there'
                else public.text_first_name(coalesce((select pe.name from public.people pe where pe.id = c.person_id and pe.kind = 'person'),
                                                     nullif(c.person_name, ''), l.owner_name)) end;
  hi := case when coalesce(first, 'there') = 'there' then 'Hi,' else 'Hi ' || first || ',' end;
  street := public.speech_street(l.property_address);
  place := case when street is null then 'your property' else 'the place on ' || street end;
  say := replace(replace(replace(r.words, '{hi}', hi), '{caller}', coalesce(nullif(me_name, ''), initcap(me))), '{place}', place);
  return jsonb_build_object('ok', true, 'person', me, 'say', say, 'voice', coalesce(r.voices->>me, 'Polly.Joanna-Neural'), 'engaged', engaged);
end $fn$;

-- the button: the signed-in caller, on a card that is theirs
create or replace function public.voicemail_drop_check(p_lead_id uuid, p_phone text) returns jsonb
language plpgsql stable security definer set search_path = public as $fn$
declare me text;
begin
  perform public.card_guard(p_lead_id);
  if not public.is_team() then raise exception 'team only'; end if;
  select person::text into me from public.team_members where lower(email) = lower(auth.jwt() ->> 'email');
  if me is null then raise exception 'not on the team'; end if;
  return public.voicemail_drop_verdict(p_lead_id, p_phone, me);
end $fn$;

-- the phone server, for a machine that answered one line of a three-line round: the caller is named, and the card
-- must be theirs (an owner's line, or a card no caller holds, passes as it does in the app)
create or replace function public.voicemail_drop_auto(p_lead_id uuid, p_phone text, p_person text) returns jsonb
language plpgsql stable security definer set search_path = public as $fn$
declare role text; cc text;
begin
  select m.role::text into role from public.team_members m where m.person::text = p_person limit 1;
  if role is null then return jsonb_build_object('ok', false, 'code', 'who', 'reason', 'Not on the team.'); end if;
  cc := public.card_caller(p_lead_id)::text;
  if role = 'caller' and (cc is distinct from p_person) and (cc is not null or public.card_owner_person(p_lead_id) is not null) then
    return jsonb_build_object('ok', false, 'code', 'card', 'reason', 'Not this caller''s card.');
  end if;
  return public.voicemail_drop_verdict(p_lead_id, p_phone, p_person);
end $fn$;

-- the phone server spoke the message: keep the row, and correct the line's call note, which the app wrote the moment
-- the line ended ("voicemail picked up, no message left")
create or replace function public.voicemail_drop_auto_done(p_lead_id uuid, p_phone text, p_person text, p_call_sid text, p_said text) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare d text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10); fixed int := 0;
begin
  if d !~ '^[0-9]{10}$' or coalesce(p_call_sid, '') !~ '^CA[0-9A-Fa-f]{32}$'
     or not exists (select 1 from public.team_members m where m.person::text = p_person)
     or not exists (select 1 from public.leads l where l.id = p_lead_id) then
    return jsonb_build_object('ok', false);
  end if;
  insert into public.voicemail_drops (lead_id, phone10, person, call_sid, said) values (p_lead_id, d, p_person, p_call_sid, left(p_said, 800))
  on conflict (call_sid) do nothing;
  update public.messages m
     set body = replace(m.body, 'No answer: voicemail picked up, no message left (three lines, Power hour).',
                                'No answer: voicemail picked up, the recorded message was left (three lines, Power hour).')
   where m.id = (select x.id from public.messages x
                  where x.lead_id = p_lead_id and x.channel = 'call' and x.from_number = '+1' || d
                    and x.sent_at > now() - interval '10 minutes'
                    and x.body like '%voicemail picked up, no message left (three lines, Power hour).%'
                  order by x.sent_at desc limit 1);
  get diagnostics fixed = row_count;
  return jsonb_build_object('ok', true, 'note_fixed', fixed > 0);
end $fn$;

revoke all on function public.voicemail_drop_verdict(uuid, text, text), public.voicemail_drop_auto(uuid, text, text),
  public.voicemail_drop_auto_done(uuid, text, text, text, text) from public, anon, authenticated;
grant execute on function public.voicemail_drop_verdict(uuid, text, text), public.voicemail_drop_auto(uuid, text, text),
  public.voicemail_drop_auto_done(uuid, text, text, text, text) to service_role;
