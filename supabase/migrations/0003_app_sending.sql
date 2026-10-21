-- App sending (WPIE docs/APP_SENDING.md, 2026-10-21).
--
-- The laptop still builds each day's plan and pushes it into planned_openers. This
-- migration lets a timer on Supabase send the APPROVED, DUE entries itself, so texts
-- go out with the laptop asleep, while keeping every send-time check WPIE's
-- `python -m wpie.campaign send` runs.
--
-- Three locks, every one OFF by default:
--   1. The Edge Function secret TWILIO_LIVE_SENDING=1. Without it the function only
--      ever calls claim_next_opener(p_dry_run => true): checks run, "would send" is
--      recorded, Twilio is never called.
--   2. campaign_control.sending_enabled, flipped by Colin (owner role) in the app.
--   3. Each text approved by Colin (planned_openers.decision = 'approved').
-- Plus the pause (set by the server on a Twilio account / carrier-filter error, or
-- mirrored from the laptop watchdog's PAUSED.json), which stops everything until
-- Colin clears it.
--
-- Static facts (state law, recipient time zone window, template wording, DNC policy at
-- plan time) are decided by Python when the plan is built and pushed with each entry.
-- This file re-checks only the facts that can change during a day.
--
-- "Never retry an ambiguous send": an entry is marked 'sending' in the same
-- transaction that picks it, BEFORE Twilio is called. Only an explicit result moves
-- it on; nothing ever moves an entry back to 'planned'.

-- ======================================================= planned_openers: send state
alter table public.planned_openers
  add column send_status      text not null default 'planned'
    check (send_status in ('planned', 'would_send', 'sending', 'sent', 'delivered', 'undelivered',
                           'failed', 'uncertain', 'skipped', 'withdrawn')),
  add column send_reason      text,
  add column claim_mode       text check (claim_mode in ('live', 'dry')),
  add column claimed_at       timestamptz,
  add column provider_sid     text unique,
  add column sent_at          timestamptz,
  add column error_code       text,
  add column send_updated_at  timestamptz,
  -- pushed by the WPIE sync from the plan entry
  add column window_start_utc timestamptz,      -- the recipient's allowed interval today (state law + campaign window)
  add column window_end_utc   timestamptz,
  add column governing_state  text,
  add column dnc_state        text,             -- screened | unknown | blocked, at plan time
  add column per_hour         integer,          -- the plan's pace
  add column body_sha256      text,             -- sha256 of body as Python validated it
  add column plan_created_at  timestamptz;

create index planned_openers_send_idx on public.planned_openers (plan_date, send_status, scheduled_at);
create index planned_openers_owner_idx on public.planned_openers (wpie_owner_id);
create index planned_openers_claimed_idx on public.planned_openers (claimed_at) where claimed_at is not null;

-- The statuses that mean "a live attempt was made" (the laptop counts its 'sending' lines the same way).
create or replace function public.opener_live_statuses() returns text[]
language sql immutable as $$ select array['sending', 'sent', 'delivered', 'undelivered', 'failed', 'uncertain'] $$;

-- ===================================================================== control row
create table public.campaign_control (
  id                  integer primary key default 1 check (id = 1),
  sending_enabled     boolean not null default false,
  sending_changed_by  text,
  sending_changed_at  timestamptz,
  paused              boolean not null default false,  -- set by the server; cleared by Colin
  pause_reason        text,
  paused_at           timestamptz,
  laptop_paused       boolean not null default false,  -- WPIE's data/campaign/PAUSED.json, pushed by the sync
  laptop_pause_reason text,
  daily_cap           integer not null default 100 check (daily_cap >= 0),
  max_per_run         integer not null default 10 check (max_per_run between 0 and 50),
  timezone            text not null default 'America/Chicago',
  window_start        time not null default '10:00',
  window_end          time not null default '18:15',
  no_sundays          boolean not null default true,
  dnc_policy          text not null default 'require_scrub' check (dnc_policy in ('require_scrub', 'allow_unknown')),
  scrub_date          date,                            -- newest national-DNC scrub on the laptop
  external_openers_date date,                          -- openers the laptop's reply agent sent itself that day
  external_openers    integer not null default 0,
  banned_words        text[] not null default '{}',    -- e.g. the business name; pushed by the sync
  pause_codes         text[] not null default array['30034', '30002', '30022', '30023', '30027', '21606', '20003'],
  filter_codes        text[] not null default array['30007', '30004'],
  filtered_max        integer not null default 3,
  rolling_sends       integer not null default 50,
  last_inbound_poll_at timestamptz,
  last_run_at         timestamptz,
  last_run_summary    jsonb,
  updated_at          timestamptz not null default now()
);
insert into public.campaign_control (id) values (1);

-- ================================================================ phones never to text
-- Pushed in full by the sync (sms suppressions, every STOP, the voice DNC list,
-- positive DNC flags) and added to by the server when a STOP arrives from Twilio.
create table public.suppressed_phones (
  phone10   text primary key check (phone10 ~ '^[0-9]{10}$'),
  reason    text not null,
  source    text not null default 'wpie',         -- wpie | twilio_inbound | app
  added_at  timestamptz not null default now()
);

-- ===================================================== inbound texts seen by the server
-- The server pulls the campaign number's inbound texts from Twilio before each run, so
-- a STOP or a reply stops the next send even while the laptop is off. The laptop keeps
-- importing the same texts into its ledger (import-replies --twilio).
create table public.twilio_inbound (
  sid         text primary key,
  from10      text not null,
  to_number   text,
  body        text,
  is_opt_out  boolean not null default false,
  lead_id     uuid references public.leads (id) on delete set null,
  received_at timestamptz not null,
  created_at  timestamptz not null default now()
);
create index twilio_inbound_from_idx on public.twilio_inbound (from10);
create index twilio_inbound_lead_idx on public.twilio_inbound (lead_id, received_at desc);

-- ==================================================== append-only send events (to the laptop)
create table public.opener_send_events (
  id            bigserial primary key,
  opener_id     uuid references public.planned_openers (id) on delete set null,
  plan_date     date,
  wpie_owner_id bigint,
  attempt       integer,
  event         text not null,      -- would_send | sending | sent | failed | uncertain | skipped | withdrawn
                                    -- | delivered | undelivered | approved_all | switch_on | switch_off | paused | pause_cleared
  reason        text,
  provider_sid  text,
  error_code    text,
  actor         text,               -- 'server' or the person's display name
  at            timestamptz not null default now()
);
create index opener_send_events_opener_idx on public.opener_send_events (opener_id);

-- ================================================ reply threads (pushed by the sync)
-- One per phone the reply agent has a conversation with. The suggestion comes from
-- WPIE's scripted reply agent (wpie.reply.brain), computed by the sync and never sent
-- by anything here. Price fields are deliberately not copied.
create table public.reply_threads (
  phone10          text primary key,
  lead_id          uuid references public.leads (id) on delete set null,
  wpie_owner_id    bigint,
  intent           text,              -- wpie.reply.rules.classify of the newest inbound text
  agent_stage      text,              -- identify | interest | qualify | book | closed
  outcome          text,              -- handoff | close_not_interested | close_wrong_number | close_dnc
  human_owned      boolean not null default false,
  handoff_flag     text,
  callback_slot    text,
  facts            jsonb not null default '{}',
  suggested_reply  text,
  suggestion_note  text,
  last_inbound_at  timestamptz,
  last_inbound     text,
  synced_at        timestamptz not null default now()
);
create index reply_threads_lead_idx on public.reply_threads (lead_id);

-- ============================================================== the claim
-- One call = at most one entry. Returns jsonb:
--   {"outcome": "idle", "reason": ...}                  nothing to do now (switch off, paused, window, cap, pace, nothing due)
--   {"outcome": "skipped", "reason": ..., "opener": {}} an entry failed a check and is skipped for good
--   {"outcome": "would_send", "opener": {}}             dry run: every check passed
--   {"outcome": "send", "opener": {}}                   live: the entry is now 'sending'; call Twilio, then record_send_result
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

  -- Pick the earliest due approved entry whose recipient window is open now.
  select * into o from public.planned_openers p
   where p.plan_date = today
     and (p.send_status = 'planned' or (not p_dry_run and p.send_status = 'would_send'))
     and (p_dry_run or p.decision = 'approved')
     and p.decision <> 'skipped'
     and coalesce(p.scheduled_at, p_now) <= p_now
     and (p.window_start_utc is null or (p.window_start_utc <= p_now and p_now < p.window_end_utc))
   order by p.scheduled_at nulls last, p.id
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
  elsif l.stage not in ('postcard_mailed', 'opener_queued') then
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
  elsif exists (select 1 from public.planned_openers p
                 where p.id <> o.id and (p.wpie_owner_id = o.wpie_owner_id or p.phone = o.phone)
                   and p.send_status = any(public.opener_live_statuses()))
     or exists (select 1 from public.messages m
                 where m.direction = 'out' and m.is_opener and m.provider_sid is not null
                   and (m.lead_id = o.lead_id or m.to_number = o.phone)) then
    why := 'owner_already_texted';
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
                              'opener', jsonb_build_object('id', o.id, 'wpie_owner_id', o.wpie_owner_id, 'attempt', o.attempt));
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
                                                         'plan_date', o.plan_date));
