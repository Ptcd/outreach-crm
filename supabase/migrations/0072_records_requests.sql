-- Records requests through the agent door (Colin 2026-10-26: "make muse a gate to manage our emailed out lead building
-- stuff"; "Muse drafts and tracks, but I approve each batch before it sends"). The public-records letters to the
-- municipal clerks and the county Registers of Deeds move from CSV trackers on the laptop to the app:
--   records_requests  one row per clerk or Register of Deeds: where it goes, where it stands, what came back
--   records_drafts    the letters the agent writes (a first request, a follow-up, a narrower re-ask)
--   records_batches   drafts the agent proposes together; nothing sends until Colin approves the batch in the app
--   records_replies   what clerks write back, copied in from the records mailbox by the laptop
-- The laptop (tools/records_bridge.py, run by the live cycle) sends ONLY approved batches, with the same mail code as
-- before, and writes back the Message-ID; it copies new replies in. The agent reads replies and marks the requests.

create table if not exists public.records_requests (
  id              uuid primary key default gen_random_uuid(),
  kind            text not null check (kind in ('municipal', 'rod')),
  name            text not null,                  -- "City of Franklin", or the county for a Register of Deeds
  county          text,
  to_email        text,
  alt_email       text,
  form_url        text,
  status          text not null default 'draft' check (status in ('draft', 'sent', 'acknowledged', 'replied', 'received', 'no_records',
                    'needs_payment', 'denied', 'bounced', 'skip')),
  sent_date       date,
  message_id      text,
  received_date   date,
  records_through text,
  next_due        date,
  notes           text,
  updated_at      timestamptz not null default now(),
  unique (kind, name)
);

create table if not exists public.records_drafts (
  id          uuid primary key default gen_random_uuid(),
  request_id  uuid not null references public.records_requests(id) on delete cascade,
  purpose     text not null default 'request' check (purpose in ('request', 'follow_up', 're_request', 'reply')),
  to_email    text not null,
  cc          text,
  subject     text not null,
  body        text not null,
  in_reply_to text,
  status      text not null default 'draft' check (status in ('draft', 'in_batch', 'approved', 'sending', 'sent', 'failed', 'rejected', 'superseded')),
  batch_id    uuid,
  written_by  text,
  created_at  timestamptz not null default now(),
  sent_at     timestamptz,
  message_id  text,
  error       text
);

create table if not exists public.records_batches (
  id          uuid primary key default gen_random_uuid(),
  proposed_by text,
  note        text,
  status      text not null default 'proposed' check (status in ('proposed', 'approved', 'rejected', 'sending', 'sent')),
  created_at  timestamptz not null default now(),
  decided_at  timestamptz,
  decided_by  text,
  sent_at     timestamptz,
  result      jsonb
);
alter table public.records_drafts add constraint records_drafts_batch_fk foreign key (batch_id) references public.records_batches(id) on delete set null;

create table if not exists public.records_replies (
  id           uuid primary key default gen_random_uuid(),
  request_id   uuid references public.records_requests(id) on delete set null,
  message_id   text unique,
  in_reply_to  text,
  from_addr    text,
  subject      text,
  received_at  timestamptz,
  body         text,
  attachments  jsonb not null default '[]'::jsonb,
  bounce       boolean not null default false,
  handled_at   timestamptz,
  handled_by   text,
  created_at   timestamptz not null default now()
);

alter table public.records_requests enable row level security;
alter table public.records_drafts enable row level security;
alter table public.records_batches enable row level security;
alter table public.records_replies enable row level security;
create policy records_requests_owner on public.records_requests for select to authenticated using (public.is_owner());
create policy records_drafts_owner on public.records_drafts for select to authenticated using (public.is_owner());
create policy records_batches_owner on public.records_batches for select to authenticated using (public.is_owner());
create policy records_replies_owner on public.records_replies for select to authenticated using (public.is_owner());

-- ------------------------------------------------------------------ the agent's side (records key)
create or replace function public.records_overview() returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'by_status', (select coalesce(jsonb_object_agg(k || ':' || s, n), '{}') from (select kind k, status s, count(*) n from public.records_requests group by 1, 2) a),
    'due', (select count(*) from public.records_requests where status = 'draft' or (next_due is not null and next_due <= current_date)
              or (status = 'sent' and sent_date <= current_date - 14)),
    'replies_unhandled', (select count(*) from public.records_replies where handled_at is null),
    'drafts_waiting', (select count(*) from public.records_drafts where status = 'draft'),
    'batches_waiting_for_colin', (select count(*) from public.records_batches where status = 'proposed'),
    'approved_not_sent', (select count(*) from public.records_batches where status in ('approved', 'sending')))
