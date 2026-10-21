-- Reply agent on the server , WPIE docs/APP_SENDING.md part 2 (Colin 2026-10-21:
-- "dont fire off the texts until we have everything e2e handled by the system except for me
-- approving the ai messages to actual candidates"; "i dont want every seller reply to reach my
-- phone and email i want the system to deal with it").
--
-- Every inbound text to the campaign numbers becomes one reply_drafts row:
--   removal   STOP / plain-language removal / hostile. The phone (and the owner's other phones)
--             is suppressed at once, whatever any switch says. A one-line confirmation is a
--             routine reply (none for a bare carrier keyword: Twilio answers those itself).
--   routine   wrong number, sold, who-is-this, bot question, not interested: WPIE's fixed lines.
--             Sent by the server only while campaign_control.routine_enabled is on (default OFF,
--             and it cannot be turned on until the red-team score for the deployed rules passes);
--             otherwise status 'would_send' and Colin may still approve it by hand.
--   candidate everything else. The reply agent drafts; status 'awaiting_approval'; only Colin's tap sends.
-- Nothing is forwarded per reply. Quiet hours: nothing goes out between quiet_start and
-- quiet_end (Central); an approved or routine reply waits ('queued') until morning.
-- Never twice, never stale: a draft is claimed in one locked transaction, and a newer inbound
-- from the same phone supersedes it.

-- DNC: Colin 2026-10-21, "they already are pre screened": unscreened phones may be texted.
-- A positive DNC flag and every STOP still block (claim_next_opener).
update public.campaign_control set dnc_policy = 'allow_unknown';
alter table public.campaign_control alter column dnc_policy set default 'allow_unknown';

alter table public.campaign_control
  add column routine_enabled     boolean not null default false,
  add column routine_changed_by  text,
  add column routine_changed_at  timestamptz,
  add column agent_rules_version text,          -- what the deployed reply-agent runs
  add column redteam_version     text,          -- the rules the last red-team run scored
  add column redteam_passed      integer,
  add column redteam_total       integer,
  add column redteam_ok          boolean not null default false,
  add column redteam_at          timestamptz,
  add column redteam_detail      jsonb,
  add column quiet_start         time not null default '21:00',
  add column quiet_end           time not null default '08:00',
  add column reply_numbers       text[] not null default array['+12629996513', '+12624180202'],
  add column agent_last_run_at   timestamptz,
  add column agent_last_summary  jsonb;

alter table public.twilio_inbound add column processed_at timestamptz;
create index twilio_inbound_unprocessed_idx on public.twilio_inbound (received_at) where processed_at is null;

create table public.reply_drafts (
  id             uuid primary key default gen_random_uuid(),
  inbound_sid    text not null unique references public.twilio_inbound (sid),
  phone10        text not null,
  our_number     text,                 -- the number they texted; the reply goes out from it
  lead_id        uuid references public.leads (id) on delete set null,
  inbound_body   text,
  inbound_at     timestamptz not null,
  intent         text,
  kind           text not null check (kind in ('removal', 'routine', 'candidate')),
  outcome        text,
  note           text,
  body           text,                 -- the reply (fixed line, or the drafted reply); null = nothing to send
  draft_source   text,                 -- fixed_line | claude | none
  status         text not null check (status in (
                   'no_reply', 'would_send', 'awaiting_approval', 'queued', 'sending', 'sent', 'dry_sent',
                   'failed', 'uncertain', 'skipped', 'superseded')),
  send_after     timestamptz,
  rules_version  text,
  provider_sid   text unique,
  error_code     text,
  sent_body      text,
  sent_at        timestamptz,
  decided_by     text,
  decided_at     timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index reply_drafts_status_idx on public.reply_drafts (status, created_at);
create index reply_drafts_phone_idx on public.reply_drafts (phone10, inbound_at desc);
create index reply_drafts_lead_idx on public.reply_drafts (lead_id);

-- ---------------------------------------------------------------- helpers
create or replace function public.in_quiet_hours(p_now timestamptz default now())
returns boolean language sql stable security definer set search_path = public as $$
  select case when c.quiet_start > c.quiet_end
              then (p_now at time zone c.timezone)::time >= c.quiet_start or (p_now at time zone c.timezone)::time < c.quiet_end
              else (p_now at time zone c.timezone)::time >= c.quiet_start and (p_now at time zone c.timezone)::time < c.quiet_end end
    from public.campaign_control c where c.id = 1
$$;

create or replace function public.quiet_hours_end(p_now timestamptz default now())
returns timestamptz language sql stable security definer set search_path = public as $$
  select case when (p_now at time zone c.timezone)::time < c.quiet_end
              then ((p_now at time zone c.timezone)::date + c.quiet_end) at time zone c.timezone
              else ((p_now at time zone c.timezone)::date + 1 + c.quiet_end) at time zone c.timezone end
    from public.campaign_control c where c.id = 1
$$;

-- --------------------------------------------- 1. inbound texts waiting for the reply agent
-- Claims up to p_limit unprocessed inbound texts to the reply numbers, oldest first, with the
-- context the reply agent needs. Marks them processed in the same transaction.
create or replace function public.reply_claim_inbound(p_limit integer default 10)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c public.campaign_control;
  out jsonb := '[]'::jsonb;
  t record;
  lid uuid;
begin
  perform pg_advisory_xact_lock(hashtext('wpie.reply_claim_inbound'));
  select * into c from public.campaign_control where id = 1;
  for t in
    select * from public.twilio_inbound i
     where i.processed_at is null and i.to_number = any(c.reply_numbers)
     order by i.received_at
     limit p_limit
     for update skip locked
  loop
    lid := coalesce(t.lead_id,
      (select ct.lead_id from public.contacts ct where ct.value_normalized = t.from10 order by ct.created_at limit 1));
    update public.twilio_inbound set processed_at = now(), lead_id = coalesce(lead_id, lid) where sid = t.sid;
    out := out || jsonb_build_object(
      'sid', t.sid, 'from10', t.from10, 'to_number', t.to_number, 'body', t.body, 'received_at', t.received_at,
      'lead_id', lid,
      'owner_name', (select l.owner_name from public.leads l where l.id = lid),
      'property_address', (select l.property_address from public.leads l where l.id = lid),
      'prior_inbound', coalesce((select jsonb_agg(x.body order by x.received_at) from public.twilio_inbound x
                                  where x.from10 = t.from10 and x.received_at < t.received_at), '[]'::jsonb),
      'last_agent_text', (select y.body from (
          select d.sent_body as body, d.sent_at as at from public.reply_drafts d where d.phone10 = t.from10 and d.status = 'sent'
          union all
          select m.body, m.sent_at from public.messages m where m.lead_id = lid and m.direction = 'out' and m.channel = 'sms'
        ) y where y.at < t.received_at order by y.at desc limit 1),
      'history', coalesce((select jsonb_agg(jsonb_build_object('who', z.who, 'body', z.body) order by z.at) from (
          select 'them' as who, x.body, x.received_at as at from public.twilio_inbound x
           where x.from10 = t.from10 and x.received_at < t.received_at
          union all
          select 'us', d.sent_body, d.sent_at from public.reply_drafts d where d.phone10 = t.from10 and d.status = 'sent'
          union all
          select case when m.direction = 'out' then 'us' else 'them' end, m.body, m.sent_at
            from public.messages m where m.lead_id = lid and m.channel = 'sms' and m.provider_sid is not null
        ) z where z.at < t.received_at), '[]'::jsonb));
  end loop;
  return out;
end $$;

-- ---------------------------------------------- 2. what the reply agent decided for one text
create or replace function public.reply_record_decision(p_sid text, p_intent text, p_kind text, p_removal boolean,
  p_outcome text, p_body text, p_draft_source text, p_note text, p_rules_version text, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  t public.twilio_inbound;
  c public.campaign_control;
  st text;
  did uuid;
  owner_phones text[];
  oid bigint;
begin
  select * into t from public.twilio_inbound where sid = p_sid;
  if not found then return jsonb_build_object('ok', false, 'reason', 'unknown_inbound'); end if;
  select * into c from public.campaign_control where id = 1;
  -- an older unanswered draft for this phone is stale now
  update public.reply_drafts set status = 'superseded', updated_at = p_now
   where phone10 = t.from10 and status in ('awaiting_approval', 'would_send', 'queued') and inbound_at < t.received_at;

  st := case
    when p_body is null or btrim(p_body) = '' then case when p_kind = 'candidate' then 'awaiting_approval' else 'no_reply' end
    when p_kind = 'candidate' then 'awaiting_approval'
    when c.routine_enabled then 'queued'
    else 'would_send' end;
  insert into public.reply_drafts (inbound_sid, phone10, our_number, lead_id, inbound_body, inbound_at, intent, kind, outcome,
                                   note, body, draft_source, status, send_after, rules_version, created_at, updated_at)
  values (t.sid, t.from10, t.to_number, t.lead_id, t.body, t.received_at, p_intent, p_kind, p_outcome, p_note,
          nullif(btrim(coalesce(p_body, '')), ''), p_draft_source, st,
          case when st = 'queued' and public.in_quiet_hours(p_now) then public.quiet_hours_end(p_now) else null end,
          p_rules_version, p_now, p_now)
  on conflict (inbound_sid) do nothing
  returning id into did;
  if did is null then return jsonb_build_object('ok', false, 'reason', 'already_decided'); end if;

  -- effects on the lead and the never-text list (removal happens regardless of any switch)
  oid := (select l.wpie_owner_id from public.leads l where l.id = t.lead_id);
  if p_removal then
    select coalesce(array_agg(distinct ct.value_normalized), '{}') into owner_phones
      from public.contacts ct join public.leads l on l.id = ct.lead_id
     where ct.kind = 'phone' and ct.value_normalized is not null and (ct.value_normalized = t.from10 or l.wpie_owner_id = oid);
    owner_phones := array_append(owner_phones, t.from10);
    insert into public.suppressed_phones (phone10, reason, source)
      select distinct p, case when p = t.from10 then 'removal_reply' else 'removal_reply_other_phone' end, 'reply_agent'
        from unnest(owner_phones) p where p ~ '^[0-9]{10}$'
    on conflict (phone10) do nothing;
    update public.contacts set suppressed = true where value_normalized = any(owner_phones);
    update public.leads set stage = 'dnc' where id = t.lead_id;
  elsif p_outcome = 'wrong_number' then
    update public.contacts set status = 'bad', note = coalesce(note || '; ', '') || 'wrong number (reply agent)'
     where value_normalized = t.from10 and lead_id = t.lead_id;
    update public.leads set stage = 'data_fix' where id = t.lead_id and stage in ('postcard_mailed', 'opener_queued', 'opener_sent', 'reply_received');
  elsif p_outcome = 'not_interested' then
    update public.leads set stage = 'dead', dead_reason = coalesce(nullif(p_note, ''), 'not interested')
     where id = t.lead_id and stage in ('postcard_mailed', 'opener_queued', 'opener_sent', 'reply_received', 'ai_qualifying');
  else
    update public.leads set stage = case when p_kind = 'candidate' then 'reply_received'::public.lead_stage else 'ai_qualifying'::public.lead_stage end
     where id = t.lead_id and stage in ('postcard_mailed', 'opener_queued', 'opener_sent');
  end if;
  update public.leads set last_inbound_at = greatest(coalesce(last_inbound_at, t.received_at), t.received_at) where id = t.lead_id;
  return jsonb_build_object('ok', true, 'id', did, 'status', st);
end $$;

-- ------------------------------------------------- 3. claim one reply for sending
-- p_mode 'auto'    : a queued routine reply whose time has come (server, routine switch on)
--        'approve' : Colin's tap on a candidate / would_send / no-draft reply (p_body = his final text)
-- Returns {outcome: send|dry_sent|queued|refused, ...}. 'send' means: status is now 'sending',
-- call Twilio, then reply_record_result. Never twice: only these statuses can be claimed.
create or replace function public.reply_claim_send(p_id uuid, p_mode text, p_body text, p_actor text, p_dry boolean,
  p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  d public.reply_drafts;
  c public.campaign_control;
  b text;
begin
  select * into d from public.reply_drafts where id = p_id for update;
  if not found then return jsonb_build_object('outcome', 'refused', 'reason', 'no such draft'); end if;
  select * into c from public.campaign_control where id = 1;
  if p_mode = 'auto' then
    if d.status <> 'queued' then return jsonb_build_object('outcome', 'refused', 'reason', 'not queued'); end if;
    if not c.routine_enabled then return jsonb_build_object('outcome', 'refused', 'reason', 'routine replies are off'); end if;
    if d.send_after is not null and d.send_after > p_now then return jsonb_build_object('outcome', 'queued', 'reason', 'quiet hours'); end if;
  elsif p_mode = 'approve' then
    if d.status not in ('awaiting_approval', 'would_send', 'no_reply', 'dry_sent') then
      return jsonb_build_object('outcome', 'refused', 'reason', 'already ' || d.status);
    end if;
  else
    raise exception 'unknown mode %', p_mode;
  end if;
  b := btrim(coalesce(case when p_mode = 'approve' then p_body end, d.body, ''));
  if b = '' then return jsonb_build_object('outcome', 'refused', 'reason', 'empty reply'); end if;
  if length(b) > 480 then return jsonb_build_object('outcome', 'refused', 'reason', 'over 480 characters'); end if;
  -- a newer text from them makes this reply stale
  if exists (select 1 from public.twilio_inbound i where i.from10 = d.phone10 and i.received_at > d.inbound_at) then
    update public.reply_drafts set status = 'superseded', updated_at = p_now where id = d.id;
    return jsonb_build_object('outcome', 'refused', 'reason', 'they texted again after this draft - see the newer one');
  end if;
  -- after a removal only the removal confirmation itself may go
  if d.kind <> 'removal' and exists (select 1 from public.suppressed_phones s where s.phone10 = d.phone10) then
    update public.reply_drafts set status = 'skipped', note = coalesce(note, '') || ' | phone opted out', updated_at = p_now where id = d.id;
    return jsonb_build_object('outcome', 'refused', 'reason', 'this phone opted out');
  end if;
  if public.in_quiet_hours(p_now) then
    update public.reply_drafts set status = 'queued', body = b, send_after = public.quiet_hours_end(p_now),
           decided_by = coalesce(p_actor, decided_by), decided_at = coalesce(decided_at, p_now), updated_at = p_now
     where id = d.id;
    return jsonb_build_object('outcome', 'queued', 'reason', 'quiet hours - goes at ' || to_char(public.quiet_hours_end(p_now) at time zone c.timezone, 'HH24:MI'));
  end if;
  if p_dry then
    update public.reply_drafts set status = 'dry_sent', sent_body = b, decided_by = coalesce(p_actor, decided_by),
           decided_at = p_now, updated_at = p_now, note = coalesce(note, '') || ' | would send (live sending is off)'
     where id = d.id;
    return jsonb_build_object('outcome', 'dry_sent', 'body', b);
  end if;
  update public.reply_drafts set status = 'sending', sent_body = b, decided_by = coalesce(p_actor, decided_by),
         decided_at = coalesce(decided_at, p_now), updated_at = p_now where id = d.id;
  return jsonb_build_object('outcome', 'send', 'id', d.id, 'to', '+1' || d.phone10, 'from', d.our_number, 'body', b);
end $$;

create or replace function public.reply_record_result(p_id uuid, p_status text, p_sid text default null,
  p_error_code text default null, p_reason text default null, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare d public.reply_drafts;
begin
  if p_status not in ('sent', 'failed', 'uncertain') then raise exception 'unknown result %', p_status; end if;
  select * into d from public.reply_drafts where id = p_id for update;
  if not found or d.status <> 'sending' then return jsonb_build_object('ok', false, 'reason', 'not sending'); end if;
  update public.reply_drafts set status = p_status, provider_sid = p_sid, error_code = p_error_code,
         sent_at = case when p_status = 'sent' then p_now end, updated_at = p_now,
         note = case when p_reason is null then note else coalesce(note, '') || ' | ' || p_reason end
   where id = p_id;
  if p_status = 'sent' and d.lead_id is not null then
    insert into public.messages (lead_id, direction, channel, body, from_number, to_number, provider_sid, source_key, status, sent_at, created_by)
    values (d.lead_id, 'out', 'sms', d.sent_body, d.our_number, '+1' || d.phone10, p_sid, 'sam:' || d.id, 'sent', p_now, null)
    on conflict (source_key) do nothing;
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- Due routine replies (and approved ones held overnight) for the server's send loop.
create or replace function public.reply_due(p_limit integer default 10, p_now timestamptz default now())
returns setof uuid language sql stable security definer set search_path = public as $$
  select id from public.reply_drafts
   where status = 'queued' and (send_after is null or send_after <= p_now)
   order by created_at limit p_limit
$$;

-- An approved reply held for quiet hours is sent by the server in the morning even with
-- routine replies off: Colin already approved it. reply_claim_send('auto') needs the switch,
-- so held approvals use this instead.
create or replace function public.reply_claim_held(p_id uuid, p_dry boolean, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare d public.reply_drafts;
begin
  select * into d from public.reply_drafts where id = p_id for update;
  if not found or d.status <> 'queued' or d.decided_by is null then return jsonb_build_object('outcome', 'refused', 'reason', 'not a held approval'); end if;
  update public.reply_drafts set status = 'awaiting_approval', updated_at = p_now where id = p_id;
  return public.reply_claim_send(p_id, 'approve', d.body, d.decided_by, p_dry, p_now);
end $$;

-- ---------------------------------------------------------------- the red team
create or replace function public.record_redteam(p_version text, p_passed integer, p_total integer, p_ok boolean,
  p_detail jsonb, p_now timestamptz default now())
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.campaign_control
     set redteam_version = p_version, redteam_passed = p_passed, redteam_total = p_total, redteam_ok = p_ok,
         redteam_detail = p_detail, redteam_at = p_now, agent_rules_version = p_version,
         -- a new rule set that fails turns routine replies off
         routine_enabled = routine_enabled and p_ok
   where id = 1;
end $$;

create or replace function public.note_agent_run(p_summary jsonb, p_now timestamptz default now())
returns void language sql security definer set search_path = public as $$
  update public.campaign_control set agent_last_run_at = p_now, agent_last_summary = p_summary where id = 1
$$;

-- ----------------------------------------------------------------- Colin's buttons
create or replace function public.set_routine_replies(p_on boolean)
returns void language plpgsql security definer set search_path = public as $$
declare who text; c public.campaign_control;
begin
  if not public.is_owner() then raise exception 'only Colin (owner) can change this'; end if;
  select * into c from public.campaign_control where id = 1;
  if p_on and not (c.redteam_ok and c.redteam_version is not null and c.redteam_version = c.agent_rules_version) then
    raise exception 'the red-team test has not passed for the rules the reply agent runs now (%/% on %)',
      coalesce(c.redteam_passed, 0), coalesce(c.redteam_total, 0), coalesce(c.redteam_version, 'none');
  end if;
  select display_name into who from public.team_members where lower(email) = lower(auth.jwt() ->> 'email');
  update public.campaign_control set routine_enabled = p_on, routine_changed_by = who, routine_changed_at = now() where id = 1;
  insert into public.opener_send_events (event, actor) values (case when p_on then 'routine_on' else 'routine_off' end, who);
end $$;

create or replace function public.skip_reply(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare who text;
begin
  if not public.is_owner() then raise exception 'only Colin (owner) can skip a reply'; end if;
  select display_name into who from public.team_members where lower(email) = lower(auth.jwt() ->> 'email');
  update public.reply_drafts set status = 'skipped', decided_by = who, decided_at = now(), updated_at = now()
   where id = p_id and status in ('awaiting_approval', 'would_send', 'no_reply', 'queued', 'dry_sent');
end $$;

-- How many replies wait for Colin (Inbox badge, morning email).
create or replace view public.reply_waiting with (security_invoker = true) as
  select count(*) filter (where status = 'awaiting_approval')::int as drafts_waiting,
         count(*) filter (where status = 'would_send')::int as routine_would_send,
         count(*) filter (where status = 'queued')::int as queued
    from public.reply_drafts;

-- ------------------------------------------------------------------ access
alter table public.reply_drafts enable row level security;
grant select on public.reply_drafts, public.reply_waiting to authenticated;
create policy reply_drafts_read on public.reply_drafts for select to authenticated using (public.is_team());

revoke all on function public.reply_claim_inbound(integer), public.reply_record_decision(text, text, text, boolean, text, text, text, text, text, timestamptz),
  public.reply_claim_send(uuid, text, text, text, boolean, timestamptz), public.reply_record_result(uuid, text, text, text, text, timestamptz),
  public.reply_due(integer, timestamptz), public.reply_claim_held(uuid, boolean, timestamptz),
  public.record_redteam(text, integer, integer, boolean, jsonb, timestamptz), public.note_agent_run(jsonb, timestamptz),
  public.in_quiet_hours(timestamptz), public.quiet_hours_end(timestamptz)
  from public, anon, authenticated;
grant execute on function public.reply_claim_inbound(integer), public.reply_record_decision(text, text, text, boolean, text, text, text, text, text, timestamptz),
  public.reply_claim_send(uuid, text, text, text, boolean, timestamptz), public.reply_record_result(uuid, text, text, text, text, timestamptz),
  public.reply_due(integer, timestamptz), public.reply_claim_held(uuid, boolean, timestamptz),
  public.record_redteam(text, integer, integer, boolean, jsonb, timestamptz), public.note_agent_run(jsonb, timestamptz),
  public.in_quiet_hours(timestamptz), public.quiet_hours_end(timestamptz)
  to service_role;
revoke all on function public.set_routine_replies(boolean), public.skip_reply(uuid) from public, anon;
grant execute on function public.set_routine_replies(boolean), public.skip_reply(uuid) to authenticated;
