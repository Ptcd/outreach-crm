-- The agent door (Colin 2026-10-25: "design it agent first"). Two Muse agents reach the app through one MCP server
-- (supabase/functions/agent-mcp): an intake agent loads prospects (address, names, phones, motivation reasons), and
-- a sender agent writes and queues the texts. Muse applies the prospect rules itself; this door only refuses what
-- is never allowed to go out: a phone that opted out or is do-not-contact, a card that is closed, a text with a
-- price, a business name or no STOP line. Every queued text still passes claim_next_opener (the switch, pause,
-- no Sundays, the window, the daily cap, already texted, replied, suppressed) like the laptop's own.
--
-- Muse's cards get negative owner numbers (-1, -2, ...): the laptop keys everything on positive WPIE owner ids and
-- never pushes or pulls a negative one into its own tables.

-- ------------------------------------------------------------------ keys (made by Colin in the app, shown once)
create table if not exists public.agent_keys (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  role        text not null check (role in ('intake', 'sender')),
  key_sha256  text not null unique,
  key_hint    text not null,
  created_at  timestamptz not null default now(),
  created_by  text,
  last_used_at timestamptz,
  revoked_at  timestamptz
);
alter table public.agent_keys enable row level security;   -- no policies: read only through the functions below

create or replace function public.create_agent_key(p_name text, p_role text)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare k text;
begin
  if not public.is_owner() then raise exception 'only Colin can make an agent key'; end if;
  if p_role not in ('intake', 'sender') then raise exception 'role is intake or sender'; end if;
  if coalesce(btrim(p_name), '') = '' then raise exception 'give the key a name'; end if;
  k := 'wpie_' || p_role || '_' || replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  insert into public.agent_keys (name, role, key_sha256, key_hint, created_by)
  values (btrim(p_name), p_role, encode(sha256(convert_to(k, 'UTF8')), 'hex'), right(k, 4), public.wpie_person()::text);
  return k;     -- shown once in the app; only its hash is kept
end $$;

