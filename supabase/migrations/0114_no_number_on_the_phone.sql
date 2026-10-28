-- No number on the phone (Colin 2026-10-28, Rick's in-person way: "we don't give offers on the phone ... we're never
-- the highest"). The package still goes to Colin with everything in it and Muse still adds the value, but Colin's step
-- is now "walk it or pass", and he gives his number at the house, with everyone on the title there.
--   waiting_value / waiting_number  Colin decides: walk it or pass (same day)
--   go_walk                          the caller's callback: the yes-or-no agreement, then book Colin's walk
--   declined                         Colin passed (the caller still makes the promised callback and closes politely),
--                                    or the seller was not ready / said no on the callback
-- And the conditioning call (Rick: "the day before the appointment ... are you ready to make a yes or no decision"): a
-- booked walk gives the caller a "Confirm walk" task the day before at 10 AM (or 3 hours before a walk booked for
-- tomorrow morning); a moved walk moves it, a walk that is off closes it. Saturday and Sunday tasks go to Adil.

alter table public.deal_packages drop constraint if exists deal_packages_status_check;
alter table public.deal_packages add constraint deal_packages_status_check check (status in ('waiting_value', 'waiting_number', 'go_walk',
  'number_ready', 'counter', 'agreed', 'walk_booked', 'declined', 'dead'));
alter table public.deal_packages add column if not exists colin_call text check (colin_call in ('walk', 'pass'));
drop index if exists public.deal_packages_one_open;
create unique index deal_packages_one_open on public.deal_packages (lead_id)
  where status in ('waiting_value', 'waiting_number', 'go_walk', 'number_ready', 'counter', 'agreed');
drop index if exists public.deal_packages_open_idx;
create index deal_packages_open_idx on public.deal_packages (status, created_at)
  where status in ('waiting_value', 'waiting_number', 'go_walk', 'number_ready', 'counter', 'agreed');

-- the caller sends the package (unchanged but for the task wording and the open-package check)
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
  if exists (select 1 from public.deal_packages d where d.lead_id = lid and d.status in ('waiting_value', 'waiting_number', 'go_walk', 'number_ready', 'counter', 'agreed')) then
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
    values (lid, cb, 'callback', coalesce(who, 'thalia'), 'Callback promised: waiting on Colin (walk it or pass) (package ' || left(v_id::text, 8) || ')');
  end if;
  update public.leads set next_action = case when walk then 'Package with Colin: walk booked on the call' else 'Package with Colin: callback ' || to_char(cb at time zone 'America/Chicago', 'Dy Mon DD HH12:MI AM') end,
         next_action_at = coalesce(cb, next_action_at),
         notes = concat_ws(' | ', notes, to_char(now() at time zone 'America/Chicago', 'YYYY-MM-DD') || ' package sent to Colin by ' || coalesce(who::text, 'the team')
                 || coalesce(': ' || nullif(btrim(p->>'motivation'), ''), ''))
   where id = lid;
  return jsonb_build_object('ok', true, 'package_id', v_id);
end $$;

-- Colin's call: walk it (the callback books his walk) or pass (the callback closes politely). No number leaves him.
create or replace function public.package_decide(p_id uuid, p_walk boolean, p_note text, p_grade text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d public.deal_packages;
begin
  if not public.is_owner() then raise exception 'only Colin decides'; end if;
  select * into d from public.deal_packages where id = p_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such package'); end if;
  if d.status not in ('waiting_value', 'waiting_number', 'go_walk') then return jsonb_build_object('ok', false, 'reason', 'this package is ' || d.status); end if;
  if p_walk is null then return jsonb_build_object('ok', false, 'reason', 'walk it or pass'); end if;
  update public.deal_packages set colin_call = case when p_walk then 'walk' else 'pass' end, number_note = nullif(btrim(coalesce(p_note, '')), ''),
         grade = nullif(p_grade, ''), priced_at = now(), status = case when p_walk then 'go_walk' else 'declined' end, ready_pinged_at = null
   where id = p_id;
  update public.tasks set note = case when p_walk
           then 'Callback: Colin wants to walk it. Ask the yes-or-no question, then book his walk (script on the card) (package ' || left(p_id::text, 8) || ')'
           else 'Callback: Colin is passing on this one. Call at the time promised and close politely (script on the card) (package ' || left(p_id::text, 8) || ')' end
   where lead_id = d.lead_id and kind = 'callback' and done_at is null and coalesce(source, '') <> 'walk_confirm';
  update public.leads set next_action = case when p_walk then 'Callback: book Colin''s walk' else 'Callback: Colin passed, close politely' end where id = d.lead_id;
  return jsonb_build_object('ok', true, 'status', case when p_walk then 'go_walk' else 'declined' end);
end $$;

-- the old "set the number" path is closed
create or replace function public.package_price(p_id uuid, p_number numeric, p_note text, p_grade text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  return jsonb_build_object('ok', false, 'reason', 'no number on the phone (Colin 2026-10-28): decide walk it or pass; Colin gives his number at the house');
end $$;

-- the callback on a go_walk package that did not end in a booked walk: not ready to decide, or no
create or replace function public.package_callback(p_id uuid, p_response text, p_note text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d public.deal_packages; who public.team_person := public.wpie_person();
begin
  if not public.is_team() then raise exception 'only the team logs a callback'; end if;
  select * into d from public.deal_packages where id = p_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such package'); end if;
  if d.status <> 'go_walk' then return jsonb_build_object('ok', false, 'reason', 'this package is ' || d.status); end if;
  if p_response not in ('not_ready', 'no') then return jsonb_build_object('ok', false, 'reason', 'not_ready or no (a yes is the walk, booked on the card)'); end if;
  update public.deal_packages set delivered_at = now(), delivered_by = who, response = 'no', status = 'declined',
         response_note = concat_ws(' | ', case when p_response = 'not_ready' then 'not ready to decide' else 'no' end, nullif(btrim(coalesce(p_note, '')), ''))
   where id = p_id;
  update public.tasks set done_at = now() where lead_id = d.lead_id and kind = 'callback' and done_at is null and coalesce(source, '') <> 'walk_confirm';
  update public.leads set notes = concat_ws(' | ', notes, to_char(now() at time zone 'America/Chicago', 'YYYY-MM-DD') || ' callback by ' || coalesce(who::text, 'the team')
                 || ': ' || case when p_response = 'not_ready' then 'not ready to decide' else 'no' end || coalesce(' (' || nullif(btrim(p_note), '') || ')', ''))
   where id = d.lead_id;
  return jsonb_build_object('ok', true, 'status', 'declined');
end $$;

-- a booked walk closes its package as walk_booked, and its promised callback with it
create or replace function public.package_walk_from_stage() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.stage = 'walkthrough_booked' and old.stage is distinct from new.stage then
    update public.deal_packages set status = 'walk_booked', delivered_at = coalesce(delivered_at, now())
     where lead_id = new.id and status in ('waiting_value', 'waiting_number', 'go_walk', 'number_ready', 'counter', 'agreed');
    update public.tasks set done_at = now() where lead_id = new.id and kind = 'callback' and done_at is null and coalesce(source, '') <> 'walk_confirm';
  end if;
  return new;
end $$;

-- the conditioning call the day before each walk
create or replace function public.walk_confirm_task() returns trigger language plpgsql security definer set search_path = public as $$
declare tz text := 'America/Chicago'; due timestamptz; who public.team_person;
begin
  if new.belt is not distinct from old.belt and new.named_date is not distinct from old.named_date then return new; end if;
  update public.tasks set done_at = now() where lead_id = new.id and source = 'walk_confirm' and done_at is null;
  if new.belt <> 'visit_booked' or new.named_date is null or new.named_date <= now() then return new; end if;
  due := ((new.named_date at time zone tz)::date - 1 + time '10:00') at time zone tz;
  if due < now() + interval '30 minutes' then due := new.named_date - interval '3 hours'; end if;
  if due < now() + interval '30 minutes' then return new; end if;   -- booked for the next few hours: they just said yes
  who := case when extract(isodow from due at time zone tz) in (6, 7) then 'adil' else 'thalia' end;
  insert into public.tasks (lead_id, due_at, kind, owner, source, note)
  values (new.id, due, 'confirm_walk', who, 'walk_confirm',
          'Confirm Colin''s walk ' || to_char(new.named_date at time zone tz, 'FMDy FMHH12:MI AM')
          || ': still good? Everyone on the title there? "If his number works for you, are you ready to give him a yes or a no that day? A no is completely fine."');
  return new;
end $$;
drop trigger if exists walk_confirm_task on public.leads;
create trigger walk_confirm_task after update of belt, named_date on public.leads for each row execute function public.walk_confirm_task();

-- the open packages with their deadlines
create or replace function public.packages_open() returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'package', to_jsonb(d) - 'comps', 'comps', d.comps,
      'lead', jsonb_build_object('id', l.id, 'owner_name', l.owner_name, 'property_address', l.property_address, 'municipality', l.municipality,
                                 'property_zip', l.property_zip, 'property_type', l.property_type, 'units', l.units),
      'person', (select pe.name from public.interests i join public.people pe on pe.id = i.person_id where i.id = d.interest_id),
      'late', case
        when d.status in ('waiting_value', 'waiting_number')
             and now() > (((d.created_at at time zone 'America/Chicago')::date + time '18:00') at time zone 'America/Chicago') then 'Colin: walk it or pass, today'
        when d.status = 'go_walk' and d.callback_at is not null and now() > d.callback_at + interval '30 minutes' then 'callback is late' end)
    order by d.created_at), '[]'::jsonb)
    from public.deal_packages d join public.leads l on l.id = d.lead_id
   where (public.is_team() or auth.uid() is null) and d.status in ('waiting_value', 'waiting_number', 'go_walk', 'number_ready', 'counter', 'agreed')
$$;

-- the ping to the caller: Colin wants to walk it
create or replace function public.package_ready_claim() returns jsonb language plpgsql security definer set search_path = public as $$
declare out jsonb; ids uuid[];
begin
  with c as (select d.id from public.deal_packages d where d.status in ('go_walk', 'number_ready') and d.ready_pinged_at is null for update skip locked),
  u as (update public.deal_packages d set ready_pinged_at = now() from c where d.id = c.id returning d.id)
  select coalesce(array_agg(id), '{}') into ids from u;
  select coalesce(jsonb_agg(jsonb_build_object('package_id', d.id, 'lead_id', l.id, 'property_address', l.property_address, 'callback_at', d.callback_at,
           'created_by', d.created_by)), '[]'::jsonb) into out
    from public.deal_packages d join public.leads l on l.id = d.lead_id where d.id = any(ids);
  return out;
end $$;

-- the funnel: "priced" now counts Colin's walk-it calls, "called back" the callbacks made or walks booked
create or replace function public.deals_funnel(p_weeks integer default 8) returns jsonb language sql stable security definer set search_path = public as $$
  with weeks as (select generate_series(date_trunc('week', now() - make_interval(weeks => greatest(1, least(p_weeks, 52)) - 1)), date_trunc('week', now()), interval '1 week') w),
  calls as (
    select date_trunc('week', m.sent_at) w, public.lead_source_kind(m.lead_id) src, count(*) n,
           count(*) filter (where m.status is not null and m.status not in ('no_answer', 'voicemail', 'inbound_missed', 'wrong_number', 'missed')) reached
      from public.messages m where m.channel = 'call' and m.sent_at > now() - make_interval(weeks => greatest(1, least(p_weeks, 52)))
     group by 1, 2),
  pk as (
    select date_trunc('week', d.created_at) w, d.source src, count(*) packages, count(*) filter (where d.hot) hot,
           count(*) filter (where d.arv is not null) valued, count(*) filter (where d.colin_call = 'walk' or d.our_number is not null) priced,
           count(*) filter (where d.delivered_at is not null) delivered, count(*) filter (where d.response in ('yes', 'close') or d.status = 'walk_booked') agreed,
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

revoke all on function public.package_decide(uuid, boolean, text, text), public.package_callback(uuid, text, text) from public, anon;
grant execute on function public.package_decide(uuid, boolean, text, text), public.package_callback(uuid, text, text) to authenticated, service_role;