$$;

create or replace function public.records_list(p_filter text default 'due', p_limit integer default 100) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'request_id', r.id, 'kind', r.kind, 'name', r.name, 'county', r.county, 'to_email', r.to_email, 'alt_email', r.alt_email,
           'form_url', r.form_url, 'status', r.status, 'sent_date', r.sent_date, 'received_date', r.received_date,
           'records_through', r.records_through, 'next_due', r.next_due, 'notes', r.notes,
           'why_due', case when r.status = 'draft' then 'never sent'
                           when r.next_due is not null and r.next_due <= current_date then 're-request date reached'
                           when r.status = 'sent' and r.sent_date <= current_date - 14 then 'no answer in 14 days: follow up' end,
           'drafts', (select jsonb_agg(jsonb_build_object('draft_id', d.id, 'purpose', d.purpose, 'status', d.status, 'subject', d.subject, 'created_at', d.created_at))
                        from public.records_drafts d where d.request_id = r.id and d.status not in ('superseded', 'rejected')),
           'replies', (select jsonb_agg(jsonb_build_object('reply_id', x.id, 'from', x.from_addr, 'subject', x.subject, 'at', x.received_at,
                         'handled', x.handled_at is not null) order by x.received_at) from public.records_replies x where x.request_id = r.id))
           order by r.kind, r.name), '[]'::jsonb)
    from (select * from public.records_requests r
           where case coalesce(p_filter, 'due')
                   when 'all' then true
                   when 'due' then r.status = 'draft' or (r.next_due is not null and r.next_due <= current_date) or (r.status = 'sent' and r.sent_date <= current_date - 14)
                   else r.status = p_filter end
           order by r.kind, r.name limit greatest(1, least(p_limit, 500))) r
$$;

create or replace function public.records_save_draft(p_request_id uuid, p_purpose text, p_to text, p_cc text, p_subject text, p_body text,
  p_in_reply_to text, p_agent text) returns jsonb language plpgsql security definer set search_path = public as $$
declare id uuid;
begin
  if not exists (select 1 from public.records_requests where records_requests.id = p_request_id) then return jsonb_build_object('ok', false, 'reason', 'no such request'); end if;
  if coalesce(p_to, '') !~ '^[^@\s]+@[^@\s]+\.[a-z]{2,}$' then return jsonb_build_object('ok', false, 'reason', 'to is not an email address'); end if;
  if length(coalesce(p_subject, '')) < 5 or length(coalesce(p_body, '')) < 40 then return jsonb_build_object('ok', false, 'reason', 'subject and body are required'); end if;
  if p_body ~* '(cash|we buy houses|investor|buy your|sell your)' then return jsonb_build_object('ok', false, 'reason', 'a records request asks for records: no buying talk'); end if;
  update public.records_drafts set status = 'superseded' where request_id = p_request_id and status = 'draft';
  insert into public.records_drafts (request_id, purpose, to_email, cc, subject, body, in_reply_to, written_by)
  values (p_request_id, coalesce(nullif(p_purpose, ''), 'request'), btrim(p_to), nullif(btrim(coalesce(p_cc, '')), ''), btrim(p_subject), p_body,
          nullif(btrim(coalesce(p_in_reply_to, '')), ''), p_agent)
  returning records_drafts.id into id;
  return jsonb_build_object('ok', true, 'draft_id', id);
