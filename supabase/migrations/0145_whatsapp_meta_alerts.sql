-- 0145: WhatsApp missed-call alerts through Meta's Cloud API (Colin's build spec 2026-10-30; Meta side done).
--   * whatsapp_alerts: one row per attempt (sent / failed / skipped while the template is not APPROVED / pending),
--     with Meta's message id or the error; the admin surface reads it. whatsapp_alert_begin suppresses a second alert
--     to the same caller for the same card (or the same unknown number) within 15 minutes.
--   * meta_wa_template_status: the template review status, cached so the function polls Meta at most every 10 minutes.
--   * inbound_call_log: a call from a number no card knows is now STORED as a bare inbound_calls row (lead_id null) so
--     the caller on shift still gets the alert with the number and "unknown property" (spec item 5). Nothing else is
--     written for it: no message, no task, no belt.
--   * missed_calls_to_alert: includes those bare rows; the person is the call-back task's owner, else
--     missed_call_person (who dialed the number out, else the shift).

create table if not exists public.whatsapp_alerts (
  id          uuid primary key default gen_random_uuid(),
  at          timestamptz not null default now(),
  call_sid    text,
  lead_id     uuid references public.leads (id) on delete set null,
  from10      text,
  person      text,
  to_wa       text,
  template    text not null default 'missed_call_alert',
  status      text not null,            -- pending / sent / failed / skipped
  message_id  text,
  error       text,
  params      jsonb,
  finished_at timestamptz
);
create index if not exists whatsapp_alerts_recent_idx on public.whatsapp_alerts (person, at desc);
alter table public.whatsapp_alerts enable row level security;
drop policy if exists whatsapp_alerts_team_read on public.whatsapp_alerts;
create policy whatsapp_alerts_team_read on public.whatsapp_alerts for select to authenticated using (public.is_team());

create table if not exists public.meta_wa_template_status (
  name       text primary key,
  status     text not null,
  checked_at timestamptz not null default now()
);

create or replace function public.meta_wa_template_get(p_name text) returns jsonb
language sql stable security definer set search_path = public as $$
  select to_jsonb(t) - 'name' from public.meta_wa_template_status t where t.name = p_name
$$;
create or replace function public.meta_wa_template_set(p_name text, p_status text) returns void
language sql security definer set search_path = public as $$
  insert into public.meta_wa_template_status (name, status, checked_at) values (p_name, p_status, now())
  on conflict (name) do update set status = excluded.status, checked_at = now()
$$;

