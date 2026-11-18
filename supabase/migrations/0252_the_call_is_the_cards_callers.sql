-- 0252: the belt's caller call is the card's caller's call, and the card says so.
--
-- Colin 2026-11-18, a screenshot of Jason Vanidestine's card (991 Howard St), which is Tyler's: under "What happens next"
-- it read "Thalia's call Fri Nov 20, 10:00 AM". The belt has one name for a caller's stop (next_stop_who = 'thalia_call',
-- from when Thalia was the only caller) and next_plain() printed that name unless the reader was Thalia. So every card
-- of Tyler's told Tyler the next call was Thalia's. A card has one owner end to end (0250): the stop is the card's
-- caller's. To a caller it now reads "Your call" (a caller only ever reads their own card); to Colin and Muse it reads
-- the card's caller by name ("Tyler's call"), or "The caller's call" where no name was handed in (the lists).
--
-- The stored value 'thalia_call' is not renamed: 151 cards and the conveyor carry it, and it never reaches a screen.

drop function public.next_plain(text, timestamptz, text, text, timestamptz, text, team_person);

CREATE OR REPLACE FUNCTION public.next_plain(p_belt text, p_next_at timestamp with time zone, p_next_who text, p_next_say text, p_named_date timestamp with time zone, p_named_event text, p_me team_person DEFAULT NULL::team_person, p_caller_name text DEFAULT NULL::text)
 RETURNS text
 LANGUAGE plpgsql
 IMMUTABLE
