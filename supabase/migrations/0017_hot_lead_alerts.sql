-- Hot-lead alerts (Colin 2026-10-22: "Yeah we need the app to notify my phone"). When a seller's
-- reply shows interest or asks about selling, Colin's cell gets a text within about a minute, sent
-- through pm-phone's PM line (never a seller number). If the lead is not marked called 15 minutes
-- later, one more text; at 7 PM Central, one line listing today's hot leads still not called.
-- Speed to lead = first call time minus the first hot reply time, on the lead card.
-- Alerts wait for 8 AM in quiet hours (21:00-08:00 Central), like the other notifications.

alter table public.leads add column if not exists hot_at timestamptz;   -- latest hot reply

create table if not exists public.hot_alerts (
  id           uuid primary key default gen_random_uuid(),
  inbound_sid  text not null unique,
  lead_id      uuid references public.leads (id) on delete cascade,
  phone10      text not null,
  first_name   text,
  address      text,
  body         text not null,
  is_test      boolean not null default false,
  created_at   timestamptz not null default now(),
  alert1_at    timestamptz,
  alert2_at    timestamptz,
  alert1_sid   text,
  called_at    timestamptz,     -- first call logged (or "I called them") after this reply: speed to lead
  last_error   text
);
create index if not exists hot_alerts_open_idx on public.hot_alerts (created_at) where alert2_at is null;
alter table public.hot_alerts enable row level security;
create policy hot_alerts_read on public.hot_alerts for select to authenticated using (public.is_team());
grant select on public.hot_alerts to authenticated;
grant select, insert, update on public.hot_alerts to service_role;

alter table public.campaign_control add column if not exists hot_digest_date date;

-- The reply agent saw a hot reply (service_role). Once per inbound text.
create or replace function public.hot_record(p_sid text, p_lead_id uuid, p_phone10 text, p_first_name text, p_address text,
  p_body text, p_is_test boolean default false, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare id uuid;
begin
  insert into public.hot_alerts (inbound_sid, lead_id, phone10, first_name, address, body, is_test, created_at)
  values (p_sid, p_lead_id, p_phone10, nullif(btrim(coalesce(p_first_name, '')), ''), nullif(btrim(coalesce(p_address, '')), ''),
          left(coalesce(p_body, ''), 500), coalesce(p_is_test, false), p_now)
  on conflict (inbound_sid) do nothing
  returning hot_alerts.id into id;
  if id is not null and p_lead_id is not null then
    update public.leads set hot_at = p_now where leads.id = p_lead_id;
  end if;
  return jsonb_build_object('ok', id is not null, 'id', id);
end $$;

-- Alerts to text now: first alerts, and second alerts 15+ minutes later for leads not called since.
-- Each is marked as it is handed out (never twice). Nothing in quiet hours.
create or replace function public.hot_claim(p_now timestamptz default now(), p_limit integer default 10)
returns jsonb language plpgsql security definer set search_path = public as $$
declare out jsonb := '[]'::jsonb; a record; called boolean;
begin
  if public.in_quiet_hours(p_now) then return out; end if;
  for a in
    select h.* from public.hot_alerts h
     where (h.alert1_at is null and h.created_at > p_now - interval '12 hours' and h.called_at is null)
        or (h.alert1_at is not null and h.alert2_at is null and h.alert1_at <= p_now - interval '15 minutes'
            and h.created_at > p_now - interval '12 hours')
     order by h.created_at limit p_limit
     for update skip locked
  loop
    called := a.called_at is not null;
    if a.alert1_at is null then
      update public.hot_alerts set alert1_at = p_now where id = a.id;
      out := out || jsonb_build_object('id', a.id, 'n', 1, 'lead_id', a.lead_id, 'phone10', a.phone10, 'first_name', a.first_name,
                                       'address', a.address, 'body', a.body, 'is_test', a.is_test);
    elsif not coalesce(called, false) then
      update public.hot_alerts set alert2_at = p_now where id = a.id;
      out := out || jsonb_build_object('id', a.id, 'n', 2, 'lead_id', a.lead_id, 'phone10', a.phone10, 'first_name', a.first_name,
                                       'address', a.address, 'body', a.body, 'is_test', a.is_test);
    else
      update public.hot_alerts set alert2_at = p_now, last_error = 'called - no second alert' where id = a.id;
    end if;
  end loop;
  return out;
end $$;

create or replace function public.hot_result(p_id uuid, p_sid text, p_error text)
returns void language sql security definer set search_path = public as $$
  update public.hot_alerts set alert1_sid = coalesce(alert1_sid, p_sid), last_error = p_error where id = p_id
$$;

-- 7 PM Central once a day: today's hot leads not called yet (empty list = nothing to send).
create or replace function public.hot_digest(p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare c public.campaign_control; today date := (p_now at time zone 'America/Chicago')::date; out jsonb;
begin
  if extract(hour from p_now at time zone 'America/Chicago') < 19 then return null; end if;
  select * into c from public.campaign_control where id = 1 for update;
  if c.hot_digest_date = today then return null; end if;
  update public.campaign_control set hot_digest_date = today where id = 1;
  select coalesce(jsonb_agg(jsonb_build_object('first_name', x.first_name, 'address', x.address, 'phone10', x.phone10,
                                               'lead_id', x.lead_id) order by x.created_at), '[]'::jsonb) into out
    from (select distinct on (coalesce(h.lead_id::text, h.phone10)) h.* from public.hot_alerts h
          where (h.created_at at time zone 'America/Chicago')::date = today and not h.is_test and h.called_at is null
          order by coalesce(h.lead_id::text, h.phone10), h.created_at) x;
  return out;
end $$;

-- "I called them" on the lead card (and every logged call): speed to lead.
create or replace function public.mark_called(p_lead_id uuid, p_at timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_team() then raise exception 'team only'; end if;
  update public.hot_alerts set called_at = p_at where lead_id = p_lead_id and called_at is null and created_at <= p_at;
  return jsonb_build_object('ok', true);
end $$;

-- log_call (0013) also stamps the call on every open hot reply of that lead.
create or replace function public.leads_first_call_from_log() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.channel = 'call' and new.lead_id is not null then
    update public.hot_alerts set called_at = new.sent_at where lead_id = new.lead_id and called_at is null and created_at <= new.sent_at;
  end if;
  return new;
end $$;
drop trigger if exists messages_first_call on public.messages;
create trigger messages_first_call after insert on public.messages
  for each row execute function public.leads_first_call_from_log();

revoke all on function public.hot_record(text, uuid, text, text, text, text, boolean, timestamptz), public.hot_claim(timestamptz, integer),
  public.hot_result(uuid, text, text), public.hot_digest(timestamptz) from public, anon, authenticated;
grant execute on function public.hot_record(text, uuid, text, text, text, text, boolean, timestamptz), public.hot_claim(timestamptz, integer),
  public.hot_result(uuid, text, text), public.hot_digest(timestamptz) to service_role;
revoke all on function public.mark_called(uuid, timestamptz) from public, anon;
grant execute on function public.mark_called(uuid, timestamptz) to authenticated;
