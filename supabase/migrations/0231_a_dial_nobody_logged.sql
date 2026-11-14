-- 0231: a dial nobody logged does not hide the card for good.
--
-- A caller who dials, hangs up and skips the card without pressing an outcome leaves the card "taken"
-- (human_takeover_at). The sweeper of 0043 only frees a call that never reached the phone company; a call that did
-- ring waited for its outcome for ever. While it waited: texts to the card were paused, a call list task
-- (power_hour) never came up in Power hour, the call-task door refused the card, and the next dial was refused with
-- "another call is waiting for its outcome". On 2026-11-14 58 live cards sat like this, some since Oct 29; Sing
-- Xiong's sheriff-sale call had been on Tyler's list since Nov 5 and never came up.
--
--   1. The phone record already says what happened. A placed call the phone company reports as not answered (no
--      answer, busy, failed, cancelled) or as picked up for under 30 seconds (a voicemail greeting, a hang-up), with
--      no outcome logged 12 hours later, is released by the system: the card goes back exactly where it was.
--   2. A call that connected for 30 seconds or more and was never logged is not guessed at: texts stay paused until
--      a person logs an outcome. But after 12 hours it no longer hides the card from its list or blocks the next
--      call; the next call takes its place.
--   3. calls_never_logged lists those connected calls by caller, for the morning email.

create or replace function public.sweep_unlogged_human_calls(p_hours integer default 12, p_talk_seconds integer default 30,
                                                             p_now timestamptz default now())
returns integer language plpgsql security definer set search_path = public as $$
declare r record; d record; n integer := 0;
begin
  for r in select l.id, l.belt, l.belt_step, l.human_takeover_key as key, l.human_takeover_drafts as drafts,
                  l.human_takeover_by as by_who, l.human_takeover_phone as phone, l.human_takeover_at as started_at,
                  g.status, coalesce(g.duration_s, 0) as secs
             from public.leads l
             join public.human_call_provider_claims pc on pc.attempt_key = l.human_takeover_key
             join public.call_legs g on g.call_sid = pc.provider_call_sid
            where l.human_takeover_at is not null and l.human_takeover_at < p_now - make_interval(hours => p_hours)
              and (g.status in ('no-answer', 'busy', 'failed', 'canceled')
                   or (g.status = 'completed' and coalesce(g.duration_s, 0) < p_talk_seconds))
            for update of l loop
    -- exactly what resume_human_call does: held belt texts go back to where they were
    for d in select x->>'id' as id, x->>'status' as status from jsonb_array_elements(coalesce(r.drafts, '[]'::jsonb)) x loop
      update public.reply_drafts set status = d.status,
        note = regexp_replace(coalesce(note, ''), ' \| human call ' || r.key || '$', ''), updated_at = p_now
        where id = d.id::uuid and lead_id = r.id and status = 'superseded';
    end loop;
    update public.leads set human_takeover_at = null, human_takeover_by = null,
      human_takeover_phone = null, human_takeover_key = null, human_takeover_drafts = null,
      human_takeover_assigned_to = null where id = r.id;
    insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
      values (r.id, 'human_call_resumed', r.belt, r.belt, r.belt_step,
        jsonb_build_object('key', 'human_resume:' || r.key, 'phone', r.phone, 'caller', r.by_who, 'started_at', r.started_at,
          'phone_record', r.status, 'seconds', r.secs,
          'reason', 'released automatically: the phone record says nobody picked up (' || r.status || ', ' || r.secs
                    || ' s) and no outcome was logged'), p_now, 'system');
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.sweep_unlogged_human_calls(integer, integer, timestamptz) from public, anon, authenticated;

