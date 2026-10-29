-- A cold no-answer stays cold (Colin 2026-10-28: "so what happens with all these leads that didnt answer? we probably
-- need logic for em"). belt_route_no_answer put any card with no belt on the warm "said yes, not booked" track after a
-- no answer: "Colin's call", a "just tried you, what time works?" text and a "you asked for a call" dial two days later,
-- for owners who never replied. Now a cold card (no reply, never reached, never hot) stays off the belts: Power hour and
-- the call list pace its dials, and after 9 dials with no contact it rests 90 days (dormant). Then the 18 cold cards it
-- had moved are put back.

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
      if dials >= 9 then
        return public.belt_enter(p_lead_id, 'dormant', 1, p_event, pl || jsonb_build_object('note', '9 dials, never reached: a 90-day rest'), p_by, p_now);
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
end $$;

-- the cold cards a no-answer put on the warm track (18 on 2026-10-28, among them the 12 logged as no answer that
-- evening after the screen-jumping bug): back to where they were, their warm-track tasks closed
do $$
declare r record;
begin
  for r in select l.id, exists (select 1 from public.messages m where m.lead_id = l.id and m.direction = 'out' and m.channel = 'sms' and m.is_opener) as texted
             from public.leads l
            where l.belt = 'yes_unbooked'
              and not exists (select 1 from public.twilio_inbound ti where ti.lead_id = l.id)
              and not exists (select 1 from public.messages m where m.lead_id = l.id and m.channel = 'call'
                               and m.status in ('interested', 'reached_no_decision', 'not_now', 'not_interested'))
              and not exists (select 1 from public.hot_alerts h where h.lead_id = l.id)
              and not exists (select 1 from public.deal_packages d where d.lead_id = l.id)
  loop
    update public.tasks set done_at = now(), note = concat_ws(E'\n', note, 'Closed: a cold no-answer, not a warm lead (fixed 2026-10-28).')
     where lead_id = r.id and source = 'belt' and done_at is null;
    insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
    values (r.id, 'move', 'yes_unbooked', null, 0, jsonb_build_object('reason', 'a cold no-answer was put on the warm track by mistake; back to cold'), now(), 'colin');
    perform set_config('wpie.in_belt_event', '1', true);
    update public.leads set belt = null, belt_step = 0, next_stop_at = null, next_stop_who = null, next_stop_say = null,
           stage = (case when r.texted then 'opener_sent' else 'postcard_mailed' end)::public.lead_stage
     where id = r.id;
    perform set_config('wpie.in_belt_event', '', true);
  end loop;
end $$;
