-- 0198: once Adil or Thalia text anything on a card, the AI stops on that card for good, and no guards apply to the
-- caller's own texts (Colin, 2026-11-07: "once adil or thalia text anything then the ai must stop and no guards apply").
--
-- The AI here is every automatic voice on a thread: the sender agent (Muse: send_reply, queue_texts) and the reply agent
-- (routine lines, the hostile line, the who-are-we line). A caller's sent team text on the card, on any phone, ever,
-- turns them all off for that card; 0197's seven-day window is gone. What stays is the law, not a guard: a phone that
-- sent STOP (opted out) is never texted by anyone, and a STOP on a caller's thread is still honoured. A 'hostile' read
-- by the reply agent on a caller's thread no longer blocks anything: the caller decides what the text meant.
--
-- The caller's own text (send_card_text) now goes through reply_claim_send in mode 'team': no wording rule (price,
-- company name, postcard), no staleness check, no quiet hours, no 480-character cap (1500 keeps Twilio honest).

create or replace function public.caller_texting(p_lead_id uuid) returns text
language sql stable security definer set search_path = public as $$
  select d.decided_by from public.reply_drafts d
   where d.lead_id = p_lead_id and d.draft_source = 'team' and d.status = 'sent' and not coalesce(d.is_test, false)
   order by d.sent_at desc nulls last limit 1
$$;
create or replace function public.caller_texting(p_lead_id uuid, p_phone10 text) returns text
language sql stable security definer set search_path = public as $$
  select public.caller_texting(p_lead_id)
$$;
revoke all on function public.caller_texting(uuid), public.caller_texting(uuid, text) from public, anon;
grant execute on function public.caller_texting(uuid), public.caller_texting(uuid, text) to authenticated, service_role;

-- the sender agent
create or replace function public.agent_start_reply(p_lead_id uuid, p_phone text, p_agent text) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  l public.leads;
  p text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10);
  li public.twilio_inbound;
  id uuid;
  who text;
begin
  select * into l from public.leads where leads.id = p_lead_id;
  if not found then raise exception 'no such card'; end if;
  if l.stage = 'dnc' then raise exception 'this card is closed (do not contact)'; end if;
  if exists (select 1 from public.suppressed_phones s where s.phone10 = p) then raise exception 'this phone opted out'; end if;
  who := public.caller_texting(p_lead_id);
  if who is not null then
    raise exception '% has texted this card themselves: the card is theirs now, leave it to them', who;
  end if;
  select * into li from public.twilio_inbound t where t.from10 = p and t.lead_id = p_lead_id order by t.received_at desc limit 1;
  if not found then raise exception 'they have not texted us from that phone: a first text or follow-up goes through queue_texts'; end if;
  insert into public.reply_drafts (phone10, our_number, lead_id, inbound_body, inbound_at, intent, kind, outcome, note, draft_source, status, notified_at)
  values (p, li.to_number, p_lead_id, li.body, now(), 'agent_reply', 'team', 'open', 'written by the sender agent (' || coalesce(p_agent, 'agent') || ')',
          'agent', 'awaiting_approval', now())
  returning reply_drafts.id into id;
  return id;
end $$;


create or replace function public.agent_replies_waiting(p_days integer default 7) returns jsonb
language sql stable security definer set search_path = public as $$
  with last_in as (
    select distinct on (t.from10) t.from10, t.lead_id, t.sid, t.body, t.received_at, t.to_number
      from public.twilio_inbound t
     where t.received_at > now() - make_interval(days => greatest(1, least(p_days, 30))) and t.lead_id is not null
     order by t.from10, t.received_at desc)
  select coalesce(jsonb_agg(public.agent_card(li.lead_id) || jsonb_build_object(
           'reply_to', jsonb_build_object('phone', li.from10, 'our_number', li.to_number, 'text', li.body, 'at', li.received_at),
           'reply_agent_read', (select jsonb_build_object('intent', d.intent, 'outcome', d.outcome, 'suggested_reply', d.body, 'note', d.note)
                                  from public.reply_drafts d where d.inbound_sid = li.sid),
           'hot', exists (select 1 from public.hot_alerts h where h.lead_id = li.lead_id and h.created_at > now() - interval '3 days'))
         order by li.received_at), '[]'::jsonb)
    from last_in li join public.leads l on l.id = li.lead_id
   where l.stage not in ('dnc', 'dead', 'closed_no_contact', 'closed_won')
     and not exists (select 1 from public.suppressed_phones s where s.phone10 = li.from10)
     and public.caller_texting(li.lead_id) is null                     -- a caller's card is the caller's
     and not exists (select 1 from public.messages m where m.direction = 'out' and m.channel = 'sms' and m.sent_at > li.received_at
                      and right(regexp_replace(coalesce(m.to_number, ''), '\D', '', 'g'), 10) = li.from10)
     and not exists (select 1 from public.reply_drafts d where d.phone10 = li.from10 and d.inbound_at >= li.received_at
                      and d.status in ('queued', 'sending', 'sent'))
