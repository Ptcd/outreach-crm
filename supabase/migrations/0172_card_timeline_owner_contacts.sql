-- 0172: the card (piece 2 of 3; Colin 2026-11-03: "they can manage all of their cards ... like a pro enterprise grade
-- thought out CRM"). What the card needs from the database:
--   people_by_uid()                    who wrote a note or logged a call: login id -> person, for the timeline
--   note_add(lead, body)               an append-only note with its author and time (leads.notes is no longer the
--                                      place callers write; it stays as the system's and the import's block)
--   card_reassign(lead, person, why)   Colin moves a card to the other caller: the lock, the assignment, the open
--                                      calls on it; logged on the belt and as a note. Owner only (0168: "by hand").
--   contact_add / contact_fix          a caller adds a phone or email, or fixes one (value, whose it is, a note)
--   lead_fix(lead, name, address, ...) a caller fixes the owner's name or the property address; the old value is
--                                      kept in a note line so nothing is lost
-- Nothing here sends anything to a seller.

create or replace function public.people_by_uid() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_object_agg(u.id::text, jsonb_build_object('person', m.person, 'display_name', m.display_name)), '{}'::jsonb)
    from public.team_members m join auth.users u on lower(u.email) = m.email
   where public.is_team()
$$;
revoke all on function public.people_by_uid() from public, anon;
grant execute on function public.people_by_uid() to authenticated;