end $$;

-- ============================================================== pause helpers
create or replace function public.trip_pause(p_reason text, p_now timestamptz default now())
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.campaign_control
     set paused = true, pause_reason = p_reason, paused_at = p_now, updated_at = p_now
   where id = 1 and not paused;
  if found then
    insert into public.opener_send_events (event, reason, actor, at) values ('paused', p_reason, 'server', p_now);
  end if;
end $$;

-- Carrier filtering: N filtered among the last M live sends (watchdog.py's rolling rule).
create or replace function public.check_filter_rule(p_now timestamptz default now())
returns void language plpgsql security definer set search_path = public as $$
declare
  c public.campaign_control;
  n integer;
begin
  select * into c from public.campaign_control where id = 1;
  select count(*) into n from (
    select p.error_code from public.planned_openers p
     where p.claim_mode = 'live' and p.claimed_at is not null
     order by p.claimed_at desc limit c.rolling_sends) x
   where x.error_code = any(c.filter_codes);
  if n >= c.filtered_max then
    perform public.trip_pause(format('%s carrier-filtered texts (%s) among the last %s sends',
                                     n, array_to_string(c.filter_codes, '/'), c.rolling_sends), p_now);
  end if;
end $$;

-- ======================================================= results from the Edge Functions
-- p_status: sent | failed (a definite 4xx refusal) | uncertain (anything else). Only a
-- 'sending' entry can move, so a late or repeated call changes nothing.
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
            format('ledger:%s:%s:opener', o.wpie_owner_id, o.attempt), 'sent', true, p_now, null)
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

