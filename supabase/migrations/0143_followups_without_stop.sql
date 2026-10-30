-- 0143: a follow-up (steps 2-5) may leave the STOP line out; a first text still needs it.
-- Colin 2026-10-30 ("the second text does not need the stop"): the door's TypeScript check already allowed it (f995e03),
-- but both database checks still demanded STOP on every step, so Muse's 102 step-2 test texts were refused this morning.
-- Same two functions as their latest definitions, one condition changed in each: agent_queue_text (queue time) and
-- claim_next_opener (send time). Everything else about the wording rules is unchanged.

-- agent_queue_text: from 0084_door_interests.sql, STOP check now step 1 only
CREATE OR REPLACE FUNCTION public.agent_queue_text(p_lead_id uuid, p_phone text, p_body text, p_step integer, p_send_after timestamp with time zone, p_agent text, p_now timestamp with time zone DEFAULT now(), p_variant text DEFAULT NULL::text, p_template text DEFAULT NULL::text, p_slot text DEFAULT NULL::text, p_interest_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c     public.campaign_control;
  l     public.leads;
  num   text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10);
  tz    text;
  t     timestamptz;
  d     date;
  ws    timestamptz;
  we    timestamptz;
  i     integer;
  att   integer := case when coalesce(p_step, 1) = 1 then 1 else 10 + p_step end;
  v_id  uuid;
  b     text := btrim(coalesce(p_body, ''));
  v     text := nullif(upper(left(btrim(coalesce(p_variant, '')), 20)), '');
  sl    text := nullif(lower(btrim(coalesce(p_slot, ''))), '');
  sh    time;
  rp    text;
  k     integer;
  reopen boolean := false;
  codes text;
  iv    public.interests;
  pid   uuid;
  iid   uuid;
