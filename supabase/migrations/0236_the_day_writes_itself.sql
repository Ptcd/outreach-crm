-- 0236: the day writes itself, and drips.
--
-- Colin 2026-11-14: "can you start having it drip out texts", then "Yes, build it" to the system writing and dripping
-- the day's texts by itself every morning. Until now the list was built at 7 AM and nothing went until the sender
-- agent happened to start (3:35 PM the day before), then all of it in a burst.
--
-- The backstop of 0219 already wrote unwritten rows in the settled wording; it was off, wrote in one go, and left out
-- the owner's next number and text 4. It is now the day's writer:
--   * it spreads what is left evenly from the start of the sending window to 50 minutes before its end, and each
--     tick writes only the next 20 minutes' worth, so every text is checked against the records shortly before it goes;
--   * it writes the owner's next number (a first text: that number has never had one from us) and text 4, in the
--     wording the sender agent used on 2026-11-13; a card with a sale ahead gets the sale text (0234); someone other
--     than the owner on the phone is asked whether they are the right person;
--   * a row the queue refuses is marked (text_day.server_note) and left for a person, not retried every tick;
--   * the sender agent is handed only what the server leaves: text 5, a first text to someone texted before, and the
--     rows it could not write.
-- Turning it on stays a setting (campaign_control.day_backstop, day_backstop_after).

alter table public.text_day add column if not exists server_note text;

create or replace function public.text_day_backstop(p_now timestamp with time zone default now(), p_limit integer default 150)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare
  c        public.campaign_control;
  d        date := (p_now at time zone 'America/Chicago')::date;
  r        record;
  body     text;
  nm       text;
  variant  text;
  tmpl     text;
  res      jsonb;
  ok       integer := 0;
  no       jsonb := '{}'::jsonb;
  why      text;
  ws       timestamptz;
  stop_at  timestamptz;
  start_at timestamptz;
  last_at  timestamptz;
  left_n   integer;
  gap      integer;
  k        integer;
begin
  select * into c from public.campaign_control where id = 1;
  if not coalesce(c.day_backstop, false) then return jsonb_build_object('ran', false, 'why', 'the backstop is off'); end if;
  if coalesce(c.paused, false) then return jsonb_build_object('ran', false, 'why', 'texting is paused'); end if;
  if (p_now at time zone 'America/Chicago')::time < c.day_backstop_after then return jsonb_build_object('ran', false, 'why', 'before the backstop hour'); end if;
  ws := (d + c.window_start) at time zone c.timezone;
  stop_at := (d + c.window_end) at time zone c.timezone - interval '50 minutes';

  drop table if exists _day_rows;
  create temp table _day_rows on commit drop as
    select t.lead_id, t.step, t.kind, t.phone, t.voice, t.ord, btrim(l.property_address) as address, l.owner_name, coalesce(l.owner_type, '') as owner_type,
           (select ct.person_name from public.contacts ct where ct.lead_id = t.lead_id and ct.value_normalized = t.phone limit 1) as person_name
      from public.text_day t join public.leads l on l.id = t.lead_id
     -- text 5 has no settled wording, and a first text to someone we have texted before (another card, another
     -- number) takes no intro: those rows wait for a person or the sender agent
     where t.day = d and coalesce(btrim(l.property_address), '') <> ''
       and t.step <= 4 and t.server_note is null
       and not (t.step = 1 and t.kind <> 'next_number' and public.card_texted_before(t.lead_id))
       and not exists (select 1 from public.planned_openers po where po.lead_id = t.lead_id and po.step = t.step
                        and right(regexp_replace(po.phone, '\D', '', 'g'), 10) = t.phone
                        and po.send_status in ('planned', 'would_send', 'sending', 'sent', 'delivered', 'undelivered', 'failed', 'uncertain'));
  select count(*) into left_n from _day_rows;
  if left_n = 0 then return jsonb_build_object('ran', true, 'queued', 0, 'left', 0); end if;

  -- the drip: what is left, spread evenly over what is left of the window, after the last text the server itself has
  -- waiting (a text someone else queued for later in the day does not hold the drip up)
  select max(po.scheduled_at) into last_at from public.planned_openers po
   where po.plan_date = d and po.lane = 'agent' and po.send_status in ('planned', 'would_send') and po.decided_by_name = 'Muse (the day)';
  start_at := greatest(p_now + interval '30 seconds', ws, coalesce(last_at + interval '20 seconds', ws));
  if start_at >= stop_at then return jsonb_build_object('ran', false, 'why', 'the sending window is closing', 'left', left_n); end if;
  gap := least(180, greatest(20, floor(extract(epoch from (stop_at - start_at)) / left_n)))::int;
  k := case when start_at > p_now + interval '20 minutes' then 0
            else least(left_n, greatest(1, p_limit), floor(extract(epoch from (p_now + interval '20 minutes' - start_at)) / gap)::int + 1) end;

  for r in select * from _day_rows order by ord limit k loop
    nm := public.text_first_name(coalesce(r.person_name, r.owner_name));
    variant := case r.step when 1 then 'V4' when 2 then 'G' when 3 then 'F3' else 'F4' end;
    tmpl := 'day_backstop';
    body := case when r.step = 1 then public.sale_first_text(r.lead_id, r.voice, d) end;
    if body is not null then
      variant := 'S'; tmpl := 'sale_date';
    else
      body := case
        when r.step = 1 and (nm = 'there' or nm <> public.text_first_name(r.owner_name) or r.owner_type in ('llc', 'trust', 'estate', 'corporation', 'entity'))
          then 'Hi ' || nm || ', this is ' || r.voice || '. Are you the right person to ask about ' || r.address || '? Reply STOP to opt out.'
        when r.step = 1 then 'Hi ' || nm || ', this is ' || r.voice || '. Are you the current owner of ' || r.address || '? Reply STOP to opt out.'
        when r.step = 2 then 'Hi ' || nm || ', ' || r.voice || ' again about ' || r.address || '. Still the owner there? Just checking I have the right place.'
        when r.step = 3 then 'Hi ' || nm || ', ' || r.voice || ' again, following up on ' || r.address || '. Is this still the best number to reach you at?'
        else 'Hi ' || nm || ', ' || r.voice || ' again. Just checking in about ' || r.address || '. Is this still a good number for you?' end;
    end if;
    res := public.agent_queue_text(r.lead_id, r.phone, body, r.step, start_at + make_interval(secs => gap * ok), 'the day', p_now, variant, tmpl, null, null);
    if res ->> 'status' = 'queued' then ok := ok + 1;
    else
      why := left(coalesce(res ->> 'reason', 'refused'), 200);
      update public.text_day set server_note = why where day = d and lead_id = r.lead_id and step = r.step;
      why := left(why, 60);
      no := no || jsonb_build_object(why, coalesce((no ->> why)::int, 0) + 1);
    end if;
  end loop;
  if ok > 0 or no <> '{}'::jsonb then
    insert into public.text_day_runs (day, at, kind, summary)
    values (d, p_now, 'backstop', jsonb_build_object('queued', ok, 'refused', no, 'left', left_n - ok, 'seconds_apart', gap));
  end if;
  return jsonb_build_object('ran', true, 'queued', ok, 'refused', no, 'left', left_n - ok, 'seconds_apart', gap);
