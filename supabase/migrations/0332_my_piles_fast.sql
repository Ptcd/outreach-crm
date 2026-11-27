-- 0332 (2026-11-27). Colin: "thalia cant see cards". Her Today page and My cards both call my_piles, and a caller's
-- login gives a statement 8 seconds. my_piles took 19 s for Thalia (8,581 cards) and 13 s for Tyler (8,662): for every
-- card it re-read the whole list of that caller's cards to say why the card is theirs, so the work grew with the
-- square of the card count, and this week's 5,700 new cards took it past the limit. Both pages showed an error
-- instead of the piles. The reason is now worked out once for all cards and joined. Same rows, same order.

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
  ), mine_why as (
    select m2.lead_id, string_agg(distinct m2.why, ', ') why from mine m2 group by m2.lead_id
  ), cards as (
    select l.id, l.owner_name, l.property_address, l.municipality, l.county, l.stage::text stage, l.belt, l.next_stop_at, l.next_stop_say,
           l.named_date, l.named_event, l.hot_at, l.locked_to,
           l.lane, l.say_next, l.reasons_to_sell, l.rest_until, l.parked_at, l.parked_why, l.next_stop_who,
           (select string_agg(c3.value_normalized, ' ') from public.contacts c3 where c3.lead_id = l.id and c3.kind = 'phone') phones,
           (select count(*) from public.messages mt where mt.lead_id = l.id and mt.channel in ('call', 'sms')) touches,
           (select left(mi.body, 160) from public.messages mi where mi.lead_id = l.id and mi.direction = 'in' and mi.channel = 'sms' order by mi.sent_at desc limit 1) last_words,
           (select left(coalesce(nz.note, nz.title), 200) from public.tasks nz where nz.lead_id = l.id and nz.kind = 'nudge' and nz.owner = who and nz.done_at is null order by nz.created_at desc limit 1) nudge,
           (select left(coalesce(pm.note, ''), 200) from public.tasks pm where pm.lead_id = l.id and pm.source = 'mine' and pm.owner = who and pm.done_at is null order by pm.due_at limit 1) promise,
           mw.why,
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
      from mine_why mw
      join public.leads l on l.id = mw.lead_id
      left join public.lead_motivation lm on lm.lead_id = l.id
      left join lateral (select x.* from public.tasks x where x.lead_id = l.id and x.owner = who and x.done_at is null
                          order by x.due_at nulls last limit 1) t on true
      left join lateral (select d.status from public.deal_packages d where d.lead_id = l.id order by d.created_at desc limit 1) pk on true
      left join lateral (select mm.sent_at, mm.body from public.messages mm where mm.lead_id = l.id and mm.channel = 'call' and mm.status is distinct from 'inbound_missed'
                          order by mm.sent_at desc limit 1) lc on true
     where not (coalesce(l.locked_to = any ((select public.caller_blind_locks())::public.team_person[]), false) or (l.locked_to is distinct from (select public.wpie_person()) and coalesce(l.assigned_to = any ((select public.caller_blind_to())::public.team_person[]), false)))
       -- a card Colin parked is hidden; a card the caller rested (rest_until) stays, in the Resting pile until it wakes (0186)
       and (l.parked_at is null or l.rest_until is not null)
  ), piled as (
    select c.*,
      case
        when c.stage in ('dead', 'dnc', 'closed_won', 'closed_no_contact', 'mail_only') then 'closed'
        when c.parked_at is not null and c.rest_until > now() then 'resting'
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
           'lane', lane, 'say_next', say_next, 'reasons', reasons_to_sell, 'phones', phones, 'touches', touches, 'last_words', last_words,
           'nudge', nudge, 'promise', promise, 'rest_until', case when parked_at is not null then rest_until end, 'rest_why', case when parked_at is not null then parked_why end,
           'next_plain', public.next_plain(belt, next_stop_at, next_stop_who, next_stop_say, named_date, named_event, who),
           'walk_at', case when belt in ('visit_booked', 'call_booked') or stage = 'walkthrough_booked' then named_date end, 'named_event', named_event, 'hot_at', hot_at)
         order by array_position(array['call_now','booked','colin','this_week','later','no_step','tried','not_called','resting','closed'], pile),
                  case when pile in ('no_step', 'tried', 'not_called') then null else next_at end nulls last,
                  case when pile = 'not_called' then coalesce(tier, 'Z') end, last_call_at desc nulls last), '[]'::jsonb))
    into res from piled;
  return res;
end $function$;
