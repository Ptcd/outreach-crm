-- No-reply follow-ups: texts 2 and 3 (Colin 2026-10-22 yes; docs/FOLLOWUP_CADENCE.md section 2).
-- The laptop plans them (variants Q2 / Q3) and the sync pushes them as planned_openers rows with
-- step 2 or 3; they need Colin's approval like openers. Send time (claim_next_opener): follow-ups
-- go first under the day's cap; a follow-up needs the owner's opener on that phone delivered
-- (text 3: text 2 delivered), no reply ever from that phone, no STOP / wrong / bad phone, 3+ days
-- since the last text to that phone, and at most 3 texts to the owner in all. Same window, Sunday
-- rule, pace, switch and live-sending locks as openers. Sent follow-ups are logged on the lead
-- with source_key 'ledger:<owner>:<attempt>:text<step>' and is_opener false.
-- Kill rule (follow-ups only): opt-outs on delivered follow-ups above 2% (50+ delivered) or above
-- twice the openers' trailing 7-day rate pauses texts 2-3, keeps openers going, and texts Colin.
-- Colin restarts follow-ups by hand (Approvals page).

alter table public.planned_openers add column if not exists step smallint not null default 1 check (step between 1 and 3);
alter table public.planned_openers drop constraint if exists planned_openers_plan_date_wpie_owner_id_attempt_key;
alter table public.planned_openers add constraint planned_openers_plan_owner_attempt_step_key unique (plan_date, wpie_owner_id, attempt, step);

alter table public.campaign_control
  add column if not exists followups_paused boolean not null default false,
  add column if not exists followups_pause_reason text,
  add column if not exists followups_paused_at timestamptz;

-- Texts for Colin about the system itself (sent by the reply agent through pm-phone, like hot alerts).
create table if not exists public.ops_alerts (
  id         bigint generated always as identity primary key,
  text       text not null,
  created_at timestamptz not null default now(),
  sent_at    timestamptz,
  sid        text,
  error      text
);
alter table public.ops_alerts enable row level security;
create policy ops_alerts_read on public.ops_alerts for select to authenticated using (public.is_team());
grant select on public.ops_alerts to authenticated;
grant select, insert, update on public.ops_alerts to service_role;

create or replace function public.check_followup_kill(p_now timestamptz default now())
returns void language plpgsql security definer set search_path = public as $$
declare fu_n int; fu_out int; op_n int; op_out int; fu_rate numeric; op_rate numeric; why text;
begin
  -- delivered follow-ups, and STOPs from those phones after the follow-up went out
  select count(*), count(*) filter (where exists (select 1 from public.twilio_inbound t
           where t.from10 = right(regexp_replace(p.phone, '\D', '', 'g'), 10) and t.is_opt_out and t.received_at >= p.sent_at))
    into fu_n, fu_out
    from public.planned_openers p where p.step > 1 and p.send_status = 'delivered' and p.claim_mode = 'live';
  if fu_n = 0 then return; end if;
  -- openers delivered in the last 7 days, and STOPs from those phones before any follow-up
  select count(*), count(*) filter (where exists (select 1 from public.twilio_inbound t
           where t.from10 = right(regexp_replace(p.phone, '\D', '', 'g'), 10) and t.is_opt_out and t.received_at >= p.sent_at
             and not exists (select 1 from public.planned_openers f where f.wpie_owner_id = p.wpie_owner_id and f.step > 1
                               and f.sent_at is not null and f.sent_at <= t.received_at)))
    into op_n, op_out
    from public.planned_openers p where p.step = 1 and p.send_status = 'delivered' and p.claim_mode = 'live'
     and p.sent_at > p_now - interval '7 days';
  fu_rate := fu_out::numeric / fu_n;
  op_rate := case when op_n > 0 then op_out::numeric / op_n else 0 end;
  if fu_n >= 50 and fu_rate > 0.02 then
    why := format('%s of %s delivered follow-ups opted out (%s%%, over 2%%)', fu_out, fu_n, round(fu_rate * 100, 1));
  elsif op_n > 0 and fu_out > 0 and fu_rate > 2 * op_rate then
    why := format('follow-up opt-outs %s%% (%s of %s) are over twice the openers'' 7-day rate (%s%%)',
                  round(fu_rate * 100, 1), fu_out, fu_n, round(op_rate * 100, 1));
  end if;
  if why is not null then
    update public.campaign_control set followups_paused = true, followups_pause_reason = why, followups_paused_at = p_now where id = 1;
    insert into public.opener_send_events (event, reason, actor, at) values ('followups_paused', why, 'server', p_now);
    insert into public.ops_alerts (text, created_at)
    values ('Follow-up texts paused: ' || why || '. Openers keep going. Restart on the Approvals page.', p_now);
  end if;
end $$;

