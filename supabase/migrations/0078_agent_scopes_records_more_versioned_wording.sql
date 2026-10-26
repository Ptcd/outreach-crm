-- Three asks from Muse, Colin's operating agent (2026-10-26), none of which loosens a guardrail:
--   1. one agent key with server-side scopes (prospects, texting, calendar, records, marks), each switchable, every call
--      logged with its scope; the old intake / sender / records keys keep working with the scopes their role had
--   2. records: four more office types (county treasurer, clerk of court, sheriff, police records custodian), a category
--      list and a cadence per request, and "re-ask forever": a sent or acknowledged request with no answer is due for a
--      polite follow-up every 14 days, without end; a received or no-records answer comes due again after the cadence;
--      fee quotes and denials stay with Colin
--   3. first-text wording versioned server-side: variants A / B / C each carry a template with versions; every queued
--      text is stamped with its variant's version, and test_results reports by variant and by version, with dates

-- ================================================================== 1. scopes
alter table public.agent_keys add column if not exists scopes text[];
alter table public.agent_keys drop constraint if exists agent_keys_role_check;
alter table public.agent_keys add constraint agent_keys_role_check check (role in ('intake', 'sender', 'records', 'agent'));

create or replace function public.agent_scopes_for(p_role text, p_scopes text[]) returns text[] language sql immutable as $$
  select coalesce(p_scopes, case p_role
    when 'intake' then array['prospects', 'marks']
    when 'sender' then array['texting', 'calendar', 'marks']
    when 'records' then array['records']
    else array['prospects', 'texting', 'calendar', 'records', 'marks'] end)
$$;