AS $fn$
declare who text; first text; ladder text; d text;
begin
  d := case when p_next_at is null then null else to_char(p_next_at at time zone 'America/Chicago', 'Dy Mon FMDD, FMHH:MI AM') end;
  who := case p_next_who
           -- the belt's caller stop is the card's caller's call, whoever that is (0252). A caller only ever reads their own
           -- card (0250), so to a caller it is 'Your call'; to anyone else it is the card's caller by name.
           when 'thalia_call' then case when p_me in ('thalia', 'adil') then 'Your call' else coalesce(nullif(btrim(p_caller_name), '') || '''s call', 'The caller''s call') end
           when 'adil_call' then case when p_me in ('thalia', 'adil') then 'Your call' else coalesce(nullif(btrim(p_caller_name), '') || '''s call', 'The caller''s call') end
           when 'owner_call' then 'The booked call'
           when 'colin_call' then 'Colin''s call'
           when 'colin_visit' then 'Colin''s walk'
           when 'auto_text' then 'A text from the machine'
           when 'draft_text' then 'A text (drafted, Colin taps it)'
           else null end;
  first := case when p_next_at is not null and who is not null then who || ' ' || d
                     || case when p_next_say is not null and p_next_say <> '' then ': "' || left(p_next_say, 120) || '"' else '' end
                when p_belt in ('cold_texts') then 'The texts are working it'
                when p_belt in ('dead', 'dnc') then 'Closed'
                when p_belt is null then 'Not on a ladder yet: your next step puts it on one'
                else 'Resting: nothing scheduled' end;
  ladder := case p_belt
    when 'cold_texts' then 'Then: text 2 at day 4, text 3 at day 18, one call from the caller after that.'
    when 'hold_not_now' then 'Then: Colin''s check-in on the day they named' || coalesce(' (' || p_named_event || ')', '') || ', and again 6 months on.'
    when 'not_now_dated' then 'Then: your call on the date they gave' || coalesce(' (' || p_named_event || ')', '') || ', one more a week after.'
    when 'not_now_condition' then 'Then: a text at 30 days about ' || coalesce(p_named_event, 'what they named') || ', your call at 90, a text at 180, quarterly after; the records wake it sooner.'
    when 'dormant' then 'Then: a text every 90 days; a "still yours?" call about a year on.'
    when 'needs_family' then 'Then: your call the day after they talk to the family, a text a week on, Colin at 30 days.'
    when 'estate_waiting' then 'Then: Colin''s calls at 3 days, 30, 90 and 180; a text at a year.'
    when 'elderly' then 'Then: Colin''s call on the day they named, then every 90 days, family on the line.'
    when 'yes_unbooked' then 'Then: a text in an hour, your call again in 2 days, a text at 2 weeks.'
    when 'replied_quiet' then 'Then: a text tomorrow, your call in 4 days, a text at 18 days.'
    when 'questions_quiet' then 'Then: a text tomorrow, your call in 4 days, a text at 18 days.'
    when 'after_call_quiet' then 'Then: Colin''s call in 3 days, a text at 10 days, Colin''s call at 30.'
    when 'call_booked' then 'A text the morning of, then the call at the slot.'
    when 'visit_booked' then 'A text the morning of, then Colin at the house.'
    when 'call_missed' then 'Then: one more try within the hour, a text, a try the next day, a text at a week.'
    when 'visit_missed' then 'Then: one more try within the hour, a text, a try the next day, a text at a week.'
    when 'offer_out' then 'Then: Colin''s call in 2 days, a text, Colin''s call at a week, a text at 30 days.'
    when 'after_visit_quiet' then 'Then: Colin''s call in 2 days, a text, Colin''s call at a week, a text at 30 days.'
    when 'too_high_or_listed' then 'Then: nothing until the listing ends or the records change; then it comes back.'
    else '' end;
  return btrim(first || '. ' || ladder);
end $fn$;

CREATE OR REPLACE FUNCTION public.card_brief(p_lead_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
declare l public.leads; me team_person; res jsonb;
begin
  perform public.card_guard(p_lead_id);   -- 0250: a card is its caller's
  if not public.is_team() then raise exception 'team only'; end if;
  me := public.wpie_person();
  select * into l from public.leads where id = p_lead_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card'); end if;
  select jsonb_build_object(
    'ok', true,
    'lane', l.lane,
    'say_next', l.say_next,
    'next_plain', public.next_plain(l.belt, l.next_stop_at, l.next_stop_who, l.next_stop_say, l.named_date, l.named_event, me,
                     (select tm.display_name from public.team_members tm where tm.person = public.card_caller(l.id))),
    'mine_next', (select jsonb_build_object('task_id', t.id, 'due_at', t.due_at, 'kind', t.kind, 'note', t.note, 'owner', t.owner, 'source', t.source)
                    from public.tasks t where t.lead_id = l.id and t.done_at is null and t.kind in ('call', 'callback', 'visit', 'text', 'other')
                   order by t.due_at nulls last limit 1),
    'why', jsonb_build_object(
       'reasons', l.reasons_to_sell,
       'motivation', (select lm.lines from public.lead_motivation lm where lm.lead_id = l.id),
       'last_words', (select left(mi.body, 240) from public.messages mi where mi.lead_id = l.id and mi.direction = 'in' and mi.channel = 'sms' order by mi.sent_at desc limit 1),
       'last_call', (select left(regexp_replace(coalesce(lc.body, ''), '^Call \([^)]*\) from \d+:\s*', ''), 240) from public.messages lc
                       where lc.lead_id = l.id and lc.channel = 'call' and lc.status is distinct from 'inbound_missed' order by lc.sent_at desc limit 1),
       'promise', (select pm.note from public.tasks pm where pm.lead_id = l.id and pm.source = 'mine' and pm.done_at is null order by pm.due_at limit 1)),
    'touches', (select coalesce(jsonb_agg(x order by x.at desc), '[]'::jsonb) from (
                  select m.sent_at at, m.channel, m.direction, coalesce(m.status, '') status, left(m.body, 140) body
                    from public.messages m where m.lead_id = l.id and m.channel in ('call', 'sms', 'note') order by m.sent_at desc limit 3) x),
    'touches_total', (select count(*) from public.messages m where m.lead_id = l.id and m.channel in ('call', 'sms')),
    'planned', (select coalesce(jsonb_agg(y order by y.at), '[]'::jsonb) from (
                  select t.due_at at, t.kind what, coalesce(t.title, t.note) words, t.owner::text who from public.tasks t
                   where t.lead_id = l.id and t.done_at is null and t.due_at is not null and t.kind <> 'nudge'
                  union all
                  select l.next_stop_at, 'belt', l.next_stop_say, l.next_stop_who where l.next_stop_at is not null and l.next_stop_at > now()
                  order by 1 limit 2) y),
    'rest', case when l.parked_at is not null then jsonb_build_object('until', l.rest_until, 'why', l.parked_why, 'by_colin', l.rest_until is null) end,
    'nudges', (select coalesce(jsonb_agg(jsonb_build_object('task_id', n.id, 'from', n.title, 'text', n.note, 'at', n.created_at, 'to', n.owner) order by n.created_at desc), '[]'::jsonb)
                 from public.tasks n where n.lead_id = l.id and n.kind = 'nudge' and n.done_at is null),
    'locked_to', l.locked_to, 'belt', l.belt, 'stage', l.stage)
  into res;
  return res;
end $fn$;

grant execute on function public.next_plain(text, timestamptz, text, text, timestamptz, text, team_person, text) to authenticated, service_role;