-- connected calls nobody logged: the card's texts stay paused until someone does
create or replace view public.calls_never_logged as
select l.id as lead_id, l.owner_name, l.property_address, g.caller as person, l.human_takeover_by as caller, l.human_takeover_phone as phone10,
       l.human_takeover_at as started_at, coalesce(g.duration_s, 0) as seconds
  from public.leads l
  join public.human_call_provider_claims pc on pc.attempt_key = l.human_takeover_key
  join public.call_legs g on g.call_sid = pc.provider_call_sid
 where l.human_takeover_at is not null and l.human_takeover_at < now() - interval '12 hours'
   and l.owner_name not ilike 'TEST %' and g.status = 'completed' and coalesce(g.duration_s, 0) >= 30;
revoke all on public.calls_never_logged from anon, authenticated;

CREATE OR REPLACE FUNCTION public.begin_human_call(p_lead_id uuid, p_phone text, p_source text, p_key text, p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare l public.leads; d text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10);
  gate jsonb; who text; person public.team_person; held jsonb; actor text; stale boolean := false;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  if p_source not in ('app', 'personal') then return jsonb_build_object('ok', false, 'reason', 'unknown call source', 'paused', false); end if;
  if coalesce(p_key, '') !~ '^[A-Za-z0-9_-]{8,100}$' then return jsonb_build_object('ok', false, 'reason', 'bad call key', 'paused', false); end if;

  -- Same first lock as the conveyor worker. Draft locks remain below every lead-state check.
  select * into l from public.leads where id = p_lead_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such lead', 'paused', false); end if;
  select tm.display_name, tm.person into who, person from public.team_members tm
   where lower(tm.email) = lower(auth.jwt() ->> 'email');
  if person is null then return jsonb_build_object('ok', false, 'reason', 'caller is not an active team member', 'paused', false); end if;
  actor := coalesce(who, person::text);

  -- Recheck every mutable authorization fact before recognizing an attempt key.
  if l.stage in ('dnc', 'dead', 'closed_no_contact', 'closed_won') or l.belt in ('dnc', 'dead') then
    return jsonb_build_object('ok', false, 'reason', 'this card is closed or do-not-contact', 'paused', false);
  end if;
  -- Do not trust the caller-supplied p_now for authorization; it exists for deterministic
  -- event timestamps in the existing RPC and must not let a client fast-forward the clock.
  if l.belt = 'not_now_dated' and l.named_date is not null and now() < l.named_date then
    return jsonb_build_object('ok', false, 'reason', 'the seller asked us to wait until the scheduled date',
      'paused', l.human_takeover_at is not null, 'not_before', l.named_date);
  end if;
  if not exists (select 1 from public.contacts c where c.lead_id = p_lead_id and c.kind = 'phone'
      and c.value_normalized = d) then
    return jsonb_build_object('ok', false, 'reason', 'that phone is not on this card', 'paused', l.human_takeover_at is not null);
  end if;
  gate := public.phone_is_blocked(d);
  if coalesce((gate->>'blocked')::boolean, true) then
    return jsonb_build_object('ok', false, 'reason', coalesce(gate->>'reason', 'phone block check failed'), 'paused', l.human_takeover_at is not null);
  end if;

  -- A call placed more than 12 hours ago with no outcome logged no longer blocks the next call (0231): the new call
  -- takes its place and the texts stay paused until an outcome is logged, as before. The earlier of the server clock
  -- and p_now: a client cannot fast-forward past the wait.
  stale := l.human_takeover_at is not null and l.human_takeover_key is distinct from p_key
           and l.human_takeover_at < least(now(), p_now) - interval '12 hours';
  if l.human_takeover_at is not null and not stale then
    if l.assigned_to is distinct from l.human_takeover_assigned_to then
      return jsonb_build_object('ok', false, 'reason', 'the card assignment changed after authorization', 'paused', true);
    end if;
    if l.human_takeover_key is distinct from p_key then
      return jsonb_build_object('ok', false, 'reason', 'another call is waiting for its outcome', 'paused', true);
    end if;
    if l.human_takeover_phone is distinct from d then
      return jsonb_build_object('ok', false, 'reason', 'the active call has a different destination', 'paused', true);
    end if;
    if l.human_takeover_by is distinct from actor then
      return jsonb_build_object('ok', false, 'reason', 'the active call belongs to another caller', 'paused', true);
    end if;
    return jsonb_build_object('ok', true, 'duplicate', true, 'paused', true, 'key', p_key);
  end if;
  if exists (select 1 from public.belt_events e where e.lead_id = p_lead_id
      and e.payload->>'key' = 'human_call:' || p_key) then
    return jsonb_build_object('ok', false, 'duplicate', true,
      'reason', 'that call authorization is no longer active', 'paused', false);
  end if;

  perform 1 from public.reply_drafts r where r.lead_id = p_lead_id and r.kind = 'belt'
    and r.status in ('queued', 'awaiting_approval', 'would_send', 'sending') for update;
  if exists (select 1 from public.reply_drafts r where r.lead_id = p_lead_id and r.kind = 'belt' and r.status = 'sending') then
    return jsonb_build_object('ok', false, 'reason', 'an automated text is already sending; check its result before calling', 'paused', false);
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'status', r.status)), '[]'::jsonb) into held
    from public.reply_drafts r where r.lead_id = p_lead_id and r.kind = 'belt'
      and r.status in ('queued', 'awaiting_approval', 'would_send');
  update public.leads set human_takeover_at = p_now, human_takeover_by = actor,
    human_takeover_phone = d, human_takeover_key = p_key,
    -- texts the abandoned call was already holding stay held with this one
    human_takeover_drafts = case when stale then coalesce(l.human_takeover_drafts, '[]'::jsonb) || held else held end,
    assigned_to = coalesce(assigned_to, person), human_takeover_assigned_to = coalesce(assigned_to, person)
   where id = p_lead_id;
  update public.reply_drafts set status = 'superseded', note = coalesce(note, '') || ' | human call ' || p_key, updated_at = p_now
   where lead_id = p_lead_id and kind = 'belt' and status in ('queued', 'awaiting_approval', 'would_send');
  update public.hot_alerts set called_at = p_now where lead_id = p_lead_id and called_at is null and created_at <= p_now;
  if stale then
    insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
      values (p_lead_id, 'human_call_abandoned', l.belt, l.belt, l.belt_step,
        jsonb_build_object('key', 'human_abandon:' || l.human_takeover_key, 'phone', l.human_takeover_phone, 'by', l.human_takeover_by,
          'started_at', l.human_takeover_at, 'reason', 'no outcome was logged in 12 hours; the next call takes its place'), p_now, actor);
  end if;
  insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
    values (p_lead_id, 'human_call_started', l.belt, l.belt, l.belt_step,
      jsonb_build_object('key', 'human_call:' || p_key, 'source', p_source, 'phone', d), p_now, actor);
  return jsonb_build_object('ok', true, 'duplicate', false, 'paused', true, 'key', p_key);