create or replace function public.agent_key_check(p_key text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare k public.agent_keys;
begin
  select * into k from public.agent_keys
   where key_sha256 = encode(sha256(convert_to(coalesce(p_key, ''), 'UTF8')), 'hex') and revoked_at is null;
  if not found then return jsonb_build_object('ok', false); end if;
  update public.agent_keys set last_used_at = now() where id = k.id;
  return jsonb_build_object('ok', true, 'id', k.id, 'name', k.name, 'role', k.role, 'scopes', to_jsonb(public.agent_scopes_for(k.role, k.scopes)));
end $$;

create or replace function public.create_agent_key(p_name text, p_role text, p_scopes text[] default null)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare k text;
begin
  if not public.is_owner() then raise exception 'only Colin can make an agent key'; end if;
  if p_role not in ('intake', 'sender', 'records', 'agent') then raise exception 'role is agent, intake, sender or records'; end if;
  if coalesce(btrim(p_name), '') = '' then raise exception 'give the key a name'; end if;
  if p_scopes is not null and not (p_scopes <@ array['prospects', 'texting', 'calendar', 'records', 'marks']) then
    raise exception 'scopes are prospects, texting, calendar, records, marks';
  end if;
  k := 'wpie_' || p_role || '_' || replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  insert into public.agent_keys (name, role, key_sha256, key_hint, created_by, scopes)
  values (btrim(p_name), p_role, encode(sha256(convert_to(k, 'UTF8')), 'hex'), right(k, 4), public.wpie_person()::text,
          case when p_role = 'agent' then coalesce(p_scopes, array['prospects', 'texting', 'calendar', 'records', 'marks']) else p_scopes end);
  return k;
end $$;

create or replace function public.set_agent_key_scopes(p_id uuid, p_scopes text[]) returns text[]
language plpgsql security definer set search_path = public as $$
declare out text[];
begin
  if not public.is_owner() then raise exception 'only Colin changes what an agent key may do'; end if;
  if not (coalesce(p_scopes, '{}') <@ array['prospects', 'texting', 'calendar', 'records', 'marks']) then
    raise exception 'scopes are prospects, texting, calendar, records, marks';
  end if;
  update public.agent_keys set scopes = coalesce(p_scopes, '{}') where id = p_id returning scopes into out;
  return out;
end $$;

create table if not exists public.agent_calls (
  id        bigint generated always as identity primary key,
  key_id    uuid references public.agent_keys(id) on delete set null,
  tool      text not null,
  scope     text,
  ok        boolean not null,
  error     text,
  ms        integer,
  at        timestamptz not null default now()
);
create index if not exists agent_calls_at_idx on public.agent_calls (at desc);
alter table public.agent_calls enable row level security;
create policy agent_calls_owner on public.agent_calls for select to authenticated using (public.is_owner());

create or replace function public.agent_log_call(p_key_id uuid, p_tool text, p_scope text, p_ok boolean, p_error text, p_ms integer)
returns void language sql security definer set search_path = public as $$
  insert into public.agent_calls (key_id, tool, scope, ok, error, ms) values (p_key_id, p_tool, p_scope, p_ok, left(p_error, 300), p_ms)
$$;

drop function if exists public.list_agent_keys();
create or replace function public.list_agent_keys()
returns table (id uuid, name text, role text, key_hint text, created_at timestamptz, last_used_at timestamptz, revoked_at timestamptz,
               scopes text[], calls_24h bigint, refused_24h bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_owner() then raise exception 'only Colin can see agent keys'; end if;
  return query select k.id, k.name, k.role, k.key_hint, k.created_at, k.last_used_at, k.revoked_at,
                      public.agent_scopes_for(k.role, k.scopes),
                      (select count(*) from public.agent_calls c where c.key_id = k.id and c.at > now() - interval '24 hours'),
                      (select count(*) from public.agent_calls c where c.key_id = k.id and c.at > now() - interval '24 hours' and not c.ok)
                 from public.agent_keys k order by k.created_at desc;
end $$;

-- ================================================================== 2. records
alter table public.records_requests drop constraint if exists records_requests_kind_check;
alter table public.records_requests add constraint records_requests_kind_check
  check (kind in ('municipal', 'rod', 'treasurer', 'clerk_of_court', 'sheriff', 'police'));
alter table public.records_requests add column if not exists categories text[] not null default '{}';
alter table public.records_requests add column if not exists cadence_days integer not null default 90 check (cadence_days between 14 and 400);
alter table public.records_requests add column if not exists follow_up_count integer not null default 0;
alter table public.records_requests add column if not exists last_asked date;
update public.records_requests set last_asked = coalesce(last_asked, sent_date) where sent_date is not null;

-- "due": never sent; a re-request whose date came; or a sent / acknowledged request with no answer in 14 days (forever)
create or replace function public.records_why_due(r public.records_requests) returns text language sql stable as $$
  select case
    when r.status = 'draft' then 'never sent'
    when r.status in ('received', 'no_records') and r.next_due is not null and r.next_due <= current_date then 're-request: the cadence came round'
    when r.status in ('sent', 'acknowledged') and coalesce(r.last_asked, r.sent_date) <= current_date - 14
      then 'no answer since ' || to_char(coalesce(r.last_asked, r.sent_date), 'Mon DD') || ': follow-up #' || (r.follow_up_count + 1)
    end
$$;

create or replace function public.records_overview() returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'by_status', (select coalesce(jsonb_object_agg(k || ':' || s, n), '{}') from (select kind k, status s, count(*) n from public.records_requests group by 1, 2) a),
    'due', (select count(*) from public.records_requests r where public.records_why_due(r) is not null),
    'for_colin', (select count(*) from public.records_requests where status in ('needs_payment', 'denied')),
    'replies_unhandled', (select count(*) from public.records_replies where handled_at is null),
    'drafts_waiting', (select count(*) from public.records_drafts where status = 'draft'),
    'batches_waiting_for_colin', (select count(*) from public.records_batches where status = 'proposed'),
    'approved_not_sent', (select count(*) from public.records_batches where status in ('approved', 'sending')))
$$;

create or replace function public.records_list(p_filter text default 'due', p_limit integer default 100) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'request_id', r.id, 'kind', r.kind, 'name', r.name, 'county', r.county, 'to_email', r.to_email, 'alt_email', r.alt_email,
           'form_url', r.form_url, 'status', r.status, 'categories', r.categories, 'cadence_days', r.cadence_days,
           'sent_date', r.sent_date, 'last_asked', r.last_asked, 'follow_up_count', r.follow_up_count,
           'received_date', r.received_date, 'records_through', r.records_through, 'next_due', r.next_due, 'notes', r.notes,
           'why_due', public.records_why_due(r), 'message_id', r.message_id,
           'drafts', (select jsonb_agg(jsonb_build_object('draft_id', d.id, 'purpose', d.purpose, 'status', d.status, 'subject', d.subject, 'created_at', d.created_at))
                        from public.records_drafts d where d.request_id = r.id and d.status not in ('superseded', 'rejected')),
           'replies', (select jsonb_agg(jsonb_build_object('reply_id', x.id, 'from', x.from_addr, 'subject', x.subject, 'at', x.received_at,
                         'handled', x.handled_at is not null) order by x.received_at) from public.records_replies x where x.request_id = r.id))
           order by r.kind, r.name), '[]'::jsonb)
    from (select * from public.records_requests r
           where case coalesce(p_filter, 'due')
                   when 'all' then true
                   when 'due' then public.records_why_due(r) is not null
                   when 'for_colin' then r.status in ('needs_payment', 'denied')
                   else r.status = p_filter or r.kind = p_filter end
           order by r.kind, r.name limit greatest(1, least(p_limit, 500))) r
