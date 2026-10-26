-- Colin's Google Calendar behind the booking (2026-10-26): the Muse texting agent offers a seller Colin's real open
-- times and books one; the booked call or visit is an event on his calendar, and the card moves the same way the app's
-- own booking moves it (belt_event 'next_step' -> call_booked / visit_booked, named_date at the slot).
--   calendar_link      the one Google connection: the OAuth client and the refresh token, both sealed (AES-GCM) by the
--                      calendar Edge Function with the CALENDAR_TOKEN_KEY secret; no one but the service role reads it
--   calendar_rules     the hours Colin takes calls and visits, slot lengths, the buffer, notice and how far ahead
--   calendar_bookings  one row per booked call or visit: the slot, the Google event, holding -> booked -> cancelled/done
-- No double booking: calendar_hold takes one lock for every booking, refuses a slot that overlaps (with the buffer) any
-- other booking or live hold, and the Edge Function re-checks Google free/busy after the hold and before the event.
-- Colin moving or deleting the event flows back to the card: calendar_sync_apply, run every 10 minutes by pg_cron.

create table if not exists public.calendar_link (
  id                 integer primary key default 1 check (id = 1),
  client_id          text,
  client_secret_enc  text,
  refresh_token_enc  text,
  google_email       text,
  scopes             text,
  calendar_id        text not null default 'primary',
  calendar_name      text,
  busy_calendar_ids  text[] not null default '{primary}',
  connected_at       timestamptz,
  connected_by       text,
  last_sync_at       timestamptz,
  last_error         text,
  last_error_at      timestamptz,
  updated_at         timestamptz not null default now()
);
insert into public.calendar_link (id) values (1) on conflict (id) do nothing;

create table if not exists public.calendar_oauth_states (
  state_sha256  text primary key,
  return_to     text not null,
  created_by    text,
  created_at    timestamptz not null default now(),
  used_at       timestamptz
);

create table if not exists public.calendar_rules (
  id                  integer primary key default 1 check (id = 1),
  time_zone           text not null default 'America/Chicago',
  call_hours          jsonb not null default '{"mon":[["09:00","17:00"]],"tue":[["09:00","17:00"]],"wed":[["09:00","17:00"]],"thu":[["09:00","17:00"]],"fri":[["09:00","17:00"]],"sat":[["09:00","12:00"]]}',
  visit_hours         jsonb not null default '{"mon":[["10:00","16:00"]],"tue":[["10:00","16:00"]],"wed":[["10:00","16:00"]],"thu":[["10:00","16:00"]],"fri":[["10:00","16:00"]],"sat":[["09:00","12:00"]]}',
  call_minutes        integer not null default 30 check (call_minutes between 10 and 180),
  visit_minutes       integer not null default 60 check (visit_minutes between 15 and 240),
  buffer_minutes      integer not null default 15 check (buffer_minutes between 0 and 120),
  min_notice_minutes  integer not null default 120 check (min_notice_minutes between 0 and 2880),
  days_ahead          integer not null default 14 check (days_ahead between 1 and 60),
  updated_at          timestamptz not null default now(),
  updated_by          text
);
insert into public.calendar_rules (id) values (1) on conflict (id) do nothing;