end $$;

create or replace function public.records_propose_batch(p_draft_ids uuid[], p_note text, p_agent text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare b uuid; n integer;
begin
  if coalesce(array_length(p_draft_ids, 1), 0) = 0 then return jsonb_build_object('ok', false, 'reason', 'no drafts'); end if;
  if array_length(p_draft_ids, 1) > 40 then return jsonb_build_object('ok', false, 'reason', 'at most 40 letters in a batch (the mailbox has a daily cap)'); end if;
  insert into public.records_batches (proposed_by, note) values (p_agent, p_note) returning id into b;
  update public.records_drafts set status = 'in_batch', batch_id = b where id = any(p_draft_ids) and status = 'draft';
  get diagnostics n = row_count;
  if n = 0 then delete from public.records_batches where id = b; return jsonb_build_object('ok', false, 'reason', 'none of those drafts are open'); end if;
  return jsonb_build_object('ok', true, 'batch_id', b, 'letters', n, 'note', 'waiting for Colin to approve in the app');
end $$;

create or replace function public.records_replies_list(p_unhandled boolean default true, p_limit integer default 50) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('reply_id', x.id, 'request_id', x.request_id, 'request', r.name, 'kind', r.kind, 'status', r.status,
           'from', x.from_addr, 'subject', x.subject, 'at', x.received_at, 'bounce', x.bounce, 'body', left(x.body, 6000),
           'attachments', x.attachments, 'handled', x.handled_at is not null) order by x.received_at), '[]'::jsonb)
    from (select * from public.records_replies where (not p_unhandled or handled_at is null) order by received_at limit greatest(1, least(p_limit, 200))) x
    left join public.records_requests r on r.id = x.request_id
$$;

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
    next_due = case when p_next_due is not null then p_next_due when p_status in ('received', 'no_records') then coalesce(p_received_date, current_date) + 90 else next_due end,
    to_email = coalesce(nullif(btrim(coalesce(p_to_email, '')), ''), to_email),
    notes = case when nullif(p_note, '') is null then notes else concat_ws(' | ', notes, to_char(current_date, 'YYYY-MM-DD') || ' ' || coalesce(p_agent, 'agent') || ': ' || p_note) end,
    updated_at = now()
   where id = p_request_id;
  if p_reply_id is not null then update public.records_replies set handled_at = now(), handled_by = p_agent, request_id = coalesce(request_id, p_request_id) where id = p_reply_id; end if;
  return jsonb_build_object('ok', true, 'request', (select to_jsonb(x) - 'notes' from public.records_requests x where x.id = p_request_id));
end $$;

-- ------------------------------------------------------------------ Colin's side (the app)
create or replace function public.records_batches_waiting() returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_owner() then raise exception 'only Colin approves records requests'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('batch_id', b.id, 'proposed_by', b.proposed_by, 'note', b.note, 'created_at', b.created_at,
           'letters', (select jsonb_agg(jsonb_build_object('draft_id', d.id, 'to', r.name, 'kind', r.kind, 'to_email', d.to_email, 'cc', d.cc,
                         'purpose', d.purpose, 'subject', d.subject, 'body', d.body) order by r.name)
                         from public.records_drafts d join public.records_requests r on r.id = d.request_id where d.batch_id = b.id))
           order by b.created_at) from public.records_batches b where b.status = 'proposed'), '[]'::jsonb);
end $$;