$$;

-- a new office, or new categories / cadence / addresses on an existing one
create or replace function public.records_set_request(p jsonb, p_agent text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid; cats text[];
begin
  select coalesce(array_agg(x), '{}') into cats from jsonb_array_elements_text(coalesce(p->'categories', '[]'::jsonb)) x;
  if nullif(p->>'request_id', '') is not null then
    update public.records_requests set
      to_email = coalesce(nullif(p->>'to_email', ''), to_email), alt_email = coalesce(nullif(p->>'alt_email', ''), alt_email),
      form_url = coalesce(nullif(p->>'form_url', ''), form_url), county = coalesce(nullif(p->>'county', ''), county),
      categories = case when p ? 'categories' then cats else categories end,
      cadence_days = coalesce(nullif(p->>'cadence_days', '')::int, cadence_days),
      notes = case when nullif(p->>'note', '') is null then notes else concat_ws(' | ', notes, to_char(current_date, 'YYYY-MM-DD') || ' ' || coalesce(p_agent, 'agent') || ': ' || (p->>'note')) end,
      updated_at = now()
     where records_requests.id = (p->>'request_id')::uuid returning records_requests.id into v_id;
    if v_id is null then return jsonb_build_object('ok', false, 'reason', 'no such request'); end if;
    return jsonb_build_object('ok', true, 'request_id', v_id, 'updated', true);
  end if;
  if coalesce(p->>'kind', '') not in ('municipal', 'rod', 'treasurer', 'clerk_of_court', 'sheriff', 'police') then
    return jsonb_build_object('ok', false, 'reason', 'kind is municipal, rod, treasurer, clerk_of_court, sheriff or police');
  end if;
  if coalesce(btrim(p->>'name'), '') = '' then return jsonb_build_object('ok', false, 'reason', 'name the office'); end if;
  insert into public.records_requests (kind, name, county, to_email, alt_email, form_url, categories, cadence_days, notes)
  values (p->>'kind', btrim(p->>'name'), nullif(p->>'county', ''), nullif(p->>'to_email', ''), nullif(p->>'alt_email', ''), nullif(p->>'form_url', ''),
          cats, coalesce(nullif(p->>'cadence_days', '')::int, 90), nullif(p->>'note', ''))
  on conflict (kind, name) do nothing returning records_requests.id into v_id;
  if v_id is null then return jsonb_build_object('ok', false, 'reason', 'that office is already on the list: pass its request_id to change it'); end if;
  return jsonb_build_object('ok', true, 'request_id', v_id, 'created', true);
end $$;

-- received / no records come due again after the request's own cadence
create or replace function public.records_mark(p_request_id uuid, p_status text, p_note text, p_received_date date, p_records_through text,
  p_next_due date, p_to_email text, p_reply_id uuid, p_agent text) returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.records_requests;
begin
  select * into r from public.records_requests where id = p_request_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such request'); end if;
  if p_status is not null and p_status not in ('draft', 'sent', 'acknowledged', 'replied', 'received', 'no_records', 'needs_payment', 'denied', 'bounced', 'skip') then
    return jsonb_build_object('ok', false, 'reason', 'status is one of draft, sent, acknowledged, replied, received, no_records, needs_payment, denied, bounced, skip');
  end if;
  update public.records_requests set
    status = coalesce(p_status, status),
    received_date = case when p_status in ('received', 'no_records') then coalesce(p_received_date, current_date) else coalesce(p_received_date, received_date) end,
    records_through = coalesce(nullif(p_records_through, ''), records_through),
    next_due = case when p_next_due is not null then p_next_due
                    when p_status in ('received', 'no_records') then coalesce(p_received_date, current_date) + r.cadence_days else next_due end,
    follow_up_count = case when p_status in ('received', 'no_records', 'acknowledged', 'replied') then 0 else follow_up_count end,
    to_email = coalesce(nullif(btrim(coalesce(p_to_email, '')), ''), to_email),
    notes = case when nullif(p_note, '') is null then notes else concat_ws(' | ', notes, to_char(current_date, 'YYYY-MM-DD') || ' ' || coalesce(p_agent, 'agent') || ': ' || p_note) end,
    updated_at = now()
   where id = p_request_id;
  if p_reply_id is not null then update public.records_replies set handled_at = now(), handled_by = p_agent, request_id = coalesce(request_id, p_request_id) where id = p_reply_id; end if;
  return jsonb_build_object('ok', true, 'request', (select to_jsonb(x) - 'notes' from public.records_requests x where x.id = p_request_id));
end $$;

-- a sent letter: the date it was asked, and the follow-up count
create or replace function public.records_sent(p_draft_id uuid, p_ok boolean, p_message_id text, p_error text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d public.records_drafts;
begin
  update public.records_drafts set status = case when p_ok then 'sent' else 'failed' end, sent_at = case when p_ok then now() end,
         message_id = p_message_id, error = left(p_error, 500) where id = p_draft_id and status = 'sending' returning * into d;
  if not found then return jsonb_build_object('ok', false); end if;
  if p_ok then
    update public.records_requests set
           status = case when d.purpose in ('request', 're_request') then 'sent' else status end,
           sent_date = case when d.purpose in ('request', 're_request') then current_date else sent_date end,
           message_id = case when d.purpose in ('request', 're_request') then p_message_id else message_id end,
           follow_up_count = case when d.purpose = 'follow_up' then follow_up_count + 1 when d.purpose in ('request', 're_request') then 0 else follow_up_count end,
           last_asked = current_date,
           notes = concat_ws(' | ', notes, to_char(current_date, 'YYYY-MM-DD') || ' sent ' || d.purpose || ' (approved batch)'), updated_at = now()
     where id = d.request_id;
  end if;
  update public.records_batches b set status = 'sent', sent_at = now()
   where b.id = d.batch_id and not exists (select 1 from public.records_drafts x where x.batch_id = b.id and x.status in ('approved', 'sending'));
  return jsonb_build_object('ok', true);
end $$;


-- the four new letters, alongside the municipal and Register of Deeds ones (0072). Plain public-records requests: they
-- ask for records and nothing else.
alter function public.records_templates() rename to records_templates_base;
create or replace function public.records_templates() returns jsonb language sql stable as $fn$
  select public.records_templates_base() || jsonb_build_object(
    'treasurer', $tpl$SUBJECT: Public records request - delinquent tax list, {county} County Treasurer

To the County Treasurer, {county} County:

Under Wisconsin's public records law, Wis. Stat. 19.31-19.39, I request a copy of the following records:

1. The current list of parcels with delinquent real estate taxes, with the tax years delinquent and the amounts owed.
2. Parcels for which a tax certificate or tax deed has been issued, or an in rem foreclosure has been started, since {start_date}.
3. Any list of parcels the county has taken by tax deed and has not yet sold.

For each parcel, if available: the parcel / tax key number, the property address, the owner of record and the owner's mailing address.

I prefer the records in electronic form; a spreadsheet or CSV export is ideal, and PDF is fine if an export isn't possible. If you'll charge fees over $25, please send me the estimate before filling the request. If the list is published online, a link is all I need. If you can send the same list again each time it is updated, that would be ideal; otherwise I'll re-request.

If any part of this request is denied, please cite the specific exemption and release the remaining records.

Thank you,
Colin Merrill
(262) 418-0202
merrillholdings@gmail.com$tpl$,
    'clerk_of_court', $tpl$SUBJECT: Public records request - civil case index, {county} County Clerk of Circuit Court

To the Clerk of Circuit Court, {county} County:

Under Wisconsin's public records law, Wis. Stat. 19.31-19.39, I request an index listing (not case file copies) of the following cases filed in {county} County from {start_date} to the present:

1. Foreclosure of mortgage cases (case type 30404), with any lis pendens.
2. Money judgments docketed against individuals (case type 30301).
3. State tax warrants (TW) docketed.
4. Probate cases opened (PR), with the personal representative named, if your index shows it.

For each case, if available: case number, filing date, case type, the party names, and the property address or legal description where the case concerns real estate.

I prefer the index in electronic form; a spreadsheet or CSV export is ideal, and PDF is fine if an export isn't possible. If you'll charge fees over $25, please send me the estimate before filling the request. If your office provides this only through a subscription or another service, please tell me which one. If you can send the same index again monthly, that would be ideal; otherwise I'll re-request.

If any part of this request is denied, please cite the specific exemption and release the remaining records.

Thank you,
Colin Merrill
(262) 418-0202
merrillholdings@gmail.com$tpl$,
    'sheriff', $tpl$SUBJECT: Public records request - sheriff's sale list, {county} County Sheriff

To the Records Custodian, {county} County Sheriff's Office:

Under Wisconsin's public records law, Wis. Stat. 19.31-19.39, I request a copy of the following records:

1. The list of scheduled sheriff's sales of real estate, with the sale date, case number, property address and the judgment amount if shown.
2. Sales adjourned or cancelled since {start_date}, with the new date where there is one.
3. The results of sheriff's sales held since {start_date}: whether the property sold, and to whom, if recorded.

I prefer the records in electronic form; a spreadsheet or CSV export is ideal, and PDF is fine if an export isn't possible. If the list is published online, a link is all I need. If you'll charge fees over $25, please send me the estimate before filling the request. If you can send the same list again monthly, that would be ideal; otherwise I'll re-request.

If any part of this request is denied, please cite the specific exemption and release the remaining records.

Thank you,
Colin Merrill
(262) 418-0202
merrillholdings@gmail.com$tpl$,
    'police', $tpl$SUBJECT: Public records request - property-related calls for service, {muni} Police Department

To the Records Custodian, {muni} Police Department:

Under Wisconsin's public records law, Wis. Stat. 19.31-19.39, I request the following records for {start_date} to the present:

1. A log of calls for service and incidents by address (date, address and incident type only, no personal information), for these types: vacant or abandoned building, burglary to a vacant structure, squatters or trespass in an unoccupied building, nuisance property, and fire.
2. Any list of properties declared chronic nuisance premises, with the date of the notice.
3. Any list of properties the department has flagged as vacant or abandoned.

I am asking for addresses and incident types, not names or other personal information; please redact anything the law requires. I prefer the records in electronic form; a spreadsheet or CSV export is ideal, and PDF is fine if an export isn't possible. If you'll charge fees over $25, please send me the estimate before filling the request. If you can send the same records again monthly, that would be ideal; otherwise I'll re-request.

If any part of this request is denied, please cite the specific exemption and release the remaining records.

Thank you,
Colin Merrill
(262) 418-0202
merrillholdings@gmail.com$tpl$,
    'categories', jsonb_build_array('lis_pendens', 'federal_tax_liens', 'construction_liens', 'decedent_terminations', 'judgments_tax_warrants',
      'certificates_of_sale', 'tax_delinquency', 'code_enforcement', 'vacant_buildings', 'water_shutoffs', 'arrest_logs', 'sheriff_sales'),
    'cadence', 'Each request has cadence_days (default 90): after a received or no-records answer the re-request comes due that many days later. A request with no answer gets a polite follow-up every 14 days, without end; there are no escalation letters.')
$fn$;
revoke all on function public.records_templates(), public.records_templates_base() from public, anon, authenticated;
grant execute on function public.records_templates(), public.records_templates_base() to service_role;

-- ================================================================== 3. versioned first-text wording
create table if not exists public.text_templates (
  id          bigint generated always as identity primary key,
  variant     text not null check (variant in ('A', 'B', 'C')),
  name        text not null,
  wording     text not null,
  version     integer not null,
  active_from timestamptz not null default now(),
  active_to   timestamptz,
  changed_by  text,
  note        text,
  unique (variant, version)
);
alter table public.text_templates enable row level security;
create policy text_templates_team on public.text_templates for select to authenticated using (public.is_team());

insert into public.text_templates (variant, name, wording, version, active_from, changed_by, note)
select v, n, w, 1, coalesce((select min(p.created_at) from public.planned_openers p where p.lane = 'agent'), now()), 'Colin (brief 2026-10-25)', 'the starting wording'
  from (values
    ('A', 'own_q', 'Person: "Hi {First}, Colin Merrill here. Are you still the owner of {address}? Reply STOP if you''d rather not hear from me." Trust / LLC / estate: "Hi {First or there}, this is Colin Merrill. Are you the right person to ask about {address}? Reply STOP if you''d rather not hear from me."'),
    ('B', 'intent_q', 'Person: "Hi {First}, Colin Merrill here. I''m looking to buy a house around {city}. Would you ever consider selling {address}? Reply STOP if you''d rather not hear from me." Trust / LLC / estate: "Hi {First or there}, this is Colin Merrill. I''m looking to buy a house around {city}. Are you the right person to ask about {address}? Reply STOP if you''d rather not hear from me."')) x(v, n, w)
on conflict (variant, version) do nothing;

alter table public.planned_openers add column if not exists template_version integer;

-- every agent first text is stamped with its variant's wording version at the moment it is queued
create or replace function public.stamp_template_version() returns trigger language plpgsql as $$
begin
  if new.lane = 'agent' and new.step = 1 and new.variant in ('A', 'B', 'C')
     and (tg_op = 'INSERT' or new.variant is distinct from old.variant or new.body is distinct from old.body) then
    new.template_version := (select t.version from public.text_templates t where t.variant = new.variant and t.active_to is null
                              order by t.version desc limit 1);
  end if;
  return new;
end $$;
drop trigger if exists stamp_template_version on public.planned_openers;
create trigger stamp_template_version before insert or update of variant, body on public.planned_openers
  for each row execute function public.stamp_template_version();
update public.planned_openers set template_version = 1 where lane = 'agent' and step = 1 and variant in ('A', 'B') and template_version is null;

create or replace function public.agent_text_templates() returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'active', (select coalesce(jsonb_agg(jsonb_build_object('variant', t.variant, 'name', t.name, 'version', t.version, 'wording', t.wording,
                 'since', t.active_from, 'changed_by', t.changed_by, 'note', t.note) order by t.variant), '[]'::jsonb)
                 from public.text_templates t where t.active_to is null),
    'history', (select coalesce(jsonb_agg(jsonb_build_object('variant', t.variant, 'name', t.name, 'version', t.version, 'from', t.active_from,
                 'to', t.active_to, 'note', t.note) order by t.variant, t.version), '[]'::jsonb) from public.text_templates t),
    'assignment', 'unchanged: the variant comes from the last character of lead_id (0-7 A, 8-f B); C exists as a slot and is used only when Colin says so')
$$;

create or replace function public.agent_set_text_template(p_variant text, p_name text, p_wording text, p_note text, p_agent text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v integer;
begin
  if p_variant not in ('A', 'B', 'C') then return jsonb_build_object('ok', false, 'reason', 'variant is A, B or C'); end if;
  if coalesce(btrim(p_wording), '') = '' or position('STOP' in p_wording) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'the wording needs a STOP line');
  end if;
  if p_wording ~ '\$' or p_wording ~* '\m(cash|as-is|as is|offer)\M' then
    return jsonb_build_object('ok', false, 'reason', 'no $, cash, as-is or offer in a first text');
  end if;
  if coalesce(btrim(p_note), '') = '' then return jsonb_build_object('ok', false, 'reason', 'say why in the note (and that Colin called it)'); end if;
  select coalesce(max(version), 0) + 1 into v from public.text_templates where variant = p_variant;
  update public.text_templates set active_to = now() where variant = p_variant and active_to is null;
  insert into public.text_templates (variant, name, wording, version, changed_by, note)
  values (p_variant, coalesce(nullif(btrim(p_name), ''), 'variant_' || lower(p_variant)), p_wording, v, coalesce(p_agent, 'agent'), p_note);
  return jsonb_build_object('ok', true, 'variant', p_variant, 'version', v, 'since', now());
end $$;

-- test_results: by variant, by slot, by cell, and now by variant version (with the dates each version ran)
create or replace function public.agent_test_results(p_days integer default 14, p_step integer default 1)
returns jsonb language sql stable security definer set search_path = public as $$
  with s as (
    select p.variant, coalesce(p.send_slot, '-') as slot, p.template_lane, p.template_version, p.send_status, p.error_code, right(p.phone, 10) ph,
           coalesce(p.sent_at, p.claimed_at) at
      from public.planned_openers p
     where p.lane = 'agent' and p.step = coalesce(p_step, 1) and p.created_at > now() - make_interval(days => greatest(1, least(p_days, 90)))),
  r as (
    select s.*,
      exists (select 1 from public.twilio_inbound t where t.from10 = s.ph and s.at is not null and t.received_at > s.at and not t.is_opt_out) as replied,
      exists (select 1 from public.twilio_inbound t where t.from10 = s.ph and s.at is not null and t.received_at > s.at and t.is_opt_out) as stopped,
      exists (select 1 from public.reply_drafts d where d.phone10 = s.ph and s.at is not null and d.inbound_at > s.at
                and (d.intent = 'wrong_number' or d.outcome = 'wrong_number')) as wrong,
      exists (select 1 from public.leads l join public.contacts c on c.lead_id = l.id where c.value_normalized = s.ph and l.hot_at is not null and l.hot_at > s.at) as hot
      from s),
  score as (
    select grp, key, jsonb_build_object(
            'templates', array_agg(distinct template_lane),
            'queued', count(*),
            'sent', count(*) filter (where send_status in ('sent', 'delivered', 'undelivered', 'failed')),
            'delivered', count(*) filter (where send_status = 'delivered'),
            'undelivered', count(*) filter (where send_status in ('undelivered', 'failed')),
            'filtered_30007', count(*) filter (where error_code = '30007'),
            'replied', count(*) filter (where replied),
            'stops', count(*) filter (where stopped),
            'wrong_numbers', count(*) filter (where wrong),
            'conversations', count(*) filter (where replied and not stopped and not wrong),
            'hot', count(*) filter (where hot),
            'reply_rate', round(100.0 * count(*) filter (where replied and not stopped and not wrong) / nullif(count(*) filter (where send_status = 'delivered'), 0), 1),
            'stop_rate', round(100.0 * count(*) filter (where stopped) / nullif(count(*) filter (where send_status = 'delivered'), 0), 1)) v
      from (select 'variant' grp, variant key, * from r
            union all select 'slot', slot, * from r
            union all select 'cell', variant || '/' || slot, * from r
            union all select 'version', variant || ' v' || coalesce(template_version::text, '?'), * from r) x
     group by grp, key)
  select jsonb_build_object('days', p_days, 'step', coalesce(p_step, 1),
    'variants', coalesce((select jsonb_agg(v || jsonb_build_object('variant', key) order by key) from score where grp = 'variant'), '[]'::jsonb),
    'slots', coalesce((select jsonb_agg(v || jsonb_build_object('slot', key) order by key) from score where grp = 'slot'), '[]'::jsonb),
    'cells', coalesce((select jsonb_agg(v || jsonb_build_object('cell', key) order by key) from score where grp = 'cell'), '[]'::jsonb),
    'versions', coalesce((select jsonb_agg(sc.v || jsonb_build_object('version', sc.key, 'ran_from', t.active_from, 'ran_to', t.active_to, 'name', t.name) order by sc.key)
                 from score sc left join public.text_templates t on sc.key = t.variant || ' v' || t.version where sc.grp = 'version'), '[]'::jsonb))
$$;

revoke all on function public.agent_text_templates(), public.agent_set_text_template(text, text, text, text, text), public.records_set_request(jsonb, text),
  public.agent_log_call(uuid, text, text, boolean, text, integer), public.agent_test_results(integer, integer), public.agent_key_check(text) from public, anon, authenticated;
grant execute on function public.agent_text_templates(), public.agent_set_text_template(text, text, text, text, text), public.records_set_request(jsonb, text),
  public.agent_log_call(uuid, text, text, boolean, text, integer), public.agent_test_results(integer, integer), public.agent_key_check(text) to service_role;
revoke all on function public.create_agent_key(text, text, text[]), public.set_agent_key_scopes(uuid, text[]), public.list_agent_keys() from public, anon;
grant execute on function public.create_agent_key(text, text, text[]), public.set_agent_key_scopes(uuid, text[]), public.list_agent_keys() to authenticated;
drop function if exists public.create_agent_key(text, text);