end $function$;

CREATE OR REPLACE FUNCTION public.power_dial_queue(p_limit integer DEFAULT 80, p_now timestamp with time zone DEFAULT now(), p_test boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with me as (select public.is_team() as ok),
  -- the phones a person's status blocks (phone_person_block, 0084), computed once for the whole queue instead of once
  -- per contact per card: as a per-row call it stopped using the index and the queue took minutes (2026-10-29)
  blocked as (
    select distinct c.value_normalized as ph from public.contacts c join public.people pe on pe.id = c.person_id
     where pe.status = 'do_not_contact'
        or (pe.status = 'deceased' and not exists (select 1 from public.contacts c2 join public.people p2 on p2.id = c2.person_id
                                                    where c2.value_normalized = c.value_normalized and p2.status = 'active'))),
  dialed as (
    select m.lead_id, count(*) filter (where m.sent_at > p_now - interval '7 days') as dials_7d, count(*) as dials_total, max(m.sent_at) as last_dial,
           count(*) filter (where (m.sent_at at time zone 'America/Chicago')::date = (p_now at time zone 'America/Chicago')::date) as dials_today
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
       -- a callback promised by one caller is that caller's (Colin 2026-10-30): on a caller's own login only their own come up
       and (t.kind <> 'callback' or public.wpie_person() not in ('thalia', 'adil') or t.owner = public.wpie_person())
       -- a power-hour set is loaded per caller (Colin 2026-11-03: "50 in each and then followups"): only its caller sees it
       and (coalesce(t.source, '') not in ('power_hour', 'power_hour_after') or public.wpie_person() not in ('thalia', 'adil') or t.owner = public.wpie_person())
     order by t.lead_id, (t.kind = 'callback') desc, (t.source = 'call_next') desc, t.due_at),
  pool as (
    select l.*, dt.task_id, dt.title as task_title, dt.reply_words, dt.task_at, dt.due_at as task_due, (dt.task_source = 'call_next') as replied,
           mc.missed_at, mc.voicemail as missed_voicemail, mc.vm_words, mc.missed_phone,
           coalesce(mc.missed_phone, dt.reply_phone, ft.phone) as thread_phone, ft.sent_at as first_text_at,
           coalesce(tx.n, 0) as texts_sent, tx.last_at as last_text_at, coalesce(d.dials_7d, 0) as dials_7d, coalesce(d.dials_total, 0) as dials_total, d.last_dial, coalesce(d.dials_today, 0) as dials_today,
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
       -- a card locked to the other caller, or with the other caller's open callback, is not mine to dial (0148)
       and (public.wpie_person() not in ('thalia', 'adil') or l.locked_to is null or l.locked_to = public.wpie_person())
       and not exists (select 1 from public.tasks cb where cb.lead_id = l.id and cb.kind = 'callback' and cb.done_at is null
                         and public.wpie_person() in ('thalia', 'adil') and cb.owner <> public.wpie_person())
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
       -- a caller's due follow-up call (the belt's) still comes up when a caller took the text thread (0163)
       -- a dial placed over 12 hours ago and never logged no longer hides the card from its list (0231)
       and (l.human_takeover_at is null or l.human_takeover_at < p_now - interval '12 hours' or dt.task_source in ('belt', 'mine'))
       and (l.named_date is null or l.named_date <= p_now)
        and (l.parked_at is null or (l.rest_until is not null and l.rest_until <= p_now))   -- parked (0182) or rested by the caller (0186) until it wakes
       -- four numbers a sitting (Thalia 2026-11-04, Colin: 'do what thalia asked for'): after four dials on a card in a day the
       -- card leaves today's queue and comes back the next day at its next untried number; a seller who called us, or a
       -- promised callback, is never capped
       and (mc.lead_id is not null or dt.task_kind = 'callback' or coalesce(d.dials_today, 0) < 4)
       -- someone who just texted back with a bit of interest (Muse's call_next) is called next, whatever the dial rules say
       -- and a seller who texted back gets the follow-up call the belt set for them (Colin 2026-11-03: "behind them any followups needed")
       and (dt.task_source in ('call_next', 'belt', 'mine', 'power_hour', 'power_hour_after') or (
            coalesce(d.dials_7d, 0) < 3
        and (d.last_dial is null or d.last_dial < p_now - interval '2 days')
        and (dt.task_id is not null or l.id not in (select lead_id from reached))
        and not exists (select 1 from public.twilio_inbound ti where ti.lead_id = l.id)
        and not exists (select 1 from public.messages mi where mi.lead_id = l.id and mi.direction = 'in' and mi.channel = 'sms')))))
       and extract(hour from (p_now at time zone public.agent_tz(coalesce(l.mailing_state, 'WI')))) between 9 and 19),
  pick as (
    select p.*,
           -- need first (0189): the motivation tier from the laptop's records, A..D; a card with no row is D
           coalesce((select case m.tier when 'A' then 0 when 'B' then 1 when 'C' then 2 else 3 end
                       from public.lead_motivation m where m.lead_id = p.id), 3) as need_rank,
           ph.value_normalized as phone, ph.line_type, ph.person_name as phone_person,
           (select count(*) from public.contacts c2 where c2.lead_id = p.id and c2.kind = 'phone' and c2.status = 'ok' and not c2.suppressed
              and not exists (select 1 from public.messages m where m.lead_id = p.id and m.channel = 'call' and coalesce(m.status, '') not like 'inbound%'
                              and right(regexp_replace(coalesce(m.to_number, ''), '\D', '', 'g'), 10) = c2.value_normalized and (m.sent_at at time zone 'America/Chicago')::date = (p_now at time zone 'America/Chicago')::date)) - 1 as other_phones
      from pool p
      cross join lateral (
        select c.value_normalized, c.line_type, c.person_name from public.contacts c
         where c.lead_id = p.id and c.kind = 'phone' and c.status = 'ok' and c.value_normalized ~ '^[0-9]{10}$'
           and not c.suppressed and not coalesce(c.dnc_app, false)
           and (c.value_normalized = p.missed_phone or (not coalesce(c.dnc_vendor, false) and coalesce(c.dnc_scrub, '') <> 'dnc'))
           and not exists (select 1 from public.suppressed_phones s where s.phone10 = c.value_normalized)
           and not exists (select 1 from blocked b where b.ph = c.value_normalized)
           -- a number already dialed today is not offered again today (0184), except to call a seller back
           and (p.src <= -2 or (true and not exists (select 1 from public.messages m where m.lead_id = p.id and m.channel = 'call' and coalesce(m.status, '') not like 'inbound%'
                              and right(regexp_replace(coalesce(m.to_number, ''), '\D', '', 'g'), 10) = c.value_normalized and (m.sent_at at time zone 'America/Chicago')::date = (p_now at time zone 'America/Chicago')::date)))
         order by (c.value_normalized = p.thread_phone) desc,
                  (c.person_id is not null and exists (select 1 from public.interests i where i.lead_id = p.id and i.person_id = c.person_id
                     and i.role in ('owner_of_record', 'co_owner', 'personal_representative', 'trustee') and i.status = 'active')) desc,
                  (c.line_type = 'mobile') desc, c.created_at
         limit 1) ph
     order by p.src, p.missed_at desc nulls last, (coalesce(p.task_source, '') = 'power_hour') desc,
              case when p.task_source = 'power_hour' then p.task_due end nulls last, p.task_at nulls last, need_rank, cardinality(p.reasons_to_sell) desc, p.dials_total, p.first_text_at nulls last, p.id
     limit greatest(1, least(coalesce(p_limit, 80), 200)))
  select coalesce(jsonb_agg(jsonb_build_object(
      'lead_id', id, 'task_id', task_id, 'source', case when src = -3 then 'missed_call' when src = -2 then 'callback' when src = -1 then 'replied'
        when task_source = 'checkin' then 'checkin' when src = 0 then 'call_list' else 'texted_silent' end, 'why', task_title,
      'missed_at', missed_at, 'voicemail', missed_voicemail, 'voicemail_words', vm_words,
      'reply', reply_words, 'task_note', task_note,
      -- the card's latest package: what Colin decided, so the caller says the right thing (0124)
      'package', (select jsonb_build_object('id', d.id, 'status', d.status, 'colin_call', d.colin_call, 'colin_asks', d.colin_asks,
                    'caller_answers', d.caller_answers, 'callback_at', d.callback_at, 'number_note', d.number_note,
                    'our_number', d.our_number, 'their_number', d.their_number)
                    from public.deal_packages d where d.lead_id = pick.id order by d.created_at desc limit 1),
      'owner_name', owner_name, 'address', property_address, 'municipality', municipality, 'mailing_state', mailing_state,
      'reasons', reasons_to_sell, 'lane', lane, 'stage', stage,
      'texts_sent', texts_sent, 'first_text_at', first_text_at, 'last_text_at', last_text_at,
      'dials_7d', dials_7d, 'dials_total', dials_total, 'last_dial', last_dial, 'dials_today', dials_today,
      'phone', phone, 'line_type', line_type, 'phone_person', phone_person, 'other_phones', greatest(other_phones, 0),
      'say_next', say_next, 'next_plain', public.next_plain(belt, next_stop_at, next_stop_who, next_stop_say, named_date, named_event, public.wpie_person()))
      order by src, missed_at desc nulls last, (coalesce(task_source, '') = 'power_hour') desc,
        case when task_source = 'power_hour' then task_due end nulls last, task_at nulls last, need_rank, cardinality(reasons_to_sell) desc, dials_total, first_text_at nulls last, id), '[]'::jsonb)
    from pick
