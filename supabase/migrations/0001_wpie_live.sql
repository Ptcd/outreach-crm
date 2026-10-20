-- WPIE live operating layer, v1.
--
-- One Postgres schema for Colin (owner) and Thalia (caller). WPIE's local SQLite
-- stays the source of truth for public-records facts; `python -m wpie.live.sync push`
-- (WPIE repo) copies the mailed owners, their phones and the campaign ledger in here
-- through SUPABASE_DB_URL, and `pull` reads stages, tasks and opener decisions back.
--
-- Fixed rule: nothing in this schema computes or suggests an offer, value or price.
-- deals.colin_offer is typed by Colin and only Colin (trigger below). No assessed
-- value, market value or sale price is ever copied in from WPIE.
--
-- Access: authenticated users who are listed in team_members (Colin = owner,
-- Thalia = caller). Everyone else, including anon, sees nothing. The sync connects
-- as the database owner (service connection), which is the only writer of WPIE facts.

-- ============================================================================ enums
create type public.lead_stage as enum (
  -- the states in wpie/reply/qualification.yaml, in pipeline order
  'postcard_mailed', 'opener_queued', 'opener_sent', 'reply_received', 'ai_qualifying',
  'handoff', 'colin_call', 'walk_decision', 'walkthrough_booked', 'offer', 'follow_up',
  'under_contract', 'closed_won', 'dead', 'closed_no_contact', 'dnc', 'data_fix',
  'mail_only', 'human_owned'
);
create type public.lead_lane as enum ('hold', 'flip');
create type public.app_role as enum ('owner', 'caller');
create type public.team_person as enum ('colin', 'thalia');
create type public.msg_direction as enum ('in', 'out');
create type public.msg_channel as enum ('sms', 'call', 'note');
create type public.contact_kind as enum ('phone', 'email');
create type public.contact_status as enum ('ok', 'bad');
create type public.gate_decision as enum ('walk', 'no_walk', 'one_more_call');
create type public.deal_status as enum ('offer', 'contract', 'closed', 'dead');
create type public.buyer_grade as enum ('A', 'B', 'C');
create type public.opener_decision as enum ('pending', 'approved', 'skipped');
create type public.milestone_kind as enum (
  -- scoreboard definitions, docs/ACQUISITION_SYSTEM_PLAYBOOK.md section 4
  'connect',          -- any person answered or replied
  'contact',          -- confirmed owner or someone with authority
  'lead',             -- a contact who would consider selling and gives a reason
  'handoff',          -- a lead with the must-fields and a booked call
  'handoff_held',     -- the call connected at the booked slot
  'qualifying_call',  -- Colin's qualifying call completed
  'walk'              -- walkthrough done
);

-- ===================================================================== team / roles
create table public.team_members (
  email       text primary key check (email = lower(email)),
  role        public.app_role not null,
  person      public.team_person not null unique,
  display_name text not null,
  created_at  timestamptz not null default now()
);
comment on table public.team_members is
  'Who may use the app. Matched on the signed-in email. Add Colin (owner) and Thalia (caller) here.';

-- The signed-in user's role, or null if they are not on the team.
create or replace function public.wpie_role() returns public.app_role
language sql stable security definer set search_path = public as $$
  select role from public.team_members
  where email = lower(coalesce(auth.jwt() ->> 'email', ''))
$$;

create or replace function public.wpie_person() returns public.team_person
language sql stable security definer set search_path = public as $$
  select person from public.team_members
  where email = lower(coalesce(auth.jwt() ->> 'email', ''))
$$;

create or replace function public.is_team() returns boolean
language sql stable as $$ select public.wpie_role() is not null $$;

create or replace function public.is_owner() returns boolean
language sql stable as $$ select coalesce(public.wpie_role() = 'owner', false) $$;