create or replace function public.list_agent_keys()
returns table (id uuid, name text, role text, key_hint text, created_at timestamptz, last_used_at timestamptz, revoked_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_owner() then raise exception 'only Colin can see agent keys'; end if;
  return query select k.id, k.name, k.role, k.key_hint, k.created_at, k.last_used_at, k.revoked_at
                 from public.agent_keys k order by k.created_at desc;
end $$;

create or replace function public.revoke_agent_key(p_id uuid)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if not public.is_owner() then raise exception 'only Colin can turn off an agent key'; end if;
  update public.agent_keys set revoked_at = now() where id = p_id and revoked_at is null;
  return found;
end $$;

-- the MCP server's check: which agent is this, and may it do this?
create or replace function public.agent_key_check(p_key text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare k public.agent_keys;
begin
  select * into k from public.agent_keys
   where key_sha256 = encode(sha256(convert_to(coalesce(p_key, ''), 'UTF8')), 'hex') and revoked_at is null;
  if not found then return jsonb_build_object('ok', false); end if;
  update public.agent_keys set last_used_at = now() where id = k.id;
  return jsonb_build_object('ok', true, 'id', k.id, 'name', k.name, 'role', k.role);
end $$;

revoke all on function public.create_agent_key(text, text), public.list_agent_keys(), public.revoke_agent_key(uuid) from public, anon;
grant execute on function public.create_agent_key(text, text), public.list_agent_keys(), public.revoke_agent_key(uuid) to authenticated;
revoke all on function public.agent_key_check(text) from public, anon, authenticated;
grant execute on function public.agent_key_check(text) to service_role;

-- ------------------------------------------------------------------ prospects
create sequence if not exists public.agent_prospect_seq;
alter table public.leads add column if not exists source text;

create table if not exists public.prospect_reasons (
  id          bigint generated always as identity primary key,
  lead_id     uuid not null references public.leads(id) on delete cascade,
  kind        text not null,
  detail      text,
  event_date  date,
  amount      numeric,
  source      text,
  added_by    text,
  created_at  timestamptz not null default now(),
  unique (lead_id, kind, detail, event_date)
);
alter table public.prospect_reasons enable row level security;
create policy prospect_reasons_team_read on public.prospect_reasons for select to authenticated using (public.is_team());

-- one prospect; merged into an existing Muse card at the same address and owner, else a new card
create or replace function public.agent_add_prospect(p jsonb, p_agent text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  addr   text := upper(regexp_replace(btrim(coalesce(p->>'address', '')), '\s+', ' ', 'g'));
  owner  text := btrim(coalesce(p->>'owner_name', ''));
  lid    uuid;
  status text := 'created';
  ph     jsonb;
  r      jsonb;
  num    text;
  added  jsonb := '[]'::jsonb;
  skipped jsonb := '[]'::jsonb;
  reasons text[];
begin
  if addr = '' then return jsonb_build_object('status', 'rejected', 'reason', 'no address'); end if;
  if owner = '' then return jsonb_build_object('status', 'rejected', 'reason', 'no owner name'); end if;
  select l.id into lid from public.leads l
   where upper(regexp_replace(btrim(coalesce(l.property_address, '')), '\s+', ' ', 'g')) = addr
     and lower(l.owner_name) = lower(owner)
     and (coalesce(p->>'zip', '') = '' or coalesce(l.property_zip, '') = '' or left(l.property_zip, 5) = left(p->>'zip', 5))
   order by l.created_at limit 1;
  select coalesce(array_agg(distinct coalesce(nullif(x->>'label', ''), x->>'kind')), '{}') into reasons
    from jsonb_array_elements(coalesce(p->'reasons', '[]'::jsonb)) x where coalesce(x->>'kind', '') <> '';
  if lid is null then
    insert into public.leads (wpie_owner_id, owner_name, owner_type, mailing_street, mailing_city, mailing_state, mailing_zip,
                              lane, county, municipality, property_address, property_zip, property_type, units,
                              reasons_to_sell, stage, source, notes)
    values (-nextval('public.agent_prospect_seq'), owner, nullif(p->>'owner_type', ''), nullif(p->>'mailing_street', ''),
            nullif(p->>'mailing_city', ''), nullif(p->>'mailing_state', ''), nullif(p->>'mailing_zip', ''),
            case when p->>'lane' = 'hold' then 'hold'::public.lead_lane else 'flip'::public.lead_lane end,
            nullif(p->>'county', ''), nullif(coalesce(p->>'city', p->>'municipality'), ''), btrim(p->>'address'),
            nullif(p->>'zip', ''), nullif(p->>'property_type', ''), nullif(p->>'units', '')::int,
            reasons, 'opener_queued', coalesce(nullif(p->>'source', ''), 'muse'), nullif(p->>'notes', ''))
    returning id into lid;
  else
    status := 'updated';
    update public.leads set reasons_to_sell = (select array_agg(distinct x) from unnest(reasons_to_sell || reasons) x),
           notes = coalesce(nullif(p->>'notes', ''), notes), updated_at = now()
     where id = lid;
  end if;
  for ph in select * from jsonb_array_elements(coalesce(p->'phones', '[]'::jsonb)) loop
    num := right(regexp_replace(coalesce(case when jsonb_typeof(ph) = 'string' then ph #>> '{}' else ph->>'number' end, ''), '\D', '', 'g'), 10);
    if num !~ '^[2-9][0-9]{2}[2-9][0-9]{6}$' then
      skipped := skipped || jsonb_build_object('number', coalesce(ph->>'number', ph #>> '{}'), 'why', 'not a US phone number');
    elsif exists (select 1 from public.contacts c where c.lead_id = lid and c.value_normalized = num) then
      skipped := skipped || jsonb_build_object('number', num, 'why', 'already on this card');
    else
      insert into public.contacts (lead_id, kind, value, value_normalized, person_name, line_type, source, confidence, note)
      values (lid, 'phone', num, num, nullif(ph->>'name', ''), nullif(lower(ph->>'type'), ''), 'muse:' || coalesce(p_agent, 'agent'),
              nullif(ph->>'confidence', '')::numeric, nullif(ph->>'note', ''));
      added := added || to_jsonb(num);
      if exists (select 1 from public.suppressed_phones s where s.phone10 = num) then
        skipped := skipped || jsonb_build_object('number', num, 'why', 'opted out before: kept on the card, never texted');
      end if;
    end if;
  end loop;
  for r in select * from jsonb_array_elements(coalesce(p->'reasons', '[]'::jsonb)) loop
    if coalesce(r->>'kind', '') = '' then continue; end if;
    insert into public.prospect_reasons (lead_id, kind, detail, event_date, amount, source, added_by)
    values (lid, r->>'kind', nullif(r->>'detail', ''), nullif(r->>'date', '')::date, nullif(r->>'amount', '')::numeric,
            nullif(r->>'source', ''), p_agent)
    on conflict do nothing;
  end loop;
  return jsonb_build_object('status', status, 'lead_id', lid, 'phones_added', added, 'phones_skipped', skipped);
end $$;

-- ------------------------------------------------------------------ texts the sender agent writes
create or replace function public.agent_tz(p_state text) returns text language sql immutable as $$
  select case
    when upper(coalesce(p_state, '')) in ('CT','DE','DC','FL','GA','IN','ME','MD','MA','MI','NH','NJ','NY','NC','OH','PA','RI','SC','VT','VA','WV','KY') then 'America/New_York'
    when upper(coalesce(p_state, '')) in ('AZ') then 'America/Phoenix'
    when upper(coalesce(p_state, '')) in ('CO','ID','MT','NM','UT','WY') then 'America/Denver'
    when upper(coalesce(p_state, '')) in ('CA','NV','OR','WA') then 'America/Los_Angeles'
    when upper(coalesce(p_state, '')) = 'AK' then 'America/Anchorage'
    when upper(coalesce(p_state, '')) = 'HI' then 'Pacific/Honolulu'
    else 'America/Chicago' end
$$;

create or replace function public.agent_queue_text(p_lead_id uuid, p_phone text, p_body text, p_step integer,
  p_send_after timestamptz, p_agent text, p_now timestamptz default now())
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
begin
  select * into c from public.campaign_control where id = 1;
  select * into l from public.leads where leads.id = p_lead_id;
  if not found then return jsonb_build_object('status', 'refused', 'reason', 'no such card'); end if;
  if coalesce(p_step, 1) not between 1 and 5 then return jsonb_build_object('status', 'refused', 'reason', 'step is 1 to 5'); end if;
  if l.stage in ('dnc', 'dead', 'closed_no_contact', 'closed_won', 'under_contract') then
    return jsonb_build_object('status', 'refused', 'reason', 'card is closed (' || l.stage::text || ')');
  end if;
  if coalesce(p_step, 1) = 1 and l.stage not in ('postcard_mailed', 'opener_queued') then
    return jsonb_build_object('status', 'refused', 'reason', 'already texted or talking (' || l.stage::text || '): a first text is for a new card');
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
  -- the first moment inside the recipient's window (campaign window hours in their time zone), never a Sunday
  tz := public.agent_tz(coalesce(l.mailing_state, 'WI'));
  t := greatest(p_now, coalesce(p_send_after, p_now));
  for i in 0..8 loop
    d := ((t at time zone tz)::date) + i;
    if c.no_sundays and extract(isodow from d) = 7 then continue; end if;
    ws := (d + c.window_start) at time zone tz;
    we := (d + c.window_end) at time zone tz;
    if we > t then t := greatest(t, ws); exit; end if;
  end loop;
  insert into public.planned_openers (plan_date, wpie_owner_id, attempt, lead_id, lane, template_lane, variant, phone, body,
         segments, scheduled_at, owner_name, property_address, decision, decided_by_name, decided_at, decision_note,
         send_status, window_start_utc, window_end_utc, governing_state, dnc_state, body_sha256, plan_created_at, step)
  values ((t at time zone c.timezone)::date, l.wpie_owner_id, att, l.id, 'agent', 'agent', coalesce(p_agent, 'muse'),
          '+1' || num, b, case when length(b) <= 160 then 1 else 2 end, t, l.owner_name, l.property_address,
          'approved', 'Muse (' || coalesce(p_agent, 'agent') || ')', p_now, 'written and queued by the sender agent',
          'planned', ws, we, upper(coalesce(l.mailing_state, 'WI')), 'unknown', encode(sha256(convert_to(b, 'UTF8')), 'hex'), p_now,
          coalesce(p_step, 1))
  on conflict (plan_date, wpie_owner_id, attempt) do nothing
  returning planned_openers.id into v_id;
  if v_id is null then return jsonb_build_object('status', 'refused', 'reason', 'this card already has that text planned for that day'); end if;
  return jsonb_build_object('status', 'queued', 'text_id', v_id, 'goes_after', t, 'window_ends', we);
end $$;

create or replace function public.agent_withdraw_text(p_id uuid, p_agent text, p_reason text)
returns boolean language plpgsql security definer set search_path = public as $$
declare o public.planned_openers;
begin
  update public.planned_openers set send_status = 'withdrawn', send_reason = coalesce(p_reason, 'withdrawn by the agent'), send_updated_at = now()
   where id = p_id and send_status in ('planned', 'would_send') returning * into o;
  if not found then return false; end if;
  insert into public.opener_send_events (opener_id, plan_date, wpie_owner_id, attempt, event, reason, actor)
  values (o.id, o.plan_date, o.wpie_owner_id, o.attempt, 'withdrawn', o.send_reason, 'Muse (' || coalesce(p_agent, 'agent') || ')');
  return true;
end $$;

revoke all on function public.agent_add_prospect(jsonb, text), public.agent_queue_text(uuid, text, text, integer, timestamptz, text, timestamptz),
  public.agent_withdraw_text(uuid, text, text) from public, anon, authenticated;
grant execute on function public.agent_add_prospect(jsonb, text), public.agent_queue_text(uuid, text, text, integer, timestamptz, text, timestamptz),
  public.agent_withdraw_text(uuid, text, text) to service_role;