end $function$;

CREATE OR REPLACE FUNCTION public.agent_ready_to_text(p_limit integer, p_followups boolean, p_all boolean, p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
       -- what the server writes itself while the backstop is on (0236) is not handed to the agent: it gets text 5, a
       -- first text to someone texted before, and the rows the server could not write
       and not (coalesce((select cc.day_backstop from public.campaign_control cc where cc.id = 1), false)
                and t.step <= 4 and t.server_note is null
                and not (t.step = 1 and t.kind <> 'next_number' and public.card_texted_before(t.lead_id)))
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
           'sale_text', public.sale_first_text(s.lead_id, s.voice, (p_now at time zone 'America/Chicago')::date),
                    'reasons_count', cardinality(l.reasons_to_sell), 'stacked_at', l.stacked_at, 'laptop_card', l.wpie_owner_id > 0) order by s.ord), '[]'::jsonb)
                    from shown s join public.leads l on l.id = s.lead_id where s.kind = 'first' and s.rn <= greatest(1, least(p_limit, 300))),
    'followups_due', (select coalesce(jsonb_agg(public.agent_card(s.lead_id) || jsonb_build_object('next_step', s.step, 'due_since', s.due_day,
                    'phone', s.phone, 'voice', s.voice, 'tier', s.tier, 'need', s.need_why, 'laptop_text', s.laptop_text, 'laptop_phone', s.phone,
           'sale_text', public.sale_first_text(s.lead_id, s.voice, (p_now at time zone 'America/Chicago')::date),
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
       'how', 'This is today''s list, built by the server from the whole store, real need first. Write each text to the phone given, signed with the name in voice. One name per thread; a first text carries the STOP line, a follow-up does not. When a card carries sale_text, send exactly that text: it is the first text for an owner with a sheriff sale ahead (Colin 2026-11-14). While the server is writing the day itself (the backstop is on) this list holds only what it leaves for you: text 5, a first text to someone texted before, and rows it could not write.'))
$function$;

CREATE OR REPLACE FUNCTION public.text_day_tick(p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  -- the noon check is for a day people write; a day the server drips is half unwritten at noon by design (0236)
  if t >= time '12:00' and t < time '18:30' and c.day_noon_checked is distinct from d and not coalesce(c.day_backstop, false) then
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
end $function$;
