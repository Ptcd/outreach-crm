-- Reopen dead cards whose texts never arrived (Muse for Colin, 2026-10-26). The laptop closes a card as
-- closed_no_contact -> dead (dead_reason no_contact) when every first text bounces, so "always try the next number"
-- could not reach it. Now a first text to another phone reopens such a card, only when the close traces to dead
-- phones alone:
--   1. every earlier first text failed delivery (30003, 30005, 30006, 30008) or went to a phone marked wrong number
--      or bad, and no text to the card was ever delivered;
--   2. nobody ever replied, called in, or talked to the team (texts, inbound calls, call notes), on any phone;
--   3. the card was closed by the laptop (no_contact, never closed by a person in the app) and is not dnc;
--   4. the target phone is a usable mobile on this card, never texted here, and not wrong number / DNC / STOP on
--      any card.
-- On acceptance the card goes back to opener_queued (belt cleared), the text is a next-phone try (attempt 2-9, its
-- follow-ups follow the phone that gets it), and the reopen is written on the card: reopened_at / reopened_reason,
-- a note, a belt event, and the stage event's source. Every other guardrail stands. The laptop sync leaves a reopened
-- card open (wpie/live/sync.py).

alter table public.leads add column if not exists reopened_at timestamptz;
alter table public.leads add column if not exists reopened_reason text;

-- null when a first text to p_phone10 may reopen this dead card; otherwise the refusal
create or replace function public.dead_reopen_problem(p_lead_id uuid, p_phone10 text) returns text
language plpgsql stable security definer set search_path = public as $$
declare
  l      public.leads;
  phones text[];
  bad    text[];
  ct     public.contacts;
begin
  select * into l from public.leads where id = p_lead_id;
  if not found then return 'no such card'; end if;
  if l.stage::text not in ('dead', 'closed_no_contact') then return 'not a closed card'; end if;
  if coalesce(l.dead_reason, '') <> 'no_contact'
     or exists (select 1 from public.lead_stage_events e where e.lead_id = p_lead_id and e.to_stage in ('dead', 'closed_no_contact') and e.source = 'app') then
    return 'card is closed (' || l.stage::text || ')';
  end if;
  select coalesce(array_agg(distinct c.value_normalized), '{}'),
         coalesce(array_agg(distinct c.value_normalized) filter (where c.status::text in ('bad', 'dead')), '{}')
    into phones, bad
    from public.contacts c join public.leads ll on ll.id = c.lead_id
   where ll.wpie_owner_id = l.wpie_owner_id and c.kind = 'phone' and c.value_normalized is not null;
  -- 2. any word from them, on any phone
  if exists (select 1 from public.twilio_inbound t where t.from10 = any(phones))
     or exists (select 1 from public.messages m where m.lead_id = p_lead_id and m.direction = 'in')
     or exists (select 1 from public.messages m where m.lead_id = p_lead_id and m.channel = 'call')
     or exists (select 1 from public.inbound_calls ic where ic.lead_id = p_lead_id or ic.from10 = any(phones))
     or exists (select 1 from public.call_notes cn where cn.lead_id = p_lead_id) then
    return 'card has a reply';
  end if;
  -- 1. every first text bounced; nothing ever delivered
  if not exists (select 1 from public.planned_openers p where p.wpie_owner_id = l.wpie_owner_id and p.step = 1 and p.send_status = any(public.opener_live_statuses()))
     and not exists (select 1 from public.messages m where m.lead_id = p_lead_id and m.direction = 'out' and m.is_opener and m.provider_sid is not null) then
    return 'card is closed (' || l.stage::text || ')';
  end if;
  if exists (select 1 from public.planned_openers p where p.wpie_owner_id = l.wpie_owner_id and p.send_status in ('delivered', 'sent', 'sending', 'uncertain'))
     or exists (select 1 from public.messages m where m.lead_id = p_lead_id and m.direction = 'out' and m.channel = 'sms' and m.status = 'delivered') then
    return 'card is closed (' || l.stage::text || '): a text to it was delivered';
  end if;
  if exists (select 1 from public.planned_openers p where p.wpie_owner_id = l.wpie_owner_id and p.step = 1 and p.send_status = any(public.opener_live_statuses())
               and not (right(regexp_replace(p.phone, '\D', '', 'g'), 10) = any(bad))
               and not (p.send_status in ('undelivered', 'failed') and coalesce(p.error_code, '') in ('30003', '30005', '30006', '30008'))) then
    return 'card is closed (' || l.stage::text || '): an earlier first text failed for another reason (not a dead number)';
  end if;
  -- 4. the target phone
  if exists (select 1 from public.planned_openers p where p.wpie_owner_id = l.wpie_owner_id and right(regexp_replace(p.phone, '\D', '', 'g'), 10) = p_phone10
               and p.send_status = any(public.opener_live_statuses()))
     or exists (select 1 from public.messages m where m.lead_id = p_lead_id and m.direction = 'out' and right(regexp_replace(coalesce(m.to_number, ''), '\D', '', 'g'), 10) = p_phone10) then
    return 'phone already tried on this card';
  end if;
  select * into ct from public.contacts c where c.lead_id = p_lead_id and c.kind = 'phone' and c.value_normalized = p_phone10 order by c.created_at limit 1;
  if not found or ct.status::text <> 'ok' or ct.suppressed or ct.dnc_app or ct.dnc_vendor or coalesce(ct.dnc_scrub::text, '') = 'dnc' then
    return 'phone not textable';
  end if;
  if coalesce(ct.line_type, '') <> 'mobile' then return 'phone not textable (' || coalesce(ct.line_type, 'line type unknown') || ', not a mobile)'; end if;
  if exists (select 1 from public.suppressed_phones s where s.phone10 = p_phone10)
     or exists (select 1 from public.contacts c where c.value_normalized = p_phone10
                  and (c.status::text in ('bad', 'dead') or c.suppressed or c.dnc_app or c.dnc_vendor or coalesce(c.dnc_scrub::text, '') = 'dnc')) then
    return 'phone not textable (wrong number, DNC or STOP on a card)';
  end if;
  return null;
