-- 0169: My cards after the 50/50 split (0168): a card locked to a caller is theirs, not proof they reached anyone. Since
-- 0168 every open card is locked to Thalia or Adil, so 'Talked, nothing scheduled' showed about 2,300 cards nobody had
-- dialed. Now: talked = took the texts, a package, a reached outcome or a live stage; tried = a call logged, never
-- reached; and a new pile not_called = their cards nobody has dialed yet (their inventory), best motivation first.

create or replace function public.my_piles(p_person public.team_person default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
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
           l.named_date, l.locked_to,
           (select string_agg(distinct m2.why, ', ') from mine m2 where m2.lead_id = l.id) why,
           t.id task_id, t.due_at task_due, t.kind task_kind, coalesce(t.title, left(t.note, 140)) task_what,
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
        when c.belt in ('call_booked', 'visit_booked', 'offer_out') or c.stage in ('walkthrough_booked', 'offer', 'under_contract') then 'booked'
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
           'last_call_at', last_call_at, 'last_call', nullif(last_call, ''), 'why', why, 'locked_to', locked_to, 'tier', tier)
         order by array_position(array['call_now','booked','colin','this_week','later','no_step','tried','not_called','closed'], pile),
                  case when pile in ('no_step', 'tried', 'not_called') then null else next_at end nulls last,
                  case when pile = 'not_called' then coalesce(tier, 'Z') end, last_call_at desc nulls last), '[]'::jsonb))
    into res from piled;
  return res;
end $$;
revoke all on function public.my_piles(public.team_person) from public;
grant execute on function public.my_piles(public.team_person) to authenticated;