$function$;

CREATE OR REPLACE FUNCTION public.agent_add_call_task(p_lead_id uuid, p_sale_date date, p_why text, p_rank integer, p_owner text, p_agent text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  l      public.leads;
  who    text := 'Muse (' || coalesce(p_agent, 'agent') || ')';
  why    text := nullif(btrim(coalesce(p_why, '')), '');
  owner  public.team_person;
  tid    uuid;
  due    timestamptz;
  ttl    text;
  nt     text;
  today  date := (now() at time zone 'America/Chicago')::date;
  last_day date;
  cleared boolean := false;
  existing uuid;
begin
  if why is null then return jsonb_build_object('ok', false, 'reason', 'say why the caller should dial this card (reason)'); end if;
  select * into l from public.leads where id = p_lead_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card'); end if;
  if l.stage in ('dnc', 'dead', 'closed_no_contact', 'closed_won', 'under_contract', 'offer', 'walkthrough_booked') then
    return jsonb_build_object('ok', false, 'reason', 'the card is ' || l.stage::text || ': no call task on it');
  end if;
  -- the 14-day rule (CLAUDE.md): a sheriff sale inside two weeks is not a lead; nobody dials it
  if p_sale_date is not null and p_sale_date < today + 14 then
    return jsonb_build_object('ok', false, 'reason', 'sheriff sale ' || p_sale_date::text || ' is inside the 14-day window (today ' || today::text || '): not callable, do not spend time on it');
  end if;
  -- whose task: the card's caller; a card with no caller takes the owner you name and is locked to them
  if lower(coalesce(p_owner, '')) = 'tyler' then p_owner := 'adil'; end if;
  if l.locked_to in ('thalia', 'adil') then
    if p_owner is not null and lower(p_owner) <> l.locked_to::text then
      return jsonb_build_object('ok', false, 'reason', 'the card is ' || initcap(l.locked_to::text) || '''s: a task goes to the card''s caller (reassign_card first if it should move)');
    end if;
    owner := l.locked_to;
  elsif lower(coalesce(p_owner, '')) in ('thalia', 'adil') then
    owner := lower(p_owner)::public.team_person;
    perform public.lock_card_to(p_lead_id, owner, 'call task by ' || who);
  else
    return jsonb_build_object('ok', false, 'reason', 'the card has no caller: pass owner (thalia or adil) or reassign_card first');
  end if;
  -- what the Power hour queue would hide anyway
  if coalesce(l.elderly_or_ill, false) or coalesce(l.grief, false) then
    return jsonb_build_object('ok', false, 'reason', 'the card is marked ' || case when coalesce(l.elderly_or_ill, false) then 'elderly or ill' else 'grief' end || ': the queue never dials it; a person decides');
  end if;
  if l.human_takeover_at is not null and l.human_takeover_at > now() - interval '12 hours' then
    return jsonb_build_object('ok', false, 'reason', 'a caller is on this card''s call right now or has not logged it yet (' || coalesce(l.human_takeover_by, 'a caller') || '): try again once it is logged');
  end if;
  if not exists (select 1 from public.contacts c where c.lead_id = p_lead_id and c.kind = 'phone' and c.status = 'ok' and c.value_normalized ~ '^[0-9]{10}$'
                   and not c.suppressed and not coalesce(c.dnc_app, false) and not coalesce(c.dnc_vendor, false) and coalesce(c.dnc_scrub, '') <> 'dnc'
                   and not exists (select 1 from public.suppressed_phones s where s.phone10 = c.value_normalized)) then
    return jsonb_build_object('ok', false, 'reason', 'no dialable phone on the card: load a confirmed number first (add_prospects), the queue would never show this task');
  end if;
  -- a date on the card: Muse's own hold loses its date (the hold, its reason and the belt stay); anyone else's date stands
  if l.named_date is not null and l.named_date > now() then
    if l.belt = 'hold_not_now' then
      update public.leads set named_date = null, updated_at = now() where id = p_lead_id;
      insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
      values (p_lead_id, 'named_date_cleared', l.belt, l.belt, l.belt_step,
              jsonb_build_object('was', l.named_date, 'reason', 'a call task on a held card: the queue hides a card until its date (' || why || ')'), now(), who);
      cleared := true;
    else
      return jsonb_build_object('ok', false, 'reason', 'the card has a date set by its belt ' || coalesce(l.belt, 'none') || ' (' || coalesce(l.named_event, 'no words') || '): not before ' || to_char(l.named_date at time zone 'America/Chicago', 'Mon DD') || '; that is the seller''s or Colin''s, not a hold of yours');
    end if;
  end if;
  -- one open list task per card
  select t.id into existing from public.tasks t where t.lead_id = p_lead_id and t.done_at is null and t.kind = 'call'
     and coalesce(t.source, '') in ('power_hour', 'power_hour_reserve', 'power_hour_after') order by t.due_at limit 1;
  if existing is not null then
    return jsonb_build_object('ok', true, 'already', true, 'task_id', existing, 'owner', owner, 'hold_date_cleared', cleared);
  end if;
  due := case when p_rank is not null then (today::timestamp + interval '12 hours') at time zone 'America/Chicago' + make_interval(mins => greatest(p_rank, 0)) else now() end;
  if p_sale_date is not null then
    last_day := p_sale_date - 14;
    ttl := 'Sheriff sale ' || to_char(p_sale_date, 'Mon DD') || ': last call day ' || to_char(last_day, 'Mon DD');
    nt := who || ' ' || today::text || ': ' || why || ' Sheriff sale ' || p_sale_date::text || '. Under the 14-day rule the last day to call is ' || last_day::text || '; after that do not dial, the sale is too close to do a deal.';
  else
    ttl := left(why, 80);
    nt := who || ' ' || today::text || ': ' || why;
  end if;
  if p_rank is not null then nt := nt || ' call list (#' || p_rank::text || ')'; end if;
  nt := nt || ' A logged call closes this task.';
  insert into public.tasks (lead_id, due_at, kind, owner, note, source, title, source_key, created_at, updated_at)
  values (p_lead_id, due, 'call', owner, left(nt, 1500), 'power_hour', ttl, 'agent:' || coalesce(p_agent, 'agent') || ':' || p_lead_id::text || ':' || today::text, now(), now())
  returning id into tid;
  insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
  values (p_lead_id, 'call_task_added', l.belt, l.belt, l.belt_step, jsonb_build_object('task_id', tid, 'owner', owner, 'sale_date', p_sale_date, 'rank', p_rank, 'why', why), now(), who);
  return jsonb_build_object('ok', true, 'task_id', tid, 'owner', owner, 'due_at', due, 'title', ttl, 'hold_date_cleared', cleared);
end $function$;


do $do$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if exists (select 1 from cron.job where jobname = 'wpie-release-unlogged-calls') then
      perform cron.unschedule('wpie-release-unlogged-calls');
    end if;
    perform cron.schedule('wpie-release-unlogged-calls', '11,41 * * * *', 'select public.sweep_unlogged_human_calls()');
  end if;
end
$do$;

-- the cards already waiting
do $$
declare n integer;
begin
  n := public.sweep_unlogged_human_calls();
  raise notice '0231: % card(s) released from a dial nobody logged', n;
end $$;
