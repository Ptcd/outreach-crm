-- 0146: the callers see the texts as they happen and can jump in (Colin 2026-10-30: "Adil and Thalia can't see the
-- texts happening so they can't jump in").
--   * thread_owners: a caller takes a seller's text thread (thread_take); from then on Muse's send_reply, the belt's
--     automated texts and the follow-up sender leave that phone alone until thread_release. Muse's own rule 7 said this
--     already ("when a person on our side has replied, you are done"); now the database enforces it.
--   * texts_live: every thread with a seller text in the last N hours, newest activity first, with the last text each
--     way, who answered last (Muse / a person / the automation), whether we owe an answer, and who owns the thread.
--     The Texts page polls it every 15 s in the foreground and listens to twilio_inbound inserts.

create table if not exists public.thread_owners (
  phone10   text primary key,
  lead_id   uuid references public.leads (id) on delete cascade,
  person    public.team_person not null,
  taken_at  timestamptz not null default now(),
  note      text
);
alter table public.thread_owners enable row level security;
drop policy if exists thread_owners_team_read on public.thread_owners;
create policy thread_owners_team_read on public.thread_owners for select to authenticated using (public.is_team());

create or replace function public.thread_take(p_lead_id uuid, p_phone text, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare p text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10); who public.team_person := public.wpie_person(); n integer;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  if who is null then return jsonb_build_object('ok', false, 'reason', 'no person on this login'); end if;
  if p !~ '^[0-9]{10}$' then return jsonb_build_object('ok', false, 'reason', 'not a phone'); end if;
  insert into public.thread_owners (phone10, lead_id, person, taken_at, note) values (p, p_lead_id, who, now(), p_note)
  on conflict (phone10) do update set lead_id = coalesce(excluded.lead_id, public.thread_owners.lead_id), person = excluded.person, taken_at = now(), note = excluded.note;
  -- an automated reply or belt text already waiting for this phone is withdrawn; the person is answering now
  update public.reply_drafts set status = 'superseded', note = coalesce(note, '') || ' | ' || who::text || ' took the thread', updated_at = now()
   where phone10 = p and coalesce(draft_source, '') <> 'team' and status in ('queued', 'awaiting_approval', 'would_send');
  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'person', who, 'withdrawn', n);
end $$;

create or replace function public.thread_release(p_phone text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare p text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10); n integer;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  delete from public.thread_owners where phone10 = p;
  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'released', n > 0);
end $$;

create or replace function public.texts_live(p_hours integer default 48, p_limit integer default 80) returns jsonb
language sql stable security definer set search_path = public as $$
  with recent as (
    select t.from10 as phone10, max(t.received_at) as last_in_at
      from public.twilio_inbound t
     where t.received_at > now() - make_interval(hours => greatest(1, least(coalesce(p_hours, 48), 24 * 14)))
     group by t.from10
     order by max(t.received_at) desc
     limit greatest(1, least(coalesce(p_limit, 80), 300))),
  last_in as (
    select distinct on (t.from10) t.from10 as phone10, t.sid, t.body, t.received_at, t.is_opt_out, t.lead_id
      from public.twilio_inbound t join recent r on r.phone10 = t.from10
     order by t.from10, t.received_at desc),
  outs as (
    select d.phone10, d.sent_body as body, d.sent_at as at, coalesce(nullif(d.decided_by, ''), 'automation') as by, 0 as src
      from public.reply_drafts d join recent r on r.phone10 = d.phone10 where d.status = 'sent' and d.sent_at is not null
    union all
    select right(regexp_replace(coalesce(m.to_number, ''), '\D', '', 'g'), 10), m.body, m.sent_at, case when m.is_opener then 'first text' else 'automation' end, 1 as src
      from public.messages m join recent r on r.phone10 = right(regexp_replace(coalesce(m.to_number, ''), '\D', '', 'g'), 10)
     where m.direction = 'out' and m.channel = 'sms' and m.provider_sid is not null and m.sent_at is not null),
  last_out as (select distinct on (phone10) phone10, body, at, by from outs order by phone10, at desc, src)
  select coalesce(jsonb_agg(jsonb_build_object(
      'phone10', li.phone10, 'lead_id', coalesce(li.lead_id, o.lead_id), 'owner_name', l.owner_name, 'address', l.property_address,
      'municipality', l.municipality, 'stage', l.stage, 'hot', l.hot_at is not null,
      'last_in', jsonb_build_object('body', li.body, 'at', li.received_at, 'opt_out', li.is_opt_out),
      'last_out', case when lo.phone10 is null then null else jsonb_build_object('body', lo.body, 'at', lo.at, 'by', lo.by) end,
      'unanswered', lo.at is null or lo.at < li.received_at,
      'owner', o.person, 'owned_at', o.taken_at,
      'intent', th.intent, 'outcome', th.outcome, 'agent_stage', th.agent_stage, 'callback_slot', th.callback_slot)
      order by li.received_at desc), '[]'::jsonb)
    from last_in li
    left join last_out lo on lo.phone10 = li.phone10
    left join public.thread_owners o on o.phone10 = li.phone10
    left join public.leads l on l.id = coalesce(li.lead_id, o.lead_id)
    left join public.reply_threads th on th.phone10 = li.phone10
   where public.is_team() and coalesce(l.owner_name, '') not ilike 'TEST %'
