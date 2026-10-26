-- The Warm Leads board (Colin 2026-10-25: "We don't really have much for warm lead management do we"). One query for
-- every card past the cold texts, grouped the way the team works them:
--   decide   a call was started and never logged, a call stop more than a day overdue, or a belt with no next stop
--   hot      said yes but not booked, a missed call or visit, a call that left no next step
--   booked   a call or visit on the calendar, an offer out
--   talking  replied and went quiet, or quiet in the middle of the questions
--   callback "not now" with the date they gave
--   nurture  the long ones: a condition, family, elderly, estate papers, hold lane, too high, dormant after a reply
-- Each row carries what the board shows: their last words, what we know (call facts and reply facts), the next stop.

create or replace function public.warm_board(p_now timestamptz default now())
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_team() then raise exception 'not on the team'; end if;
  return coalesce((
    select jsonb_agg(row_to_json(x)::jsonb order by x.sort_at nulls last)
    from (
      select l.id, l.owner_name, l.property_address, l.municipality, l.county, l.belt, l.stage::text as stage,
             l.belt_step, l.next_stop_at, l.next_stop_who, l.next_stop_say, l.named_date, l.named_event,
             l.assigned_to::text as assigned_to, l.hot_at, l.human_takeover_at, l.human_takeover_by, l.call_facts,
             l.elderly_or_ill, l.grief,
             coalesce((select jsonb_object_agg(k, v) from (
                 select distinct on (e.key) e.key as k, e.value as v
                   from public.reply_drafts d, jsonb_each(d.facts) e
                  where d.lead_id = l.id and d.facts is not null and jsonb_typeof(d.facts) = 'object'
                  order by e.key, d.inbound_at desc) f), '{}'::jsonb) as facts,
             li.body as last_in_body, li.received_at as last_in_at,
             (select max(m.sent_at) from public.messages m where m.lead_id = l.id and m.direction = 'out') as last_out_at,
             (select count(*) from public.twilio_inbound t where t.lead_id = l.id) as replies,
             g.grp, g.why,
             case g.grp when 'booked' then coalesce(l.named_date, l.next_stop_at) else coalesce(l.next_stop_at, l.named_date) end as sort_at
        from public.leads l
        left join lateral (select t.body, t.received_at from public.twilio_inbound t where t.lead_id = l.id
                            order by t.received_at desc limit 1) li on true
        cross join lateral (select
          case
            when l.human_takeover_at is not null then 'decide'
            when l.next_stop_who in ('thalia_call', 'colin_call', 'colin_visit') and l.next_stop_at < p_now - interval '1 day' then 'decide'
            when l.next_stop_at is null and l.belt not in ('too_high_or_listed', 'dormant') then 'decide'
            when l.belt in ('yes_unbooked', 'call_missed', 'visit_missed', 'after_call_quiet') then 'hot'
            when l.belt in ('call_booked', 'visit_booked', 'offer_out') then 'booked'
            when l.belt in ('replied_quiet', 'questions_quiet') then 'talking'
            when l.belt = 'not_now_dated' then 'callback'
            else 'nurture' end as grp,
          case
            when l.human_takeover_at is not null then 'A call was started ' || to_char(l.human_takeover_at at time zone 'America/Chicago', 'Dy FMHH12:MI AM') || ' and never logged'
            when l.next_stop_who in ('thalia_call', 'colin_call', 'colin_visit') and l.next_stop_at < p_now - interval '1 day' then 'The call is more than a day overdue'
            when l.next_stop_at is null and l.belt not in ('too_high_or_listed', 'dormant') then 'No next step on this card'
          end as why) g
       where l.belt is not null and l.belt not in ('cold_texts', 'dead', 'dnc')
         and l.stage not in ('dnc', 'dead', 'closed_no_contact', 'closed_won')
         and (l.belt <> 'dormant' or exists (select 1 from public.twilio_inbound t where t.lead_id = l.id))
    ) x), '[]'::jsonb);
end $$;
revoke all on function public.warm_board(timestamptz) from public, anon;
grant execute on function public.warm_board(timestamptz) to authenticated;