create or replace function public.resume_followups()
returns void language plpgsql security definer set search_path = public as $$
declare who text;
begin
  if not public.is_owner() then raise exception 'only Colin (owner) can restart follow-ups'; end if;
  select display_name into who from public.team_members where lower(email) = lower(auth.jwt() ->> 'email');
  update public.campaign_control set followups_paused = false, followups_pause_reason = null, followups_paused_at = null where id = 1;
  insert into public.opener_send_events (event, actor) values ('followups_resumed', coalesce(who, 'owner'));
end $$;

create or replace function public.ops_claim(p_limit integer default 5)
returns jsonb language plpgsql security definer set search_path = public as $$
declare out jsonb := '[]'::jsonb; a record;
begin
  for a in select * from public.ops_alerts where sent_at is null order by created_at limit p_limit for update skip locked loop
    update public.ops_alerts set sent_at = now() where id = a.id;
    out := out || jsonb_build_object('id', a.id, 'text', a.text);
  end loop;
  return out;
end $$;

create or replace function public.ops_result(p_id bigint, p_sid text, p_error text)
returns void language sql security definer set search_path = public as $$
  update public.ops_alerts set sid = p_sid, error = p_error where id = p_id
$$;

create or replace function public.claim_next_opener(p_dry_run boolean default true, p_now timestamptz default now())
returns jsonb
language plpgsql security definer set search_path = public as $$
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

  if o.window_start_utc is null or o.window_end_utc is null then
    why := 'no_recipient_window';
  elsif o.body_sha256 is null or o.body_sha256 <> encode(sha256(convert_to(o.body, 'UTF8')), 'hex') then
    why := 'body_changed_since_plan';
  elsif o.phone is null or o.phone !~ '^\+1[2-9][0-9]{2}[2-9][0-9]{6}$' then
    why := 'phone_invalid';
  elsif o.lead_id is null or l.id is null then
    why := 'no_lead';
  elsif o.step = 1 and l.stage not in ('postcard_mailed', 'opener_queued') then
    why := 'lead_stage_' || l.stage::text;
  elsif o.step > 1 and l.stage <> 'opener_sent' then
    why := 'lead_stage_' || l.stage::text;
  elsif exists (select 1 from public.suppressed_phones s where s.phone10 = v_phone10) then
    why := 'phone_suppressed';
  elsif exists (select 1 from public.suppressed_phones s where s.phone10 = any(owner_phones))
     or exists (select 1 from public.contacts ct where ct.value_normalized = any(owner_phones) and ct.suppressed) then
    why := 'owner_opted_out_on_another_phone';
  elsif exists (select 1 from public.messages m where m.lead_id = o.lead_id and m.direction = 'in' and m.channel = 'sms')
     or exists (select 1 from public.twilio_inbound t where t.from10 = any(owner_phones)) then
    why := 'owner_replied';
  elsif exists (select 1 from public.contacts ct where ct.value_normalized = v_phone10
                  and (ct.dnc_vendor or ct.dnc_scrub = 'dnc' or ct.dnc_app)) then
    why := 'phone_dnc_positive';
  elsif exists (select 1 from public.contacts ct where ct.value_normalized = v_phone10 and ct.lead_id = o.lead_id and ct.status = 'bad') then
    why := 'phone_marked_bad';
  elsif (select count(distinct ct.lead_id) from public.contacts ct where ct.value_normalized = v_phone10) > 1 then
    why := 'phone_shared';
  elsif c.dnc_policy = 'require_scrub' and (coalesce(o.dnc_state, '') <> 'screened'
        or exists (select 1 from public.contacts ct where ct.value_normalized = v_phone10 and ct.dnc_scrub <> 'clear')) then
    why := 'dnc_unscreened_under_require_scrub';
  elsif c.dnc_policy = 'require_scrub' and (c.scrub_date is null or today - c.scrub_date > 31) then
    why := 'dnc_scrub_older_than_31_days';
  elsif o.step = 1 and (exists (select 1 from public.planned_openers p
                 where p.id <> o.id and (p.wpie_owner_id = o.wpie_owner_id or p.phone = o.phone)
                   and p.send_status = any(public.opener_live_statuses()))
     or exists (select 1 from public.messages m
                 where m.direction = 'out' and m.is_opener and m.provider_sid is not null
                   and (m.lead_id = o.lead_id or m.to_number = o.phone))) then
    why := 'owner_already_texted';
  -- Texts 2 and 3 (docs/FOLLOWUP_CADENCE.md section 2), in place of "already texted":
  elsif o.step > 1 and not (
        exists (select 1 from public.planned_openers p where p.wpie_owner_id = o.wpie_owner_id and p.step = 1
                  and p.phone = o.phone and p.send_status = 'delivered')
     or exists (select 1 from public.messages m where m.lead_id = o.lead_id and m.is_opener and m.direction = 'out'
                  and m.to_number = o.phone and m.status = 'delivered')) then
    why := 'opener_not_delivered';
  elsif o.step = 3 and not exists (select 1 from public.planned_openers p where p.wpie_owner_id = o.wpie_owner_id
                  and p.step = 2 and p.phone = o.phone and p.send_status = 'delivered') then
    why := 'text_2_not_delivered';
  elsif o.step > 1 and exists (select 1 from public.planned_openers p where p.id <> o.id and p.wpie_owner_id = o.wpie_owner_id
                  and p.step = o.step and p.send_status = any(public.opener_live_statuses())) then
    why := 'step_already_sent';
  elsif o.step > 1 and exists (select 1 from public.twilio_inbound t where t.from10 = v_phone10) then
    why := 'owner_replied';
  elsif o.step > 1 and exists (select 1 from public.contacts ct where ct.value_normalized = v_phone10 and ct.status::text in ('bad', 'dead')) then
    why := 'phone_marked_bad';
  elsif o.step > 1 and (select count(*) from (
          select p.id::text from public.planned_openers p where p.wpie_owner_id = o.wpie_owner_id and p.id <> o.id
             and p.send_status = any(public.opener_live_statuses())
          union
          select coalesce(m.provider_sid, m.id::text) from public.messages m where m.lead_id = o.lead_id
             and m.direction = 'out' and m.channel = 'sms' and m.provider_sid is not null
             and not exists (select 1 from public.planned_openers p2 where p2.provider_sid = m.provider_sid)) n) >= 3 then
    why := 'three_texts_sent';
  elsif o.step > 1 and (select greatest(
          (select max(coalesce(p.sent_at, p.claimed_at)) from public.planned_openers p where p.phone = o.phone and p.id <> o.id
              and p.send_status = any(public.opener_live_statuses())),
          (select max(m.sent_at) from public.messages m where m.to_number = o.phone and m.direction = 'out' and m.channel = 'sms')))
        > p_now - interval '3 days' then
    why := 'too_soon';
  elsif position('STOP' in o.body) = 0 then
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
end $$;