-- Delivery status from Twilio's status callback (opener-status Edge Function).
create or replace function public.record_delivery(p_sid text, p_status text, p_error_code text default null,
  p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  o public.planned_openers;
  c public.campaign_control;
  st text;
begin
  st := case lower(p_status) when 'delivered' then 'delivered'
                             when 'undelivered' then 'undelivered'
                             when 'failed' then 'undelivered'
                             else null end;
  select * into o from public.planned_openers where provider_sid = p_sid for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'unknown_sid');
  end if;
  if st is not null and o.send_status in ('sent', 'uncertain', 'delivered') and o.send_status <> st then
    update public.planned_openers set send_status = st, error_code = coalesce(nullif(p_error_code, ''), error_code),
           send_updated_at = p_now where id = o.id;
    insert into public.opener_send_events (opener_id, plan_date, wpie_owner_id, attempt, event, provider_sid, error_code, actor, at)
    values (o.id, o.plan_date, o.wpie_owner_id, o.attempt, st, p_sid, nullif(p_error_code, ''), 'server', p_now);
    update public.messages set status = st where provider_sid = p_sid;
  end if;
  select * into c from public.campaign_control where id = 1;
  if nullif(p_error_code, '') is not null and p_error_code = any(c.pause_codes) then
    perform public.trip_pause(format('Twilio error %s on delivery: account or registration problem', p_error_code), p_now);
  end if;
  perform public.check_filter_rule(p_now);
  return jsonb_build_object('ok', true);
