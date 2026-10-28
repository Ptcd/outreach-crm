-- Records follow-ups on standing approval (Muse 2026-10-28: "First requests keeping the batch-approval step is fine. But
-- follow-ups and re-requests on an already-approved template, to an office already asked, should be sendable without a
-- per-batch approval ... Right now the records engine sends those by email outside WPIE to hold the daily cadence,
-- which splits the record in two places").
--   * records_settings.standing_purposes (default follow_up, re_request): letters of those kinds go out on standing
--     approval when the request already had a letter sent to that same address. First requests and replies to a clerk
--     still wait for Colin's approval in the app. records_requests.standing_approval overrides it for one request
--     (true = always standing, false = never).
--   * records_propose_batch splits a proposal: the standing letters become a batch approved at once ("standing
--     approval"), the rest a batch waiting for Colin. Never a $ amount, a fee estimate or an offer to pay on standing
--     approval (Colin 2026-10-27: "don't ask for fees").
--   * records_claim_approved takes at most 40 letters a pass (the laptop sends 40 a pass): before, it marked every
--     approved letter "sending" at once, and a stopped pass stranded the rest.

create table if not exists public.records_settings (
  id integer primary key default 1 check (id = 1),
  standing_purposes text[] not null default '{follow_up,re_request}',
  updated_at timestamptz not null default now()
);
insert into public.records_settings (id) values (1) on conflict (id) do nothing;
grant select on public.records_settings to authenticated;
alter table public.records_settings enable row level security;
drop policy if exists records_settings_read on public.records_settings;
create policy records_settings_read on public.records_settings for select to authenticated using (public.is_team());

alter table public.records_requests add column if not exists standing_approval boolean;

create or replace function public.records_draft_standing(p_draft_id uuid) returns text
language sql stable security definer set search_path = public as $$
  -- null when this letter may go on standing approval; otherwise why not
  select case
    when d.id is null then 'no such draft'
    when r.standing_approval is false then 'this request needs Colin''s approval every time'
    when r.standing_approval is not true and not (d.purpose = any(s.standing_purposes)) then 'a ' || d.purpose || ' waits for Colin'
    when not exists (select 1 from public.records_drafts x where x.request_id = d.request_id and x.status = 'sent'
                       and lower(btrim(x.to_email)) = lower(btrim(d.to_email))) then 'nothing was sent to that address for this request yet'
    when d.body ~* '(\$|estimate|agree to pay|will pay|happy to pay|invoice me)' then 'mentions money: Colin approves it'
    else null end
    from public.records_drafts d join public.records_requests r on r.id = d.request_id
    cross join public.records_settings s
   where d.id = p_draft_id and s.id = 1
$$;

create or replace function public.records_propose_batch(p_draft_ids uuid[], p_note text, p_agent text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare b uuid; sb uuid; n integer := 0; ns integer := 0; standing uuid[]; rest uuid[];
begin
  if coalesce(array_length(p_draft_ids, 1), 0) = 0 then return jsonb_build_object('ok', false, 'reason', 'no drafts'); end if;
  if array_length(p_draft_ids, 1) > 40 then return jsonb_build_object('ok', false, 'reason', 'at most 40 letters in a batch (the mailbox has a daily cap)'); end if;
  select coalesce(array_agg(d.id) filter (where public.records_draft_standing(d.id) is null), '{}'),
         coalesce(array_agg(d.id) filter (where public.records_draft_standing(d.id) is not null), '{}')
    into standing, rest
    from public.records_drafts d where d.id = any(p_draft_ids) and d.status = 'draft';
  if coalesce(array_length(standing, 1), 0) > 0 then
    insert into public.records_batches (proposed_by, note, status, decided_at, decided_by)
    values (p_agent, concat_ws(' | ', p_note, 'standing approval: follow-ups and re-requests to an office already written to'), 'approved', now(), 'standing approval')
    returning id into sb;
    update public.records_drafts set status = 'approved', batch_id = sb where id = any(standing) and status = 'draft';
    get diagnostics ns = row_count;
  end if;
  if coalesce(array_length(rest, 1), 0) > 0 then
    insert into public.records_batches (proposed_by, note) values (p_agent, p_note) returning id into b;
    update public.records_drafts set status = 'in_batch', batch_id = b where id = any(rest) and status = 'draft';
    get diagnostics n = row_count;
    if n = 0 then delete from public.records_batches where id = b; b := null; end if;
  end if;
  if n + ns = 0 then return jsonb_build_object('ok', false, 'reason', 'none of those drafts are open'); end if;
  return jsonb_strip_nulls(jsonb_build_object('ok', true,
    'sending_on_standing_approval', case when ns > 0 then jsonb_build_object('batch_id', sb, 'letters', ns) end,
    'waiting_for_colin', case when n > 0 then jsonb_build_object('batch_id', b, 'letters', n,
      'why', (select jsonb_object_agg(x.id, public.records_draft_standing(x.id)) from public.records_drafts x where x.batch_id = b)) end,
    -- the old fields, for callers that read them
    'batch_id', coalesce(b, sb), 'letters', n + ns,
    'note', case when n > 0 then 'waiting for Colin to approve in the app' else 'approved on standing approval: the laptop sends them' end));
end $$;

create or replace function public.records_claim_approved() returns jsonb language plpgsql security definer set search_path = public as $$
declare out jsonb;
begin
  with pick as (
    select d.id from public.records_drafts d
     where d.status = 'approved' and d.batch_id in (select id from public.records_batches where status in ('approved', 'sending'))
     order by d.created_at, d.id limit 40 for update skip locked),
  c as (
    update public.records_drafts d set status = 'sending' from pick where d.id = pick.id
    returning d.*)
  select coalesce(jsonb_agg(jsonb_build_object('draft_id', c.id, 'batch_id', c.batch_id, 'request_id', c.request_id, 'kind', r.kind, 'name', r.name,
           'to', c.to_email, 'cc', c.cc, 'subject', c.subject, 'body', c.body, 'in_reply_to', c.in_reply_to)), '[]'::jsonb) into out
    from c join public.records_requests r on r.id = c.request_id;
  update public.records_batches set status = 'sending' where status = 'approved'
     and exists (select 1 from public.records_drafts d where d.batch_id = records_batches.id and d.status = 'sending');
  return out;
end $$;

revoke all on function public.records_draft_standing(uuid) from public, anon, authenticated;
grant execute on function public.records_draft_standing(uuid) to service_role;
