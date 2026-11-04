-- 0182: parked cards (Colin 2026-11-04: "divide them up into 4 lots based on motivation reasons and take the worst two
-- lots out of thalia and adil's crms"). leads.parked_at / parked_why mark a card the callers never see: it leaves
-- My cards (my_piles) and Power hour (power_dial_queue) but keeps its owner, its belt and its texts; the laptop's
-- texting rules do not read it. Colin parks and un-parks lots by hand (tools, as owner); nothing parks on its own.
-- A reply or a new record that puts the card in front of a caller again should un-park it (see wake rules later).

alter table public.leads add column if not exists parked_at timestamptz;
alter table public.leads add column if not exists parked_why text;
create index if not exists leads_parked_idx on public.leads (parked_at) where parked_at is not null;

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
       -- a power-hour set is loaded per caller (Colin 2026-11-03: "50 in each and then followups"): only its caller sees it
       and (coalesce(t.source, '') not in ('power_hour', 'power_hour_after') or public.wpie_person() not in ('thalia', 'adil') or t.owner = public.wpie_person())
     order by t.lead_id, (t.kind = 'callback') desc, (t.source = 'call_next') desc, t.due_at),
  pool as (
    select l.*, dt.task_id, dt.title as task_title, dt.reply_words, dt.task_at, dt.due_at as task_due, (dt.task_source = 'call_next') as replied,
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
       -- a caller's due follow-up call (the belt's) still comes up when a caller took the text thread (0163)
       and (l.human_takeover_at is null or dt.task_source in ('belt', 'mine'))
       and (l.named_date is null or l.named_date <= p_now)
        and l.parked_at is null   -- parked (0182): out of the callers' CRMs, the texts still work it
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
     order by p.src, p.missed_at desc nulls last, (coalesce(p.task_source, '') = 'power_hour') desc,
              case when p.task_source = 'power_hour' then p.task_due end nulls last, p.task_at nulls last, cardinality(p.reasons_to_sell) desc, p.first_text_at nulls last, p.id
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
      'dials_7d', dials_7d, 'dials_total', dials_total, 'last_dial', last_dial,
      'phone', phone, 'line_type', line_type, 'phone_person', phone_person, 'other_phones', greatest(other_phones, 0))
      order by src, missed_at desc nulls last, (coalesce(task_source, '') = 'power_hour') desc,
        case when task_source = 'power_hour' then task_due end nulls last, task_at nulls last, cardinality(reasons_to_sell) desc, first_text_at nulls last, id), '[]'::jsonb)
    from pick
$function$;