end $$;

-- Inbound text pulled from Twilio by the server. A STOP-style text suppresses the phone.
create or replace function public.record_inbound(p_sid text, p_from text, p_to text, p_body text,
  p_is_opt_out boolean, p_received_at timestamptz)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  f10 text := right(regexp_replace(coalesce(p_from, ''), '\D', '', 'g'), 10);
  lid uuid;
begin
  if length(f10) <> 10 then
    return jsonb_build_object('ok', false, 'reason', 'bad_from');
  end if;
  select ct.lead_id into lid from public.contacts ct where ct.value_normalized = f10 order by ct.created_at limit 1;
  insert into public.twilio_inbound (sid, from10, to_number, body, is_opt_out, lead_id, received_at)
  values (p_sid, f10, p_to, p_body, coalesce(p_is_opt_out, false), lid, p_received_at)
  on conflict (sid) do nothing;
  if coalesce(p_is_opt_out, false) then
    insert into public.suppressed_phones (phone10, reason, source) values (f10, 'stop_reply', 'twilio_inbound')
    on conflict (phone10) do nothing;
    update public.contacts set suppressed = true where value_normalized = f10;
  end if;
  return jsonb_build_object('ok', true, 'lead_id', lid);
end $$;

-- ================================================================ Colin's buttons
create or replace function public.set_sending(p_on boolean)
returns void language plpgsql security definer set search_path = public as $$
declare who text;
begin
  if not public.is_owner() then raise exception 'only Colin (owner) can turn sending on or off'; end if;
  select display_name into who from public.team_members where lower(email) = lower(auth.jwt() ->> 'email');
  update public.campaign_control
     set sending_enabled = p_on, sending_changed_by = who, sending_changed_at = now(), updated_at = now()
   where id = 1;
  insert into public.opener_send_events (event, actor) values (case when p_on then 'switch_on' else 'switch_off' end, who);
end $$;

create or replace function public.clear_pause()
returns void language plpgsql security definer set search_path = public as $$
declare who text;
begin
  if not public.is_owner() then raise exception 'only Colin (owner) can clear a pause'; end if;
  select display_name into who from public.team_members where lower(email) = lower(auth.jwt() ->> 'email');
  update public.campaign_control set paused = false, pause_reason = null, paused_at = null, updated_at = now() where id = 1;
  insert into public.opener_send_events (event, actor) values ('pause_cleared', who);
end $$;

-- Approve every waiting text of a day; the ids in p_except are skipped instead.
create or replace function public.approve_day(p_date date, p_except uuid[] default '{}')
returns jsonb language plpgsql security definer set search_path = public as $$
declare who text; n_ok integer; n_skip integer;
begin
  if not public.is_owner() then raise exception 'only Colin (owner) can approve texts'; end if;
  select display_name into who from public.team_members where lower(email) = lower(auth.jwt() ->> 'email');
  update public.planned_openers set decision = 'skipped', decided_by = auth.uid(), decided_by_name = who,
         decided_at = now(), decision_note = coalesce(decision_note, 'left out of approve-all')
   where plan_date = p_date and decision = 'pending' and send_status in ('planned', 'would_send') and id = any(p_except);
  get diagnostics n_skip = row_count;
  update public.planned_openers set decision = 'approved', decided_by = auth.uid(), decided_by_name = who, decided_at = now()
   where plan_date = p_date and decision = 'pending' and send_status in ('planned', 'would_send') and not (id = any(p_except));
  get diagnostics n_ok = row_count;
  insert into public.opener_send_events (plan_date, event, reason, actor)
  values (p_date, 'approved_all', format('%s approved, %s left out', n_ok, n_skip), who);
  return jsonb_build_object('approved', n_ok, 'skipped', n_skip);