create or replace function public.record_send_result(p_id uuid, p_status text, p_sid text default null,
  p_error_code text default null, p_reason text default null, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  o public.planned_openers;
  c public.campaign_control;
begin
  if p_status not in ('sent', 'failed', 'uncertain') then
    raise exception 'unknown send result %', p_status;
  end if;
  select * into o from public.planned_openers where id = p_id for update;
  if not found or o.send_status <> 'sending' then
    return jsonb_build_object('ok', false, 'reason', 'not_sending');
  end if;
  update public.planned_openers
     set send_status = p_status, provider_sid = coalesce(p_sid, provider_sid), error_code = p_error_code,
         send_reason = p_reason, sent_at = case when p_status = 'sent' then p_now else sent_at end,
         send_updated_at = p_now
   where id = p_id;
  insert into public.opener_send_events (opener_id, plan_date, wpie_owner_id, attempt, event, reason, provider_sid, error_code, actor, at)
  values (o.id, o.plan_date, o.wpie_owner_id, o.attempt, p_status, p_reason, p_sid, p_error_code, 'server', p_now);
  if p_status = 'sent' and o.lead_id is not null then
    -- The same natural key the WPIE sync uses, so its later push updates this row.
    insert into public.messages (lead_id, contact_id, direction, channel, body, from_number, to_number, provider_sid,
                                 source_key, status, is_opener, sent_at, created_by)
    values (o.lead_id,
            (select ct.id from public.contacts ct where ct.lead_id = o.lead_id
               and ct.value_normalized = right(regexp_replace(o.phone, '\D', '', 'g'), 10) order by ct.created_at limit 1),
            'out', 'sms', o.body, null, o.phone, p_sid,
            case when o.step > 1 then format('ledger:%s:%s:text%s', o.wpie_owner_id, o.attempt, o.step)
                 else format('ledger:%s:%s:opener', o.wpie_owner_id, o.attempt) end,
            'sent', o.step = 1, p_now, null)
    on conflict (source_key) do update set provider_sid = coalesce(messages.provider_sid, excluded.provider_sid),
                                           status = excluded.status;
    update public.leads set stage = 'opener_sent' where id = o.lead_id and stage in ('postcard_mailed', 'opener_queued');
  end if;
  select * into c from public.campaign_control where id = 1;
  if p_error_code is not null and p_error_code = any(c.pause_codes) then
    perform public.trip_pause(format('Twilio error %s on a send: account or registration problem', p_error_code), p_now);
  end if;
  perform public.check_filter_rule(p_now);
  return jsonb_build_object('ok', true);
end $$;

revoke all on function public.check_followup_kill(timestamptz), public.ops_claim(integer), public.ops_result(bigint, text, text)
  from public, anon, authenticated;
grant execute on function public.check_followup_kill(timestamptz), public.ops_claim(integer), public.ops_result(bigint, text, text) to service_role;
revoke all on function public.resume_followups() from public, anon;
grant execute on function public.resume_followups() to authenticated;