create table if not exists public.calendar_bookings (
  id                  uuid primary key default gen_random_uuid(),
  lead_id             uuid not null references public.leads(id) on delete cascade,
  kind                text not null check (kind in ('call', 'visit')),
  starts_at           timestamptz not null,
  ends_at             timestamptz not null check (ends_at > starts_at),
  status              text not null default 'holding' check (status in ('holding', 'booked', 'cancelled', 'done', 'failed')),
  hold_expires_at     timestamptz,
  google_calendar_id  text,
  google_event_id     text,
  html_link           text,
  booked_by           text,
  notes               jsonb,
  cancelled_reason    text,
  last_synced_at      timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create index if not exists calendar_bookings_live_lead on public.calendar_bookings (lead_id) where status in ('holding', 'booked');
create index if not exists calendar_bookings_live_time on public.calendar_bookings (starts_at) where status in ('holding', 'booked');

alter table public.calendar_link enable row level security;
alter table public.calendar_oauth_states enable row level security;
alter table public.calendar_rules enable row level security;
alter table public.calendar_bookings enable row level security;
revoke all on public.calendar_link, public.calendar_oauth_states, public.calendar_rules from public, anon, authenticated;
revoke all on public.calendar_bookings from public, anon, authenticated;
grant select on public.calendar_bookings to authenticated;
drop policy if exists calendar_bookings_team_read on public.calendar_bookings;
create policy calendar_bookings_team_read on public.calendar_bookings for select to authenticated using (public.is_team());

-- ------------------------------------------------------------------ the hours, checked
-- {"mon": [["09:00","17:00"]], ...}: days sun..sat, each a list of [start, end] in 24-hour HH:MM, start before end.
create or replace function public.calendar_hours_ok(p jsonb) returns boolean language plpgsql immutable as $$
declare k text; w jsonb;
begin
  if p is null or jsonb_typeof(p) <> 'object' then return false; end if;
  for k in select jsonb_object_keys(p) loop
    if k not in ('sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat') or jsonb_typeof(p->k) <> 'array' then return false; end if;
    for w in select jsonb_array_elements(p->k) loop
      if jsonb_typeof(w) <> 'array' or jsonb_array_length(w) <> 2 then return false; end if;
      if coalesce(w->>0, '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' or coalesce(w->>1, '') !~ '^([01][0-9]|2[0-4]):[0-5][0-9]$' then return false; end if;
      if (w->>0) >= (w->>1) or (w->>1) > '24:00' then return false; end if;
    end loop;
  end loop;
  return true;
end $$;

-- ------------------------------------------------------------------ Colin, in the app
create or replace function public.calendar_settings(p_now timestamptz default now())
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare k public.calendar_link; r public.calendar_rules;
begin
  if not public.is_owner() then raise exception 'only Colin can see the calendar settings'; end if;
  select * into k from public.calendar_link where id = 1;
  select * into r from public.calendar_rules where id = 1;
  return jsonb_build_object(
    'client_ready', k.client_id is not null and k.client_secret_enc is not null,
    'connected', k.refresh_token_enc is not null,
    'google_email', k.google_email, 'calendar_id', k.calendar_id, 'calendar_name', k.calendar_name,
    'busy_calendar_ids', to_jsonb(k.busy_calendar_ids), 'connected_at', k.connected_at,
    'last_sync_at', k.last_sync_at, 'last_error', k.last_error, 'last_error_at', k.last_error_at,
    'rules', to_jsonb(r) - 'id',
    'upcoming', coalesce((select jsonb_agg(jsonb_build_object('booking_id', b.id, 'lead_id', b.lead_id, 'kind', b.kind,
                    'starts_at', b.starts_at, 'ends_at', b.ends_at, 'owner_name', l.owner_name, 'address', l.property_address,
                    'html_link', b.html_link, 'booked_by', b.booked_by) order by b.starts_at)
                  from public.calendar_bookings b join public.leads l on l.id = b.lead_id
                 where b.status = 'booked' and b.ends_at > p_now), '[]'::jsonb));
end $$;

create or replace function public.calendar_set_rules(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.calendar_rules; n integer;
begin
  if not public.is_owner() then raise exception 'only Colin can change the booking hours'; end if;
  select * into r from public.calendar_rules where id = 1 for update;
  if p ? 'call_hours' then
    if not public.calendar_hours_ok(p->'call_hours') then raise exception 'call hours: each day needs a start before its end (HH:MM)'; end if;
    r.call_hours := p->'call_hours';
  end if;
  if p ? 'visit_hours' then
    if not public.calendar_hours_ok(p->'visit_hours') then raise exception 'visit hours: each day needs a start before its end (HH:MM)'; end if;
    r.visit_hours := p->'visit_hours';
  end if;
  if p ? 'time_zone' then
    if p->>'time_zone' not in ('America/Chicago', 'America/New_York', 'America/Denver', 'America/Los_Angeles') then raise exception 'time zone: a US zone'; end if;
    r.time_zone := p->>'time_zone';
  end if;
  r.call_minutes := coalesce((p->>'call_minutes')::integer, r.call_minutes);
  r.visit_minutes := coalesce((p->>'visit_minutes')::integer, r.visit_minutes);
  r.buffer_minutes := coalesce((p->>'buffer_minutes')::integer, r.buffer_minutes);
  r.min_notice_minutes := coalesce((p->>'min_notice_minutes')::integer, r.min_notice_minutes);
  r.days_ahead := coalesce((p->>'days_ahead')::integer, r.days_ahead);
  update public.calendar_rules set time_zone = r.time_zone, call_hours = r.call_hours, visit_hours = r.visit_hours,
         call_minutes = r.call_minutes, visit_minutes = r.visit_minutes, buffer_minutes = r.buffer_minutes,
         min_notice_minutes = r.min_notice_minutes, days_ahead = r.days_ahead, updated_at = now(),
         updated_by = coalesce(public.wpie_person()::text, 'owner')
   where id = 1;
  return public.calendar_settings();
end $$;

-- which calendar the bookings go on, and which calendars count as busy (it always includes the booking calendar)
create or replace function public.calendar_choose(p_calendar_id text, p_calendar_name text, p_busy text[])
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_owner() then raise exception 'only Colin can pick the calendar'; end if;
  if coalesce(btrim(p_calendar_id), '') = '' then raise exception 'pick a calendar'; end if;
  update public.calendar_link set calendar_id = btrim(p_calendar_id), calendar_name = nullif(btrim(coalesce(p_calendar_name, '')), ''),
         busy_calendar_ids = (select array_agg(distinct x) from unnest(coalesce(p_busy, '{}') || array[btrim(p_calendar_id)]) x where coalesce(x, '') <> ''),
         updated_at = now()
   where id = 1;
  return public.calendar_settings();
end $$;

-- ------------------------------------------------------------------ the Edge Function (service role)
create or replace function public.calendar_runtime()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('connected', k.refresh_token_enc is not null, 'client_id', k.client_id, 'client_secret_enc', k.client_secret_enc,
           'refresh_token_enc', k.refresh_token_enc, 'google_email', k.google_email, 'calendar_id', k.calendar_id,
           'busy_calendar_ids', to_jsonb(k.busy_calendar_ids), 'rules', to_jsonb(r) - 'id')
    from public.calendar_link k, public.calendar_rules r where k.id = 1 and r.id = 1
$$;

create or replace function public.calendar_store_client(p_client_id text, p_secret_enc text, p_by text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if coalesce(p_client_id, '') !~ '\.apps\.googleusercontent\.com$' or coalesce(p_secret_enc, '') = '' then
    return jsonb_build_object('ok', false, 'reason', 'that is not a Google OAuth client');
  end if;
  -- a new client invalidates the old refresh token: connect again
  update public.calendar_link set client_id = p_client_id, client_secret_enc = p_secret_enc,
         refresh_token_enc = case when client_id is distinct from p_client_id then null else refresh_token_enc end,
         connected_by = coalesce(p_by, connected_by), updated_at = now()
   where id = 1;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.calendar_oauth_start(p_state_sha256 text, p_return_to text, p_by text)
returns void language sql security definer set search_path = public as $$
  delete from public.calendar_oauth_states where created_at < now() - interval '1 day';
  insert into public.calendar_oauth_states (state_sha256, return_to, created_by) values (p_state_sha256, p_return_to, p_by);
$$;

-- the state Google sends back: good once, for 15 minutes; returns where to send Colin back to
create or replace function public.calendar_oauth_finish(p_state_sha256 text)
returns text language plpgsql security definer set search_path = public as $$
declare s public.calendar_oauth_states;
begin
  update public.calendar_oauth_states set used_at = now()
   where state_sha256 = p_state_sha256 and used_at is null and created_at > now() - interval '15 minutes'
  returning * into s;
  return s.return_to;
end $$;

create or replace function public.calendar_store_token(p_refresh_enc text, p_email text, p_scopes text, p_by text)
returns void language sql security definer set search_path = public as $$
  update public.calendar_link set refresh_token_enc = coalesce(p_refresh_enc, refresh_token_enc),
         google_email = coalesce(p_email, google_email), scopes = coalesce(p_scopes, scopes),
         connected_at = now(), connected_by = coalesce(p_by, connected_by), last_error = null, last_error_at = null, updated_at = now()
   where id = 1;
$$;

create or replace function public.calendar_disconnect_clear()
returns void language sql security definer set search_path = public as $$
  update public.calendar_link set refresh_token_enc = null, google_email = null, scopes = null, connected_at = null,
         last_error = null, last_error_at = null, updated_at = now() where id = 1;
$$;

create or replace function public.calendar_note(p_error text, p_synced boolean default false)
returns void language sql security definer set search_path = public as $$
  update public.calendar_link set last_error = left(p_error, 500), last_error_at = case when p_error is null then last_error_at else now() end,
         last_sync_at = case when p_synced then now() else last_sync_at end
   where id = 1;
$$;

-- our own bookings and live holds in a window, other than one card's (Google already shows booked events; a hold is not
-- on Google yet, so this is what keeps two agents off the same slot)
create or replace function public.calendar_busy(p_from timestamptz, p_to timestamptz, p_except_lead uuid default null, p_now timestamptz default now())
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('start', b.starts_at, 'end', b.ends_at) order by b.starts_at), '[]'::jsonb)
    from public.calendar_bookings b
   where (b.status = 'booked' or (b.status = 'holding' and b.hold_expires_at > p_now))
     and b.lead_id is distinct from p_except_lead and b.starts_at < p_to and b.ends_at > p_from
$$;

create or replace function public.calendar_hold(p_lead_id uuid, p_kind text, p_start timestamptz, p_end timestamptz, p_by text,
                                                p_notes jsonb default null, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare l public.leads; buf interval; clash public.calendar_bookings; old public.calendar_bookings; bid uuid;
begin
  perform pg_advisory_xact_lock(hashtext('wpie_calendar_booking'));
  select * into l from public.leads where id = p_lead_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card'); end if;
  if p_kind not in ('call', 'visit') then return jsonb_build_object('ok', false, 'reason', 'kind is call or visit'); end if;
  if l.stage in ('dnc', 'dead', 'closed_won', 'closed_no_contact') or l.belt in ('dnc', 'dead') then
    return jsonb_build_object('ok', false, 'reason', format('this card is closed (%s): nothing to book', coalesce(l.belt, l.stage::text)));
  end if;
  if l.elderly_or_ill or l.grief then
    return jsonb_build_object('ok', false, 'reason', 'an older, ill or grieving owner: the team calls them at their pace. mark_card note and tell Colin instead');
  end if;
  if p_start <= p_now or p_end <= p_start then return jsonb_build_object('ok', false, 'reason', 'that time has passed'); end if;
  select make_interval(mins => buffer_minutes) into buf from public.calendar_rules where id = 1;
  select * into clash from public.calendar_bookings b
   where (b.status = 'booked' or (b.status = 'holding' and b.hold_expires_at > p_now)) and b.lead_id <> p_lead_id
     and b.starts_at < p_end + buf and b.ends_at > p_start - buf
   limit 1;
  if found then return jsonb_build_object('ok', false, 'reason', 'that time was just taken'); end if;
  select * into old from public.calendar_bookings b where b.lead_id = p_lead_id and b.status = 'booked' and b.ends_at > p_now
   order by b.starts_at desc limit 1;
  update public.calendar_bookings set status = 'failed', cancelled_reason = 'a newer hold', updated_at = p_now
   where lead_id = p_lead_id and status = 'holding';
  insert into public.calendar_bookings (lead_id, kind, starts_at, ends_at, status, hold_expires_at, booked_by, notes)
  values (p_lead_id, p_kind, p_start, p_end, 'holding', p_now + interval '3 minutes', p_by, p_notes)
  returning id into bid;
  return jsonb_build_object('ok', true, 'booking_id', bid,
    'replaces', case when old.id is null then null else jsonb_build_object('booking_id', old.id, 'calendar_id', old.google_calendar_id,
                     'event_id', old.google_event_id, 'start', old.starts_at, 'end', old.ends_at) end);
end $$;

create or replace function public.calendar_release(p_booking_id uuid, p_reason text)
returns void language sql security definer set search_path = public as $$
  update public.calendar_bookings set status = 'failed', cancelled_reason = left(p_reason, 300), updated_at = now()
   where id = p_booking_id and status = 'holding';
$$;

-- the event is on Google: the hold is a booking, an older booking of the card is replaced, and the card moves the way
-- the app's booking moves it (next_step -> call_booked / visit_booked, named_date at the slot)
create or replace function public.calendar_confirm(p_booking_id uuid, p_calendar_id text, p_event_id text, p_html_link text, p_by text,
                                                   p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare b public.calendar_bookings; res jsonb; tz text; l public.leads;
begin
  select * into b from public.calendar_bookings where id = p_booking_id for update;
  if not found or b.status <> 'holding' then return jsonb_build_object('ok', false, 'reason', 'the hold is gone'); end if;
  update public.calendar_bookings set status = 'booked', google_calendar_id = p_calendar_id, google_event_id = p_event_id,
         html_link = p_html_link, hold_expires_at = null, updated_at = p_now
   where id = b.id;
  update public.calendar_bookings set status = 'cancelled', cancelled_reason = 'moved to a new time', updated_at = p_now
   where lead_id = b.lead_id and id <> b.id and status = 'booked';
  res := public.belt_event(b.lead_id, 'next_step',
           jsonb_build_object('at', b.starts_at, 'kind', case when b.kind = 'visit' then 'walk' else 'call' end, 'source', 'calendar', 'booking_id', b.id),
           p_by, p_now);
  select time_zone into tz from public.calendar_rules where id = 1;
  update public.leads set notes = concat_ws(' | ', notes, format('%s booked Colin''s %s for %s', coalesce(p_by, 'agent'), b.kind,
           to_char(b.starts_at at time zone tz, 'Dy Mon FMDD FMHH12:MI AM')))
   where id = b.lead_id;
  select * into l from public.leads where id = b.lead_id;
  return coalesce(res, '{}'::jsonb) || jsonb_build_object('booking_id', b.id, 'stage', l.stage, 'belt', l.belt, 'named_date', l.named_date);
end $$;

create or replace function public.calendar_active_booking(p_lead_id uuid, p_now timestamptz default now())
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('booking_id', b.id, 'kind', b.kind, 'start', b.starts_at, 'end', b.ends_at,
           'calendar_id', b.google_calendar_id, 'event_id', b.google_event_id)
    from public.calendar_bookings b where b.lead_id = p_lead_id and b.status = 'booked' and b.ends_at > p_now
   order by b.starts_at desc limit 1
$$;

-- a booking is off (the agent cancelled it, or Colin deleted the event): the card goes back to "said yes, not booked",
-- whose first stop is a person calling to set a new time, unless the card has already moved on from this booking
create or replace function public.calendar_cancel(p_booking_id uuid, p_reason text, p_by text, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare b public.calendar_bookings; l public.leads; res jsonb;
begin
  select * into b from public.calendar_bookings where id = p_booking_id for update;
  if not found or b.status not in ('booked', 'holding') then return jsonb_build_object('ok', false, 'reason', 'no live booking'); end if;
  update public.calendar_bookings set status = 'cancelled', cancelled_reason = left(coalesce(p_reason, 'cancelled'), 300), updated_at = p_now
   where id = b.id;
  select * into l from public.leads where id = b.lead_id for update;
  if l.belt in ('call_booked', 'visit_booked', 'call_missed', 'visit_missed') and l.named_date = b.starts_at then
    res := public.belt_event(b.lead_id, 'move', jsonb_build_object('belt', 'yes_unbooked',
             'reason', left(coalesce(p_reason, 'the booking was cancelled') || ': set a new time', 300), 'source', 'calendar'), p_by, p_now);
    update public.leads set named_date = null, named_event = null where id = b.lead_id;
  end if;
  select * into l from public.leads where id = b.lead_id;
  return jsonb_build_object('ok', true, 'booking_id', b.id, 'stage', l.stage, 'belt', l.belt, 'card_moved', res is not null);
end $$;

-- ------------------------------------------------------------------ Colin edits the event: the sync
create or replace function public.calendar_sync_targets(p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  update public.calendar_bookings set status = 'done', updated_at = p_now where status = 'booked' and ends_at < p_now - interval '1 day';
  update public.calendar_bookings set status = 'failed', cancelled_reason = coalesce(cancelled_reason, 'hold expired'), updated_at = p_now
   where status = 'holding' and hold_expires_at < p_now - interval '10 minutes';
  return coalesce((select jsonb_agg(jsonb_build_object('booking_id', b.id, 'calendar_id', b.google_calendar_id, 'event_id', b.google_event_id,
                     'start', b.starts_at, 'end', b.ends_at) order by b.starts_at)
                     from public.calendar_bookings b where b.status = 'booked' and b.google_event_id is not null), '[]'::jsonb);
end $$;

-- p_what: same | moved (p_start, p_end are the event's new times) | cancelled
create or replace function public.calendar_sync_apply(p_booking_id uuid, p_what text, p_start timestamptz, p_end timestamptz,
                                                      p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare b public.calendar_bookings; l public.leads; res jsonb; who text := 'Google Calendar';
begin
  select * into b from public.calendar_bookings where id = p_booking_id for update;
  if not found or b.status <> 'booked' then return jsonb_build_object('ok', false, 'reason', 'no live booking'); end if;
  if p_what = 'cancelled' then
    return public.calendar_cancel(b.id, 'taken off Colin''s calendar', who, p_now) || jsonb_build_object('what', 'cancelled');
  elsif p_what = 'moved' and p_start is not null and p_end > p_start and (p_start, p_end) is distinct from (b.starts_at, b.ends_at) then
    update public.calendar_bookings set starts_at = p_start, ends_at = p_end, last_synced_at = p_now, updated_at = p_now where id = b.id;
    select * into l from public.leads where id = b.lead_id for update;
    if l.belt in ('call_booked', 'visit_booked', 'call_missed', 'visit_missed') and l.named_date = b.starts_at then
      res := public.belt_event(b.lead_id, 'next_step', jsonb_build_object('at', p_start, 'kind', case when b.kind = 'visit' then 'walk' else 'call' end,
               'source', 'calendar', 'booking_id', b.id, 'note', 'Colin moved it on his calendar'), who, p_now);
    end if;
    select * into l from public.leads where id = b.lead_id;
    return jsonb_build_object('ok', true, 'what', 'moved', 'booking_id', b.id, 'belt', l.belt, 'named_date', l.named_date, 'card_moved', res is not null);
  end if;
  update public.calendar_bookings set last_synced_at = p_now where id = b.id;
  return jsonb_build_object('ok', true, 'what', 'same', 'booking_id', b.id);
end $$;

-- ------------------------------------------------------------------ access
revoke all on function public.calendar_hours_ok(jsonb), public.calendar_settings(timestamptz), public.calendar_set_rules(jsonb),
  public.calendar_choose(text, text, text[]), public.calendar_runtime(), public.calendar_store_client(text, text, text),
  public.calendar_oauth_start(text, text, text), public.calendar_oauth_finish(text), public.calendar_store_token(text, text, text, text),
  public.calendar_disconnect_clear(), public.calendar_note(text, boolean), public.calendar_busy(timestamptz, timestamptz, uuid, timestamptz),
  public.calendar_hold(uuid, text, timestamptz, timestamptz, text, jsonb, timestamptz), public.calendar_release(uuid, text),
  public.calendar_confirm(uuid, text, text, text, text, timestamptz), public.calendar_active_booking(uuid, timestamptz),
  public.calendar_cancel(uuid, text, text, timestamptz), public.calendar_sync_targets(timestamptz),
  public.calendar_sync_apply(uuid, text, timestamptz, timestamptz, timestamptz)
  from public, anon, authenticated;
grant execute on function public.calendar_hours_ok(jsonb), public.calendar_settings(timestamptz), public.calendar_set_rules(jsonb),
  public.calendar_choose(text, text, text[]) to authenticated, service_role;
grant execute on function public.calendar_runtime(), public.calendar_store_client(text, text, text),
  public.calendar_oauth_start(text, text, text), public.calendar_oauth_finish(text), public.calendar_store_token(text, text, text, text),
  public.calendar_disconnect_clear(), public.calendar_note(text, boolean), public.calendar_busy(timestamptz, timestamptz, uuid, timestamptz),
  public.calendar_hold(uuid, text, timestamptz, timestamptz, text, jsonb, timestamptz), public.calendar_release(uuid, text),
  public.calendar_confirm(uuid, text, text, text, text, timestamptz), public.calendar_active_booking(uuid, timestamptz),
  public.calendar_cancel(uuid, text, text, timestamptz), public.calendar_sync_targets(timestamptz),
  public.calendar_sync_apply(uuid, text, timestamptz, timestamptz, timestamptz)
  to service_role;

-- ------------------------------------------------------------------ the sync timer (every 10 minutes)
-- To stop it: select cron.unschedule('wpie-calendar-sync');
do $do$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron')
     and exists (select 1 from pg_extension where extname = 'pg_net')
     and to_regclass('vault.decrypted_secrets') is not null then
    if exists (select 1 from cron.job where jobname = 'wpie-calendar-sync') then perform cron.unschedule('wpie-calendar-sync'); end if;
    perform cron.schedule(
      'wpie-calendar-sync',
      '3,13,23,33,43,53 * * * *',
      $job$
      select net.http_post(
        url := 'https://jyfetargyaaxcqmxdgft.supabase.co/functions/v1/calendar',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'x-wpie-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'send_openers_cron_secret')),
        body := '{"action":"sync"}'::jsonb,
        timeout_milliseconds := 55000);
      $job$);
  end if;
end
$do$;