begin
  select * into c from public.campaign_control where id = 1;
  select * into l from public.leads where leads.id = p_lead_id;
  if not found then return jsonb_build_object('status', 'refused', 'reason', 'no such card'); end if;
  if coalesce(p_step, 1) not between 1 and 5 then return jsonb_build_object('status', 'refused', 'reason', 'step is 1 to 5'); end if;
  if l.stage in ('dnc', 'dead', 'closed_no_contact', 'closed_won', 'under_contract') then
    -- a card the laptop closed only because its phones were dead comes back for the next phone (0080)
    if coalesce(p_step, 1) = 1 and l.stage in ('dead', 'closed_no_contact') then
      rp := public.dead_reopen_problem(p_lead_id, num);
      if rp is not null then return jsonb_build_object('status', 'refused', 'reason', rp); end if;
      reopen := true;
    else
      return jsonb_build_object('status', 'refused', 'reason', 'card is closed (' || l.stage::text || ')');
    end if;
  end if;
  if coalesce(p_step, 1) = 1 and (reopen or l.stage not in ('postcard_mailed', 'opener_queued')
       or exists (select 1 from public.planned_openers po where po.wpie_owner_id = l.wpie_owner_id and po.attempt between 1 and 9
                    and po.send_status = any(public.opener_live_statuses()))
       or exists (select 1 from public.messages m where m.lead_id = p_lead_id and m.direction = 'out' and m.is_opener and m.provider_sid is not null)) then
    -- the next phone on the card (0079): allowed when every earlier first text bounced or reached a wrong number
    if not reopen then
      rp := public.next_phone_problem(p_lead_id, num);
      if rp is not null then
        return jsonb_build_object('status', 'refused', 'reason', 'already texted or talking (' || l.stage::text || '): ' || rp);
      end if;
    end if;
    select coalesce(max(po.attempt), 1) + 1 into att from public.planned_openers po
     where po.wpie_owner_id = l.wpie_owner_id and po.attempt between 1 and 9;
    if att > 9 then return jsonb_build_object('status', 'refused', 'reason', 'nine first texts already: this card needs a skip trace'); end if;
  elsif coalesce(p_step, 1) > 1 then
    -- a follow-up belongs to the first text that reached this phone (attempt = that first text's attempt * 10 + step)
    select po.attempt into k from public.planned_openers po
     where po.wpie_owner_id = l.wpie_owner_id and po.attempt between 1 and 9 and right(regexp_replace(po.phone, '\D', '', 'g'), 10) = num
       and po.send_status = 'delivered' order by po.attempt desc limit 1;
    att := coalesce(k, 1) * 10 + p_step;
  end if;
  if not exists (select 1 from public.contacts ct where ct.lead_id = p_lead_id and ct.kind = 'phone' and ct.value_normalized = num
                  and ct.status = 'ok' and not ct.dnc_app and not ct.suppressed and not ct.dnc_vendor and ct.dnc_scrub <> 'dnc') then
    return jsonb_build_object('status', 'refused', 'reason', 'that phone is not a usable phone on this card');
  end if;
  if exists (select 1 from public.suppressed_phones s where s.phone10 = num) then
    return jsonb_build_object('status', 'refused', 'reason', 'this phone opted out');
  end if;
  -- the person the text is for (0083): a do-not-contact or deceased person's number is never texted, on any card
  rp := public.phone_person_block(num);
  if rp is not null then return jsonb_build_object('status', 'refused', 'reason', rp); end if;
  if p_interest_id is not null then
    select * into iv from public.interests i where i.id = p_interest_id and i.lead_id = p_lead_id;
    if not found then return jsonb_build_object('status', 'refused', 'reason', 'no such person on this card (interest_id)'); end if;
    if iv.status <> 'active' or (select pe.status from public.people pe where pe.id = iv.person_id) <> 'active' then
      return jsonb_build_object('status', 'refused', 'reason', 'that person is closed on this card (' || iv.status || ')');
    end if;
    if not exists (select 1 from public.contacts ct where ct.lead_id = p_lead_id and ct.value_normalized = num and ct.person_id = iv.person_id) then
      return jsonb_build_object('status', 'refused', 'reason', 'that phone is not that person''s on this card (add it to them with add_prospects)');
    end if;
    pid := iv.person_id; iid := iv.id;
  else
    select i.person_id, i.id into pid, iid from public.contacts ct join public.interests i on i.person_id = ct.person_id and i.lead_id = p_lead_id
      join public.people pe on pe.id = i.person_id
     where ct.lead_id = p_lead_id and ct.value_normalized = num and i.status = 'active' and pe.status = 'active'
     order by array_position(array['personal_representative', 'special_administrator', 'owner_of_record', 'co_owner', 'trustee', 'heir', 'spouse', 'occupant', 'other'], i.role)
     limit 1;
    if pid is null and exists (select 1 from public.contacts ct where ct.lead_id = p_lead_id and ct.value_normalized = num and ct.person_id is not null) then
      return jsonb_build_object('status', 'refused', 'reason', 'everyone this phone belongs to on this card is closed (deceased, do not contact or not the contact)');
    end if;
  end if;
  if exists (select 1 from public.twilio_inbound ti where ti.from10 = num) then
    return jsonb_build_object('status', 'refused', 'reason', 'they already texted back: replies go to the reply agent and the team');
  end if;
  if b = '' or (coalesce(p_step, 1) = 1 and position('STOP' in b) = 0) then return jsonb_build_object('status', 'refused', 'reason', 'a first text needs a STOP line (a follow-up may leave it out)'); end if;
  if position('$' in b) > 0 then return jsonb_build_object('status', 'refused', 'reason', 'no prices or $ in a text'); end if;
  if length(b) > 320 then return jsonb_build_object('status', 'refused', 'reason', 'over 320 characters'); end if;
  if exists (select 1 from unnest(c.banned_words) w where w <> '' and position(lower(w) in lower(b)) > 0) then
    return jsonb_build_object('status', 'refused', 'reason', 'names the business');
  end if;
  if exists (select 1 from public.planned_openers po where po.lead_id = p_lead_id and po.step = coalesce(p_step, 1)
              and po.send_status in ('planned', 'would_send', 'sending')) then
    return jsonb_build_object('status', 'refused', 'reason', 'a text for this step is already waiting: withdraw it first');
  end if;
  if sl is not null and sl not in ('am', 'pm') then return jsonb_build_object('status', 'refused', 'reason', 'slot is am or pm'); end if;
  tz := public.agent_tz(coalesce(l.mailing_state, 'WI'));
  t := greatest(p_now, coalesce(p_send_after, p_now));
  -- the time-of-day test (Colin 2026-10-26: "200 daily in morning and 200 at 5", "9 is fine"): am goes from 9 AM, pm from 5 PM,
  -- their time; an am text queued after noon waits for the next morning
  if sl is not null then
    sh := case sl when 'am' then time '09:00' else time '17:00' end;
    if sl = 'am' and (t at time zone tz)::time >= time '12:00' then
      t := (((t at time zone tz)::date + 1) + sh) at time zone tz;
    else
      t := greatest(t, (((t at time zone tz)::date) + sh) at time zone tz);
    end if;
  end if;
  for i in 0..8 loop
    d := ((t at time zone tz)::date) + i;
    if c.no_sundays and extract(isodow from d) = 7 then continue; end if;
    ws := (d + c.window_start) at time zone tz;
    we := (d + c.window_end) at time zone tz;
    if we > t then t := greatest(t, ws); exit; end if;
  end loop;
  insert into public.planned_openers (plan_date, wpie_owner_id, attempt, lead_id, lane, template_lane, variant, send_slot, per_hour, phone, body,
         segments, scheduled_at, owner_name, property_address, decision, decided_by_name, decided_at, decision_note,
         send_status, window_start_utc, window_end_utc, governing_state, dnc_state, body_sha256, plan_created_at, step)
  values ((t at time zone c.timezone)::date, l.wpie_owner_id, att, l.id, 'agent', coalesce(nullif(left(btrim(coalesce(p_template, '')), 40), ''), 'agent'),
          coalesce(v, '-'), sl, case when sl = 'am' then 270 else 100 end, '+1' || num, b, case when length(b) <= 160 then 1 else 2 end, t, l.owner_name, l.property_address,
          'approved', 'Muse (' || coalesce(p_agent, 'agent') || ')', p_now, 'written and queued by the sender agent',
          'planned', ws, we, upper(coalesce(l.mailing_state, 'WI')), 'unknown', encode(sha256(convert_to(b, 'UTF8')), 'hex'), p_now,
          coalesce(p_step, 1))
  -- the laptop's copy of the same text, handed over to the agent, is taken over by the agent's wording
  on conflict (plan_date, wpie_owner_id, attempt) do update set
    lane = 'agent', template_lane = excluded.template_lane, variant = excluded.variant, send_slot = excluded.send_slot, phone = excluded.phone, body = excluded.body,
    segments = excluded.segments, scheduled_at = excluded.scheduled_at, decision = 'approved', decided_by_name = excluded.decided_by_name,
    decided_at = excluded.decided_at, decision_note = excluded.decision_note, send_status = 'planned', send_reason = null,
    send_updated_at = p_now, window_start_utc = excluded.window_start_utc, window_end_utc = excluded.window_end_utc,
    governing_state = excluded.governing_state, body_sha256 = excluded.body_sha256, per_hour = excluded.per_hour, step = excluded.step,
    claim_mode = null, claimed_at = null, provider_sid = null, error_code = null
    where planned_openers.send_status = 'withdrawn' and planned_openers.send_reason = 'handed to the sender agent'
  returning planned_openers.id into v_id;
  if v_id is null then return jsonb_build_object('status', 'refused', 'reason', 'this card already has that text planned for that day'); end if;
  if iid is not null then update public.planned_openers set interest_id = iid where id = v_id; end if;
  if reopen then
    select string_agg(distinct po.error_code, ', ') into codes from public.planned_openers po
     where po.wpie_owner_id = l.wpie_owner_id and po.step = 1 and po.error_code is not null;
    update public.leads set stage = 'opener_queued', belt = null, belt_step = 0, next_stop_at = null, next_stop_who = null,
           dead_reason = null, reopened_at = p_now,
           reopened_reason = 'delivery-failure cascade: every first text bounced' || coalesce(' (' || codes || ')', '') || '; next phone ' || num,
           notes = concat_ws(' | ', notes, to_char(p_now at time zone 'America/Chicago', 'YYYY-MM-DD') || ' reopened by Muse (' || coalesce(p_agent, 'agent')
                   || '): closed as ' || l.stage::text || ' only because every first text bounced' || coalesce(' (' || codes || ')', '') || '; texting the next phone ' || num)
     where id = p_lead_id;
    update public.lead_stage_events set source = 'agent: delivery-failure reopen'
     where id = (select max(e.id) from public.lead_stage_events e where e.lead_id = p_lead_id and e.to_stage = 'opener_queued');
    insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
    values (p_lead_id, 'reopened', l.belt, null, null, jsonb_build_object('from_stage', l.stage::text, 'why', 'every first text bounced', 'codes', codes, 'next_phone', num), p_now,
            'Muse (' || coalesce(p_agent, 'agent') || ')');
  end if;
  return jsonb_build_object('status', 'queued', 'text_id', v_id, 'goes_after', t, 'window_ends', we, 'variant', coalesce(v, '-'), 'slot', sl,
    'next_phone', coalesce(p_step, 1) = 1 and att > 1, 'reopened', reopen,
    'interest_id', iid, 'person', (select pe.name from public.people pe where pe.id = pid));
end $function$;

-- claim_next_opener: from 0084_door_interests.sql, STOP check now step 1 only
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
  if used >= c.daily_cap then
    return jsonb_build_object('outcome', 'idle', 'reason', 'daily_cap_reached', 'used', used);
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
    and (select count(distinct coalesce(ct.person_id::text, ct.lead_id::text)) from public.contacts ct where ct.value_normalized = v_phone10) > 1 then
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
  elsif coalesce(o.step, 1) = 1 and position('STOP' in o.body) = 0 then
    why := 'template:no_stop_line';
  elsif position('$' in o.body) > 0 then
    why := 'template:price_symbol';
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
