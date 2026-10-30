-- 0148: a card locks to the caller who had contact with the seller (Colin 2026-10-30: "lock cards to people permanently
-- after they've had contact with them"; and "that's Adil's customer" when Adil's promised callback came up on Thalia's
-- Power hour). leads.locked_to is set the first time a caller (Thalia or Adil) logs a reached outcome (interested,
-- reached_no_decision, not_now) or takes the seller's text thread; it never moves on its own. On a caller's own login the
-- Power hour list skips cards locked to the other caller and callbacks promised by the other caller; the shared owner
-- login (Colin) still sees everything. An inbound call from a locked card rings its caller; a missed call alerts them.

alter table public.leads add column if not exists locked_to public.team_person;
alter table public.leads add column if not exists locked_at timestamptz;
create index if not exists leads_locked_to_idx on public.leads (locked_to) where locked_to is not null;

-- Lock a card to a caller on first contact. A later contact by someone else never moves it (Colin: permanently).
create or replace function public.lock_card_to(p_lead_id uuid, p_person public.team_person, p_why text default null) returns boolean
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if p_person is null or p_person not in ('thalia', 'adil') then return false; end if;
  update public.leads set locked_to = p_person, locked_at = now(), assigned_to = coalesce(assigned_to, p_person),
         notes = concat_ws(' | ', notes, to_char(now() at time zone 'America/Chicago', 'YYYY-MM-DD') || ' card locked to ' || initcap(p_person::text) || coalesce(' (' || p_why || ')', ''))
   where id = p_lead_id and locked_to is null;
  get diagnostics n = row_count;
  return n > 0;
end $$;
revoke all on function public.lock_card_to(uuid, public.team_person, text) from public, anon;
grant execute on function public.lock_card_to(uuid, public.team_person, text) to authenticated, service_role;


-- log_call: from 0121_disconnected.sql, a reached outcome locks the card to the caller
CREATE OR REPLACE FUNCTION public.log_call(p_lead_id uuid, p_phone text, p_outcome text, p_note text DEFAULT NULL::text, p_when timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
declare who text; d text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10); l public.leads;
  phones text[]; label text; named_day date; follow_at timestamptz; tz text; disconnected boolean := p_outcome = 'disconnected';