-- ======================================================================== helpers
create or replace function public.touch_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- ========================================================================== leads
create table public.leads (
  id               uuid primary key default gen_random_uuid(),
  wpie_owner_id    bigint unique,            -- WPIE owners.id; null only for a lead typed in the app
  owner_name       text not null,
  owner_type       text,
  mailing_street   text,
  mailing_city     text,
  mailing_state    text,
  mailing_zip      text,
  lane             public.lead_lane,
  county           text,
  municipality     text,
  property_address text,
  property_zip     text,
  wpie_property_id bigint,
  parcel_id        text,
  property_type    text,
  units            integer,
  reasons_to_sell  text[] not null default '{}',
  score            numeric,                  -- WPIE ranking score (signal strength), not a value
  mailed_on        date,
  mail_channel     text,
  stage            public.lead_stage not null default 'postcard_mailed',
  stage_changed_at timestamptz not null default now(),
  next_action_at   timestamptz,
  next_action      text,
  assigned_to      public.team_person,
  dead_reason      text,
  notes            text,
  last_inbound_at  timestamptz,
  synced_at        timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index leads_stage_idx on public.leads (stage);
create index leads_lane_county_idx on public.leads (lane, county);
create index leads_next_action_idx on public.leads (next_action_at) where next_action_at is not null;
create index leads_assigned_idx on public.leads (assigned_to, next_action_at);
create index leads_property_idx on public.leads (wpie_property_id);
create index leads_reasons_idx on public.leads using gin (reasons_to_sell);

create trigger leads_touch before update on public.leads
  for each row execute function public.touch_updated_at();

-- Stage history: every change, who made it (null user = the sync).
create table public.lead_stage_events (
  id          bigint generated always as identity primary key,
  lead_id     uuid not null references public.leads (id) on delete cascade,
  from_stage  public.lead_stage,
  to_stage    public.lead_stage not null,
  changed_by  uuid,
  source      text not null,                 -- 'app' or 'sync'
  at          timestamptz not null default now()
);
create index lead_stage_events_lead_idx on public.lead_stage_events (lead_id, at desc);
create index lead_stage_events_to_idx on public.lead_stage_events (to_stage, at);

create or replace function public.leads_stage_log() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into public.lead_stage_events (lead_id, from_stage, to_stage, changed_by, source)
    values (new.id, null, new.stage, auth.uid(), case when auth.uid() is null then 'sync' else 'app' end);
  elsif new.stage is distinct from old.stage then
    new.stage_changed_at := now();
    insert into public.lead_stage_events (lead_id, from_stage, to_stage, changed_by, source)
    values (new.id, old.stage, new.stage, auth.uid(), case when auth.uid() is null then 'sync' else 'app' end);
  end if;
  return new;
end $$;
create trigger leads_stage_log_ins after insert on public.leads
  for each row execute function public.leads_stage_log();
create trigger leads_stage_log_upd before update of stage on public.leads
  for each row execute function public.leads_stage_log();

-- Scoreboard milestones: first time each happens for a lead.
create table public.lead_milestones (
  id        bigint generated always as identity primary key,
  lead_id   uuid not null references public.leads (id) on delete cascade,
  kind      public.milestone_kind not null,
  at        timestamptz not null default now(),
  marked_by uuid default auth.uid(),
  note      text,
  unique (lead_id, kind)
);
create index lead_milestones_kind_idx on public.lead_milestones (kind, at);

-- ======================================================================= contacts
create table public.contacts (
  id               uuid primary key default gen_random_uuid(),
  lead_id          uuid not null references public.leads (id) on delete cascade,
  wpie_contact_id  bigint unique,            -- WPIE contacts.id; null for one added in the app
  kind             public.contact_kind not null default 'phone',
  value            text not null,
  value_normalized text,                     -- 10-digit phone, lower-case email
  person_name      text,
  line_type        text,                     -- mobile / landline / business / voip / unknown
  dnc_vendor       boolean not null default false,  -- the vendor's DNC flag
  dnc_scrub        text not null default 'unknown' check (dnc_scrub in ('unknown', 'clear', 'dnc')),
  suppressed       boolean not null default false,  -- on WPIE's STOP / suppression list
  dnc_app          boolean not null default false,  -- marked do-not-contact in this app
  source           text,
  status           public.contact_status not null default 'ok',
  wpie_status      text,
  confidence       numeric,
  note             text,
  synced_at        timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index contacts_lead_idx on public.contacts (lead_id);
create index contacts_value_idx on public.contacts (value_normalized);
create trigger contacts_touch before update on public.contacts
  for each row execute function public.touch_updated_at();

-- ======================================================================= messages
create table public.messages (
  id            uuid primary key default gen_random_uuid(),
  lead_id       uuid not null references public.leads (id) on delete cascade,
  contact_id    uuid references public.contacts (id) on delete set null,
  direction     public.msg_direction not null,
  channel       public.msg_channel not null,
  body          text,
  from_number   text,
  to_number     text,
  provider_sid  text unique,
  source_key    text unique,                 -- natural key from the sync, e.g. ledger:<owner>:<attempt>:opener
  status        text,                        -- ledger / Twilio status
  is_opener     boolean not null default false,
  is_opt_out    boolean not null default false,
  sent_at       timestamptz not null default now(),
  seen_at       timestamptz,
  seen_by       uuid,
  created_by    uuid default auth.uid(),
  created_at    timestamptz not null default now()
);
create index messages_lead_idx on public.messages (lead_id, sent_at desc);
create index messages_unseen_in_idx on public.messages (sent_at desc) where direction = 'in' and seen_at is null;
create index messages_opener_idx on public.messages (sent_at) where is_opener;

-- An inbound human reply is a "connect" and bumps the lead.
create or replace function public.messages_after_insert() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.direction = 'in' then
    update public.leads set last_inbound_at = greatest(coalesce(last_inbound_at, new.sent_at), new.sent_at)
    where id = new.lead_id;
    if not new.is_opt_out then
      insert into public.lead_milestones (lead_id, kind, at, marked_by)
      values (new.lead_id, 'connect', new.sent_at, null)
      on conflict (lead_id, kind) do nothing;
    end if;
  end if;
  return new;
end $$;
create trigger messages_after_insert after insert on public.messages
  for each row execute function public.messages_after_insert();

-- ========================================================================== tasks
create table public.tasks (
  id          uuid primary key default gen_random_uuid(),
  lead_id     uuid references public.leads (id) on delete cascade,
  due_at      timestamptz not null,
  kind        text not null default 'call',  -- call / text / letter / confirm_walk / follow-up bucket id
  owner       public.team_person not null,
  done_at     timestamptz,
  note        text,
  created_by  uuid default auth.uid(),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index tasks_open_idx on public.tasks (owner, due_at) where done_at is null;
create index tasks_lead_idx on public.tasks (lead_id);
create trigger tasks_touch before update on public.tasks
  for each row execute function public.touch_updated_at();

-- ==================================================================== gate scores
-- The walk / don't-walk gate, docs/SELLER_QUALIFICATION_LOGIC.md section b.
-- Six items, 0-2 each. suggested_decision applies the written pass rule; Colin's
-- own call is `decision`.
create or replace function public.gate_suggestion(
  reason_and_clock smallint, decision_makers smallint, number_and_anchor smallint,
  flexibility smallint, condition smallint, numbers_close smallint, hard_stops text[]
) returns public.gate_decision
language sql immutable as $$
  select case
    when coalesce(array_length(hard_stops, 1), 0) > 0 then 'no_walk'::public.gate_decision
    when numbers_close = 0 then 'no_walk'::public.gate_decision
    when decision_makers = 2
         and numbers_close >= 1
         and (flexibility >= 1 or numbers_close = 2)
         and ((reason_and_clock + decision_makers + number_and_anchor + flexibility + condition + numbers_close) >= 9
              or (numbers_close = 2
                  and (reason_and_clock + decision_makers + number_and_anchor + flexibility + condition + numbers_close) >= 7))
      then 'walk'::public.gate_decision
    when (reason_and_clock + decision_makers + number_and_anchor + flexibility + condition + numbers_close) >= 7
      then 'one_more_call'::public.gate_decision
    else 'no_walk'::public.gate_decision
  end
$$;

create table public.gate_scores (
  id                 uuid primary key default gen_random_uuid(),
  lead_id            uuid not null references public.leads (id) on delete cascade,
  reason_and_clock   smallint not null check (reason_and_clock between 0 and 2),
  decision_makers    smallint not null check (decision_makers between 0 and 2),
  number_and_anchor  smallint not null check (number_and_anchor between 0 and 2),
  flexibility        smallint not null check (flexibility between 0 and 2),
  condition          smallint not null check (condition between 0 and 2),
  numbers_close      smallint not null check (numbers_close between 0 and 2),
  hard_stops         text[] not null default '{}' check (hard_stops <@ array[
                       'dnc_or_no_contact', 'listed_active', 'no_authority',
                       'elderly_without_family', 'hold_lane_no_financials']::text[]),
  total              smallint generated always as (
                       reason_and_clock + decision_makers + number_and_anchor + flexibility + condition + numbers_close
                     ) stored,
  suggested_decision public.gate_decision generated always as (
                       public.gate_suggestion(reason_and_clock, decision_makers, number_and_anchor,
                                              flexibility, condition, numbers_close, hard_stops)
                     ) stored,
  decision           public.gate_decision not null,
  note               text,
  decided_by         uuid default auth.uid(),
  decided_by_name    text,
  at                 timestamptz not null default now()
);
create index gate_scores_lead_idx on public.gate_scores (lead_id, at desc);

-- ========================================================================== deals
create table public.deals (
  id            uuid primary key default gen_random_uuid(),
  lead_id       uuid not null references public.leads (id) on delete cascade,
  status        public.deal_status not null default 'offer',
  colin_offer   numeric(12, 2),              -- typed by Colin only; nothing generates it
  contract_date date,
  close_date    date,
  notes         text,
  created_by    uuid default auth.uid(),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index deals_lead_idx on public.deals (lead_id);
create index deals_contract_idx on public.deals (contract_date) where contract_date is not null;
create index deals_close_idx on public.deals (close_date) where close_date is not null;
create trigger deals_touch before update on public.deals
  for each row execute function public.touch_updated_at();

create or replace function public.deals_offer_guard() returns trigger
language plpgsql as $$
begin
  if (tg_op = 'INSERT' and new.colin_offer is not null)
     or (tg_op = 'UPDATE' and new.colin_offer is distinct from old.colin_offer) then
    if not public.is_owner() then
      raise exception 'colin_offer can only be entered by Colin (owner role)';
    end if;
  end if;
  return new;
end $$;
create trigger deals_offer_guard before insert or update on public.deals
  for each row execute function public.deals_offer_guard();

-- ========================================================================= buyers
-- Cash-buyer list stub (playbook section 6). Buy-box figures are what the buyer
-- told Colin; nothing here derives them.
create table public.buyers (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  entity        text,
  phones        text[] not null default '{}',
  email         text,
  buy_zips      text[] not null default '{}',
  buy_price_min numeric(12, 2),
  buy_price_max numeric(12, 2),
  buy_types     text[] not null default '{}',
  grade         public.buyer_grade not null default 'C',
  verified_at   timestamptz,
  notes         text,
  created_by    uuid default auth.uid(),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index buyers_grade_idx on public.buyers (grade);
create index buyers_zips_idx on public.buyers using gin (buy_zips);
create trigger buyers_touch before update on public.buyers
  for each row execute function public.touch_updated_at();

-- ================================================================ planned openers
-- WPIE's daily plan (data/campaign/plan_<date>.json), pushed by the sync. Colin
-- approves or skips here; the sync pulls decisions back. Sending stays in WPIE.
create table public.planned_openers (
  id             uuid primary key default gen_random_uuid(),
  plan_date      date not null,
  wpie_owner_id  bigint not null,
  attempt        integer not null default 1,
  lead_id        uuid references public.leads (id) on delete set null,
  lane           text,
  template_lane  text,
  variant        text,
  phone          text,
  body           text not null,
  segments       integer,
  scheduled_at   timestamptz,
  owner_name     text,
  property_address text,
  decision       public.opener_decision not null default 'pending',
  decided_by     uuid,
  decided_by_name text,
  decided_at     timestamptz,
  decision_note  text,
  synced_at      timestamptz,
  created_at     timestamptz not null default now(),
  unique (plan_date, wpie_owner_id, attempt)
);
create index planned_openers_day_idx on public.planned_openers (plan_date, decision);

-- ============================================================= scoreboard views
-- Definitions: docs/ACQUISITION_SYSTEM_PLAYBOOK.md section 4. Weeks start Monday,
-- Milwaukee time. Number 12 (profit per 1,000 owners) is not computed here.
create view public.scoreboard_facts with (security_invoker = true) as
  select m.lead_id, 'opener_sent'::text as metric, m.sent_at as at
    from public.messages m
   where m.direction = 'out' and m.is_opener and m.provider_sid is not null
  union all
  select m.lead_id, 'delivered', m.sent_at
    from public.messages m
   where m.direction = 'out' and m.is_opener and m.status = 'delivered'
  union all
  select m.lead_id, 'replied', min(m.sent_at)
    from public.messages m
   where m.direction = 'in' and not m.is_opt_out
   group by m.lead_id
  union all
  select m.lead_id, 'opted_out', min(m.sent_at)
    from public.messages m
   where m.direction = 'in' and m.is_opt_out
   group by m.lead_id
  union all
  select ms.lead_id, ms.kind::text, ms.at
    from public.lead_milestones ms
  union all
  select d.lead_id, 'contract', d.contract_date::timestamp at time zone 'America/Chicago'
    from public.deals d where d.contract_date is not null
  union all
  select d.lead_id, 'close', d.close_date::timestamp at time zone 'America/Chicago'
    from public.deals d where d.close_date is not null;

create view public.scoreboard_weekly with (security_invoker = true) as
  with f as (
    select date_trunc('week', f.at at time zone 'America/Chicago')::date as week_start,
           coalesce(l.lane::text, 'unknown') as lane, f.metric
      from public.scoreboard_facts f join public.leads l on l.id = f.lead_id
  ), c as (
    select week_start, coalesce(lane, 'all') as lane,
           count(*) filter (where metric = 'opener_sent')     as openers_sent,
           count(*) filter (where metric = 'delivered')       as delivered,
           count(*) filter (where metric = 'replied')         as replies,
           count(*) filter (where metric = 'opted_out')       as opt_outs,
           count(*) filter (where metric = 'connect')         as connects,
           count(*) filter (where metric = 'contact')         as contacts,
           count(*) filter (where metric = 'lead')            as leads,
           count(*) filter (where metric = 'handoff')         as handoffs,
           count(*) filter (where metric = 'handoff_held')    as handoffs_held,
           count(*) filter (where metric = 'qualifying_call') as qualifying_calls,
           count(*) filter (where metric = 'walk')            as walks,
           count(*) filter (where metric = 'contract')        as contracts,
           count(*) filter (where metric = 'close')           as closes
      from f
     group by grouping sets ((week_start, lane), (week_start))
  )
  select c.*,
         round(delivered::numeric / nullif(openers_sent, 0), 4)      as delivery_rate,
         round(replies::numeric / nullif(delivered, 0), 4)           as reply_rate,
         round(opt_outs::numeric / nullif(delivered, 0), 4)          as opt_out_rate,
         round(contacts::numeric / nullif(connects, 0), 4)           as contact_rate,
         round(leads::numeric / nullif(delivered, 0), 4)             as leads_per_delivered,
         round(handoffs_held::numeric / nullif(handoffs, 0), 4)      as handoffs_held_rate,
         round(walks::numeric / nullif(qualifying_calls, 0), 4)      as walk_rate,
         round(walks::numeric / nullif(contracts, 0), 2)             as walks_per_contract
    from c;

-- Same numbers split by WPIE signal (a lead with three reasons counts under each).
create view public.scoreboard_weekly_by_signal with (security_invoker = true) as
  select date_trunc('week', f.at at time zone 'America/Chicago')::date as week_start,
         r.signal,
         count(*) filter (where f.metric = 'opener_sent') as openers_sent,
         count(*) filter (where f.metric = 'delivered')   as delivered,
         count(*) filter (where f.metric = 'replied')     as replies,
         count(*) filter (where f.metric = 'opted_out')   as opt_outs,
         count(*) filter (where f.metric = 'lead')        as leads,
         count(*) filter (where f.metric = 'walk')        as walks,
         count(*) filter (where f.metric = 'contract')    as contracts
    from public.scoreboard_facts f
    join public.leads l on l.id = f.lead_id
    cross join lateral unnest(case when cardinality(l.reasons_to_sell) = 0 then array['(none)']
                                   else l.reasons_to_sell end) as r(signal)
   group by 1, 2;

-- Number 10, follow-up debt, is a snapshot: open leads 2+ days past their next action.
create view public.followup_debt with (security_invoker = true) as
  select l.id as lead_id, l.owner_name, l.property_address, l.stage, l.next_action_at,
         l.next_action, l.assigned_to,
         floor(extract(epoch from (now() - l.next_action_at)) / 86400)::int as days_late
    from public.leads l
   where l.next_action_at is not null
     and l.next_action_at < now() - interval '2 days'
     and l.stage not in ('closed_won', 'dead', 'closed_no_contact', 'dnc', 'mail_only');

create view public.pipeline_counts with (security_invoker = true) as
  select stage, lane, county, count(*)::int as n
    from public.leads group by stage, lane, county;

-- ================================================================== row security
alter table public.team_members      enable row level security;
alter table public.leads             enable row level security;
alter table public.lead_stage_events enable row level security;
alter table public.lead_milestones   enable row level security;
alter table public.contacts          enable row level security;
alter table public.messages          enable row level security;
alter table public.tasks             enable row level security;
alter table public.gate_scores       enable row level security;
alter table public.deals             enable row level security;
alter table public.buyers            enable row level security;
alter table public.planned_openers   enable row level security;

-- Nobody but the team, and nothing for anon.
revoke all on all tables in schema public from anon;
revoke all on all tables in schema public from authenticated;
revoke all on all sequences in schema public from anon;
grant usage on schema public to authenticated;

-- team_members: the team can see who is on it; only Colin changes it.
grant select, insert, update, delete on public.team_members to authenticated;
create policy team_read on public.team_members for select to authenticated using (public.is_team());
create policy team_owner_write on public.team_members for all to authenticated
  using (public.is_owner()) with check (public.is_owner());

-- leads: WPIE facts come from the sync; the app edits only the working columns.
grant select, insert on public.leads to authenticated;
grant update (stage, next_action_at, next_action, assigned_to, dead_reason, notes) on public.leads to authenticated;
grant delete on public.leads to authenticated;
create policy leads_read on public.leads for select to authenticated using (public.is_team());
create policy leads_insert on public.leads for insert to authenticated with check (public.is_team());
create policy leads_update on public.leads for update to authenticated using (public.is_team()) with check (public.is_team());
create policy leads_delete on public.leads for delete to authenticated using (public.is_owner());

grant select on public.lead_stage_events to authenticated;
create policy stage_events_read on public.lead_stage_events for select to authenticated using (public.is_team());

grant select, insert, delete on public.lead_milestones to authenticated;
grant usage on all sequences in schema public to authenticated;
create policy milestones_read on public.lead_milestones for select to authenticated using (public.is_team());
create policy milestones_insert on public.lead_milestones for insert to authenticated with check (public.is_team());
create policy milestones_delete on public.lead_milestones for delete to authenticated using (public.is_team());

grant select, insert on public.contacts to authenticated;
grant update (status, dnc_app, note) on public.contacts to authenticated;
create policy contacts_read on public.contacts for select to authenticated using (public.is_team());
create policy contacts_insert on public.contacts for insert to authenticated with check (public.is_team());
create policy contacts_update on public.contacts for update to authenticated using (public.is_team()) with check (public.is_team());

-- messages: SMS rows come only from the sync; the app logs calls and notes.
grant select, insert on public.messages to authenticated;
grant update (seen_at, seen_by) on public.messages to authenticated;
create policy messages_read on public.messages for select to authenticated using (public.is_team());
create policy messages_insert on public.messages for insert to authenticated
  with check (public.is_team() and channel in ('call', 'note') and provider_sid is null and source_key is null);
create policy messages_seen on public.messages for update to authenticated using (public.is_team()) with check (public.is_team());

grant select, insert, update, delete on public.tasks to authenticated;
create policy tasks_read on public.tasks for select to authenticated using (public.is_team());
create policy tasks_write on public.tasks for insert to authenticated with check (public.is_team());
create policy tasks_update on public.tasks for update to authenticated using (public.is_team()) with check (public.is_team());
create policy tasks_delete on public.tasks for delete to authenticated using (public.is_team());

-- gate: Colin scores; Thalia can read.
grant select, insert on public.gate_scores to authenticated;
create policy gate_read on public.gate_scores for select to authenticated using (public.is_team());
create policy gate_insert on public.gate_scores for insert to authenticated with check (public.is_owner());

-- deals: Colin only, read and write.
grant select, insert, update, delete on public.deals to authenticated;
create policy deals_owner on public.deals for all to authenticated
  using (public.is_owner()) with check (public.is_owner());

grant select, insert, update, delete on public.buyers to authenticated;
create policy buyers_read on public.buyers for select to authenticated using (public.is_team());
create policy buyers_write on public.buyers for insert to authenticated with check (public.is_team());
create policy buyers_update on public.buyers for update to authenticated using (public.is_team()) with check (public.is_team());
create policy buyers_delete on public.buyers for delete to authenticated using (public.is_owner());

-- planned openers: the team reads; Colin decides (decision columns only).
grant select on public.planned_openers to authenticated;
grant update (decision, decided_by, decided_by_name, decided_at, decision_note) on public.planned_openers to authenticated;
create policy openers_read on public.planned_openers for select to authenticated using (public.is_team());
create policy openers_decide on public.planned_openers for update to authenticated
  using (public.is_owner()) with check (public.is_owner());

grant select on public.scoreboard_facts, public.scoreboard_weekly, public.scoreboard_weekly_by_signal,
                public.followup_debt, public.pipeline_counts to authenticated;
grant execute on function public.wpie_role(), public.wpie_person(), public.is_team(), public.is_owner(),
                         public.gate_suggestion(smallint, smallint, smallint, smallint, smallint, smallint, text[])
  to authenticated;
