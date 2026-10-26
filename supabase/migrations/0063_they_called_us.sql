-- They called us (2026-10-24: two sellers called the texting numbers and left voicemails, one with his address and
-- cell, one asking for a text back; nobody acted for hours, because pm-phone only rang Colin's cell and emailed him).
-- pm-phone now reports every call to a seller line from a phone on a card, through public.inbound_call_log
-- (service role only):
--   * answered  -> the call is logged on the card. Nothing moves: whoever answered logs the outcome as usual.
--   * missed    -> logged on the card, and the card moves to "Said yes, not booked" (yes_unbooked, "they called us")
--                  with a call-back task due now for whoever is on shift: Thalia Mon-Fri 9-5 CT, Adil Sat-Sun 8-8 CT,
--                  else Colin. A card with a call or visit booked, an offer out, a contract, or an older/ill/grieving
--                  owner keeps its belt; the call-back is a task of its own (Colin's, for an older/ill/grieving owner).
--   * voicemail -> the recording finished: the card and the task say a voicemail was left.
--   * transcript-> the voicemail's words go into the task note and the card's call entry. Only there: nothing else
--                  (belt_events, inbound_calls) keeps them.
-- A number that texted STOP, is do-not-contact, suppressed or marked bad, or a card already on DNC: the call is
-- logged on the card and nothing else happens (the card is not reopened, no task). A number on no card: nothing is
-- written and pm-phone behaves as before.
-- Each Twilio callback is safe to repeat: one row per call in inbound_calls keyed by the CallSid.

create table if not exists public.inbound_calls (
  call_sid     text primary key,
  lead_id      uuid references public.leads (id) on delete cascade,
  from10       text not null,
  to_number    text,
  status       text not null,                -- answered / missed / blocked
  voicemail    boolean not null default false,
  transcribed  boolean not null default false,
  task_id      uuid references public.tasks (id) on delete set null,
  message_id   uuid references public.messages (id) on delete set null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index if not exists inbound_calls_lead_idx on public.inbound_calls (lead_id, created_at desc);
alter table public.inbound_calls enable row level security;
create policy inbound_calls_team_read on public.inbound_calls for select to authenticated using (public.is_team());

-- Who takes a call-back right now (Colin 2026-10-26): Thalia Mon-Fri 9:00-17:00, Adil Sat-Sun 8:00-20:00 (Central),
-- Colin the rest of the time.
create or replace function public.on_shift_person(p_at timestamptz default now())
returns public.team_person language sql stable as $$
  select case
    when extract(isodow from p_at at time zone 'America/Chicago') between 1 and 5
         and (p_at at time zone 'America/Chicago')::time >= time '09:00' and (p_at at time zone 'America/Chicago')::time < time '17:00'
      then 'thalia'
    when extract(isodow from p_at at time zone 'America/Chicago') >= 6
         and (p_at at time zone 'America/Chicago')::time >= time '08:00' and (p_at at time zone 'America/Chicago')::time < time '20:00'
      then 'adil'
    else 'colin' end::public.team_person
$$;

-- An inbound call on the card is a call entry, not an outcome: it must not mark a hot alert "called" (that is our
-- call to them). Same as before for every other call entry.
create or replace function public.leads_first_call_from_log()
 returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if new.channel = 'call' and new.lead_id is not null and coalesce(new.status, '') not like 'inbound\_%' then
    update public.hot_alerts set called_at = new.sent_at where lead_id = new.lead_id and called_at is null and created_at <= new.sent_at;
  end if;
  return new;
end $$;

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
    if lid is null then return jsonb_build_object('ok', true, 'matched', false); end if;
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
        who := public.on_shift_person(p_now);
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

revoke all on function public.inbound_call_log(text, text, text, text, integer, text, timestamptz) from public, anon, authenticated;
grant execute on function public.inbound_call_log(text, text, text, text, integer, text, timestamptz) to service_role;
revoke all on function public.on_shift_person(timestamptz) from public, anon;
grant execute on function public.on_shift_person(timestamptz) to authenticated, service_role;
grant select on public.inbound_calls to authenticated;
grant all on public.inbound_calls to service_role;