end $$;
revoke all on function public.dead_reopen_problem(uuid, text) from public, anon, authenticated;
grant execute on function public.dead_reopen_problem(uuid, text) to service_role;

-- a reopened card that is withdrawn and queued again (stage opener_queued, earlier first texts bounced) is still a next-phone try
create or replace function public.next_phone_problem(p_lead_id uuid, p_phone10 text) returns text
language plpgsql stable security definer set search_path = public as $$
declare
  l      public.leads;
  phones text[];
  bad    text[];
  firsts integer;
begin
  select * into l from public.leads where id = p_lead_id;
  if not found then return 'no such card'; end if;
  if l.stage::text not in ('opener_queued', 'opener_sent', 'reply_received', 'data_fix') then
    return 'a first text is for a new card';
  end if;
  select coalesce(array_agg(distinct ct.value_normalized), '{}'),
         coalesce(array_agg(distinct ct.value_normalized) filter (where ct.status::text in ('bad', 'dead')), '{}')
    into phones, bad
    from public.contacts ct join public.leads ll on ll.id = ct.lead_id
   where ll.wpie_owner_id = l.wpie_owner_id and ct.kind = 'phone' and ct.value_normalized is not null;
  with f as (
    select right(regexp_replace(p.phone, '\D', '', 'g'), 10) ph, p.send_status st from public.planned_openers p
     where p.wpie_owner_id = l.wpie_owner_id and p.step = 1 and p.send_status = any(public.opener_live_statuses())
    union all
    select right(regexp_replace(m.to_number, '\D', '', 'g'), 10), m.status from public.messages m
     where m.lead_id = p_lead_id and m.direction = 'out' and m.is_opener and m.provider_sid is not null)
  select count(*) into firsts from f;
  if firsts = 0 then return 'a first text is for a new card'; end if;
  if exists (select 1 from public.planned_openers p where p.wpie_owner_id = l.wpie_owner_id and p.step = 1
               and p.send_status = any(public.opener_live_statuses()) and right(regexp_replace(p.phone, '\D', '', 'g'), 10) = p_phone10)
     or exists (select 1 from public.messages m where m.lead_id = p_lead_id and m.direction = 'out' and m.is_opener and m.provider_sid is not null
               and right(regexp_replace(m.to_number, '\D', '', 'g'), 10) = p_phone10) then
    return 'this phone already had its first text';
  end if;
  if exists (select 1 from public.planned_openers p where p.wpie_owner_id = l.wpie_owner_id and p.step = 1
               and p.send_status in ('sending', 'sent', 'delivered', 'uncertain')
               and not (right(regexp_replace(p.phone, '\D', '', 'g'), 10) = any(bad)))
     or exists (select 1 from public.messages m where m.lead_id = p_lead_id and m.direction = 'out' and m.is_opener and m.provider_sid is not null
               and coalesce(m.status, '') not in ('undelivered', 'failed')
               and not (right(regexp_replace(m.to_number, '\D', '', 'g'), 10) = any(bad))) then
    return 'an earlier first text may have arrived (wait for its delivery result, or mark that phone wrong_number)';
  end if;
  if exists (select 1 from public.twilio_inbound t where t.from10 = any(phones) and not (t.from10 = any(bad)))
     or exists (select 1 from public.messages m where m.lead_id = p_lead_id and m.direction = 'in' and m.channel = 'sms'
                  and not (right(regexp_replace(coalesce(m.from_number, ''), '\D', '', 'g'), 10) = any(bad))) then
    return 'they texted back from a good phone';
  end if;
  return null;
end $$;

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

revoke all on function public.agent_queue_text(uuid, text, text, integer, timestamptz, text, timestamptz, text, text, text) from public, anon, authenticated;
grant execute on function public.agent_queue_text(uuid, text, text, integer, timestamptz, text, timestamptz, text, text, text) to service_role;