CREATE OR REPLACE FUNCTION public.my_piles(p_person team_person DEFAULT NULL::team_person)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare who public.team_person; eod timestamptz; res jsonb;
begin
  if not public.is_team() then raise exception 'only the team'; end if;
  who := coalesce(p_person, public.wpie_person());
  if who is distinct from public.wpie_person()
     and coalesce((select role::text from public.team_members where person = public.wpie_person() limit 1), '') <> 'owner' then
    who := public.wpie_person();
  end if;
  eod := (date_trunc('day', now() at time zone 'America/Chicago') + interval '1 day') at time zone 'America/Chicago';
  with ppl as (
    select tm.person, u.id uid from public.team_members tm join auth.users u on lower(u.email) = tm.email where tm.person = who
  ), mine as (
    select id lead_id, 'your card' why from public.leads where locked_to = who
    union select id, 'assigned' from public.leads where assigned_to = who
    union select id, 'took the texts' from public.leads where human_takeover_assigned_to = who or lower(coalesce(human_takeover_by, '')) = who::text
    union select lead_id, 'built the package' from public.deal_packages where created_by = who
    union select m.lead_id, 'logged a call' from public.messages m join ppl on ppl.uid = m.created_by where m.channel = 'call' and m.lead_id is not null
    union select lead_id, 'call on their list' from public.tasks
           where owner = who and done_at is null and lead_id is not null and coalesce(source, '') not in ('power_hour', 'power_hour_after')
  ), cards as (
    select l.id, l.owner_name, l.property_address, l.municipality, l.county, l.stage::text stage, l.belt, l.next_stop_at, l.next_stop_say,
           l.named_date, l.named_event, l.hot_at, l.locked_to,
           (select string_agg(distinct m2.why, ', ') from mine m2 where m2.lead_id = l.id) why,
           t.id task_id, t.due_at task_due, t.kind task_kind, t.source task_source, coalesce(t.title, left(t.note, 140)) task_what,
           pk.status pkg,
           (l.human_takeover_assigned_to = who
            or exists (select 1 from public.deal_packages d2 where d2.lead_id = l.id)
            or exists (select 1 from public.messages m3 where m3.lead_id = l.id and m3.channel = 'call'
                        and m3.status in ('interested', 'reached_no_decision', 'not_now', 'inbound_answered'))
            or l.stage in ('reply_received', 'ai_qualifying', 'handoff', 'colin_call', 'walk_decision', 'human_owned')) talked,
           lm.tier,
           (lc.sent_at is not null) dialed,
           lc.sent_at last_call_at, left(regexp_replace(coalesce(lc.body, ''), '^Call \([^)]*\) from \d+:\s*', ''), 220) last_call
      from public.leads l
      left join public.lead_motivation lm on lm.lead_id = l.id
      left join lateral (select x.* from public.tasks x where x.lead_id = l.id and x.owner = who and x.done_at is null
                          order by x.due_at nulls last limit 1) t on true
      left join lateral (select d.status from public.deal_packages d where d.lead_id = l.id order by d.created_at desc limit 1) pk on true
      left join lateral (select mm.sent_at, mm.body from public.messages mm where mm.lead_id = l.id and mm.channel = 'call' and mm.status is distinct from 'inbound_missed'
                          order by mm.sent_at desc limit 1) lc on true
     where l.id in (select lead_id from mine) and l.parked_at is null
  ), piled as (
    select c.*,
      case
        when c.stage in ('dead', 'dnc', 'closed_won', 'closed_no_contact', 'mail_only') then 'closed'
        when c.task_due is not null and c.task_due < eod then 'call_now'
        when c.belt in ('call_booked', 'visit_booked', 'visit_missed', 'call_missed', 'offer_out') or c.stage in ('walkthrough_booked', 'offer', 'under_contract')
             or (c.hot_at is not null and c.hot_at > now() - interval '14 days') then 'booked'
        when c.pkg in ('waiting_value', 'waiting_number', 'counter') then 'colin'
        when c.task_due is not null and c.task_due < now() + interval '7 days' then 'this_week'
        when c.task_due is not null or (c.next_stop_at is not null and c.next_stop_at > now())
             or c.belt in ('not_now_dated', 'not_now_condition', 'needs_family', 'elderly', 'estate_waiting', 'hold_not_now', 'dormant', 'too_high_or_listed') then 'later'
        when c.talked then 'no_step'
        when c.dialed then 'tried'
        else 'not_called'
      end pile,
      coalesce(c.task_due, case when c.next_stop_at > now() then c.next_stop_at end, case when c.named_date > now() then c.named_date end) next_at
    from cards c
  )
  select jsonb_build_object('person', who, 'cards', coalesce(jsonb_agg(jsonb_build_object(
           'lead_id', id, 'owner_name', owner_name, 'address', property_address, 'municipality', municipality, 'county', county,
           'stage', stage, 'belt', belt, 'pile', pile, 'next_at', next_at,
           'next_what', coalesce(task_what, case when next_stop_at > now() then next_stop_say end),
           'last_call_at', last_call_at, 'last_call', nullif(last_call, ''), 'why', why, 'locked_to', locked_to, 'tier', tier,
           'task_id', task_id, 'task_kind', task_kind, 'task_source', task_source,
           'walk_at', case when belt in ('visit_booked', 'call_booked') or stage = 'walkthrough_booked' then named_date end, 'named_event', named_event, 'hot_at', hot_at)
         order by array_position(array['call_now','booked','colin','this_week','later','no_step','tried','not_called','closed'], pile),
                  case when pile in ('no_step', 'tried', 'not_called') then null else next_at end nulls last,
                  case when pile = 'not_called' then coalesce(tier, 'Z') end, last_call_at desc nulls last), '[]'::jsonb))
    into res from piled;
  return res;
end $function$;