create or replace function public.note_add(p_lead_id uuid, p_body text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare mid uuid;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  if nullif(btrim(coalesce(p_body, '')), '') is null then return jsonb_build_object('ok', false, 'reason', 'an empty note'); end if;
  insert into public.messages (lead_id, direction, channel, body, status, created_by, sent_at)
  values (p_lead_id, 'out', 'note', btrim(p_body), null, auth.uid(), now()) returning id into mid;
  return jsonb_build_object('ok', true, 'id', mid, 'by', public.wpie_person());
end $$;
revoke all on function public.note_add(uuid, text) from public, anon;
grant execute on function public.note_add(uuid, text) to authenticated;

create or replace function public.card_reassign(p_lead_id uuid, p_person public.team_person, p_why text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare l public.leads; was public.team_person; n integer;
begin
  if not public.is_owner() then raise exception 'only Colin moves a card'; end if;
  if p_person not in ('thalia', 'adil') then return jsonb_build_object('ok', false, 'reason', 'a card belongs to Thalia or Adil'); end if;
  select * into l from public.leads where id = p_lead_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card'); end if;
  was := l.locked_to;
  if was is not distinct from p_person then return jsonb_build_object('ok', true, 'already', true); end if;
  update public.leads set locked_to = p_person, locked_at = now(),
         assigned_to = case when assigned_to in ('thalia', 'adil') or assigned_to is null then p_person else assigned_to end,
         human_takeover_assigned_to = case when human_takeover_assigned_to in ('thalia', 'adil') then p_person else human_takeover_assigned_to end,
         next_stop_who = next_stop_who
   where id = p_lead_id;
  -- the card's open calls and callbacks go with it (Colin's own stay his)
  update public.tasks set owner = p_person, updated_at = now(), notified_at = null
   where lead_id = p_lead_id and done_at is null and owner in ('thalia', 'adil') and owner <> p_person;
  get diagnostics n = row_count;
  insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
  values (p_lead_id, 'reassigned', l.belt, l.belt, l.belt_step, jsonb_build_object('from', was, 'to', p_person, 'why', p_why, 'tasks_moved', n), now(), 'Colin');
  insert into public.messages (lead_id, direction, channel, body, status, created_by, sent_at)
  values (p_lead_id, 'out', 'note', 'Card moved to ' || initcap(p_person::text) || coalesce(' from ' || initcap(was::text), '') || coalesce(': ' || nullif(btrim(p_why), ''), ''), null, auth.uid(), now());
  return jsonb_build_object('ok', true, 'from', was, 'to', p_person, 'tasks_moved', n);
end $$;
revoke all on function public.card_reassign(uuid, public.team_person, text) from public, anon;
grant execute on function public.card_reassign(uuid, public.team_person, text) to authenticated;

create or replace function public.contact_add(p_lead_id uuid, p_kind text, p_value text, p_person_name text default null, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v text; norm text; cid uuid; who text;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  who := coalesce(public.wpie_person()::text, 'team');
  if p_kind = 'phone' then
    norm := right(regexp_replace(coalesce(p_value, ''), '\D', '', 'g'), 10);
    if length(norm) <> 10 then return jsonb_build_object('ok', false, 'reason', 'a phone needs 10 digits'); end if;
    v := norm;
  elsif p_kind = 'email' then
    v := lower(btrim(coalesce(p_value, '')));
    if v !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then return jsonb_build_object('ok', false, 'reason', 'that is not an email address'); end if;
    norm := v;
  else
    return jsonb_build_object('ok', false, 'reason', 'phone or email');
  end if;
  if exists (select 1 from public.contacts c where c.lead_id = p_lead_id and c.kind = p_kind::public.contact_kind and coalesce(c.value_normalized, c.value) = norm) then
    return jsonb_build_object('ok', false, 'reason', 'already on the card');
  end if;
  insert into public.contacts (lead_id, kind, value, value_normalized, person_name, source, status, note, created_at, updated_at)
  values (p_lead_id, p_kind::public.contact_kind, v, norm, nullif(btrim(p_person_name), ''), 'added by ' || initcap(who), 'ok',
          concat_ws(' | ', nullif(btrim(p_note), ''), to_char(now() at time zone 'America/Chicago', 'YYYY-MM-DD') || ' added by ' || initcap(who)), now(), now())
  returning id into cid;
  return jsonb_build_object('ok', true, 'id', cid);
end $$;

create or replace function public.contact_fix(p_contact_id uuid, p_value text default null, p_person_name text default null, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c public.contacts; v text; norm text; who text; changed text[] := '{}';
begin
  if not public.is_team() then raise exception 'team only'; end if;
  select * into c from public.contacts where id = p_contact_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such phone or email'); end if;
  who := coalesce(public.wpie_person()::text, 'team');
  if nullif(btrim(coalesce(p_value, '')), '') is not null then
    if c.kind = 'phone' then
      norm := right(regexp_replace(p_value, '\D', '', 'g'), 10);
      if length(norm) <> 10 then return jsonb_build_object('ok', false, 'reason', 'a phone needs 10 digits'); end if;
      v := norm;
    else
      v := lower(btrim(p_value)); norm := v;
      if v !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then return jsonb_build_object('ok', false, 'reason', 'that is not an email address'); end if;
    end if;
    if norm is distinct from coalesce(c.value_normalized, c.value) then
      update public.contacts set value = v, value_normalized = norm, line_type = case when c.kind = 'phone' then null else line_type end, updated_at = now() where id = c.id;
      changed := changed || ('was ' || c.value);
    end if;
  end if;
  if p_person_name is not null and nullif(btrim(p_person_name), '') is distinct from c.person_name then
    update public.contacts set person_name = nullif(btrim(p_person_name), ''), updated_at = now() where id = c.id;
    changed := changed || ('was ' || coalesce(c.person_name, 'nobody named'));
  end if;
  if cardinality(changed) > 0 or nullif(btrim(coalesce(p_note, '')), '') is not null then
    update public.contacts set note = concat_ws(' | ', note, nullif(btrim(p_note), ''),
      to_char(now() at time zone 'America/Chicago', 'YYYY-MM-DD') || ' fixed by ' || initcap(who) || case when cardinality(changed) > 0 then ' (' || array_to_string(changed, '; ') || ')' else '' end),
      updated_at = now() where id = c.id;
  end if;
  return jsonb_build_object('ok', true, 'id', c.id, 'changed', changed);
end $$;

create or replace function public.lead_fix(p_lead_id uuid, p_owner_name text default null, p_property_address text default null,
                                            p_municipality text default null, p_property_zip text default null, p_why text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare l public.leads; who text; changed text[] := '{}';
begin
  if not public.is_team() then raise exception 'team only'; end if;
  select * into l from public.leads where id = p_lead_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card'); end if;
  who := coalesce(public.wpie_person()::text, 'team');
  if nullif(btrim(coalesce(p_owner_name, '')), '') is not null and btrim(p_owner_name) is distinct from l.owner_name then
    update public.leads set owner_name = btrim(p_owner_name) where id = l.id; changed := changed || ('name was ' || coalesce(l.owner_name, '(blank)'));
  end if;
  if nullif(btrim(coalesce(p_property_address, '')), '') is not null and btrim(p_property_address) is distinct from l.property_address then
    update public.leads set property_address = btrim(p_property_address) where id = l.id; changed := changed || ('address was ' || coalesce(l.property_address, '(blank)'));
  end if;
  if nullif(btrim(coalesce(p_municipality, '')), '') is not null and btrim(p_municipality) is distinct from l.municipality then
    update public.leads set municipality = btrim(p_municipality) where id = l.id; changed := changed || ('town was ' || coalesce(l.municipality, '(blank)'));
  end if;
  if nullif(btrim(coalesce(p_property_zip, '')), '') is not null and btrim(p_property_zip) is distinct from l.property_zip then
    update public.leads set property_zip = btrim(p_property_zip) where id = l.id; changed := changed || ('zip was ' || coalesce(l.property_zip, '(blank)'));
  end if;
  if cardinality(changed) = 0 then return jsonb_build_object('ok', true, 'changed', changed); end if;
  insert into public.messages (lead_id, direction, channel, body, status, created_by, sent_at)
  values (p_lead_id, 'out', 'note', 'Card fixed by ' || initcap(who) || ': ' || array_to_string(changed, '; ') || coalesce(' (' || nullif(btrim(p_why), '') || ')', ''), null, auth.uid(), now());
  return jsonb_build_object('ok', true, 'changed', changed);
end $$;

revoke all on function public.contact_add(uuid, text, text, text, text) from public, anon;
revoke all on function public.contact_fix(uuid, text, text, text) from public, anon;
revoke all on function public.lead_fix(uuid, text, text, text, text, text) from public, anon;
grant execute on function public.contact_add(uuid, text, text, text, text) to authenticated;
grant execute on function public.contact_fix(uuid, text, text, text) to authenticated;
grant execute on function public.lead_fix(uuid, text, text, text, text, text) to authenticated;