begin
  if not public.is_team() then raise exception 'team only'; end if;
  -- a disconnected number (Colin 2026-10-28: "add an option on dialer for disconnected number") is logged the wrong-number
  -- way, so the belt, the call lock and the lists all treat it as they do today: that number is marked bad, the card
  -- stays open, and the owner's next number gets a first text (ready_to_text next_numbers). The card says which.
  if disconnected then p_outcome := 'wrong_number'; end if;
  if p_outcome not in ('interested', 'not_now', 'not_interested', 'wrong_number', 'dnc', 'no_answer', 'reached_no_decision') then
    return jsonb_build_object('ok', false, 'reason', 'pick an outcome');
  end if;
  select * into l from public.leads where id = p_lead_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such lead'); end if;
  tz := public.belt_tz(l.mailing_state);
  if p_outcome = 'not_now' and p_when is not null then
    named_day := (p_when at time zone tz)::date;
    follow_at := public.not_now_followup_at(named_day, l.mailing_state, now());
    if follow_at is null then
      return jsonb_build_object('ok', false, 'reason', 'the check-back date cannot be before today');
    end if;
  end if;
  select display_name into who from public.team_members where lower(email) = lower(auth.jwt() ->> 'email');
  if p_outcome in ('interested', 'reached_no_decision', 'not_now') then perform public.lock_card_to(p_lead_id, public.wpie_person(), 'reached on a call'); end if;
  label := case p_outcome when 'interested' then 'Interested' when 'not_now' then 'Not now' when 'not_interested' then 'Not interested'
                          when 'wrong_number' then case when disconnected then 'Disconnected number' else 'Wrong number' end when 'no_answer' then 'No answer'
                          when 'reached_no_decision' then 'Reached, no decision' else 'Do not contact' end;
  if p_outcome = 'not_now' and p_when is not null then
    update public.leads set named_date = follow_at where id = p_lead_id;
    label := label || ' until ' || to_char(named_day, 'Mon DD');
  end if;
  insert into public.messages (lead_id, direction, channel, body, from_number, sent_at, seen_at, status)
  values (p_lead_id, 'in', 'call', format('Call (%s)%s: %s%s', coalesce(who, 'team'),
            case when d ~ '^[0-9]{10}$' then ' from ' || d else '' end, label,
            coalesce(E'\n' || nullif(btrim(coalesce(p_note, '')), ''), '')),
          case when d ~ '^[0-9]{10}$' then '+1' || d end, now(), now(), p_outcome);
  update public.leads set call_facts = jsonb_set(call_facts, '{last_call}', jsonb_build_object('value', p_outcome, 'at', now(), 'by', who))
   where id = p_lead_id;

  if p_outcome in ('interested', 'reached_no_decision') then
    update public.leads set stage = case when stage in ('walkthrough_booked', 'offer', 'under_contract', 'closed_won') then stage else 'colin_call' end
     where id = p_lead_id;
  elsif p_outcome = 'no_answer' then
    null;
  elsif p_outcome = 'not_now' then
    update public.leads set stage = 'follow_up', next_action = coalesce(next_action, 'Check back'),
           next_action_at = coalesce(follow_at, next_action_at, now() + interval '30 days') where id = p_lead_id;
  elsif p_outcome = 'not_interested' then
    update public.leads set stage = 'dead', dead_reason = coalesce(nullif(btrim(coalesce(p_note, '')), ''), 'Not interested (call)') where id = p_lead_id;
  elsif p_outcome = 'wrong_number' then
    if d ~ '^[0-9]{10}$' then
      update public.contacts set status = 'bad',
             note = case when disconnected then concat_ws('; ', note, 'disconnected (call ' || to_char(now() at time zone 'America/Chicago', 'YYYY-MM-DD') || ')') else note end
       where lead_id = p_lead_id and value_normalized = d;
    end if;
    update public.leads set stage = 'data_fix' where id = p_lead_id;
  else
    select array_agg(distinct c.value_normalized) into phones from public.contacts c
     where c.lead_id = p_lead_id and c.kind = 'phone' and c.value_normalized ~ '^[0-9]{10}$';
    phones := coalesce(phones, '{}');
    if d ~ '^[0-9]{10}$' and not d = any(phones) then phones := array_append(phones, d); end if;
    insert into public.suppressed_phones (phone10, reason, source)
      select distinct p, 'dnc_call', 'app' from unnest(phones) p on conflict (phone10) do nothing;
    update public.contacts set suppressed = true, dnc_app = true where value_normalized = any(phones);
    update public.leads set stage = 'dnc' where id = p_lead_id;
  end if;
  return jsonb_build_object('ok', true, 'outcome', p_outcome, 'until', follow_at, 'named_day', named_day);
end $$;

-- thread_take: from 0146_texts_live.sql, locks the card
create or replace function public.thread_take(p_lead_id uuid, p_phone text, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare p text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10); who public.team_person := public.wpie_person(); n integer;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  if who is null then return jsonb_build_object('ok', false, 'reason', 'no person on this login'); end if;
  if p !~ '^[0-9]{10}$' then return jsonb_build_object('ok', false, 'reason', 'not a phone'); end if;
  if p_lead_id is not null then perform public.lock_card_to(p_lead_id, who, 'took the text thread'); end if;
  insert into public.thread_owners (phone10, lead_id, person, taken_at, note) values (p, p_lead_id, who, now(), p_note)
  on conflict (phone10) do update set lead_id = coalesce(excluded.lead_id, public.thread_owners.lead_id), person = excluded.person, taken_at = now(), note = excluded.note;
  -- an automated reply or belt text already waiting for this phone is withdrawn; the person is answering now
  update public.reply_drafts set status = 'superseded', note = coalesce(note, '') || ' | ' || who::text || ' took the thread', updated_at = now()
   where phone10 = p and coalesce(draft_source, '') <> 'team' and status in ('queued', 'awaiting_approval', 'would_send');
  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'person', who, 'withdrawn', n);
end $$;

-- power_dial_queue: from 0142_power_dial_queue_blocked_set.sql
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
       -- a callback promised by one caller is that caller's (Colin 2026-10-30): on a caller's own login only their own come up
       and (t.kind <> 'callback' or public.wpie_person() not in ('thalia', 'adil') or t.owner = public.wpie_person())
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
           and not exists (select 1 from blocked b where b.ph = c.value_normalized)
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
$function$
;