-- one alert per caller per card (or per unknown number) per 15 minutes, the same call included: a skipped send
-- (template not approved) or a pending one holds the slot so a retry every minute does not log a row every minute
create or replace function public.whatsapp_alert_begin(p_call_sid text, p_lead_id uuid, p_from10 text, p_person text, p_to text, p_params jsonb default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare prev public.whatsapp_alerts; v_id uuid;
begin
  select * into prev from public.whatsapp_alerts w
   where w.person = p_person and w.at > now() - interval '15 minutes' and w.status in ('sent', 'skipped', 'pending')
     and ((p_lead_id is not null and w.lead_id = p_lead_id) or (p_lead_id is null and w.lead_id is null and w.from10 = p_from10))
   order by w.at desc limit 1;
  if found then
    return jsonb_build_object('ok', false, 'reason', case when prev.status = 'sent' then 'duplicate' else 'recent_' || prev.status end, 'prior_id', prev.id);
  end if;
  insert into public.whatsapp_alerts (call_sid, lead_id, from10, person, to_wa, status, params)
  values (p_call_sid, p_lead_id, p_from10, p_person, p_to, 'pending', p_params) returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

create or replace function public.whatsapp_alert_finish(p_id uuid, p_status text, p_message_id text default null, p_error text default null) returns void
language sql security definer set search_path = public as $$
  update public.whatsapp_alerts set status = p_status, message_id = p_message_id, error = left(p_error, 400), finished_at = now() where id = p_id
$$;

revoke all on function public.meta_wa_template_get(text), public.meta_wa_template_set(text, text),
  public.whatsapp_alert_begin(text, uuid, text, text, text, jsonb), public.whatsapp_alert_finish(uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.meta_wa_template_get(text), public.meta_wa_template_set(text, text),
  public.whatsapp_alert_begin(text, uuid, text, text, text, jsonb), public.whatsapp_alert_finish(uuid, text, text, text) to service_role;

-- bare rows for unknown callers come through too; the person is the task owner, else who dialed / the shift
create or replace function public.missed_calls_to_alert(p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'call_sid', ic.call_sid, 'lead_id', ic.lead_id, 'from10', ic.from10, 'at', ic.created_at, 'voicemail', ic.voicemail,
      'vm_verdict', ic.vm_verdict, 'owner_name', l.owner_name, 'address', l.property_address, 'municipality', l.municipality,
      'person', who.p::text, 'email', nullif(btrim(m.alert_email), ''), 'whatsapp', nullif(btrim(m.alert_whatsapp), ''), 'display_name', m.display_name)
      order by ic.created_at), '[]'::jsonb)
    from public.inbound_calls ic
    left join public.tasks t on t.id = ic.task_id
    left join public.leads l on l.id = ic.lead_id
    cross join lateral (select coalesce(t.owner, public.missed_call_person(ic.from10, ic.created_at)) as p) who
    join public.team_members m on m.person = who.p
   where ic.status = 'missed' and ic.alerted_at is null
     and ic.created_at > p_now - interval '6 hours' and ic.created_at <= p_now
     and who.p in ('thalia', 'adil')
$$;