create or replace function public.records_decide_batch(p_batch_id uuid, p_approve boolean, p_drop uuid[] default '{}') returns jsonb
language plpgsql security definer set search_path = public as $$
declare who text; n integer;
begin
  if not public.is_owner() then raise exception 'only Colin approves records requests'; end if;
  select display_name into who from public.team_members where lower(email) = lower(auth.jwt() ->> 'email');
  if not exists (select 1 from public.records_batches where id = p_batch_id and status = 'proposed') then
    return jsonb_build_object('ok', false, 'reason', 'that batch is not waiting');
  end if;
  if coalesce(array_length(p_drop, 1), 0) > 0 then
    update public.records_drafts set status = 'rejected', batch_id = null where batch_id = p_batch_id and id = any(p_drop);
  end if;
  if p_approve then
    update public.records_drafts set status = 'approved' where batch_id = p_batch_id and status = 'in_batch';
    get diagnostics n = row_count;
    update public.records_batches set status = case when n > 0 then 'approved' else 'rejected' end, decided_at = now(), decided_by = coalesce(who, 'Colin') where id = p_batch_id;
  else
    update public.records_drafts set status = 'rejected' where batch_id = p_batch_id and status = 'in_batch';
    update public.records_batches set status = 'rejected', decided_at = now(), decided_by = coalesce(who, 'Colin') where id = p_batch_id;
    n := 0;
  end if;
  return jsonb_build_object('ok', true, 'approved_letters', n);
end $$;

-- ------------------------------------------------------------------ the laptop's side (service role)
create or replace function public.records_claim_approved() returns jsonb language plpgsql security definer set search_path = public as $$
declare out jsonb;
begin
  with c as (
    update public.records_drafts d set status = 'sending'
     where d.status = 'approved' and d.batch_id in (select id from public.records_batches where status in ('approved', 'sending'))
    returning d.*)
  select coalesce(jsonb_agg(jsonb_build_object('draft_id', c.id, 'batch_id', c.batch_id, 'request_id', c.request_id, 'kind', r.kind, 'name', r.name,
           'to', c.to_email, 'cc', c.cc, 'subject', c.subject, 'body', c.body, 'in_reply_to', c.in_reply_to)), '[]'::jsonb) into out
    from c join public.records_requests r on r.id = c.request_id;
  update public.records_batches set status = 'sending' where status = 'approved'
     and exists (select 1 from public.records_drafts d where d.batch_id = records_batches.id and d.status = 'sending');
  return out;
end $$;

