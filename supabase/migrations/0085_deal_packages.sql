-- The package (Colin 2026-10-27, the partner model run Rick's way): a caller's first call never prices; it ends in a
-- package on the card. Colin gets it by email with everything in it, Muse adds the value and comps, Colin sets the
-- number, the caller delivers it on the callback ("around {number}, once my partner sees it") and books the walk.
-- Nothing can sit unseen: each state has its own owner and its own deadline.
--   waiting_value   sent by the caller; Muse pulls the value and comps (Colin can price without them)
--   waiting_number  Colin's turn: same day
--   number_ready    the caller's turn: the callback at the time promised
--   counter         the seller countered on the callback: back to Colin
--   agreed          yes or close: the caller books the walk
--   walk_booked / declined / dead
-- The funnel (packages -> valued -> priced -> delivered -> agreed -> walks) is counted by where the lead came from:
-- hot_text, inbound or cold_list (Colin: "8 should be done somehow").

create table if not exists public.deal_packages (
  id              uuid primary key default gen_random_uuid(),
  lead_id         uuid not null references public.leads(id) on delete cascade,
  interest_id     uuid references public.interests(id) on delete set null,
  source          text not null default 'cold_list' check (source in ('hot_text', 'inbound', 'cold_list', 'other')),
  status          text not null default 'waiting_value' check (status in ('waiting_value', 'waiting_number', 'number_ready', 'counter',
                    'agreed', 'walk_booked', 'declined', 'dead')),
  hot             boolean not null default false,
  need            text,
  condition       jsonb not null default '{}',     -- the checklist: roof, hvac, water_heater, foundation, electrical, plumbing, windows, kitchen_baths, yard, fix_first, other
  timeline        text,
  their_number    text,
  their_basis     text,
  on_title        text,
  owed            text,
  occupancy       text,
  photos          text,
  other_buyers    text,
  concerns        text,
  motivation      text,
  callback_at     timestamptz,
  walk_booked_on_call boolean not null default false,
  created_by      public.team_person,
  created_at      timestamptz not null default now(),
  -- Muse: the value
  arv             numeric,
  arv_basis       text,
  comps           jsonb,
  valued_by       text,
  valued_at       timestamptz,
  -- Colin: the number
  our_number      numeric,
  number_note     text,
  grade           text check (grade in ('A', 'B', 'C')),
  priced_at       timestamptz,
  -- the callback
  said_number     numeric,
  delivered_at    timestamptz,
  delivered_by    public.team_person,
  response        text check (response in ('yes', 'close', 'counter', 'no')),
  counter_number  numeric,
  response_note   text,
  -- mail and pings
  emailed_at      timestamptz,
  email_error     text,
  ready_pinged_at timestamptz,
  updated_at      timestamptz not null default now()
);
create index if not exists deal_packages_open_idx on public.deal_packages (status, created_at) where status in ('waiting_value', 'waiting_number', 'number_ready', 'counter', 'agreed');
create index if not exists deal_packages_lead_idx on public.deal_packages (lead_id);
create unique index if not exists deal_packages_one_open on public.deal_packages (lead_id)
  where status in ('waiting_value', 'waiting_number', 'number_ready', 'counter', 'agreed');
alter table public.deal_packages enable row level security;
create policy deal_packages_team on public.deal_packages for select to authenticated using (public.is_team());
create trigger deal_packages_touch before update on public.deal_packages for each row execute function public.touch_updated_at();

-- where a lead came from, for the funnel
create or replace function public.lead_source_kind(p_lead_id uuid) returns text language sql stable security definer set search_path = public as $$
  select case
    when exists (select 1 from public.inbound_calls ic where ic.lead_id = p_lead_id) then 'inbound'
    when exists (select 1 from public.twilio_inbound t where t.lead_id = p_lead_id and not t.is_opt_out) then 'hot_text'
    else 'cold_list' end
$$;

-- the caller sends the package: everything on the card, a callback task at the time promised (or the walk booked)
create or replace function public.package_submit(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid; who public.team_person := public.wpie_person(); lid uuid := nullif(p->>'lead_id', '')::uuid; cb timestamptz := nullif(p->>'callback_at', '')::timestamptz;
        walk boolean := coalesce((p->>'walk_booked_on_call')::boolean, false); l public.leads;
begin
  if not public.is_team() then raise exception 'only the team sends packages'; end if;
  select * into l from public.leads where id = lid;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card'); end if;
  if coalesce(btrim(p->>'need'), '') = '' and coalesce(p->'condition', '{}'::jsonb) = '{}'::jsonb then
    return jsonb_build_object('ok', false, 'reason', 'a package needs their reason or the condition, in their words');
  end if;
  if cb is null and not walk then return jsonb_build_object('ok', false, 'reason', 'set the callback time you promised (or say the walk is booked)'); end if;
  if exists (select 1 from public.deal_packages d where d.lead_id = lid and d.status in ('waiting_value', 'waiting_number', 'number_ready', 'counter', 'agreed')) then
    return jsonb_build_object('ok', false, 'reason', 'this card already has an open package');
  end if;
  insert into public.deal_packages (lead_id, interest_id, source, hot, need, condition, timeline, their_number, their_basis, on_title, owed,
         occupancy, photos, other_buyers, concerns, motivation, callback_at, walk_booked_on_call, created_by)
  values (lid, nullif(p->>'interest_id', '')::uuid, coalesce(nullif(p->>'source', ''), public.lead_source_kind(lid)), coalesce((p->>'hot')::boolean, false),
          nullif(btrim(p->>'need'), ''), coalesce(p->'condition', '{}'::jsonb), nullif(btrim(p->>'timeline'), ''), nullif(btrim(p->>'their_number'), ''),
          nullif(btrim(p->>'their_basis'), ''), nullif(btrim(p->>'on_title'), ''), nullif(btrim(p->>'owed'), ''), nullif(btrim(p->>'occupancy'), ''),
          nullif(btrim(p->>'photos'), ''), nullif(btrim(p->>'other_buyers'), ''), nullif(btrim(p->>'concerns'), ''), nullif(btrim(p->>'motivation'), ''),
          cb, walk, who)
  returning id into v_id;
  if cb is not null then
    insert into public.tasks (lead_id, due_at, kind, owner, note)
    values (lid, cb, 'callback', coalesce(who, 'thalia'), 'Callback promised: deliver Colin''s number (package ' || left(v_id::text, 8) || ')');
  end if;
  update public.leads set next_action = case when walk then 'Package with Colin: walk booked on the call' else 'Package with Colin: callback ' || to_char(cb at time zone 'America/Chicago', 'Dy Mon DD HH12:MI AM') end,
         next_action_at = coalesce(cb, next_action_at),
         notes = concat_ws(' | ', notes, to_char(now() at time zone 'America/Chicago', 'YYYY-MM-DD') || ' package sent to Colin by ' || coalesce(who::text, 'the team')
                 || coalesce(': ' || nullif(btrim(p->>'motivation'), ''), ''))
   where id = lid;
  return jsonb_build_object('ok', true, 'package_id', v_id);
end $$;

-- Muse adds the value and the comps it found; Colin checks them
create or replace function public.package_set_value(p_id uuid, p_arv numeric, p_basis text, p_comps jsonb, p_agent text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d public.deal_packages;
begin
  select * into d from public.deal_packages where id = p_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such package'); end if;
  if p_arv is null or p_arv <= 0 then return jsonb_build_object('ok', false, 'reason', 'arv is the after-repair value in dollars'); end if;
  if coalesce(btrim(p_basis), '') = '' then return jsonb_build_object('ok', false, 'reason', 'say how you got it (basis): which comps, which sources'); end if;
  update public.deal_packages set arv = p_arv, arv_basis = btrim(p_basis), comps = coalesce(p_comps, '[]'::jsonb), valued_by = coalesce(p_agent, 'agent'),
         valued_at = now(), status = case when status = 'waiting_value' then 'waiting_number' else status end
   where id = p_id;
  return jsonb_build_object('ok', true, 'status', (select status from public.deal_packages where id = p_id));
end $$;

-- Colin sets the number (and grades the package); the caller is pinged and the callback task carries it
create or replace function public.package_price(p_id uuid, p_number numeric, p_note text, p_grade text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d public.deal_packages;
begin
  if not public.is_owner() then raise exception 'only Colin sets the number'; end if;
  select * into d from public.deal_packages where id = p_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such package'); end if;
  if d.status not in ('waiting_value', 'waiting_number', 'counter', 'number_ready') then return jsonb_build_object('ok', false, 'reason', 'this package is ' || d.status); end if;
  if p_number is null or p_number <= 0 then return jsonb_build_object('ok', false, 'reason', 'the number is in dollars'); end if;
  update public.deal_packages set our_number = p_number, number_note = nullif(btrim(coalesce(p_note, '')), ''), grade = nullif(p_grade, ''),
         priced_at = now(), status = 'number_ready', ready_pinged_at = null where id = p_id;
  update public.tasks set note = 'Callback: Colin''s number is ready (package ' || left(p_id::text, 8) || ')'
   where lead_id = d.lead_id and kind = 'callback' and done_at is null;
  return jsonb_build_object('ok', true);
end $$;

-- the callback: what the caller said, and what they answered
create or replace function public.package_delivered(p_id uuid, p_said numeric, p_response text, p_counter numeric, p_note text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d public.deal_packages; who public.team_person := public.wpie_person();
begin
  if not public.is_team() then raise exception 'only the team logs a callback'; end if;
  select * into d from public.deal_packages where id = p_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such package'); end if;
  if d.status <> 'number_ready' then return jsonb_build_object('ok', false, 'reason', 'there is no number from Colin to deliver yet'); end if;
  if p_response not in ('yes', 'close', 'counter', 'no') then return jsonb_build_object('ok', false, 'reason', 'response is yes, close, counter or no'); end if;
  if p_said is distinct from d.our_number then
    return jsonb_build_object('ok', false, 'reason', 'the only number you say is Colin''s: ' || d.our_number::text);
  end if;
  update public.deal_packages set said_number = p_said, delivered_at = now(), delivered_by = who, response = p_response,
         counter_number = case when p_response = 'counter' then p_counter end, response_note = nullif(btrim(coalesce(p_note, '')), ''),
         status = case p_response when 'counter' then 'counter' when 'no' then 'declined' else 'agreed' end
   where id = p_id;
  update public.tasks set done_at = now() where lead_id = d.lead_id and kind = 'callback' and done_at is null;
  update public.leads set next_action = case p_response when 'counter' then 'Counter for Colin: ' || coalesce(p_counter::text, '?')
                                                         when 'no' then next_action else 'Book Colin''s walk' end,
         notes = concat_ws(' | ', notes, to_char(now() at time zone 'America/Chicago', 'YYYY-MM-DD') || ' callback by ' || coalesce(who::text, 'the team')
                 || ': said around ' || p_said::text || ', answer ' || p_response || coalesce(' ' || p_counter::text, '') || coalesce(' (' || nullif(btrim(p_note), '') || ')', ''))
   where id = d.lead_id;
  return jsonb_build_object('ok', true, 'status', (select status from public.deal_packages where id = p_id));
end $$;

-- the walk is booked, or the package ends
create or replace function public.package_close(p_id uuid, p_status text, p_note text) returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_team() then raise exception 'only the team'; end if;
  if p_status not in ('walk_booked', 'declined', 'dead') then return jsonb_build_object('ok', false, 'reason', 'walk_booked, declined or dead'); end if;
  update public.deal_packages set status = p_status, response_note = concat_ws(' | ', response_note, nullif(btrim(coalesce(p_note, '')), '')) where id = p_id;
  update public.tasks set done_at = now() where kind = 'callback' and done_at is null and lead_id = (select lead_id from public.deal_packages where id = p_id);
  return jsonb_build_object('ok', true);
end $$;

-- a booked walk on the card closes its package as walk_booked
create or replace function public.package_walk_from_stage() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.stage = 'walkthrough_booked' and old.stage is distinct from new.stage then
    update public.deal_packages set status = 'walk_booked' where lead_id = new.id and status in ('waiting_value', 'waiting_number', 'number_ready', 'counter', 'agreed');
  end if;
  return new;
end $$;
drop trigger if exists package_walk_from_stage on public.leads;
create trigger package_walk_from_stage after update of stage on public.leads for each row execute function public.package_walk_from_stage();

-- the open packages with their deadlines: Colin prices the same day, the caller calls back at the time promised
create or replace function public.packages_open() returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'package', to_jsonb(d) - 'comps', 'comps', d.comps,
      'lead', jsonb_build_object('id', l.id, 'owner_name', l.owner_name, 'property_address', l.property_address, 'municipality', l.municipality,
                                 'property_zip', l.property_zip, 'property_type', l.property_type, 'units', l.units),
      'person', (select pe.name from public.interests i join public.people pe on pe.id = i.person_id where i.id = d.interest_id),
      'late', case
        when d.status in ('waiting_value', 'waiting_number', 'counter')
             and now() > (((d.created_at at time zone 'America/Chicago')::date + time '18:00') at time zone 'America/Chicago') then 'Colin: price it today'
        when d.status = 'number_ready' and d.callback_at is not null and now() > d.callback_at + interval '30 minutes' then 'callback is late'
        when d.status = 'agreed' and now() > d.delivered_at + interval '1 day' then 'book the walk' end)
    order by d.created_at), '[]'::jsonb)
    from public.deal_packages d join public.leads l on l.id = d.lead_id
   where (public.is_team() or auth.uid() is null) and d.status in ('waiting_value', 'waiting_number', 'number_ready', 'counter', 'agreed')
$$;

-- the funnel by list (Colin: "8 should be done somehow"): calls, then packages, valued, priced, delivered, agreed, walks
create or replace function public.deals_funnel(p_weeks integer default 8) returns jsonb language sql stable security definer set search_path = public as $$
  with weeks as (select generate_series(date_trunc('week', now() - make_interval(weeks => greatest(1, least(p_weeks, 52)) - 1)), date_trunc('week', now()), interval '1 week') w),
  calls as (
    select date_trunc('week', m.sent_at) w, public.lead_source_kind(m.lead_id) src, count(*) n,
           count(*) filter (where m.status is not null and m.status not in ('no_answer', 'voicemail', 'inbound_missed', 'wrong_number', 'missed')) reached
      from public.messages m where m.channel = 'call' and m.sent_at > now() - make_interval(weeks => greatest(1, least(p_weeks, 52)))
     group by 1, 2),
  pk as (
    select date_trunc('week', d.created_at) w, d.source src, count(*) packages, count(*) filter (where d.hot) hot,
           count(*) filter (where d.arv is not null) valued, count(*) filter (where d.our_number is not null) priced,
           count(*) filter (where d.delivered_at is not null) delivered, count(*) filter (where d.response in ('yes', 'close')) agreed,
           count(*) filter (where d.status = 'walk_booked') walks,
           count(*) filter (where d.grade = 'A') grade_a, count(*) filter (where d.grade = 'B') grade_b, count(*) filter (where d.grade = 'C') grade_c
      from public.deal_packages d where d.created_at > now() - make_interval(weeks => greatest(1, least(p_weeks, 52)))
     group by 1, 2)
  select coalesce(jsonb_agg(jsonb_build_object('week', to_char(x.w, 'YYYY-MM-DD'), 'source', x.src,
           'calls', coalesce(c.n, 0), 'reached', coalesce(c.reached, 0), 'packages', coalesce(p.packages, 0), 'hot', coalesce(p.hot, 0),
           'valued', coalesce(p.valued, 0), 'priced', coalesce(p.priced, 0), 'delivered', coalesce(p.delivered, 0),
           'agreed', coalesce(p.agreed, 0), 'walks', coalesce(p.walks, 0),
           'grades', jsonb_build_object('A', coalesce(p.grade_a, 0), 'B', coalesce(p.grade_b, 0), 'C', coalesce(p.grade_c, 0)))
         order by x.w desc, x.src), '[]'::jsonb)
    from (select weeks.w, s.src from weeks cross join (values ('hot_text'), ('inbound'), ('cold_list'), ('other')) s(src)) x
    left join calls c on c.w = x.w and c.src = x.src
    left join pk p on p.w = x.w and p.src = x.src
   where public.is_team() or auth.uid() is null
$$;

-- the email to Colin and the "number ready" ping: claimed and recorded by the minute-by-minute run (reply-agent)
create or replace function public.package_mail_claim(p_limit integer default 5) returns jsonb language plpgsql security definer set search_path = public as $$
declare out jsonb; ids uuid[];
begin
  with c as (
    select d.id from public.deal_packages d where d.emailed_at is null and d.created_at > now() - interval '3 days'
     order by d.created_at limit greatest(1, least(p_limit, 20)) for update skip locked),
  u as (update public.deal_packages d set emailed_at = now(), email_error = null from c where d.id = c.id returning d.id)
  select coalesce(array_agg(id), '{}') into ids from u;
  select coalesce(jsonb_agg(jsonb_build_object('package', to_jsonb(d), 'lead', jsonb_build_object('id', l.id, 'owner_name', l.owner_name,
           'property_address', l.property_address, 'municipality', l.municipality, 'property_zip', l.property_zip),
           'person', (select pe.name from public.interests i join public.people pe on pe.id = i.person_id where i.id = d.interest_id))), '[]'::jsonb)
    into out
    from public.deal_packages d join public.leads l on l.id = d.lead_id
   where d.id = any(ids);
  return out;
end $$;

create or replace function public.package_mail_failed(p_id uuid, p_error text) returns void language sql security definer set search_path = public as $$
  update public.deal_packages set emailed_at = null, email_error = left(p_error, 300) where id = p_id
$$;

create or replace function public.package_ready_claim() returns jsonb language plpgsql security definer set search_path = public as $$
declare out jsonb; ids uuid[];
begin
  with c as (select d.id from public.deal_packages d where d.status = 'number_ready' and d.ready_pinged_at is null for update skip locked),
  u as (update public.deal_packages d set ready_pinged_at = now() from c where d.id = c.id returning d.id)
  select coalesce(array_agg(id), '{}') into ids from u;
  select coalesce(jsonb_agg(jsonb_build_object('package_id', d.id, 'lead_id', l.id, 'property_address', l.property_address, 'callback_at', d.callback_at,
           'created_by', d.created_by)), '[]'::jsonb) into out
    from public.deal_packages d join public.leads l on l.id = d.lead_id where d.id = any(ids);
  return out;
end $$;

-- the agent door: packages waiting for a value (Muse pulls comps; it never sets a number)
create or replace function public.agent_packages_to_value(p_limit integer default 20) returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('package_id', d.id, 'status', d.status, 'hot', d.hot, 'created_at', d.created_at,
           'condition', d.condition, 'their_number', d.their_number, 'their_basis', d.their_basis, 'occupancy', d.occupancy,
           'card', public.agent_card(d.lead_id)) order by d.hot desc, d.created_at), '[]'::jsonb)
    from (select * from public.deal_packages where status = 'waiting_value' or (arv is null and status in ('waiting_number', 'counter'))
           order by hot desc, created_at limit greatest(1, least(p_limit, 50))) d
$$;

revoke all on function public.package_set_value(uuid, numeric, text, jsonb, text), public.package_mail_claim(integer), public.package_mail_failed(uuid, text),
  public.package_ready_claim(), public.agent_packages_to_value(integer) from public, anon, authenticated;
grant execute on function public.package_set_value(uuid, numeric, text, jsonb, text), public.package_mail_claim(integer), public.package_mail_failed(uuid, text),
  public.package_ready_claim(), public.agent_packages_to_value(integer) to service_role;
revoke all on function public.package_submit(jsonb), public.package_price(uuid, numeric, text, text), public.package_delivered(uuid, numeric, text, numeric, text),
  public.package_close(uuid, text, text), public.packages_open(), public.deals_funnel(integer) from public, anon;
grant execute on function public.package_submit(jsonb), public.package_price(uuid, numeric, text, text), public.package_delivered(uuid, numeric, text, numeric, text),
  public.package_close(uuid, text, text), public.packages_open(), public.deals_funnel(integer) to authenticated, service_role;
