-- The 90-day rest is a check-in CALL (Colin 2026-10-28: "yeah 90 day check in call, and the caller needs to know thats
-- what it is"). 0126 rested a cold card after 9 dials with no contact on the dormant belt, whose check-in is a text
-- ("We spoke before about {street}...": untrue for someone never reached, and impossible on a landline). Now the rest
-- puts a call on the caller's list 90 days out (4:30 PM Central, Power hour), titled "90-day check-in call" with the
-- history in the note; Power hour and Today's list show it as such. A check-in that gets no answer sets the next one.

create or replace function public.cold_rest(p_lead_id uuid, p_why text, p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public as $$
declare due timestamptz; tz text := 'America/Chicago'; last_try text; dials integer;
begin
  due := (((p_now at time zone tz)::date + 90) + time '16:30') at time zone tz;
  if extract(isodow from due at time zone tz) in (6, 7) then due := due + make_interval(days => (8 - extract(isodow from due at time zone tz)::int)); end if;
  select to_char(max(m.sent_at) at time zone tz, 'Mon DD'), count(*) into last_try, dials from public.messages m
   where m.lead_id = p_lead_id and m.channel = 'call' and coalesce(m.status, '') not like 'inbound%';
  update public.tasks set done_at = now() where lead_id = p_lead_id and done_at is null and (source = 'belt' or source = 'checkin');
  insert into public.tasks (lead_id, due_at, kind, owner, source, title, note)
  values (p_lead_id, due, 'call', 'thalia', 'checkin', '90-day check-in call',
          '90-day check-in call: ' || coalesce(dials, 0) || ' tries with no answer, last on ' || coalesce(last_try, '?') || ' (' || p_why || '). '
          || 'Call it like a fresh cold call: "Are you still the owner?", then "Any interest in selling it?"');
  perform set_config('wpie.in_belt_event', '1', true);
  update public.leads set stage = 'follow_up', belt = null, belt_step = 0, next_stop_at = null, next_stop_who = null, next_stop_say = null,
         next_action = '90-day check-in call', next_action_at = due where id = p_lead_id;
  perform set_config('wpie.in_belt_event', '', true);
  insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
  values (p_lead_id, 'move', null, null, 0, jsonb_build_object('reason', '90-day rest: ' || p_why, 'checkin_at', due), p_now, 'conveyor');
  return jsonb_build_object('ok', true, 'rest', true, 'checkin_at', due);
end $$;
revoke all on function public.cold_rest(uuid, text, timestamptz) from public, anon, authenticated;
grant execute on function public.cold_rest(uuid, text, timestamptz) to service_role;

CREATE OR REPLACE FUNCTION public.belt_route_no_answer(p_lead_id uuid, pl jsonb, p_by text, p_now timestamp with time zone, p_event text DEFAULT 'no_answer'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
declare l public.leads; n integer; dials integer;
begin
  select * into l from public.leads where id = p_lead_id;
  update public.leads set unanswered_count = unanswered_count + 1 where id = p_lead_id;
  if l.belt is null then
    -- a cold owner who didn't answer stays cold (Colin 2026-10-28: "what happens with all these leads that didnt answer?"):
    -- never the warm "said yes, not booked" track, which is for people who replied or talked to us. Power hour and the
    -- call list pace the next dials (3 a week, never two days running); after 9 dials with no contact, a 90-day rest.
    if not exists (select 1 from public.twilio_inbound ti where ti.lead_id = p_lead_id)
       and not exists (select 1 from public.messages m where m.lead_id = p_lead_id and m.channel = 'call'
                        and m.status in ('interested', 'reached_no_decision', 'not_now', 'not_interested'))
       and not exists (select 1 from public.hot_alerts h where h.lead_id = p_lead_id) then
      select count(*) into dials from public.messages m where m.lead_id = p_lead_id and m.channel = 'call' and coalesce(m.status, '') not like 'inbound%';
      -- resting: a check-in call that got no answer sets the next one; 9 dials with no contact start the rest (0127)
      if l.stage = 'follow_up' and exists (select 1 from public.tasks t where t.lead_id = p_lead_id and t.source = 'checkin') then
        return public.cold_rest(p_lead_id, 'the 90-day check-in call got no answer too', p_now);
      end if;
      if dials >= 9 then
        return public.cold_rest(p_lead_id, dials || ' dials, never reached', p_now);
      end if;
      return jsonb_build_object('ok', true, 'cold', true, 'dials', dials, 'note', 'a cold no-answer: the next dial comes from Power hour or the call list');
    end if;
    return public.belt_enter(p_lead_id, 'yes_unbooked', 2, p_event, pl, p_by, p_now);
  end if;
  if l.belt = 'call_booked' then
    select count(*) into n from public.belt_events e where e.lead_id = p_lead_id and e.to_belt = 'call_missed' and e.at > p_now - interval '30 days';
    if n > 0 then return public.belt_enter(p_lead_id, 'dormant', 1, p_event, pl || '{"note":"second no-show"}', p_by, p_now); end if;
    return public.belt_enter(p_lead_id, 'call_missed', 1, p_event, pl, p_by, p_now);
  elsif l.belt = 'visit_booked' then
    select count(*) into n from public.belt_events e where e.lead_id = p_lead_id and e.to_belt = 'visit_missed' and e.at > p_now - interval '30 days';
    if n > 0 then return public.belt_enter(p_lead_id, 'dormant', 1, p_event, pl || '{"note":"second no-show"}', p_by, p_now); end if;
    return public.belt_enter(p_lead_id, 'visit_missed', 1, p_event, pl, p_by, p_now);
  end if;
  return public.belt_enter(p_lead_id, l.belt, l.belt_step + 1, p_event, pl, p_by, p_now);
end $$;;

CREATE OR REPLACE FUNCTION public.power_dial_queue(p_limit integer DEFAULT 80, p_now timestamp with time zone DEFAULT now(), p_test boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $$
  with me as (select public.is_team() as ok),
  dialed as (
    select m.lead_id, count(*) filter (where m.sent_at > p_now - interval '7 days') as dials_7d, count(*) as dials_total, max(m.sent_at) as last_dial
      -- our dials only: a logged call is stored as 'in' with its outcome; their own calls to us are 'inbound...'
      from public.messages m where m.channel = 'call' and coalesce(m.status, '') not like 'inbound%' group by m.lead_id),
  reached as (
    select distinct m.lead_id from public.messages m
     where m.channel = 'call' and coalesce(m.status, '') not in ('no_answer', 'voicemail', 'inbound_missed', 'missed', 'busy', 'failed', 'canceled', 'blocked')),
  first_text as (
    select distinct on (m.lead_id) m.lead_id, right(regexp_replace(m.to_number, '\D', '', 'g'), 10) as phone, m.sent_at
      from public.messages m
     where m.direction = 'out' and m.channel = 'sms' and m.is_opener and m.provider_sid is not null and coalesce(m.status, '') not in ('undelivered', 'failed')
     order by m.lead_id, m.sent_at),
  texts as (
    select m.lead_id, count(*) as n, max(m.sent_at) as last_at from public.messages m
     where m.direction = 'out' and m.channel = 'sms' and m.provider_sid is not null group by m.lead_id),
  -- a seller who called us and nobody picked up, not called back since (the same rule as Today's Missed calls box)
  missed as (
    select distinct on (ic.lead_id) ic.lead_id, ic.from10 as missed_phone, ic.created_at as missed_at, ic.voicemail,
           nullif(substring(m.body from 'Voicemail: "(.*)"'), '') as vm_words
      from public.inbound_calls ic left join public.messages m on m.id = ic.message_id
     where ic.lead_id is not null and ic.created_at > p_now - interval '48 hours'
       and (ic.status in ('missed', 'blocked', 'no_answer', 'busy', 'failed') or ic.voicemail)
       -- a caller whose number is on the stop list ("erase my number") is never a callback, on any of the card's numbers
       and not exists (select 1 from public.suppressed_phones s where s.phone10 = ic.from10)
       -- the voicemail was read (0118): an upset caller, a stop, the wrong person or someone who isn't a seller is never a
       -- callback; a voicemail not read yet waits up to 10 minutes so nobody calls a caller who was angry
       and coalesce(ic.vm_verdict, '') not in ('stop', 'wrong_person', 'upset', 'not_seller')
       and not (ic.voicemail and ic.vm_verdict is null and ic.created_at > p_now - interval '10 minutes')
       and not exists (select 1 from public.messages o where o.lead_id = ic.lead_id and o.channel = 'call' and o.sent_at > ic.created_at
                         and coalesce(o.status, '') not like 'inbound%')
     order by ic.lead_id, ic.created_at desc),
  due_tasks as (
    select distinct on (t.lead_id) t.lead_id, t.id as task_id, t.title, t.due_at, t.source as task_source, t.kind as task_kind, t.note as task_note, t.quote as reply_words,
           nullif(t.phone10, '') as reply_phone, t.created_at as task_at from public.tasks t
     where t.done_at is null and t.lead_id is not null
       and ((t.kind = 'call' and t.due_at <= p_now + interval '12 hours')
         -- a callback promised to a seller comes up from 15 minutes before its time (0124)
         or (t.kind = 'callback' and t.due_at <= p_now + interval '15 minutes'))
       and t.owner in ('thalia', 'adil')
     order by t.lead_id, (t.kind = 'callback') desc, (t.source = 'call_next') desc, t.due_at),
  pool as (
    select l.*, dt.task_id, dt.title as task_title, dt.reply_words, dt.task_at, (dt.task_source = 'call_next') as replied,
           mc.missed_at, mc.voicemail as missed_voicemail, mc.vm_words, mc.missed_phone,
           coalesce(mc.missed_phone, dt.reply_phone, ft.phone) as thread_phone, ft.sent_at as first_text_at,
           coalesce(tx.n, 0) as texts_sent, tx.last_at as last_text_at, coalesce(d.dials_7d, 0) as dials_7d, coalesce(d.dials_total, 0) as dials_total, d.last_dial,
           dt.task_source, case when mc.lead_id is not null then -3 when dt.task_kind = 'callback' then -2 when dt.task_source = 'call_next' then -1
                when dt.task_id is not null then 0 else 1 end as src, dt.task_note
      from public.leads l
      left join missed mc on mc.lead_id = l.id
      left join due_tasks dt on dt.lead_id = l.id
      left join first_text ft on ft.lead_id = l.id
      left join texts tx on tx.lead_id = l.id
      left join dialed d on d.lead_id = l.id
     where (select ok from me)
       -- a card on another caller's screen right now is theirs (two callers in Power hour, 0120)
       and not exists (select 1 from public.power_claims pc where pc.lead_id = l.id and pc.until > p_now
                         and pc.person is distinct from public.wpie_person())
       -- a walkthrough runs on TEST cards only, and the real queue never shows them
       and (l.owner_name ilike 'TEST %') = coalesce(p_test, false)
       -- a seller who called us comes first, whatever the card's stage or dial count (Colin 2026-10-28: "should
       -- automatically be top of the list to call"); only a dead or do-not-contact card is left out
       and (((mc.lead_id is not null or dt.task_kind = 'callback') and l.stage not in ('dnc', 'dead', 'closed_no_contact')) or (
           (dt.task_id is not null or (l.stage = 'opener_sent' and ft.sent_at < p_now - interval '3 days')
            or (coalesce(p_test, false) and l.stage = 'opener_sent'))   -- a TEST card needs no task and no texts
       and l.stage not in ('dnc', 'dead', 'closed_no_contact', 'closed_won', 'under_contract', 'walkthrough_booked', 'offer')
       and not coalesce(l.elderly_or_ill, false) and not coalesce(l.grief, false)
       and l.human_takeover_at is null
       and (l.named_date is null or l.named_date <= p_now)
       -- someone who just texted back with a bit of interest (Muse's call_next) is called next, whatever the dial rules say
       and (dt.task_source = 'call_next' or (
            coalesce(d.dials_7d, 0) < 3
        and (d.last_dial is null or d.last_dial < p_now - interval '2 days')
        and (dt.task_id is not null or l.id not in (select lead_id from reached))
        and not exists (select 1 from public.twilio_inbound ti where ti.lead_id = l.id)
        and not exists (select 1 from public.messages mi where mi.lead_id = l.id and mi.direction = 'in' and mi.channel = 'sms')))))
       and extract(hour from (p_now at time zone public.agent_tz(coalesce(l.mailing_state, 'WI')))) between 9 and 19),
  pick as (
    select p.*, ph.value_normalized as phone, ph.line_type, ph.person_name as phone_person,
           (select count(*) from public.contacts c2 where c2.lead_id = p.id and c2.kind = 'phone' and c2.status = 'ok' and not c2.suppressed) - 1 as other_phones
      from pool p
      cross join lateral (
        select c.value_normalized, c.line_type, c.person_name from public.contacts c
         where c.lead_id = p.id and c.kind = 'phone' and c.status = 'ok' and c.value_normalized ~ '^[0-9]{10}$'
           and not c.suppressed and not coalesce(c.dnc_app, false)
           and (c.value_normalized = p.missed_phone or (not coalesce(c.dnc_vendor, false) and coalesce(c.dnc_scrub, '') <> 'dnc'))
           and not exists (select 1 from public.suppressed_phones s where s.phone10 = c.value_normalized)
           and public.phone_person_block(c.value_normalized) is null
         order by (c.value_normalized = p.thread_phone) desc,
                  (c.person_id is not null and exists (select 1 from public.interests i where i.lead_id = p.id and i.person_id = c.person_id
                     and i.role in ('owner_of_record', 'co_owner', 'personal_representative', 'trustee') and i.status = 'active')) desc,
                  (c.line_type = 'mobile') desc, c.created_at
         limit 1) ph
     order by p.src, p.missed_at desc nulls last, p.task_at nulls last, cardinality(p.reasons_to_sell) desc, p.first_text_at nulls last, p.id
     limit greatest(1, least(coalesce(p_limit, 80), 200)))
  select coalesce(jsonb_agg(jsonb_build_object(
      'lead_id', id, 'task_id', task_id, 'source', case when src = -3 then 'missed_call' when src = -2 then 'callback' when src = -1 then 'replied'
        when task_source = 'checkin' then 'checkin' when src = 0 then 'call_list' else 'texted_silent' end, 'why', task_title,
      'missed_at', missed_at, 'voicemail', missed_voicemail, 'voicemail_words', vm_words,
      'reply', reply_words, 'task_note', task_note,
      -- the card's latest package: what Colin decided, so the caller says the right thing (0124)
      'package', (select jsonb_build_object('id', d.id, 'status', d.status, 'colin_call', d.colin_call, 'colin_asks', d.colin_asks,
                    'caller_answers', d.caller_answers, 'callback_at', d.callback_at, 'number_note', d.number_note)
                    from public.deal_packages d where d.lead_id = pick.id order by d.created_at desc limit 1),
      'owner_name', owner_name, 'address', property_address, 'municipality', municipality, 'mailing_state', mailing_state,
      'reasons', reasons_to_sell, 'lane', lane, 'stage', stage,
      'texts_sent', texts_sent, 'first_text_at', first_text_at, 'last_text_at', last_text_at,
      'dials_7d', dials_7d, 'dials_total', dials_total, 'last_dial', last_dial,
      'phone', phone, 'line_type', line_type, 'phone_person', phone_person, 'other_phones', greatest(other_phones, 0))
      order by src, missed_at desc nulls last, task_at nulls last, cardinality(reasons_to_sell) desc, first_text_at nulls last, id), '[]'::jsonb)
    from pick
$$;;;