end $$;

-- Pull back everything of a day that has not been sent.
create or replace function public.withdraw_day(p_date date)
returns jsonb language plpgsql security definer set search_path = public as $$
declare who text; n integer;
begin
  if not public.is_owner() then raise exception 'only Colin (owner) can withdraw texts'; end if;
  select display_name into who from public.team_members where lower(email) = lower(auth.jwt() ->> 'email');
  with w as (
    update public.planned_openers set send_status = 'withdrawn', send_reason = 'withdrawn by ' || coalesce(who, 'Colin'),
           send_updated_at = now()
     where plan_date = p_date and send_status in ('planned', 'would_send')
    returning id, plan_date, wpie_owner_id, attempt)
  insert into public.opener_send_events (opener_id, plan_date, wpie_owner_id, attempt, event, reason, actor)
  select id, plan_date, wpie_owner_id, attempt, 'withdrawn', 'withdrawn in the app', who from w;
  get diagnostics n = row_count;
  return jsonb_build_object('withdrawn', n);
end $$;

-- What the last run did, for the status strip on Approvals.
create or replace function public.note_run(p_summary jsonb, p_inbound_polled boolean, p_now timestamptz default now())
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.campaign_control
     set last_run_at = p_now, last_run_summary = p_summary,
         last_inbound_poll_at = case when p_inbound_polled then p_now else last_inbound_poll_at end
   where id = 1;
end $$;

-- The cron's shared secret lives in Supabase Vault (created by supabase/setup/send_openers_cron.sql).
create or replace function public.cron_secret_ok(p_secret text)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare s text;
begin
  execute 'select decrypted_secret from vault.decrypted_secrets where name = ''send_openers_cron_secret'' limit 1' into s;
  return s is not null and p_secret is not null and s = p_secret;
exception when others then
  return false;
end $$;

-- ================================================================== access
alter table public.campaign_control   enable row level security;
alter table public.suppressed_phones  enable row level security;
alter table public.twilio_inbound     enable row level security;
alter table public.opener_send_events enable row level security;
alter table public.reply_threads      enable row level security;

grant select on public.campaign_control, public.suppressed_phones, public.twilio_inbound,
                public.opener_send_events, public.reply_threads to authenticated;
create policy control_read on public.campaign_control for select to authenticated using (public.is_team());
create policy suppressed_read on public.suppressed_phones for select to authenticated using (public.is_team());
create policy inbound_read on public.twilio_inbound for select to authenticated using (public.is_team());
create policy send_events_read on public.opener_send_events for select to authenticated using (public.is_team());
create policy reply_threads_read on public.reply_threads for select to authenticated using (public.is_team());

-- The server-side functions are for the Edge Functions (service_role) only.
revoke all on function public.claim_next_opener(boolean, timestamptz), public.record_send_result(uuid, text, text, text, text, timestamptz),
                       public.record_delivery(text, text, text, timestamptz), public.record_inbound(text, text, text, text, boolean, timestamptz),
                       public.trip_pause(text, timestamptz), public.check_filter_rule(timestamptz), public.cron_secret_ok(text),
                       public.note_run(jsonb, boolean, timestamptz)
  from public, anon, authenticated;
grant execute on function public.claim_next_opener(boolean, timestamptz), public.record_send_result(uuid, text, text, text, text, timestamptz),
                          public.record_delivery(text, text, text, timestamptz), public.record_inbound(text, text, text, text, boolean, timestamptz),
                          public.cron_secret_ok(text), public.note_run(jsonb, boolean, timestamptz)
  to service_role;
-- Colin's buttons check the owner role inside.
revoke all on function public.set_sending(boolean), public.clear_pause(), public.approve_day(date, uuid[]), public.withdraw_day(date)
  from public, anon;
grant execute on function public.set_sending(boolean), public.clear_pause(), public.approve_day(date, uuid[]), public.withdraw_day(date)
  to authenticated;