$$;

revoke all on function public.thread_take(uuid, text, text), public.thread_release(text), public.texts_live(integer, integer) from public, anon;
grant execute on function public.thread_take(uuid, text, text), public.thread_release(text), public.texts_live(integer, integer) to authenticated, service_role;

-- the seller's text arrives on the Texts page as it lands
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'twilio_inbound') then
    execute 'alter publication supabase_realtime add table public.twilio_inbound';
  end if;
exception when others then null; end $$;


-- agent_start_reply: from 0064_agent_runs_texting.sql, refused while a person owns the thread
create or replace function public.agent_start_reply(p_lead_id uuid, p_phone text, p_agent text) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  l public.leads;
  p text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10);
  li public.twilio_inbound;
  id uuid;
begin
  select * into l from public.leads where leads.id = p_lead_id;
  if not found then raise exception 'no such card'; end if;
  if l.stage = 'dnc' then raise exception 'this card is closed (do not contact)'; end if;
  if exists (select 1 from public.suppressed_phones s where s.phone10 = p) then raise exception 'this phone opted out'; end if;
  if exists (select 1 from public.thread_owners o where o.phone10 = p) then
    raise exception '% has this thread: a person on our side is texting them, say nothing further', (select initcap(o.person::text) from public.thread_owners o where o.phone10 = p);
  end if;
  select * into li from public.twilio_inbound t where t.from10 = p and t.lead_id = p_lead_id order by t.received_at desc limit 1;
  if not found then raise exception 'they have not texted us from that phone: a first text or follow-up goes through queue_texts'; end if;
  insert into public.reply_drafts (phone10, our_number, lead_id, inbound_body, inbound_at, intent, kind, outcome, note, draft_source, status, notified_at)
  values (p, li.to_number, p_lead_id, li.body, now(), 'agent_reply', 'team', 'open', 'written by the sender agent (' || coalesce(p_agent, 'agent') || ')',
          'agent', 'awaiting_approval', now())
  returning reply_drafts.id into id;
  return id;
end $$;

-- belt_claim_text_guarded: from 0037_seller_appointment_shift.sql, refused while a person owns a thread on the card
create or replace function public.belt_claim_text_guarded(p_lead_id uuid, p_dry boolean default true,
  p_force boolean default false, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare paused timestamptz;
begin
  select human_takeover_at into paused from public.leads where id = p_lead_id for update;
  if paused is not null then return jsonb_build_object('outcome', 'refused', 'reason', 'human call in progress'); end if;
  if exists (select 1 from public.thread_owners o where o.lead_id = p_lead_id) then return jsonb_build_object('outcome', 'refused', 'reason', 'a person has this thread'); end if;
  return public.belt_claim_text(p_lead_id, p_dry, p_force, p_now);
end $$;

-- claim_next_opener: from 0143_followups_without_stop.sql, a follow-up to a phone a person owns is skipped (human_owned)
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
  elsif exists (select 1 from public.thread_owners th where th.phone10 = v_phone10) then
    why := 'human_owned';
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
