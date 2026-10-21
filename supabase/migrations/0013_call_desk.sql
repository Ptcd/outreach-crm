-- Call desk (Colin 2026-10-21): a seller calls the seller line; whoever answers (Colin or Adil, on a
-- phone) types the last digits of the caller's number, lands on the lead, reads what is already
-- known, asks the open questions with one-tap answers, and logs the call with an outcome.
--   phone_lookup(digits)    owners whose phone ends in those digits (or is exactly that number)
--   new_caller(phone, name) a lead card with just the phone, for a number we have never seen
--   call_answer(lead, key, value)  one answer from the call script, kept on the lead (call_facts)
--   log_call(lead, phone, outcome, note)  the call on the lead's history + the stage it implies;
--                           "do not contact" suppresses the owner's phones the way a texted STOP does
-- Nothing here sends anything.

alter table public.leads add column if not exists call_facts jsonb not null default '{}'::jsonb;

create index if not exists contacts_last4_idx on public.contacts (right(value_normalized, 4)) where kind = 'phone';

create or replace function public.phone_lookup(p_digits text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare d text := regexp_replace(coalesce(p_digits, ''), '\D', '', 'g'); out jsonb;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  if length(d) > 10 then d := right(d, 10); end if;
  if length(d) < 3 then return '[]'::jsonb; end if;
  select coalesce(jsonb_agg(x order by x->>'exact' desc, x->>'owner_name'), '[]'::jsonb) into out from (
    select distinct on (l.id) jsonb_build_object(
      'lead_id', l.id, 'owner_name', l.owner_name, 'property_address', l.property_address, 'municipality', l.municipality,
      'lane', l.lane, 'stage', l.stage, 'phone', c.value_normalized, 'person_name', c.person_name,
      'blocked', c.suppressed or c.dnc_app or c.dnc_vendor or l.stage = 'dnc', 'exact', c.value_normalized = d) as x
    from public.contacts c join public.leads l on l.id = c.lead_id
    where c.kind = 'phone' and c.value_normalized is not null
      and (case when length(d) = 4 then right(c.value_normalized, 4) = d else c.value_normalized like '%' || d end)
    order by l.id, (c.value_normalized = d) desc
    limit 50
  ) s;
  return out;
end $$;

create or replace function public.new_caller(p_phone text, p_name text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare d text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10); lid uuid; nm text;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  if d !~ '^[0-9]{10}$' then return jsonb_build_object('ok', false, 'reason', 'Type the full 10-digit number for a new caller.'); end if;
  select c.lead_id into lid from public.contacts c where c.kind = 'phone' and c.value_normalized = d order by c.created_at limit 1;
  if lid is not null then return jsonb_build_object('ok', true, 'lead_id', lid, 'existing', true); end if;
  nm := coalesce(nullif(btrim(coalesce(p_name, '')), ''),
                 format('New caller (%s) %s-%s', substr(d, 1, 3), substr(d, 4, 3), substr(d, 7)));
  insert into public.leads (owner_name, stage, next_action, notes)
  values (nm, 'colin_call', 'Find out which property and who they are', 'Created from an inbound call.')
  returning id into lid;
  insert into public.contacts (lead_id, kind, value, value_normalized, person_name, source, line_type)
  values (lid, 'phone', d, d, nullif(btrim(coalesce(p_name, '')), ''), 'inbound_call', 'unknown');
  return jsonb_build_object('ok', true, 'lead_id', lid, 'existing', false);
end $$;

-- One answer from the call script: call_facts[key] = { value, at, by }. "next_step" also sets the
-- lead's next action (walk-through or call-back time).
create or replace function public.call_answer(p_lead_id uuid, p_key text, p_value jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare who text; at timestamptz; kind text;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  if p_key !~ '^[a-z_]{2,40}$' then return jsonb_build_object('ok', false, 'reason', 'bad key'); end if;
  select display_name into who from public.team_members where lower(email) = lower(auth.jwt() ->> 'email');
  update public.leads
     set call_facts = case when p_value is null or p_value = 'null'::jsonb then call_facts - p_key
                           else jsonb_set(call_facts, array[p_key], jsonb_build_object('value', p_value, 'at', now(), 'by', who)) end
   where id = p_lead_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such lead'); end if;
  if p_key = 'next_step' and jsonb_typeof(p_value) = 'object' then
    kind := p_value->>'kind';
    at := nullif(p_value->>'at', '')::timestamptz;
    if kind = 'walk' then
      update public.leads set stage = 'walkthrough_booked', next_action = 'Walk-through', next_action_at = at,
             assigned_to = coalesce(assigned_to, 'colin') where id = p_lead_id;
    elsif kind = 'callback' then
      update public.leads set stage = case when stage in ('dead', 'dnc', 'closed_won', 'under_contract') then stage else 'colin_call' end,
             next_action = 'Colin calls back', next_action_at = at, assigned_to = coalesce(assigned_to, 'colin') where id = p_lead_id;
    end if;
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- The call itself. Outcomes: interested / not_now / not_interested / wrong_number / dnc.
create or replace function public.log_call(p_lead_id uuid, p_phone text, p_outcome text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare who text; d text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10); l public.leads;
  phones text[]; label text;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  if p_outcome not in ('interested', 'not_now', 'not_interested', 'wrong_number', 'dnc') then
    return jsonb_build_object('ok', false, 'reason', 'pick an outcome');
  end if;
  select * into l from public.leads where id = p_lead_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such lead'); end if;
  select display_name into who from public.team_members where lower(email) = lower(auth.jwt() ->> 'email');
  label := case p_outcome when 'interested' then 'Interested' when 'not_now' then 'Not now' when 'not_interested' then 'Not interested'
                          when 'wrong_number' then 'Wrong number' else 'Do not contact' end;
  insert into public.messages (lead_id, direction, channel, body, from_number, sent_at, seen_at, status)
  values (p_lead_id, 'in', 'call', format('Call (%s)%s: %s%s', coalesce(who, 'team'),
            case when d ~ '^[0-9]{10}$' then ' from ' || d else '' end, label,
            coalesce(E'\n' || nullif(btrim(coalesce(p_note, '')), ''), '')),
          case when d ~ '^[0-9]{10}$' then '+1' || d end, now(), now(), p_outcome);
  update public.leads set call_facts = jsonb_set(call_facts, '{last_call}', jsonb_build_object('value', p_outcome, 'at', now(), 'by', who))
   where id = p_lead_id;

  if p_outcome = 'interested' then
    update public.leads set stage = case when stage in ('walkthrough_booked', 'offer', 'under_contract', 'closed_won') then stage else 'colin_call' end
     where id = p_lead_id;
  elsif p_outcome = 'not_now' then
    update public.leads set stage = 'follow_up', next_action = coalesce(next_action, 'Check back'),
           next_action_at = coalesce(next_action_at, now() + interval '30 days') where id = p_lead_id;
  elsif p_outcome = 'not_interested' then
    update public.leads set stage = 'dead', dead_reason = coalesce(nullif(btrim(coalesce(p_note, '')), ''), 'Not interested (call)') where id = p_lead_id;
  elsif p_outcome = 'wrong_number' then
    if d ~ '^[0-9]{10}$' then
      update public.contacts set status = 'bad' where lead_id = p_lead_id and value_normalized = d;
    end if;
    update public.leads set stage = 'data_fix' where id = p_lead_id;
  else
    -- Do not contact: every phone of this owner, like a removal reply by text.
    select array_agg(distinct c.value_normalized) into phones from public.contacts c
     where c.lead_id = p_lead_id and c.kind = 'phone' and c.value_normalized ~ '^[0-9]{10}$';
    phones := coalesce(phones, '{}');
    if d ~ '^[0-9]{10}$' and not d = any(phones) then phones := array_append(phones, d); end if;
    insert into public.suppressed_phones (phone10, reason, source)
      select distinct p, 'dnc_call', 'app' from unnest(phones) p
    on conflict (phone10) do nothing;
    update public.contacts set suppressed = true, dnc_app = true where value_normalized = any(phones);
    update public.leads set stage = 'dnc' where id = p_lead_id;
  end if;
  return jsonb_build_object('ok', true, 'outcome', p_outcome);
end $$;

revoke all on function public.phone_lookup(text), public.new_caller(text, text), public.call_answer(uuid, text, jsonb),
  public.log_call(uuid, text, text, text) from public, anon;
grant execute on function public.phone_lookup(text), public.new_caller(text, text), public.call_answer(uuid, text, jsonb),
  public.log_call(uuid, text, text, text) to authenticated, service_role;
