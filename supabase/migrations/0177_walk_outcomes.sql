-- 0177: a booked walk or call has its own outcomes on My cards (Colin 2026-11-04: "our crm needs logic for these waiting
-- to walk or hot lead properties, thalia should have a section where these cards are and be able to move them around
-- and then put them on followup if they waver or no show"). walk_outcome(lead, outcome, at, note), for the card's caller
-- (or Colin):
--   rebook      a new day and time: the belt re-books the visit or the call (next_step), the confirm call moves with it
--   waver       "we'll think about it": their words on the card, and a call for Colin an hour before the walk so he
--               decides whether to go; the walk stays
--   no_show     nobody there, nobody answering: the walk comes off and the card goes to the caller's check-back
--               (not_now_dated, whose stops are the caller's since 0170), three days out unless a date is given
--   check_back  "not now", cancelled, cold feet: same, on the date they named, with their words as the event
-- The Booked pile on My cards (my_piles) also holds hot cards, and carries the walk's time.

create or replace function public.walk_outcome(p_lead_id uuid, p_outcome text, p_at timestamptz default null, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare l public.leads; who public.team_person; what text; res jsonb; at timestamptz; ev text; n integer; by_name text;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  select * into l from public.leads where id = p_lead_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card'); end if;
  who := public.wpie_person();
  by_name := initcap(coalesce(who::text, 'team'));
  if not public.is_owner() and l.locked_to is distinct from who then return jsonb_build_object('ok', false, 'reason', 'not your card'); end if;
  -- what is booked: a walk (Colin's visit) or a call
  what := case when l.belt in ('visit_booked', 'visit_missed') or l.stage::text = 'walkthrough_booked' then 'walk' else 'call' end;
  if p_outcome = 'rebook' then
    if p_at is null then return jsonb_build_object('ok', false, 'reason', 'a day and time'); end if;
    res := public.belt_event(p_lead_id, 'next_step', jsonb_build_object('kind', case when what = 'walk' then 'walk' else 'callback' end, 'at', p_at, 'note', p_note), by_name, now());
    insert into public.messages (lead_id, direction, channel, body, status, created_by, sent_at)
    values (p_lead_id, 'out', 'note', initcap(what) || ' moved to ' || to_char(p_at at time zone 'America/Chicago', 'Dy Mon FMDD, FMHH:MI AM')
            || coalesce(' (' || nullif(btrim(p_note), '') || ')', '') || ' by ' || by_name, null, auth.uid(), now());
    return coalesce(res, '{}'::jsonb) || jsonb_build_object('ok', true, 'outcome', 'rebook', 'at', p_at);
  elsif p_outcome = 'waver' then
    insert into public.messages (lead_id, direction, channel, body, status, created_by, sent_at)
    values (p_lead_id, 'out', 'note', 'Wavering before the ' || what || ': ' || coalesce(nullif(btrim(p_note), ''), 'no words given') || ' (' || by_name || ')', null, auth.uid(), now());
    at := greatest(now() + interval '5 minutes', coalesce(l.named_date, now()) - interval '1 hour');
    insert into public.tasks (lead_id, due_at, kind, owner, note, created_by, source, source_key, title)
    values (p_lead_id, at, 'call', 'colin', 'Seller wavered before the ' || what || coalesce(' at ' || to_char(l.named_date at time zone 'America/Chicago', 'Dy FMHH:MI AM'), '')
            || ': "' || coalesce(nullif(btrim(p_note), ''), '') || '". Decide whether to go; the ' || what || ' is still on.', auth.uid(), 'waver',
            'waver:' || p_lead_id::text || ':' || to_char(now(), 'YYYYMMDDHH24MI'), 'Seller wavered: go or not?')
    on conflict (source_key) do nothing;
    insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
    values (p_lead_id, 'flag', l.belt, l.belt, l.belt_step, jsonb_build_object('flag', 'waver', 'note', p_note), now(), by_name);
    return jsonb_build_object('ok', true, 'outcome', 'waver', 'colin_call_at', at);
  elsif p_outcome in ('no_show', 'check_back') then
    at := coalesce(p_at, now() + interval '3 days');
    ev := coalesce(nullif(btrim(p_note), ''), case when p_outcome = 'no_show' then 'no-show on the ' || what else 'check back' end);
    -- the walk's own tasks come off (the belt change cancels its stops; the confirm call is not a belt stop)
    update public.tasks t set done_at = now(), note = concat_ws(' | ', t.note, p_outcome || ' (' || by_name || ')')
     where t.lead_id = p_lead_id and t.done_at is null and (t.source in ('walk_confirm', 'waver') or (t.kind = 'callback' and t.source is distinct from 'belt'));
    get diagnostics n = row_count;
    res := public.belt_event(p_lead_id, 'named_date', jsonb_build_object('named_date', at, 'named_event', ev, 'reason', p_outcome), by_name, now());
    insert into public.messages (lead_id, direction, channel, body, status, created_by, sent_at)
    values (p_lead_id, 'out', 'note', (case when p_outcome = 'no_show' then 'No-show on the ' || what else 'Off the ' || what || ', check back' end) || ': ' || ev
            || '. Check-back ' || to_char(at at time zone 'America/Chicago', 'Dy Mon FMDD') || ' (' || by_name || ')', null, auth.uid(), now());
    return coalesce(res, '{}'::jsonb) || jsonb_build_object('ok', true, 'outcome', p_outcome, 'check_back_at', at, 'tasks_closed', n);
  end if;
  return jsonb_build_object('ok', false, 'reason', 'rebook, waver, no_show or check_back');
end $$;
revoke all on function public.walk_outcome(uuid, text, timestamptz, text) from public, anon;
grant execute on function public.walk_outcome(uuid, text, timestamptz, text) to authenticated;

-- the Booked pile: walks, calls, offers, and hot cards of the last two weeks, with the walk's time on the row
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
     where l.id in (select lead_id from mine)
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