create or replace function public.records_sent(p_draft_id uuid, p_ok boolean, p_message_id text, p_error text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d public.records_drafts;
begin
  update public.records_drafts set status = case when p_ok then 'sent' else 'failed' end, sent_at = case when p_ok then now() end,
         message_id = p_message_id, error = left(p_error, 500) where id = p_draft_id and status = 'sending' returning * into d;
  if not found then return jsonb_build_object('ok', false); end if;
  if p_ok then
    update public.records_requests set status = case when d.purpose in ('request', 're_request') then 'sent' else status end,
           sent_date = case when d.purpose in ('request', 're_request') then current_date else sent_date end,
           message_id = case when d.purpose in ('request', 're_request') then p_message_id else message_id end,
           notes = concat_ws(' | ', notes, to_char(current_date, 'YYYY-MM-DD') || ' sent ' || d.purpose || ' (approved batch)'), updated_at = now()
     where id = d.request_id;
  end if;
  update public.records_batches b set status = 'sent', sent_at = now()
   where b.id = d.batch_id and not exists (select 1 from public.records_drafts x where x.batch_id = b.id and x.status in ('approved', 'sending'));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.records_add_reply(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare rid uuid; id uuid;
begin
  select r.id into rid from public.records_requests r
   where (nullif(p->>'in_reply_to', '') is not null and (r.message_id = p->>'in_reply_to'
          or exists (select 1 from public.records_drafts d where d.request_id = r.id and d.message_id = p->>'in_reply_to')))
      or lower(coalesce(r.to_email, '')) = lower(coalesce(p->>'from', '')) or lower(coalesce(r.alt_email, '')) = lower(coalesce(p->>'from', ''))
   order by (r.message_id = p->>'in_reply_to') desc nulls last limit 1;
  if rid is null and position('@' in coalesce(p->>'from', '')) > 0 then
    select r.id into rid from public.records_requests r
     where split_part(lower(coalesce(r.to_email, '')), '@', 2) = split_part(lower(p->>'from'), '@', 2) and split_part(lower(p->>'from'), '@', 2) <> 'gmail.com' limit 1;
  end if;
  insert into public.records_replies (request_id, message_id, in_reply_to, from_addr, subject, received_at, body, attachments, bounce)
  values (rid, p->>'message_id', nullif(p->>'in_reply_to', ''), p->>'from', p->>'subject', (p->>'received_at')::timestamptz, left(p->>'body', 20000),
          coalesce(p->'attachments', '[]'::jsonb), coalesce((p->>'bounce')::boolean, false))
  on conflict (message_id) do nothing returning records_replies.id into id;
  return jsonb_build_object('ok', id is not null, 'matched', rid is not null);
end $$;

create or replace function public.records_upsert_request(p jsonb) returns uuid language plpgsql security definer set search_path = public as $$
declare id uuid;
begin
  insert into public.records_requests (kind, name, county, to_email, alt_email, form_url, status, sent_date, message_id, received_date,
                                       records_through, next_due, notes)
  values (p->>'kind', p->>'name', nullif(p->>'county', ''), nullif(p->>'to_email', ''), nullif(p->>'alt_email', ''), nullif(p->>'form_url', ''),
          coalesce(nullif(p->>'status', ''), 'draft'), nullif(p->>'sent_date', '')::date, nullif(p->>'message_id', ''),
          nullif(p->>'received_date', '')::date, nullif(p->>'records_through', ''), nullif(p->>'next_due', '')::date, nullif(p->>'notes', ''))
  on conflict (kind, name) do nothing
  returning records_requests.id into id;
  return id;
end $$;

revoke all on function public.records_overview(), public.records_list(text, integer), public.records_save_draft(uuid, text, text, text, text, text, text, text),
  public.records_propose_batch(uuid[], text, text), public.records_replies_list(boolean, integer),
  public.records_mark(uuid, text, text, date, text, date, text, uuid, text), public.records_claim_approved(), public.records_sent(uuid, boolean, text, text),
  public.records_add_reply(jsonb), public.records_upsert_request(jsonb) from public, anon, authenticated;
grant execute on function public.records_overview(), public.records_list(text, integer), public.records_save_draft(uuid, text, text, text, text, text, text, text),
  public.records_propose_batch(uuid[], text, text), public.records_replies_list(boolean, integer),
  public.records_mark(uuid, text, text, date, text, date, text, uuid, text), public.records_claim_approved(), public.records_sent(uuid, boolean, text, text),
  public.records_add_reply(jsonb), public.records_upsert_request(jsonb) to service_role;
revoke all on function public.records_batches_waiting(), public.records_decide_batch(uuid, boolean, uuid[]) from public, anon;
grant execute on function public.records_batches_waiting(), public.records_decide_batch(uuid, boolean, uuid[]) to authenticated;

-- the agent key gains a third role
alter table public.agent_keys drop constraint if exists agent_keys_role_check;
alter table public.agent_keys add constraint agent_keys_role_check check (role in ('intake', 'sender', 'records'));
create or replace function public.create_agent_key(p_name text, p_role text)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare k text;
begin
  if not public.is_owner() then raise exception 'only Colin can make an agent key'; end if;
  if p_role not in ('intake', 'sender', 'records') then raise exception 'role is intake, sender or records'; end if;
  if coalesce(btrim(p_name), '') = '' then raise exception 'give the key a name'; end if;
  k := 'wpie_' || p_role || '_' || replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  insert into public.agent_keys (name, role, key_sha256, key_hint, created_by)
  values (btrim(p_name), p_role, encode(sha256(convert_to(k, 'UTF8')), 'hex'), right(k, 4), public.wpie_person()::text);
  return k;
end $$;

-- the two letters, word for word from wpie/records/*.txt (fill {muni} / {county}, {start_date}, {last_roll})
create or replace function public.records_templates() returns jsonb language sql immutable as $fn$
  select jsonb_build_object(
    'municipal', $tpl$SUBJECT: Public records request - property code, utility, fire and vacancy records ({muni})

To the Records Custodian, {muni}:

Under Wisconsin's public records law, Wis. Stat. 19.31-19.39, I request copies of the following records for properties in the {muni}. For each, the property address and tax key / parcel number are the most useful fields; owner name and dates help too.

1. Code enforcement: building, property maintenance, health and zoning cases (orders, notices of violation, citations, reinspection fees) opened from {start_date} to the present, with date opened, type of violation and current status (open or closed). This includes junk or inoperable vehicle and zoning violations.

2. Condemnations and placards: properties declared unfit for habitation, unsafe or condemned, including after a fire, since {start_date}.

3. Charges billed to properties since {start_date}: abatement and special charges (grass or weed cutting, snow and ice removal, trash or junk removal, board-up, emergency repairs, razing costs), and any unpaid property-code citations or fines.

4. Water and sewer: accounts shut off or without service for non-payment, current accounts more than 90 days in arrears, and the delinquent water, sewer or other utility charges certified to the {last_roll} tax roll, with amounts.

5. Fire incidents: addresses of structure fires since {start_date} at one- to four-unit residential and small multifamily buildings, with the incident date and estimated loss if recorded. If the fire department keeps these records, please forward this item to its records custodian or tell me whom to ask.

6. Vacancy: any current list of properties registered or flagged as vacant or abandoned buildings, buildings flagged as unregistered, and any raze or demolition orders issued since {start_date}.

7. Rentals: if the {muni} runs a rental registration or inspection program, rental properties with failed inspections since {start_date}, and properties identified as unregistered rentals.

8. Chronic nuisance: any chronic nuisance premises notices issued since {start_date}.

I prefer the records in electronic form; a spreadsheet export from your permitting, code, utility or records system is ideal. If an export isn't possible, PDF copies are fine. If you'll charge fees over $25, please send me the estimate before filling the request. Where a list doesn't exist, the underlying records for these categories are fine. If some of these records are held by another office (for example the utility, the fire department or a contracted inspector), please let me know who to ask. If you can send the same lists again monthly, that would be ideal; otherwise I'll re-request.

If any part of this request is denied, please cite the specific exemption and release the remaining records.

Thank you,
Colin Merrill
(262) 418-0202
merrillholdings@gmail.com
$tpl$,
    'rod', $tpl$SUBJECT: Public records request - lis pendens and lien index, {county} County Register of Deeds

To the Register of Deeds, {county} County:

Under Wisconsin's public records law, Wis. Stat. 19.31-19.39, I request an index listing (not document copies) of the following documents recorded in {county} County from {start_date} to the present:

1. Lis pendens (notices of pending action), including those filed in foreclosure cases.
2. Federal tax liens and releases.
3. Construction liens.
4. Terminations of Decedent's Interest.
5. Any judgments, state tax warrants or other liens that your office records.

For each document, if available: document type, document number, recording date, the party names (grantor and grantee), and the legal description, tax parcel number or property address.

I prefer the index in electronic form; a spreadsheet or CSV export from your recording system is ideal, and PDF is fine if an export isn't possible. If you'll charge fees over $25, please send me the estimate before filling the request. If your office provides this data only through an online subscription service, please let me know which one and its terms. If you can send the same index again monthly, that would be ideal; otherwise I'll re-request.

If any part of this request is denied, please cite the specific exemption and release the remaining records.

Thank you,
Colin Merrill
(262) 418-0202
merrillholdings@gmail.com
$tpl$,
    'how', 'First line is SUBJECT: ...; the rest is the body. start_date = the day after records_through, else one year before today. last_roll = last year. A follow-up quotes the original subject with "Re:" and asks politely for a status or an estimated date; a re-request uses the same letter with start_date = the day after records_through.')
$fn$;
revoke all on function public.records_templates() from public, anon, authenticated;
grant execute on function public.records_templates() to service_role;