-- inbound_call_log: from 0144_missed_call_person.sql, unknown callers stored as bare rows
create or replace function public.inbound_call_log(p_call_sid text, p_from text, p_to text, p_event text,
  p_duration integer default null, p_transcript text default null, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare d text := right(regexp_replace(coalesce(p_from, ''), '\D', '', 'g'), 10);
  line text := right(regexp_replace(coalesce(p_to, ''), '\D', '', 'g'), 10);
  ic public.inbound_calls; l public.leads; lid uuid; others text; blocked jsonb; who public.team_person;
  mid uuid; tid uuid; key text; res jsonb; prev text; head text; tnote text; words text; at_txt text;
begin
  if coalesce(p_call_sid, '') !~ '^CA[0-9A-Fa-f]{32}$' then return jsonb_build_object('ok', false, 'reason', 'bad call id'); end if;
  if p_event not in ('answered', 'missed', 'voicemail', 'transcript') then return jsonb_build_object('ok', false, 'reason', 'bad event'); end if;
  if d !~ '^[0-9]{10}$' then return jsonb_build_object('ok', true, 'matched', false, 'reason', 'no caller number'); end if;

  select * into ic from public.inbound_calls where call_sid = p_call_sid for update;
  if found then
    lid := ic.lead_id;
    if lid is null then
      insert into public.inbound_calls (call_sid, lead_id, from10, to_number, status, voicemail, created_at, updated_at)
      values (p_call_sid, null, d, nullif(p_to, ''), case when p_event = 'answered' then 'answered' else 'missed' end, p_event = 'voicemail', p_now, p_now)
      on conflict (call_sid) do update set status = case when excluded.status = 'answered' then 'answered' else public.inbound_calls.status end,
        voicemail = public.inbound_calls.voicemail or excluded.voicemail, updated_at = p_now;
      return jsonb_build_object('ok', true, 'matched', false, 'stored', true);
    end if;
  else
    -- the card this caller belongs to: the one they texted from, then the one we last texted them on, then any card
    -- with the number (open cards first)
    select c.lead_id into lid from public.contacts c join public.leads x on x.id = c.lead_id
     where c.kind = 'phone' and c.value_normalized = d
     order by (select max(t.received_at) from public.twilio_inbound t where t.lead_id = c.lead_id and t.from10 = d) desc nulls last,
              (select max(m.sent_at) from public.messages m where m.lead_id = c.lead_id and m.direction = 'out' and m.channel = 'sms'
                 and m.to_number in (d, '+1' || d)) desc nulls last,
              (x.belt in ('dead', 'dnc') or x.stage in ('dead', 'dnc', 'closed_no_contact')) asc, x.updated_at desc
     limit 1;
    if lid is null then
      select t.lead_id into lid from public.twilio_inbound t where t.from10 = d and t.lead_id is not null order by t.received_at desc limit 1;
    end if;
    if lid is null then
      insert into public.inbound_calls (call_sid, lead_id, from10, to_number, status, voicemail, created_at, updated_at)
      values (p_call_sid, null, d, nullif(p_to, ''), case when p_event = 'answered' then 'answered' else 'missed' end, p_event = 'voicemail', p_now, p_now)
      on conflict (call_sid) do update set status = case when excluded.status = 'answered' then 'answered' else public.inbound_calls.status end,
        voicemail = public.inbound_calls.voicemail or excluded.voicemail, updated_at = p_now;
      return jsonb_build_object('ok', true, 'matched', false, 'stored', true);
    end if;
  end if;

  select * into l from public.leads where id = lid for update;
  at_txt := to_char(coalesce(ic.created_at, p_now) at time zone 'America/Chicago', 'Dy Mon DD HH12:MI AM');
  head := format('%s called %s', public.belt_fmt_phone(d),
                 case when line ~ '^[0-9]{10}$' then 'our ' || public.belt_fmt_phone(line) else 'us' end);

  if ic.call_sid is null then
    -- first word of this call
    blocked := public.phone_is_blocked(d);
    insert into public.inbound_calls (call_sid, lead_id, from10, to_number, status, created_at, updated_at)
    values (p_call_sid, lid, d, nullif(p_to, ''),
            case when p_event = 'answered' then 'answered'
                 when coalesce((blocked->>'blocked')::boolean, false) or l.belt = 'dnc' or l.stage = 'dnc' then 'blocked'
                 else 'missed' end, p_now, p_now)
    returning * into ic;
    insert into public.messages (lead_id, direction, channel, body, from_number, to_number, source_key, status, sent_at)
    values (lid, 'in', 'call',
            case when ic.status = 'answered' then format('Call from %s, answered%s', head,
                                                         case when coalesce(p_duration, 0) > 0 then format(' (%s min %s s)', p_duration / 60, p_duration % 60) else '' end)
                 when ic.status = 'blocked' then format('Missed call: %s. Not called back (%s); the card stays closed.', head,
                                                        coalesce(nullif(blocked->>'reason', ''), 'do not contact'))
                 else format('Missed call: %s. Call them back.', head) end,
            '+1' || d, nullif(p_to, ''), 'icall:' || p_call_sid,
            case when ic.status = 'answered' then 'inbound_answered' else 'inbound_missed' end, p_now)
    returning id into mid;
    update public.inbound_calls set message_id = mid where call_sid = p_call_sid;
    ic.message_id := mid;

    if ic.status = 'missed' then
      select string_agg(distinct coalesce(x.property_address, x.owner_name), '; ') into others
        from public.contacts c join public.leads x on x.id = c.lead_id
       where c.kind = 'phone' and c.value_normalized = d and c.lead_id <> lid;
      tnote := format('%s at %s and did not get anyone. Call them back now.', head, at_txt)
            || coalesce(' Same number is also on: ' || others || '.', '');
      if l.elderly_or_ill or l.grief then
        who := 'colin';
        tnote := tnote || ' Older, ill or grieving: family on the line, their pace, no deadlines.';
      else
        who := public.missed_call_person(d, p_now);
      end if;
      if l.belt in ('call_booked', 'visit_booked', 'offer_out', 'elderly') or l.elderly_or_ill or l.grief
         or l.stage in ('walkthrough_booked', 'offer', 'under_contract', 'closed_won') then
        -- the card is further along: keep its belt, the call-back is a task of its own
        insert into public.tasks (lead_id, due_at, kind, owner, note, title, source, source_key, phone10, created_by)
        values (lid, p_now, 'call', who, tnote, 'They called us: call back', 'inbound_call', 'icall:' || p_call_sid, d, null)
        on conflict (source_key) do update set note = excluded.note
        returning id into tid;
        insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
        values (lid, 'they_called', l.belt, l.belt, l.belt_step,
                jsonb_build_object('key', 'icall:' || p_call_sid, 'phone', d, 'task_id', tid, 'note', 'card kept its belt'), p_now, 'phone line');
      else
        prev := current_setting('wpie.in_belt_event', true);
        perform set_config('wpie.in_belt_event', '1', true);
        res := public.belt_enter(lid, 'yes_unbooked', 1, 'they_called',
                 jsonb_build_object('key', 'icall:' || p_call_sid, 'phone', d, 'said', 'They called us'), 'phone line', p_now);
        perform set_config('wpie.in_belt_event', coalesce(prev, ''), true);
        select * into l from public.leads where id = lid;
        if coalesce((res->>'ok')::boolean, false) and l.belt = 'yes_unbooked' then
          key := format('belt:%s:%s:%s:%s', lid, l.belt, l.belt_round, l.belt_step);
          -- the belt's stop is the call-back: due now, on whoever is on shift (the belt would slide it to its own
          -- calling hours and give it to the weekday/weekend caller regardless of the hour)
          update public.tasks t set due_at = p_now, owner = who, kind = 'call', title = 'They called us: call back',
                 phone10 = d, done_at = null,
                 note = tnote
           where t.source_key = key
           returning t.id into tid;
          if tid is null then
            insert into public.tasks (lead_id, due_at, kind, owner, note, title, source, source_key, phone10, created_by)
            values (lid, p_now, 'call', who, tnote, 'They called us: call back', 'belt', key, d, null)
            returning id into tid;
          end if;
          perform set_config('wpie.in_belt_event', '1', true);
          update public.leads set next_stop_at = p_now,
                 next_stop_who = case when who = 'colin' then 'colin_call' else 'thalia_call' end,
                 next_stop_say = 'They called us: call back now', next_action = 'They called us: call back',
                 next_action_at = p_now, assigned_to = who
           where id = lid;
          perform set_config('wpie.in_belt_event', coalesce(prev, ''), true);
        end if;
      end if;
      update public.inbound_calls set task_id = tid where call_sid = p_call_sid;
      ic.task_id := tid;
    end if;
  elsif p_event = 'answered' and ic.status = 'missed' then
    -- Twilio does not send "answered" after "missed" for one call; nothing to undo
    null;
  end if;

  if p_event = 'voicemail' and not ic.voicemail then
    words := format('Left a voicemail%s.', case when coalesce(p_duration, 0) > 0 then format(' (%s s)', p_duration) else '' end);
    update public.inbound_calls set voicemail = true, updated_at = p_now where call_sid = p_call_sid;
    update public.messages set body = body || E'\n' || words where id = ic.message_id;
    update public.tasks set note = coalesce(note, '') || E'\n' || words where id = ic.task_id;
  elsif p_event = 'transcript' and not ic.transcribed then
    words := coalesce(nullif(btrim(left(coalesce(p_transcript, ''), 2000)), ''), '');
    words := case when words = '' then 'Voicemail: (no transcription; the recording is in Colin''s email)'
                  else 'Voicemail: "' || words || '"' end;
    update public.inbound_calls set voicemail = true, transcribed = true, updated_at = p_now where call_sid = p_call_sid;
    update public.messages set body = body || E'\n' || words where id = ic.message_id;
    update public.tasks set note = coalesce(note, '') || E'\n' || words where id = ic.task_id;
  end if;

  return jsonb_build_object('ok', true, 'matched', true, 'lead_id', lid, 'status', ic.status, 'task_id', ic.task_id,
                            'owner', (select owner::text from public.tasks where id = ic.task_id));
end $$;
