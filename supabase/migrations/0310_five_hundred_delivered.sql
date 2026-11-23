-- 0310: 500 delivered a day (Colin 2026-11-23: "keep texting till we get to 500 texts out per day, not including the
-- ones that bounced ... if we send out 500 texts in a day and 82 bounce as undeliverable or like as numbers not in
-- service, we just send 82 more"). The day's cap is daily_cap plus every text that bounced today on a dead number
-- (30003 unreachable, 30005 not in service, 30006 cannot take texts), never more than day_send_ceiling in all. A text
-- the carrier filtered (30007) is not refilled: that is the carriers pushing back, and more volume makes it worse.
-- The list is rebuilt within the quarter hour after a dead number comes back, so the refill goes out the same day;
-- the drip spreads what is left over what is left of the window. The bounced card's own next number still goes the
-- next day (one text a card a day). The laptop pushes daily_cap 500 (cap_schedule.json "default").

alter table public.campaign_control add column if not exists day_send_ceiling integer not null default 700;
alter table public.campaign_control add column if not exists day_refill_codes text[] not null default array['30003', '30005', '30006'];
comment on column public.campaign_control.day_send_ceiling is 'The most texts a day may send with the dead-number refill (0310).';
comment on column public.campaign_control.day_refill_codes is 'Carrier codes that give a day its slot back (0310): dead numbers only.';

create or replace function public.day_dead_bounces(p_day date)
 returns integer language sql stable security definer set search_path to 'public'
as $function$
  select count(*)::int from public.planned_openers po, public.campaign_control c
   where c.id = 1 and po.plan_date = p_day and po.send_status in ('undelivered', 'failed')
     and po.error_code = any (coalesce(c.day_refill_codes, array['30003', '30005', '30006']))
$function$;

create or replace function public.day_cap_now(p_now timestamp with time zone default now())
 returns integer language sql stable security definer set search_path to 'public'
as $function$
  select least(coalesce(c.day_send_ceiling, 700), coalesce(c.daily_cap, 400) + public.day_dead_bounces((p_now at time zone c.timezone)::date))
    from public.campaign_control c where c.id = 1
$function$;

CREATE OR REPLACE FUNCTION public.claim_next_opener(p_dry_run boolean DEFAULT true, p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c          public.campaign_control;
  o          public.planned_openers;
  l          public.leads;
  local_ts   timestamp;
  today      date;
  mode       text := case when p_dry_run then 'dry' else 'live' end;
  counted    text[];
  used       integer;
  last_hour  integer;
  pace       integer;
  v_phone10    text;
  owner_phones text[];
  why        text;
  retry      boolean := false;
  w          text;
begin
  perform pg_advisory_xact_lock(hashtext('wpie.claim_next_opener'));
  select * into c from public.campaign_control where id = 1;
  if not found then
    return jsonb_build_object('outcome', 'idle', 'reason', 'no_control_row');
  end if;
  if not p_dry_run and not c.sending_enabled then
    return jsonb_build_object('outcome', 'idle', 'reason', 'switch_off');
  end if;
  if c.paused or c.laptop_paused then
    return jsonb_build_object('outcome', 'idle', 'reason', 'paused',
                              'detail', coalesce(c.pause_reason, c.laptop_pause_reason));
  end if;
  local_ts := p_now at time zone c.timezone;
  today := local_ts::date;
  if c.no_sundays and extract(isodow from local_ts) = 7 then
    return jsonb_build_object('outcome', 'idle', 'reason', 'sunday');
  end if;
  if local_ts::time < c.window_start or local_ts::time >= c.window_end then
    return jsonb_build_object('outcome', 'idle', 'reason', 'outside_window');
  end if;

  -- Daily cap: one cap across app sends, laptop campaign sends and the reply agent's own openers.
  counted := case when p_dry_run then array['would_send'] else public.opener_live_statuses() end;
  select count(distinct coalesce(x.lead_id::text, x.k)) into used from (
    select p.lead_id, p.wpie_owner_id::text || ':' || p.attempt as k
      from public.planned_openers p
     where p.send_status = any(counted) and p.claim_mode = mode
       and (p.claimed_at at time zone c.timezone)::date = today
    union all
    select m.lead_id, m.id::text
      from public.messages m
     where not p_dry_run and m.direction = 'out' and m.is_opener and m.provider_sid is not null
       and (m.sent_at at time zone c.timezone)::date = today
  ) x;
  if not p_dry_run and c.external_openers_date = today then
    used := used + c.external_openers;
  end if;
  -- 0310: the day's cap counts what got through: each dead-number bounce today is one more, up to the ceiling
  if used >= public.day_cap_now(p_now) then
    return jsonb_build_object('outcome', 'idle', 'reason', 'daily_cap_reached', 'used', used, 'cap', public.day_cap_now(p_now));
  end if;

  -- Follow-ups' own brake (0018): re-checked before picking, so a trip stops texts 2-3 right away.
  if not c.followups_paused then
    perform public.check_followup_kill(p_now);
    select * into c from public.campaign_control where id = 1;
  end if;

  -- Pick the earliest due approved entry whose recipient window is open now. Follow-ups (texts 2
  -- and 3) go first: a due follow-up loses value faster than a new opener, so under the cap
  -- the new openers wait.
  select * into o from public.planned_openers p
   where p.plan_date = today
     and (p.send_status = 'planned' or (not p_dry_run and p.send_status = 'would_send'))
     and (p_dry_run or p.decision = 'approved')
     and p.decision <> 'skipped'
     and coalesce(p.scheduled_at, p_now) <= p_now
     and (p.window_start_utc is null or (p.window_start_utc <= p_now and p_now < p.window_end_utc))
     and (p.step = 1 or not c.followups_paused)
   order by (p.step > 1) desc, p.scheduled_at nulls last, p.id
   limit 1
   for update skip locked;
  if not found then
    return jsonb_build_object('outcome', 'idle', 'reason', 'nothing_due', 'used', used);
  end if;

  -- Hourly pace (the plan's per_hour; the cap when the plan has none).
  pace := coalesce(nullif(o.per_hour, 0), c.daily_cap);
  select count(*) into last_hour from public.planned_openers p
   where p.send_status = any(counted) and p.claim_mode = mode
     and p.claimed_at > p_now - interval '1 hour' and p.claimed_at <= p_now;
  if last_hour >= pace then
    return jsonb_build_object('outcome', 'idle', 'reason', 'hourly_pace_reached', 'last_hour', last_hour);
  end if;

  -- ---------------------------------------------------------------- per-entry checks
  v_phone10 := right(regexp_replace(coalesce(o.phone, ''), '\D', '', 'g'), 10);
  select * into l from public.leads where id = o.lead_id;
  select coalesce(array_agg(distinct ct.value_normalized), '{}') into owner_phones
    from public.contacts ct join public.leads ll on ll.id = ct.lead_id
   where ll.wpie_owner_id = o.wpie_owner_id and ct.kind = 'phone' and ct.value_normalized is not null;
  owner_phones := array_append(owner_phones, v_phone10);
  -- the next phone on the card (0079): a first text to another phone when every earlier first text never arrived
  retry := o.step = 1 and o.attempt between 2 and 9 and public.next_phone_problem(o.lead_id, v_phone10) is null;

  if o.window_start_utc is null or o.window_end_utc is null then
    why := 'no_recipient_window';
  elsif o.body_sha256 is null or o.body_sha256 <> encode(sha256(convert_to(o.body, 'UTF8')), 'hex') then
    why := 'body_changed_since_plan';
  elsif o.phone is null or o.phone !~ '^\+1[2-9][0-9]{2}[2-9][0-9]{6}$' then
    why := 'phone_invalid';
  elsif o.lead_id is null or l.id is null then
    why := 'no_lead';
  elsif o.step = 1 and not retry and l.stage not in ('postcard_mailed', 'opener_queued') then
    why := 'lead_stage_' || l.stage::text;
  elsif o.step > 1 and l.stage <> 'opener_sent' then
    why := 'lead_stage_' || l.stage::text;
  elsif exists (select 1 from public.suppressed_phones s where s.phone10 = v_phone10) then
    why := 'phone_suppressed';
  elsif exists (select 1 from public.suppressed_phones s where s.phone10 = any(owner_phones))
     or exists (select 1 from public.contacts ct where ct.value_normalized = any(owner_phones) and ct.suppressed) then
    why := 'owner_opted_out_on_another_phone';
  elsif not retry and (exists (select 1 from public.messages m where m.lead_id = o.lead_id and m.direction = 'in' and m.channel = 'sms')
     or exists (select 1 from public.twilio_inbound t where t.from10 = any(owner_phones))) then
    why := 'owner_replied';
  elsif exists (select 1 from public.contacts ct where ct.value_normalized = v_phone10
                  and (ct.dnc_vendor or ct.dnc_scrub = 'dnc' or ct.dnc_app)) then
    why := 'phone_dnc_positive';
  elsif exists (select 1 from public.contacts ct where ct.value_normalized = v_phone10 and ct.lead_id = o.lead_id and ct.status = 'bad') then
    why := 'phone_marked_bad';
  elsif public.phone_person_block(v_phone10) is not null then
    why := 'person_do_not_contact';
  -- a number on several cards is fine when it is one person's (0083); two different people on two cards is not
  elsif (select count(distinct ct.lead_id) from public.contacts ct where ct.value_normalized = v_phone10) > 1
    and (select count(distinct coalesce(ct.person_id::text, ct.lead_id::text)) from public.contacts ct where ct.value_normalized = v_phone10) > 1
    -- nor when every card carrying the number has the same owner name (0235): one owner, two houses. The number
    -- still gets one first text only (owner_already_texted, below), and a STOP on it stops every card.
    and (select count(distinct upper(regexp_replace(coalesce(ll.owner_name, ''), '[^A-Za-z0-9]', '', 'g')))
           from public.contacts ct join public.leads ll on ll.id = ct.lead_id where ct.value_normalized = v_phone10) > 1 then
    why := 'phone_shared';
  elsif c.dnc_policy = 'require_scrub' and (coalesce(o.dnc_state, '') <> 'screened'
        or exists (select 1 from public.contacts ct where ct.value_normalized = v_phone10 and ct.dnc_scrub <> 'clear')) then
    why := 'dnc_unscreened_under_require_scrub';
  elsif c.dnc_policy = 'require_scrub' and (c.scrub_date is null or today - c.scrub_date > 31) then
    why := 'dnc_scrub_older_than_31_days';
  elsif o.step = 1 and not retry and (exists (select 1 from public.planned_openers p
                 where p.id <> o.id and (p.wpie_owner_id = o.wpie_owner_id or p.phone = o.phone)
                   and p.send_status = any(public.opener_live_statuses()))
     or exists (select 1 from public.messages m
                 where m.direction = 'out' and m.is_opener and m.provider_sid is not null
                   and (m.lead_id = o.lead_id or m.to_number = o.phone))) then
    why := 'owner_already_texted';
  -- Texts 2 and 3 (docs/FOLLOWUP_CADENCE.md section 2), in place of "already texted":
  elsif o.step > 1 and not (
        exists (select 1 from public.planned_openers p where p.wpie_owner_id = o.wpie_owner_id and p.attempt = o.attempt / 10
                  and p.phone = o.phone and p.send_status = 'delivered')
     or exists (select 1 from public.messages m where m.lead_id = o.lead_id and m.is_opener and m.direction = 'out'
                  and m.to_number = o.phone and m.status = 'delivered')) then
    why := 'opener_not_delivered';
  elsif o.step = 3 and not exists (select 1 from public.planned_openers p where p.wpie_owner_id = o.wpie_owner_id
                  and p.attempt = (o.attempt / 10) * 10 + 2 and p.phone = o.phone and p.send_status = 'delivered') then
    why := 'text_2_not_delivered';
  elsif o.step > 1 and exists (select 1 from public.planned_openers p where p.id <> o.id and p.wpie_owner_id = o.wpie_owner_id
                  and p.attempt = o.attempt and p.send_status = any(public.opener_live_statuses())) then
    why := 'step_already_sent';
  elsif o.step > 1 and exists (select 1 from public.twilio_inbound t where t.from10 = v_phone10) then
    why := 'owner_replied';
  elsif o.step > 1 and exists (select 1 from public.contacts ct where ct.value_normalized = v_phone10 and ct.status::text in ('bad', 'dead')) then
    why := 'phone_marked_bad';
  elsif o.step > 1 and (select count(*) from (
          select p.id::text from public.planned_openers p where p.wpie_owner_id = o.wpie_owner_id and p.id <> o.id
             and p.send_status = any(public.opener_live_statuses()) and p.send_status not in ('undelivered', 'failed')
          union
          select coalesce(m.provider_sid, m.id::text) from public.messages m where m.lead_id = o.lead_id
             and m.direction = 'out' and m.channel = 'sms' and m.provider_sid is not null
             and not exists (select 1 from public.planned_openers p2 where p2.provider_sid = m.provider_sid)) n) >= 5 then
    why := 'all_texts_sent';
  elsif o.step > 1 and (select greatest(
          (select max(coalesce(p.sent_at, p.claimed_at)) from public.planned_openers p where p.phone = o.phone and p.id <> o.id
              and p.send_status = any(public.opener_live_statuses())),
          (select max(m.sent_at) from public.messages m where m.to_number = o.phone and m.direction = 'out' and m.channel = 'sms')))
        > p_now - interval '36 hours' then
    why := 'too_soon';
  elsif exists (select 1 from public.thread_owners th where th.phone10 = v_phone10) then
    why := 'human_owned';
  elsif coalesce(o.step, 1) = 1 and position('STOP' in o.body) = 0 then
    why := 'template:no_stop_line';
  else
    foreach w in array c.banned_words loop
      if w <> '' and position(lower(w) in lower(o.body)) > 0 then
        why := 'template:names_business';
      end if;
    end loop;
  end if;

  if why is not null then
    update public.planned_openers set send_status = 'skipped', send_reason = why, send_updated_at = p_now where id = o.id;
    insert into public.opener_send_events (opener_id, plan_date, wpie_owner_id, attempt, event, reason, actor, at)
    values (o.id, o.plan_date, o.wpie_owner_id, o.attempt, 'skipped', why, 'server', p_now);
    return jsonb_build_object('outcome', 'skipped', 'reason', why,
                              'opener', jsonb_build_object('id', o.id, 'wpie_owner_id', o.wpie_owner_id, 'attempt', o.attempt, 'step', o.step));
  end if;

  update public.planned_openers
     set send_status = case when p_dry_run then 'would_send' else 'sending' end,
         claim_mode = mode, claimed_at = p_now, send_reason = null, send_updated_at = p_now
   where id = o.id;
  insert into public.opener_send_events (opener_id, plan_date, wpie_owner_id, attempt, event, actor, at)
  values (o.id, o.plan_date, o.wpie_owner_id, o.attempt, case when p_dry_run then 'would_send' else 'sending' end, 'server', p_now);
  return jsonb_build_object('outcome', case when p_dry_run then 'would_send' else 'send' end,
                            'opener', jsonb_build_object('id', o.id, 'phone', o.phone, 'body', o.body,
                                                         'wpie_owner_id', o.wpie_owner_id, 'attempt', o.attempt,
                                                         'step', o.step, 'plan_date', o.plan_date));
end $function$;

CREATE OR REPLACE FUNCTION public.text_day_build(p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c       public.campaign_control;
  d       date := (p_now at time zone 'America/Chicago')::date;
  cap     integer;
  room    integer;
  n       integer;
  nxt     integer;
  added   jsonb := '{}'::jsonb;
  ph      record;
  best    boolean;
  left_out integer;
begin
  select * into c from public.campaign_control where id = 1;
  if coalesce(c.no_sundays, true) and extract(isodow from d) = 7 then
    return jsonb_build_object('day', d, 'built', false, 'why', 'Sunday: no texts');
  end if;
  -- a text carried over to a day its card's caller is off does not go (0238)
  perform public.caller_off_sweep(d);
  cap := public.day_cap_now(p_now);   -- 0310: plus today's dead-number bounces, up to the ceiling
  best := c.day_best_first_day is not distinct from d;   -- 0262: a day the strongest cards go first
  drop table if exists _day_pool;
  create temp table _day_pool on commit drop as select * from public.text_pool(p_now) where block is null;

  delete from public.text_day t
   where t.day = d
     and not exists (select 1 from public.planned_openers po where po.lead_id = t.lead_id and po.step = t.step and po.plan_date = d and po.lane = 'agent'
                        and po.send_status not in ('withdrawn', 'skipped'))   -- a withdrawn text does not keep its row on the list (0237), nor one the send check refused (0257)
     and (not exists (select 1 from _day_pool p where p.lead_id = t.lead_id and p.step = t.step)
          or public.text_name_is_off(t.voice, d));   -- 0273: a row waiting in an off caller's name leaves too
  get diagnostics left_out = row_count;

  -- what the day has already spent: the list, and any text the agent queued for today that is not on it
  select count(*) into n from public.text_day t where t.day = d;
  room := cap - n - (select count(*) from public.planned_openers po
                      where po.plan_date = d and po.lane = 'agent' and po.send_status in ('planned', 'would_send', 'sending', 'sent', 'delivered', 'undelivered', 'failed', 'uncertain')
                        and not exists (select 1 from public.text_day t where t.day = d and t.lead_id = po.lead_id and t.step = po.step));
  select coalesce(max(t.ord), 0) into nxt from public.text_day t where t.day = d;

  for ph in
    select * from (values
      -- 0262: on a best-first day every tier A, B or C text that is ready goes on the list before anything weaker
      (0, 'best_first', 'first', array[1], case when best then 100000 else 0 end, array['A', 'B', 'C']),
      (1, 'best_followups_2_3', 'followup', array[2, 3], case when best then 100000 else 0 end, array['A', 'B', 'C']),
      (2, 'best_next_numbers', 'next_number', array[1], case when best then 100000 else 0 end, array['A', 'B', 'C']),
      (3, 'best_followups_4_5', 'followup', array[4, 5], case when best then 100000 else 0 end, array['A', 'B', 'C']),
      (4, 'first_floor', 'first', array[1], greatest(0, coalesce(c.day_first_floor, 140) - (select count(*) from public.text_day t where t.day = d and t.kind = 'first')::int), null::text[]),
      (5, 'followups_2_3', 'followup', array[2, 3], 100000, null::text[]),
      (6, 'next_numbers', 'next_number', array[1], 100000, null::text[]),
      (7, 'followups_4_5', 'followup', array[4, 5], 100000, null::text[]),
      (8, 'more_first', 'first', array[1], 100000, null::text[])) as v(n, name, kind, steps, quota, tiers)
     order by n
  loop
    exit when room <= 0;
    continue when ph.quota <= 0;
    with pick as (
      select p.*, row_number() over (order by case when ph.tiers is null then 9 else case p.tier when 'A' then 1 when 'B' then 2 else 3 end end, p.step, p.ord) as rn from _day_pool p
       where p.kind = ph.kind and p.step = any (ph.steps)
         and (ph.tiers is null or p.tier = any (ph.tiers))
         and not exists (select 1 from public.text_day t where t.day = d and t.lead_id = p.lead_id)
       order by case when ph.tiers is null then 9 else case p.tier when 'A' then 1 when 'B' then 2 else 3 end end, p.step, p.ord limit least(room, ph.quota))
    insert into public.text_day (day, lead_id, step, kind, phone, voice, tier, need_why, due_day, ord, listed_at)
    select d, k.lead_id, k.step, k.kind, k.phone, public.card_voice(k.lead_id), k.tier, k.need_why, k.due_day, nxt + k.rn, p_now from pick k
     where not public.text_name_is_off(public.card_voice(k.lead_id), d)   -- 0273
    on conflict (day, lead_id, step) do nothing;
    get diagnostics n = row_count;
    room := room - n;
    nxt := nxt + n;
    added := added || jsonb_build_object(ph.name, n);
  end loop;

  update public.campaign_control set day_last_build_at = p_now where id = 1;
  insert into public.text_day_runs (day, at, kind, summary)
  values (d, p_now, 'build', jsonb_build_object('added', added, 'left_the_list', left_out, 'room_left', greatest(room, 0), 'cap', cap,
          'dead_bounces_today', public.day_dead_bounces(d),
          'listed', (select count(*) from public.text_day t where t.day = d)));
  return jsonb_build_object('day', d, 'built', true, 'cap', cap, 'added', added, 'left_the_list', left_out,
    'listed', (select count(*) from public.text_day t where t.day = d), 'room_left', greatest(room, 0));
end $function$;

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
  -- a Sunday is opened one day at a time (0240): the rule is off on the Sunday that was opened and on every other day
  if coalesce(c.sundays_closed, false) and coalesce(c.no_sundays, true) is distinct from (c.sunday_open_day is distinct from d) then
    update public.campaign_control set no_sundays = (sunday_open_day is distinct from d) where id = 1;
    select * into c from public.campaign_control where id = 1;
  end if;
  -- 0277: with the standing rule gone, Sunday is never shut, whatever an older setting says
  if not coalesce(c.sundays_closed, false) and coalesce(c.no_sundays, true) then
    update public.campaign_control set no_sundays = false where id = 1;
    select * into c from public.campaign_control where id = 1;
  end if;
  if coalesce(c.no_sundays, true) and extract(isodow from d) = 7 then return jsonb_build_object('day', d, 'why', 'Sunday'); end if;
  if t >= time '07:00' and t < time '18:30'
     and (c.day_last_build_at is null or (c.day_last_build_at at time zone 'America/Chicago')::date < d or c.day_last_build_at < p_now - interval '55 minutes'
          -- 0310: dead numbers came back since the last build: refill within the quarter hour, not the hour
          or (c.day_last_build_at < p_now - interval '14 minutes'
              and exists (select 1 from public.planned_openers po where po.plan_date = d and po.send_status in ('undelivered', 'failed')
                            and po.error_code = any (coalesce(c.day_refill_codes, array['30003', '30005', '30006']))
                            and po.send_updated_at > c.day_last_build_at))) then
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