-- inbound_call_ring: from 0138_inbound_call_ring.sql, a locked card rings its caller
create or replace function public.inbound_call_ring(p_digits text, p_at timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public as $$
  with d as (select right(regexp_replace(coalesce(p_digits, ''), '\D', '', 'g'), 10) as ph),
  last_dialer as (
    select lower(e.by) as who from public.belt_events e, d
     where e.event = 'human_call_started' and e.at > p_at - interval '60 minutes' and e.at <= p_at
       and right(regexp_replace(coalesce(e.payload->>'phone', ''), '\D', '', 'g'), 10) = d.ph and d.ph <> ''
       and lower(e.by) in ('thalia', 'adil', 'colin')
     order by e.at desc limit 1),
  locked as (
    select l.locked_to::text as who from public.contacts c join public.leads l on l.id = c.lead_id, d
     where c.kind = 'phone' and c.value_normalized = d.ph and d.ph <> '' and l.locked_to in ('thalia', 'adil')
     order by l.locked_at desc nulls last limit 1),
  shift as (select public.on_shift_person(p_at)::text as who,
                   extract(isodow from p_at at time zone 'America/Chicago') between 1 and 5
                   and (p_at at time zone 'America/Chicago')::time >= time '16:00' and (p_at at time zone 'America/Chicago')::time < time '18:00' as power_hour)
  select jsonb_build_object(
    'ring', to_jsonb(case
      when (select who from last_dialer) is not null then array[(select who from last_dialer)]
      when (select who from locked) is not null then array[(select who from locked)]
      when (select power_hour from shift) then array['thalia', 'adil']
      when (select who from shift) = 'colin' then array['colin', 'thalia', 'adil']
      else array[(select who from shift)] end),
    'return_call', (select who from last_dialer) is not null,
    'locked_to', (select who from locked),
    'dialed_by', (select who from last_dialer))
$$;

-- missed_call_person: from 0144_missed_call_person.sql, the locked caller before the shift
create or replace function public.missed_call_person(p_from10 text, p_at timestamptz default now()) returns public.team_person
language sql stable security definer set search_path = public as $$
  with d as (select right(regexp_replace(coalesce(p_from10, ''), '\D', '', 'g'), 10) as ph),
  last_dialer as (
    select lower(e.by) as who from public.belt_events e, d
     where e.event = 'human_call_started' and e.at > p_at - interval '7 days' and e.at <= p_at
       and right(regexp_replace(coalesce(e.payload->>'phone', ''), '\D', '', 'g'), 10) = d.ph and d.ph <> ''
       and lower(e.by) in ('thalia', 'adil', 'colin')
     order by e.at desc limit 1)
  , locked as (
    select l.locked_to as who from public.contacts c join public.leads l on l.id = c.lead_id, d
     where c.kind = 'phone' and c.value_normalized = d.ph and d.ph <> '' and l.locked_to in ('thalia', 'adil')
     order by l.locked_at desc nulls last limit 1)
  select coalesce((select who from last_dialer)::public.team_person, (select who from locked), public.on_shift_person(p_at))
$$;

-- backfill: cards a caller already reached, from the call log ("Call (Thalia) ...: Interested"), first contact wins
with contacts as (
  select m.lead_id, lower(substring(m.body from '^Call \((\w+)\)')) as who, min(m.sent_at) as first_at
    from public.messages m where m.channel = 'call' and m.status in ('interested', 'reached_no_decision', 'not_now')
   group by m.lead_id, lower(substring(m.body from '^Call \((\w+)\)'))),
first_contact as (select distinct on (lead_id) lead_id, who, first_at from contacts where who in ('thalia', 'adil') order by lead_id, first_at)
update public.leads l set locked_to = f.who::public.team_person, locked_at = f.first_at,
       notes = concat_ws(' | ', l.notes, '2026-10-30 card locked to ' || initcap(f.who) || ' (backfill: reached on ' || to_char(f.first_at at time zone 'America/Chicago', 'Mon DD') || ')')
  from first_contact f where f.lead_id = l.id and l.locked_to is null;