$$;

create or replace function public.agent_queue_text(p_lead_id uuid, p_phone text, p_body text, p_step integer,
  p_send_after timestamptz, p_agent text, p_now timestamptz default now(), p_variant text default null, p_template text default null,
  p_slot text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
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
begin
  select * into c from public.campaign_control where id = 1;
  select * into l from public.leads where leads.id = p_lead_id;
  if not found then return jsonb_build_object('status', 'refused', 'reason', 'no such card'); end if;
  if public.caller_texting(p_lead_id) is not null then
    return jsonb_build_object('status', 'refused', 'reason', public.caller_texting(p_lead_id) || ' has texted this card themselves: the card is theirs now, no more texts from the system');
  end if;
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
  if exists (select 1 from public.twilio_inbound ti where ti.from10 = num) then
    return jsonb_build_object('status', 'refused', 'reason', 'they already texted back: replies go to the reply agent and the team');
  end if;
  if b = '' or position('STOP' in b) = 0 then return jsonb_build_object('status', 'refused', 'reason', 'the text needs a STOP line'); end if;
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
    'next_phone', coalesce(p_step, 1) = 1 and att > 1, 'reopened', reopen);
end $$;


-- the reply agent
create or replace function public.reply_record_decision(p_sid text, p_intent text, p_kind text, p_removal boolean, p_outcome text, p_body text, p_draft_source text, p_note text, p_rules_version text, p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  t public.twilio_inbound;
  c public.campaign_control;
  st text;
  did uuid;
  owner_phones text[];
  oid bigint;
  who text;
  removal boolean := p_removal;
begin
  select * into t from public.twilio_inbound where sid = p_sid;
  if not found then return jsonb_build_object('ok', false, 'reason', 'unknown_inbound'); end if;
  select * into c from public.campaign_control where id = 1;
  update public.reply_drafts set status = 'superseded', updated_at = p_now
   where phone10 = t.from10 and status in ('awaiting_approval', 'would_send', 'queued') and inbound_at < t.received_at;

  who := public.caller_texting(t.lead_id);
  if who is not null then
    -- a caller has texted this card: the AI is off it for good (Colin 2026-11-07). Nothing is queued or sent by the
    -- reply agent; a suggested line is kept for the caller to see. A STOP is still law; a 'hostile' read is not.
    if removal and p_intent <> 'opt_out' then removal := false; end if;
  end if;
  st := case
    when who is not null then case when p_kind = 'candidate' or coalesce(btrim(p_body), '') <> '' then 'awaiting_approval' else 'no_reply' end
    -- the sender agent answers (agent_runs_texting): read, recorded, nothing queued and nothing for the team to approve
    when c.agent_runs_texting then 'no_reply'
    when p_body is null or btrim(p_body) = '' then case when p_kind = 'candidate' then 'awaiting_approval' else 'no_reply' end
    when p_kind = 'candidate' then 'awaiting_approval'
    when c.routine_enabled then 'queued'
    else 'would_send' end;
  insert into public.reply_drafts (inbound_sid, phone10, our_number, lead_id, inbound_body, inbound_at, intent, kind, outcome,
                                   note, body, draft_source, status, send_after, rules_version, created_at, updated_at)
  values (t.sid, t.from10, t.to_number, t.lead_id, t.body, t.received_at, p_intent, p_kind, p_outcome, p_note,
          nullif(btrim(coalesce(p_body, '')), ''), p_draft_source, st,
          case when st = 'queued' then public.auto_reply_at(p_now) else null end,
          p_rules_version, p_now, p_now)
  on conflict (inbound_sid) do nothing
  returning id into did;
  if did is null then return jsonb_build_object('ok', false, 'reason', 'already_decided'); end if;

  oid := (select l.wpie_owner_id from public.leads l where l.id = t.lead_id);
  if removal and p_outcome = 'wrong_number' then
    -- not the owner, asked to stop: this phone only; the card stays open for the owner's other numbers
    perform public.block_wrong_person_phone(t.lead_id, t.from10, 'reply_agent');
    update public.leads set stage = 'data_fix' where id = t.lead_id and stage in ('postcard_mailed', 'opener_queued', 'opener_sent', 'reply_received');
  elsif removal then
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
  elsif who is not null and p_removal and not removal then
    null;   -- the caller decides what a hostile text means
  elsif p_outcome = 'not_interested' then
    update public.leads set stage = 'dead', dead_reason = coalesce(nullif(p_note, ''), 'not interested')
     where id = t.lead_id and stage in ('postcard_mailed', 'opener_queued', 'opener_sent', 'reply_received', 'ai_qualifying');
  else
    update public.leads set stage = case when p_kind = 'candidate' then 'reply_received'::public.lead_stage else 'ai_qualifying'::public.lead_stage end
     where id = t.lead_id and stage in ('postcard_mailed', 'opener_queued', 'opener_sent');
  end if;
  update public.leads set last_inbound_at = greatest(coalesce(last_inbound_at, t.received_at), t.received_at) where id = t.lead_id;
  return jsonb_build_object('ok', true, 'id', did, 'status', st);
end $function$;


-- the caller's own text
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
  elsif p_mode = 'team' then
    -- a caller's own text from the card (Colin 2026-11-07: once Adil or Thalia text, no guards apply). Only the law
    -- stays: a phone that opted out is never texted (checked below). No wording rule, no staleness, no quiet hours.
    if d.status not in ('awaiting_approval', 'would_send', 'no_reply', 'dry_sent') then
      return jsonb_build_object('outcome', 'refused', 'reason', 'already ' || d.status);
    end if;
  elsif p_mode = 'approve' then
    if d.status not in ('awaiting_approval', 'would_send', 'no_reply', 'dry_sent') then
      return jsonb_build_object('outcome', 'refused', 'reason', 'already ' || d.status);
    end if;
  else
    raise exception 'unknown mode %', p_mode;
  end if;
  b := btrim(coalesce(case when p_mode in ('approve', 'team') then p_body end, d.body, ''));
  if b = '' then return jsonb_build_object('outcome', 'refused', 'reason', 'empty reply'); end if;
  if length(b) > 480 and p_mode <> 'team' then return jsonb_build_object('outcome', 'refused', 'reason', 'over 480 characters'); end if;
  if length(b) > 1500 then return jsonb_build_object('outcome', 'refused', 'reason', 'over 1500 characters'); end if;
  -- a newer text from them makes this reply stale
  if p_mode <> 'team' and exists (select 1 from public.twilio_inbound i where i.from10 = d.phone10 and i.received_at > d.inbound_at) then
    update public.reply_drafts set status = 'superseded', updated_at = p_now where id = d.id;
    return jsonb_build_object('outcome', 'refused', 'reason', 'they texted again after this draft - see the newer one');
  end if;
  -- after a removal only the removal confirmation itself may go
  if d.kind <> 'removal' and exists (select 1 from public.suppressed_phones s where s.phone10 = d.phone10) then
    update public.reply_drafts set status = 'skipped', note = coalesce(note, '') || ' | phone opted out', updated_at = p_now where id = d.id;
    return jsonb_build_object('outcome', 'refused', 'reason', 'this phone opted out');
  end if;
  if p_mode <> 'team' and public.in_quiet_hours(p_now) then
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


revoke all on function public.agent_replies_waiting(integer), public.agent_start_reply(uuid, text, text) from public, anon, authenticated;
grant execute on function public.agent_replies_waiting(integer), public.agent_start_reply(uuid, text, text) to service_role;
revoke all on function public.agent_queue_text(uuid, text, text, integer, timestamptz, text, timestamptz, text, text, text) from public, anon, authenticated;
grant execute on function public.agent_queue_text(uuid, text, text, integer, timestamptz, text, timestamptz, text, text, text) to service_role;
