-- The records agent (Colin 2026-10-28: the records agent scope v2, "set up as scheduled task"). A Claude session on
-- the laptop works the records grid through WPIE: it drafts, proposes and tracks here, the records bridge sends, and
-- Muse supervises. WPIE is the only shared surface (Muse 2026-10-28: "WPIE is the only shared surface. Requests,
-- drafts, batches, approvals, notes, fee items - all there").
--
-- 1. Sending pace. The bridge claimed every approved letter at once and the 15-minute step cut it off: on 10-27 it
--    took 198, sent 21, and 177 sat in "sending" since. Now a claim takes at most p_limit (the bridge asks for 12, which
--    fits the step), never more than records_settings.daily_cap (60, the scope's mailbox ceiling) sent in a Central day,
--    never a second letter to the same address on the same day (one ask per office per day), and a letter claimed more
--    than 30 minutes ago that never came back sent goes back to "approved".
-- 2. Row fields from the grid: office_kind, fee_status, next_action, refresh_offset, worked_by; statuses for the
--    scope's states (form_required, fee_quoted, stopped, parked, unverified).
-- 3. The ramp: the agent's first 7 days AND first 25 sent letters, whichever ends later. In the ramp the agent's
--    letters wait for Muse to release them (records_muse_decide); after it they go on standing approval. Never on
--    standing approval: a letter that mentions money, and the first DA / Attorney General letter in a county (Colin).
-- 4. The backlog throttle: Muse posts the unverified-address count (records_post_backlog); the agent reads it with
--    records_agent_state. Over 3,000, or a stamp older than 8 days: no new first requests. Under 2,000: open.
-- 5. records_log: the agent's and Muse's notes to each other (the scope's coordination log, in WPIE).

-- ------------------------------------------------------------------ 1. pace
alter table public.records_drafts add column if not exists claimed_at timestamptz;
alter table public.records_settings add column if not exists daily_cap integer not null default 60;

create or replace function public.records_claim_approved(p_limit integer default 40) returns jsonb
language plpgsql security definer set search_path = public as $$
declare out jsonb; s public.records_settings; today date := (now() at time zone 'America/Chicago')::date; sent_today integer; room integer;
begin
  select * into s from public.records_settings where id = 1;
  -- a claim that never came back (the step was cut off): back in line
  update public.records_drafts set status = 'approved', claimed_at = null
   where status = 'sending' and message_id is null and coalesce(claimed_at, created_at) < now() - interval '30 minutes';
  select count(*) into sent_today from public.records_drafts
   where (status = 'sent' and (sent_at at time zone 'America/Chicago')::date = today) or status = 'sending';
  room := greatest(0, least(coalesce(p_limit, 40), 40, coalesce(s.daily_cap, 60) - sent_today));
  if room = 0 then return '[]'::jsonb; end if;
  with cand as (
    select d.id, d.to_email, d.created_at from public.records_drafts d
     where d.status = 'approved' and d.batch_id in (select id from public.records_batches where status in ('approved', 'sending'))
       -- one ask per office per day: nothing already sent (or going) to that address today
       and not exists (select 1 from public.records_drafts x where lower(btrim(x.to_email)) = lower(btrim(d.to_email)) and x.id <> d.id
                         and ((x.status = 'sent' and (x.sent_at at time zone 'America/Chicago')::date = today) or x.status = 'sending'))
     order by d.created_at, d.id),
  one_each as (select distinct on (lower(btrim(to_email))) id, created_at from cand order by lower(btrim(to_email)), created_at, id),
  pick as (select o.id from one_each o order by o.created_at, o.id limit room),
  c as (
    update public.records_drafts d set status = 'sending', claimed_at = now() from pick where d.id = pick.id
    returning d.*)
  select coalesce(jsonb_agg(jsonb_build_object('draft_id', c.id, 'batch_id', c.batch_id, 'request_id', c.request_id, 'kind', r.kind, 'name', r.name,
           'to', c.to_email, 'cc', c.cc, 'subject', c.subject, 'body', c.body, 'in_reply_to', c.in_reply_to)), '[]'::jsonb) into out
    from c join public.records_requests r on r.id = c.request_id;
  update public.records_batches set status = 'sending' where status = 'approved'
     and exists (select 1 from public.records_drafts d where d.batch_id = records_batches.id and d.status = 'sending');
  return out;
end $$;
drop function if exists public.records_claim_approved();
revoke all on function public.records_claim_approved(integer) from public, anon, authenticated;
grant execute on function public.records_claim_approved(integer) to service_role;

-- the 177 water letters cut off on 10-27 (Colin approved them: "Send em"; 23 of 200 went, each with its saved copy)
update public.records_drafts set status = 'approved', claimed_at = null where status = 'sending' and message_id is null;

-- ------------------------------------------------------------------ 2. row fields
alter table public.records_requests add column if not exists office_kind text;
alter table public.records_requests add column if not exists fee_status text;
alter table public.records_requests add column if not exists next_action text;
alter table public.records_requests add column if not exists refresh_offset integer not null default 0 check (refresh_offset between 0 and 13);
alter table public.records_requests add column if not exists worked_by text not null default 'muse' check (worked_by in ('muse', 'records_agent'));
alter table public.records_requests add column if not exists last_data_received date;
alter table public.records_requests add column if not exists phone text;
alter table public.records_requests drop constraint if exists records_requests_status_check;
alter table public.records_requests add constraint records_requests_status_check check (status in ('draft', 'sent', 'acknowledged', 'replied',
  'received', 'no_records', 'needs_payment', 'denied', 'bounced', 'skip', 'unverified', 'form_required', 'fee_quoted', 'stopped', 'parked'));
alter table public.records_requests drop constraint if exists records_requests_kind_check;
alter table public.records_requests add constraint records_requests_kind_check
  check (kind in ('municipal', 'rod', 'treasurer', 'clerk_of_court', 'sheriff', 'police', 'utility', 'fire', 'web'));
alter table public.records_drafts drop constraint if exists records_drafts_purpose_check;
alter table public.records_drafts add constraint records_drafts_purpose_check
  check (purpose in ('request', 'follow_up', 're_request', 'reply', 'form', 'fee', 'enforcement'));

-- ------------------------------------------------------------------ 5. the log (first: the state reads it)
create table if not exists public.records_log (
  id          bigserial primary key,
  at          timestamptz not null default now(),
  author      text not null,
  for_whom    text not null default 'muse' check (for_whom in ('muse', 'records_agent', 'colin', 'all')),
  request_id  uuid references public.records_requests(id) on delete set null,
  note        text not null,
  resolved_at timestamptz,
  resolved_by text
);
create index if not exists records_log_open on public.records_log (for_whom, at) where resolved_at is null;
alter table public.records_log enable row level security;
drop policy if exists records_log_read on public.records_log;
create policy records_log_read on public.records_log for select to authenticated using (public.is_team());
grant select on public.records_log to authenticated;

-- ------------------------------------------------------------------ 3. ramp, 4. throttle
alter table public.records_settings add column if not exists ramp_started date;
alter table public.records_settings add column if not exists ramp_days integer not null default 7;
alter table public.records_settings add column if not exists ramp_letters integer not null default 25;
alter table public.records_settings add column if not exists ramp_reinstated_at timestamptz;
alter table public.records_settings add column if not exists backlog_count integer;
alter table public.records_settings add column if not exists backlog_stamped_at timestamptz;
alter table public.records_settings add column if not exists backlog_note text;

create or replace function public.records_agent_state() returns jsonb language sql stable security definer set search_path = public as $$
  with s as (select * from public.records_settings where id = 1),
  agent_sent as (
    select count(*) n from public.records_drafts d, s
     where d.written_by = 'records_agent' and d.status = 'sent'
       and d.sent_at >= coalesce(s.ramp_started::timestamptz, now())),
  ramp as (
    -- on the ramp: until 7 days have passed AND 25 of the agent's letters have gone; and again after a failed audit,
    -- until Muse clears it
    select s.ramp_started is null or s.ramp_reinstated_at is not null
           or current_date < s.ramp_started + s.ramp_days or (select n from agent_sent) < s.ramp_letters as on_ramp
      from s)
  select jsonb_build_object(
    'ramp', (select on_ramp from ramp),
    'ramp_started', (select ramp_started from s),
    'ramp_letters_sent', (select n from agent_sent), 'ramp_needs', (select ramp_letters from s),
    'ramp_ends_no_earlier_than', (select coalesce(ramp_started, current_date) + ramp_days from s),
    'sent_today', (select count(*) from public.records_drafts where status = 'sent' and (sent_at at time zone 'America/Chicago')::date = (now() at time zone 'America/Chicago')::date),
    'daily_cap', (select daily_cap from s),
    'backlog_count', (select backlog_count from s), 'backlog_stamped_at', (select backlog_stamped_at from s),
    'new_first_requests', (select case
        when backlog_stamped_at is null or backlog_stamped_at < now() - interval '8 days' then 'paused: no fresh backlog stamp (fail closed)'
        when backlog_count > 3000 then 'paused: backlog over 3,000'
        when backlog_count >= 2000 then 'hold steady: backlog 2,000-3,000, open nothing new'
        else 'open' end from s),
    'unread_log', (select count(*) from public.records_log l where l.for_whom = 'records_agent' and l.resolved_at is null))
$$;

create or replace function public.records_post_backlog(p_count integer, p_note text, p_agent text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if p_count is null or p_count < 0 then return jsonb_build_object('ok', false, 'reason', 'count is the number of unverified addresses (0 or more)'); end if;
  update public.records_settings set backlog_count = p_count, backlog_stamped_at = now(), backlog_note = left(p_note, 300), updated_at = now() where id = 1;
  insert into public.records_log (author, for_whom, note) values (coalesce(p_agent, 'muse'), 'records_agent',
    format('backlog stamp: %s unverified addresses%s', p_count, coalesce(' (' || nullif(btrim(p_note), '') || ')', '')));
  return public.records_agent_state();
end $$;

-- ------------------------------------------------------------------ 5. the log

create or replace function public.records_log_write(p_author text, p_for text, p_note text, p_request_id uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v bigint;
begin
  if coalesce(btrim(p_note), '') = '' then return jsonb_build_object('ok', false, 'reason', 'a note needs words'); end if;
  insert into public.records_log (author, for_whom, note, request_id) values (p_author, coalesce(nullif(p_for, ''), 'all'), left(p_note, 4000), p_request_id)
  returning id into v;
  return jsonb_build_object('ok', true, 'id', v);
end $$;

create or replace function public.records_log_read(p_for text, p_days integer default 7, p_unresolved boolean default false) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'at', l.at, 'author', l.author, 'for', l.for_whom, 'note', l.note,
           'request', (select r.name from public.records_requests r where r.id = l.request_id), 'request_id', l.request_id,
           'resolved_at', l.resolved_at) order by l.at desc), '[]'::jsonb)
    from public.records_log l
   where l.at > now() - make_interval(days => greatest(1, least(coalesce(p_days, 7), 90)))
     and (p_for is null or l.for_whom in (p_for, 'all') or l.author = p_for)
     and (not p_unresolved or l.resolved_at is null)
$$;

create or replace function public.records_log_resolve(p_id bigint, p_by text) returns jsonb
language sql security definer set search_path = public as $$
  update public.records_log set resolved_at = now(), resolved_by = p_by where id = p_id and resolved_at is null
  returning jsonb_build_object('ok', true, 'id', id)
$$;

-- ------------------------------------------------------------------ 3. ramp: who approves what
create or replace function public.records_draft_standing(p_draft_id uuid) returns text
language sql stable security definer set search_path = public as $$
  -- null when this letter may go on standing approval; otherwise why not
  select case
    when d.id is null then 'no such draft'
    when d.body ~* '(\$|agree to pay|will pay|happy to pay|invoice me|enclosed (is )?(a )?(check|payment))' then 'mentions money: Colin approves it'
    when d.purpose = 'enforcement' and not exists (select 1 from public.records_drafts x join public.records_requests rx on rx.id = x.request_id
                    where x.purpose = 'enforcement' and x.status = 'sent' and rx.county = r.county)
      then 'the first DA / Attorney General letter in ' || coalesce(r.county, 'this county') || ': Colin approves it after the summary'
    when d.written_by = 'records_agent' and (public.records_agent_state()->>'ramp')::boolean then 'ramp: Muse reviews and releases the agent''s letters'
    when d.written_by = 'records_agent' then null
    when r.standing_approval is false then 'this request needs Colin''s approval every time'
    when r.standing_approval is not true and not (d.purpose = any(s.standing_purposes)) then 'a ' || d.purpose || ' waits for Colin'
    when not exists (select 1 from public.records_drafts x where x.request_id = d.request_id and x.status = 'sent'
                       and lower(btrim(x.to_email)) = lower(btrim(d.to_email))) then 'nothing was sent to that address for this request yet'
    else null end
    from public.records_drafts d join public.records_requests r on r.id = d.request_id
    cross join public.records_settings s
   where d.id = p_draft_id and s.id = 1
$$;

-- Muse releases (or returns) the agent's letters in the ramp; never a money letter or a first DA/AG letter (Colin's)
create or replace function public.records_muse_decide(p_batch_id uuid, p_approve boolean, p_drop uuid[], p_note text, p_agent text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare n integer := 0; bad text;
begin
  if not exists (select 1 from public.records_batches where id = p_batch_id and status = 'proposed') then
    return jsonb_build_object('ok', false, 'reason', 'that batch is not waiting');
  end if;
  select string_agg(public.records_draft_standing(d.id), '; ') into bad from public.records_drafts d
   where d.batch_id = p_batch_id and d.status = 'in_batch' and not (d.id = any(coalesce(p_drop, '{}')))
     and (d.written_by is distinct from 'records_agent' or public.records_draft_standing(d.id) not like 'ramp:%');
  if p_approve and bad is not null then
    return jsonb_build_object('ok', false, 'reason', 'only Colin approves these: ' || bad || ' (drop them with drop[] to release the rest)');
  end if;
  if coalesce(array_length(p_drop, 1), 0) > 0 then
    update public.records_drafts set status = 'draft', batch_id = null where batch_id = p_batch_id and id = any(p_drop);
    insert into public.records_log (author, for_whom, note) values (coalesce(p_agent, 'muse'), 'records_agent',
      format('returned %s letter(s) from batch %s: %s', array_length(p_drop, 1), left(p_batch_id::text, 8), coalesce(p_note, 'see the drafts')));
  end if;
  if p_approve then
    update public.records_drafts set status = 'approved' where batch_id = p_batch_id and status = 'in_batch';
    get diagnostics n = row_count;
    update public.records_batches set status = case when n > 0 then 'approved' else 'rejected' end, decided_at = now(),
           decided_by = 'Muse (ramp review)' || coalesce(': ' || nullif(btrim(p_note), ''), '') where id = p_batch_id;
  else
    update public.records_drafts set status = 'draft', batch_id = null where batch_id = p_batch_id and status = 'in_batch';
    update public.records_batches set status = 'rejected', decided_at = now(), decided_by = 'Muse (ramp review)' where id = p_batch_id;
    insert into public.records_log (author, for_whom, note) values (coalesce(p_agent, 'muse'), 'records_agent',
      format('returned batch %s: %s', left(p_batch_id::text, 8), coalesce(p_note, 'see the drafts')));
  end if;
  return jsonb_build_object('ok', true, 'released', n);
end $$;

-- a failed audit puts the agent back on the ramp (Muse, from the weekly sample)
create or replace function public.records_reinstate_ramp(p_reason text, p_agent text, p_on boolean default true) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  update public.records_settings set ramp_reinstated_at = case when p_on then now() end, updated_at = now() where id = 1;
  insert into public.records_log (author, for_whom, note) values (coalesce(p_agent, 'muse'), 'all',
    case when p_on then 'ramp reinstated: ' || coalesce(p_reason, 'failed audit') else 'ramp cleared: ' || coalesce(p_reason, 'clean sample passed') end);
  return public.records_agent_state();
end $$;

-- the agent starts today
update public.records_settings set ramp_started = coalesce(ramp_started, (now() at time zone 'America/Chicago')::date) where id = 1;

revoke all on function public.records_agent_state(), public.records_post_backlog(integer, text, text), public.records_log_write(text, text, text, uuid),
  public.records_log_read(text, integer, boolean), public.records_log_resolve(bigint, text), public.records_muse_decide(uuid, boolean, uuid[], text, text),
  public.records_reinstate_ramp(text, text, boolean) from public, anon, authenticated;
grant execute on function public.records_agent_state(), public.records_post_backlog(integer, text, text), public.records_log_write(text, text, text, uuid),
  public.records_log_read(text, integer, boolean), public.records_log_resolve(bigint, text), public.records_muse_decide(uuid, boolean, uuid[], text, text),
  public.records_reinstate_ramp(text, text, boolean) to service_role;
