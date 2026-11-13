-- The day (0219), one fix found the evening it shipped, on a build of tomorrow's list against the live store (rolled
-- back): the owner's next number is a first text (step 1) on another phone, and the card already has a step 1 that went
-- to the wrong person, so ready_to_text and the backstop took the row for written and never showed it. A row is
-- written when a text for its step went to ITS phone.

create or replace function public.agent_ready_to_text(p_limit integer, p_followups boolean, p_all boolean, p_now timestamptz default now())
returns jsonb language sql stable security definer set search_path = public as $$
  with d as (select (p_now at time zone 'America/Chicago')::date as day),
  handed as (
    select distinct on (p.lead_id, p.step) p.lead_id, p.step, p.body as laptop_text
      from public.planned_openers p
     where p.lane <> 'agent' and p.send_reason = 'handed to the sender agent' and p.send_status = 'withdrawn'
       and p.plan_date >= ((p_now at time zone 'America/Chicago')::date - 7)
     order by p.lead_id, p.step, p.plan_date desc),
  listed as (
    select t.lead_id, t.kind, t.step, t.phone, t.voice, t.tier, t.need_why, t.due_day, t.ord from public.text_day t, d
     where t.day = d.day
       -- written already: a text for this step to THIS phone (the owner's next number is step 1 again, on another phone)
       and not exists (select 1 from public.planned_openers po where po.lead_id = t.lead_id and po.step = t.step
                        and right(regexp_replace(po.phone, '\D', '', 'g'), 10) = t.phone
                        and po.send_status in ('planned', 'would_send', 'sending', 'sent', 'delivered'))),
  pool as (
    select p.lead_id, p.kind, p.step, p.phone, public.card_voice(p.lead_id) as voice, p.tier, p.need_why, p.due_day, p.ord::int as ord
      from public.text_pool(p_now) p
     where p.block is null and p.ord <= 300
       and not exists (select 1 from public.text_day t where t.day = (p_now at time zone 'America/Chicago')::date)),
  todo as (select * from listed union all select * from pool),
  shown as (
    select x.*, h.laptop_text, row_number() over (partition by x.kind order by x.ord) as rn from todo x
      left join handed h on h.lead_id = x.lead_id and h.step = x.step
     where x.kind <> 'followup' or p_followups)
  select jsonb_build_object(
    'new_cards', (select coalesce(jsonb_agg(public.agent_card(s.lead_id) || jsonb_build_object('next_step', 1, 'phone', s.phone, 'voice', s.voice,
                    'tier', s.tier, 'need', s.need_why, 'laptop_text', s.laptop_text, 'laptop_phone', s.phone,
                    'reasons_count', cardinality(l.reasons_to_sell), 'stacked_at', l.stacked_at, 'laptop_card', l.wpie_owner_id > 0) order by s.ord), '[]'::jsonb)
                    from shown s join public.leads l on l.id = s.lead_id where s.kind = 'first' and s.rn <= greatest(1, least(p_limit, 300))),
    'followups_due', (select coalesce(jsonb_agg(public.agent_card(s.lead_id) || jsonb_build_object('next_step', s.step, 'due_since', s.due_day,
                    'phone', s.phone, 'voice', s.voice, 'tier', s.tier, 'need', s.need_why, 'laptop_text', s.laptop_text, 'laptop_phone', s.phone,
                    'reasons_count', cardinality(l.reasons_to_sell), 'stacked_at', l.stacked_at) order by s.ord), '[]'::jsonb)
                    from shown s join public.leads l on l.id = s.lead_id where s.kind = 'followup' and s.rn <= greatest(1, least(p_limit, 300))),
    'next_numbers', (select coalesce(jsonb_agg(public.agent_card(s.lead_id) || jsonb_build_object('next_step', 1, 'phone', s.phone, 'voice', s.voice,
                    'why', 'the number we texted reached someone else; this is the owner''s next number',
                    'reasons_count', cardinality(l.reasons_to_sell)) order by s.ord), '[]'::jsonb)
                    from shown s join public.leads l on l.id = s.lead_id where s.kind = 'next_number' and s.rn <= greatest(1, least(p_limit, 300))),
    'followups_due_total', (select count(*) from todo where kind = 'followup'),
    'followups_due_by_step', (select coalesce(jsonb_object_agg(step, n), '{}'::jsonb) from (select step, count(*) n from todo where kind = 'followup' group by step) x),
    'the_day', jsonb_build_object(
       'day', (select day from d),
       'list_built', exists (select 1 from public.text_day t, d where t.day = d.day),
       'left_to_write', (select count(*) from todo),
       'left_by_kind', (select coalesce(jsonb_object_agg(k, n), '{}'::jsonb) from (
           select case when kind = 'followup' then 'step_' || step else kind end as k, count(*) n from todo group by 1) x),
       'how', 'This is today''s list, built by the server from the whole store, real need first. Write each text to the phone given, signed with the name in voice. One name per thread; a first text carries the STOP line, a follow-up does not.'))
$$;

create or replace function public.text_day_backstop(p_now timestamptz default now(), p_limit integer default 150) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  c    public.campaign_control;
  d    date := (p_now at time zone 'America/Chicago')::date;
  r    record;
  body text;
  nm   text;
  res  jsonb;
  ok   integer := 0;
  no   jsonb := '{}'::jsonb;
  why  text;
begin
  select * into c from public.campaign_control where id = 1;
  if not coalesce(c.day_backstop, false) then return jsonb_build_object('ran', false, 'why', 'the backstop is off'); end if;
  if (p_now at time zone 'America/Chicago')::time < c.day_backstop_after then return jsonb_build_object('ran', false, 'why', 'before the backstop hour'); end if;
  for r in
    select t.*, l.property_address, l.owner_name,
           (select ct.person_name from public.contacts ct where ct.lead_id = t.lead_id and ct.value_normalized = t.phone limit 1) as person_name
      from public.text_day t join public.leads l on l.id = t.lead_id
     where t.day = d and t.step <= 3 and coalesce(btrim(l.property_address), '') <> ''
       and not exists (select 1 from public.planned_openers po where po.lead_id = t.lead_id and po.step = t.step
                        and right(regexp_replace(po.phone, '\D', '', 'g'), 10) = t.phone
                        and po.send_status in ('planned', 'would_send', 'sending', 'sent', 'delivered', 'undelivered', 'failed', 'uncertain'))
     order by t.ord limit greatest(1, least(p_limit, 400))
  loop
    nm := public.text_first_name(coalesce(r.person_name, r.owner_name));
    body := case
      when r.step = 1 and nm = 'there' then 'Hi there, this is ' || r.voice || '. Are you the right person to ask about ' || btrim(r.property_address) || '? Reply STOP to opt out.'
      when r.step = 1 then 'Hi ' || nm || ', this is ' || r.voice || '. Are you the current owner of ' || btrim(r.property_address) || '? Reply STOP to opt out.'
      when r.step = 2 then 'Hi ' || nm || ', ' || r.voice || ' again about ' || btrim(r.property_address) || '. Still the owner there? Just checking I have the right place.'
      else 'Hi ' || nm || ', ' || r.voice || ' again, following up on ' || btrim(r.property_address) || '. Is this still the best number to reach you at?' end;
    res := public.agent_queue_text(r.lead_id, r.phone, body, r.step, null, 'the day', p_now,
                                   case r.step when 1 then 'V4' when 2 then 'G' else 'F3' end, 'day_backstop', null, null);
    if res ->> 'status' = 'queued' then ok := ok + 1;
    else
      why := left(coalesce(res ->> 'reason', 'refused'), 60);
      no := no || jsonb_build_object(why, coalesce((no ->> why)::int, 0) + 1);
    end if;
  end loop;
  insert into public.text_day_runs (day, at, kind, summary) values (d, p_now, 'backstop', jsonb_build_object('queued', ok, 'refused', no));
  return jsonb_build_object('ran', true, 'queued', ok, 'refused', no);
end $$;

-- The clock. pg_cron calls this every 15 minutes; it decides what the hour calls for.
--   7:00 to 18:30 Central, Monday to Saturday: build, then top up once an hour
--   noon: if most of the list is still unwritten, say so on the desk (once)
--   the backstop, when it is on
--   19:15: the day's report on the desk (once), flagged when the new people run out inside five days
create or replace function public.text_day_tick(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  c    public.campaign_control;
  d    date := (p_now at time zone 'America/Chicago')::date;
  t    time := (p_now at time zone 'America/Chicago')::time;
  out  jsonb := '{}'::jsonb;
  r    jsonb;
  low  boolean;
  txt  text;
begin
  select * into c from public.campaign_control where id = 1;
  if coalesce(c.no_sundays, true) and extract(isodow from d) = 7 then return jsonb_build_object('day', d, 'why', 'Sunday'); end if;
  if t >= time '07:00' and t < time '18:30'
     and (c.day_last_build_at is null or (c.day_last_build_at at time zone 'America/Chicago')::date < d or c.day_last_build_at < p_now - interval '55 minutes') then
    out := out || jsonb_build_object('build', public.text_day_build(p_now));
  end if;
  if t >= time '12:00' and t < time '18:30' and c.day_noon_checked is distinct from d then
    r := public.text_day_report(p_now);
    update public.campaign_control set day_noon_checked = d where id = 1;
    if (r ->> 'listed')::int >= 20 and (r ->> 'not_written')::int * 2 > (r ->> 'listed')::int then
      perform public.desk_post('desk', 'all', 'note', 'The day ' || d || ': at noon ' || (r ->> 'not_written') || ' of ' || (r ->> 'listed') || ' texts are not written',
        'The day''s list (text_day) has ' || (r ->> 'listed') || ' texts on it and ' || (r ->> 'not_written') || ' have not been written and queued yet. '
        || 'The list is in ready_to_text, need first. ' || case when coalesce(c.day_backstop, false) then 'The backstop is on and will write the rest in the settled wording.'
           else 'The backstop is off, so nothing goes out for those rows unless they are queued.' end);
      out := out || jsonb_build_object('noon', 'posted');
    end if;
  end if;
  if coalesce(c.day_backstop, false) and t >= c.day_backstop_after and t < time '18:30' then
    out := out || jsonb_build_object('backstop', public.text_day_backstop(p_now));
  end if;
  if t >= time '19:15' and c.day_reported is distinct from d then
    r := public.text_day_report(p_now);
    update public.campaign_control set day_reported = d where id = 1;
    insert into public.text_day_runs (day, at, kind, summary) values (d, p_now, 'report', r);
    low := (r ->> 'days_of_new_people')::numeric < 5;
    txt := 'Listed ' || (r ->> 'listed') || ' (cap ' || coalesce(r ->> 'cap', '?') || ', floor of new people ' || (r ->> 'floor') || '); not written ' || (r ->> 'not_written')
        || '; off the list ' || (r ->> 'off_list_today') || E'.\nBy kind: ' || (r -> 'by_kind')::text
        || E'\nReplies today ' || (r ->> 'replies_today') || ', STOPs ' || (r ->> 'stops_today') || ', hot ' || (r ->> 'hot_today')
        || E'.\nNew people still ready: ' || (r ->> 'first_ready') || ' by tier ' || (r -> 'first_ready_by_tier')::text || ', about ' || (r ->> 'days_of_new_people') || ' days at the floor.'
        || E'\nFollow-ups ready by step: ' || (r -> 'followups_ready_by_step')::text || '; next numbers ' || (r ->> 'next_numbers_ready')
        || E'.\nWhy the rest of the first-text store is not ready: ' || (r -> 'first_blocked')::text
        || E'\nFollow-ups held back: ' || (r -> 'followups_blocked')::text
        || E'\nRecord verdicts as of ' || coalesce(r ->> 'verdicts_as_of', 'never') || '.';
    perform public.desk_post('desk', 'all', 'report',
      'The day ' || d || case when low then ': NEW PEOPLE RUN OUT IN ' || (r ->> 'days_of_new_people') || ' DAYS' else ': report' end, left(txt, 11000));
    out := out || jsonb_build_object('report', 'posted', 'low_supply', low);
  end if;
  return out;
end $$;

-- the team's read of the day (the app, later a page): the same numbers the desk gets
create or replace function public.the_day() returns jsonb language sql stable security definer set search_path = public as $$
  select case when public.is_team() then public.text_day_report(now()) else jsonb_build_object('ok', false, 'reason', 'not on the team') end
$$;

revoke all on function public.agent_ready_to_text(integer, boolean, boolean, timestamptz), public.text_day_backstop(timestamptz, integer) from public, anon, authenticated;
grant execute on function public.agent_ready_to_text(integer, boolean, boolean, timestamptz), public.text_day_backstop(timestamptz, integer) to service_role;
