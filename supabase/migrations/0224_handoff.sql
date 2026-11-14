-- 0224: a bulk hand-off of verified rows from one agent to another, with no row data on the desk.
--
-- Muse verified 85 eviction rows and moved them to Muse 2 as 35 desk posts (206 to 240), because a desk post holds
-- 12,000 characters. Her ask (desk 242, 243), which Colin said yes to on 2026-11-13: deposit a row set once under a
-- batch id; the loading agent pulls rows 50 to 100 at a time, loads them with the same duplicate guard add_prospects
-- has, and each row's result is written back against the batch. Acceptance: 500 rows move with no desk post carrying
-- row data.
--
--   handoff_batches   one row set: who deposited it, what it is, the loading instructions
--   handoff_rows      each row: the prospect as add_prospects takes it, the caller a new card goes to, its result
--   deposit           add rows (again and again, same key = same row) until the batch is marked final
--   pull              the loader claims the next rows to read them (a claim lapses after two hours)
--   load              the server loads the claimed rows through agent_add_prospect and writes each result itself
--   reject            a row the loader refuses, with the reason
--   the report        one desk post when the last row has a result: counts and reasons, never rows

create sequence if not exists public.handoff_code_seq;

create table if not exists public.handoff_batches (
  id            uuid primary key default gen_random_uuid(),
  code          text not null unique,
  title         text not null,
  instructions  text,
  deposited_by  text not null,
  status        text not null default 'open' check (status in ('open', 'ready', 'done', 'cancelled')),
  created_at    timestamptz not null default now(),
  ready_at      timestamptz,
  done_at       timestamptz,
  report_post   bigint
);

create table if not exists public.handoff_rows (
  id          uuid primary key default gen_random_uuid(),
  batch_id    uuid not null references public.handoff_batches (id) on delete cascade,
  n           integer not null,                       -- the order the rows were deposited in
  key         text not null,                          -- the depositor's own id for the row: the same key is the same row
  prospect    jsonb not null,                         -- exactly what add_prospects takes for one prospect
  caller      text check (caller in ('thalia', 'adil')),   -- who a NEW card goes to; an existing card keeps its caller
  note        text,
  status      text not null default 'waiting' check (status in ('waiting', 'claimed', 'created', 'stacked', 'rejected')),
  claimed_by  text,
  claimed_at  timestamptz,
  tries       integer not null default 0,
  last_error  text,
  lead_id     uuid,
  result      jsonb,
  reason      text,
  done_by     text,
  done_at     timestamptz,
  created_at  timestamptz not null default now(),
  unique (batch_id, key)
);
create index if not exists handoff_rows_batch_idx on public.handoff_rows (batch_id, status, n);

alter table public.handoff_batches enable row level security;
alter table public.handoff_rows enable row level security;
grant select on public.handoff_batches, public.handoff_rows to authenticated, service_role;
drop policy if exists handoff_batches_team_read on public.handoff_batches;
create policy handoff_batches_team_read on public.handoff_batches for select to authenticated using (public.is_team());
drop policy if exists handoff_rows_team_read on public.handoff_rows;
create policy handoff_rows_team_read on public.handoff_rows for select to authenticated using (public.is_team());

-- A batch by its code (H-12) or its id.
create or replace function public.handoff_find(p_batch text) returns public.handoff_batches
language sql stable security definer set search_path = public as $$
  select b from public.handoff_batches b
   where b.code = upper(btrim(coalesce(p_batch, ''))) or b.id::text = lower(btrim(coalesce(p_batch, ''))) limit 1
$$;

create or replace function public.handoff_counts(p_batch_id uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('rows', count(*), 'waiting', count(*) filter (where status = 'waiting'), 'claimed', count(*) filter (where status = 'claimed'),
           'created', count(*) filter (where status = 'created'), 'stacked', count(*) filter (where status = 'stacked'),
           'rejected', count(*) filter (where status = 'rejected'))
    from public.handoff_rows where batch_id = p_batch_id
$$;

-- When every row has a result: the batch is done and ONE report goes on the desk, with counts and reasons only.
create or replace function public.handoff_finish(p_batch_id uuid) returns boolean
language plpgsql security definer set search_path = public as $$
declare b public.handoff_batches; c jsonb; why text; who text; pid jsonb;
begin
  select * into b from public.handoff_batches where id = p_batch_id for update;
  if not found or b.status <> 'ready' then return false; end if;
  c := public.handoff_counts(p_batch_id);
  if (c->>'waiting')::int > 0 or (c->>'claimed')::int > 0 or (c->>'rows')::int = 0 then return false; end if;
  select string_agg(r || ' x' || k::text, '; ' order by k desc) into why
    from (select left(coalesce(reason, 'no reason given'), 120) r, count(*) k from public.handoff_rows
           where batch_id = p_batch_id and status = 'rejected' group by 1 order by 2 desc limit 10) x;
  select string_agg(distinct done_by, ', ') into who from public.handoff_rows where batch_id = p_batch_id and done_by is not null;
  pid := public.desk_post('desk', 'all', 'report', 'HAND-OFF DONE: ' || b.code || ' ' || b.title,
    b.code || ', "' || b.title || '", deposited by ' || b.deposited_by || ': ' || (c->>'rows') || ' rows.' || E'\n'
    || 'New cards: ' || (c->>'created') || '. Stacked onto a card we already had: ' || (c->>'stacked') || '. Rejected: ' || (c->>'rejected') || '.' || E'\n'
    || case when why is not null then 'Why rejected: ' || why || E'\n' else '' end
    || 'Loaded by: ' || coalesce(who, 'nobody') || '.' || E'\n'
    || 'Every row with its card and result: handoff_batches with batch_id ' || b.code || ' and rows true.');
  update public.handoff_batches set status = 'done', done_at = now(), report_post = nullif(pid->>'id', '')::bigint where id = p_batch_id;
  return true;
end $$;

-- ------------------------------------------------------------------ deposit
create or replace function public.agent_handoff_deposit(p jsonb, p_agent text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  b public.handoff_batches; x jsonb; pr jsonb; k text; cl text; ex public.handoff_rows;
  added integer := 0; updated integer := 0; refused jsonb := '[]'::jsonb; nxt integer; why text;
  who text := coalesce(nullif(btrim(p_agent), ''), 'agent');
begin
  if nullif(btrim(coalesce(p->>'batch_id', '')), '') is not null then
    b := public.handoff_find(p->>'batch_id');
    if b.id is null then return jsonb_build_object('ok', false, 'reason', 'no such batch'); end if;
    if lower(b.deposited_by) <> lower(who) then return jsonb_build_object('ok', false, 'reason', 'this batch was deposited by ' || b.deposited_by || ': only they add to it'); end if;
    if b.status <> 'open' then return jsonb_build_object('ok', false, 'reason', 'this batch is ' || b.status || ': it takes no more rows. Start a new one'); end if;
    if p ? 'instructions' and nullif(btrim(p->>'instructions'), '') is not null then
      update public.handoff_batches set instructions = btrim(p->>'instructions') where id = b.id;
    end if;
  else
    if coalesce(btrim(p->>'title'), '') = '' then return jsonb_build_object('ok', false, 'reason', 'a new batch needs a title (what these rows are)'); end if;
    insert into public.handoff_batches (code, title, instructions, deposited_by)
    values ('H-' || nextval('public.handoff_code_seq')::text, btrim(p->>'title'), nullif(btrim(coalesce(p->>'instructions', '')), ''), who)
    returning * into b;
  end if;
  if p ? 'rows' and jsonb_typeof(p->'rows') <> 'array' then return jsonb_build_object('ok', false, 'reason', 'rows is a list'); end if;
  if jsonb_array_length(coalesce(p->'rows', '[]'::jsonb)) > 250 then return jsonb_build_object('ok', false, 'reason', 'at most 250 rows a call: send the rest in the next call with this batch_id (' || b.code || ')'); end if;
  select coalesce(max(n), 0) into nxt from public.handoff_rows where batch_id = b.id;
  for x in select * from jsonb_array_elements(coalesce(p->'rows', '[]'::jsonb)) loop
    k := left(btrim(coalesce(x->>'key', '')), 160);
    pr := x->'prospect';
    cl := lower(btrim(coalesce(x->>'caller', '')));
    if cl = 'tyler' then cl := 'adil'; end if;
    why := case
      when k = '' then 'no key (your own id for the row)'
      when pr is null or jsonb_typeof(pr) <> 'object' then 'no prospect (the row as add_prospects takes it)'
      when coalesce(btrim(pr->>'address'), '') = '' then 'the prospect has no address'
      when coalesce(btrim(pr->>'owner_name'), '') = '' and coalesce(jsonb_array_length(case when jsonb_typeof(pr->'interests') = 'array' then pr->'interests' else '[]'::jsonb end), 0) = 0
        then 'the prospect has no owner_name and no interests'
      when cl not in ('', 'thalia', 'adil') then 'caller is thalia or tyler'
    end;
    if why is not null then refused := refused || jsonb_build_object('key', nullif(k, ''), 'reason', why); continue; end if;
    select * into ex from public.handoff_rows where batch_id = b.id and key = k;
    if found then
      if ex.status <> 'waiting' then refused := refused || jsonb_build_object('key', k, 'reason', 'already ' || ex.status); continue; end if;
      update public.handoff_rows set prospect = pr, caller = nullif(cl, ''), note = nullif(btrim(coalesce(x->>'note', '')), '') where id = ex.id;
      updated := updated + 1;
    else
      nxt := nxt + 1;
      insert into public.handoff_rows (batch_id, n, key, prospect, caller, note)
      values (b.id, nxt, k, pr, nullif(cl, ''), nullif(btrim(coalesce(x->>'note', '')), ''));
      added := added + 1;
    end if;
  end loop;
  if coalesce((p->>'final')::boolean, false) then
    if not exists (select 1 from public.handoff_rows where batch_id = b.id) then
      return jsonb_build_object('ok', false, 'batch_id', b.code, 'reason', 'a batch with no rows cannot be final', 'refused', refused);
    end if;
    update public.handoff_batches set status = 'ready', ready_at = now() where id = b.id;
  end if;
  select * into b from public.handoff_batches where id = b.id;
  return jsonb_build_object('ok', true, 'batch_id', b.code, 'status', b.status, 'added', added, 'updated', updated, 'refused', refused,
    'counts', public.handoff_counts(b.id),
    'next', case when b.status = 'open' then 'send the rest with this batch_id; final: true on the last call makes it ready to load'
                 else 'ready: the loading agent pulls it with handoff_pull. Post ONE line on the desk naming the batch, never the rows' end);
end $$;

-- ------------------------------------------------------------------ read
create or replace function public.agent_handoff_batches(p jsonb, p_agent text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare b public.handoff_batches; lim integer := least(greatest(coalesce(nullif(p->>'limit', '')::integer, 100), 1), 500);
        after_n integer := coalesce(nullif(p->>'after', '')::integer, 0); st text := nullif(btrim(coalesce(p->>'status', '')), '');
begin
  if nullif(btrim(coalesce(p->>'batch_id', '')), '') is null then
    return coalesce((select jsonb_agg(jsonb_build_object('batch_id', x.code, 'title', x.title, 'deposited_by', x.deposited_by, 'status', x.status,
               'created_at', x.created_at, 'ready_at', x.ready_at, 'done_at', x.done_at, 'counts', public.handoff_counts(x.id)) order by x.created_at desc)
      from (select * from public.handoff_batches h where h.status in ('open', 'ready') or h.created_at > now() - interval '30 days' order by h.created_at desc limit 50) x), '[]'::jsonb);
  end if;
  b := public.handoff_find(p->>'batch_id');
  if b.id is null then return jsonb_build_object('ok', false, 'reason', 'no such batch'); end if;
  return jsonb_build_object('ok', true, 'batch_id', b.code, 'title', b.title, 'instructions', b.instructions, 'deposited_by', b.deposited_by, 'status', b.status,
    'created_at', b.created_at, 'ready_at', b.ready_at, 'done_at', b.done_at, 'counts', public.handoff_counts(b.id),
    'why_rejected', coalesce((select jsonb_object_agg(r, k) from (select left(coalesce(reason, 'no reason given'), 120) r, count(*) k from public.handoff_rows
                                where batch_id = b.id and status = 'rejected' group by 1) z), '{}'::jsonb),
    'rows', case when coalesce((p->>'rows')::boolean, false) then coalesce((
        select jsonb_agg(jsonb_build_object('n', r.n, 'row_id', r.id, 'key', r.key, 'status', r.status, 'lead_id', r.lead_id, 'reason', r.reason,
                 'loaded_by', r.done_by, 'address', r.prospect->>'address', 'caller', r.caller)
                 || case when coalesce((p->>'payload')::boolean, false) then jsonb_build_object('prospect', r.prospect, 'note', r.note) else '{}'::jsonb end
                 order by r.n)
          from (select * from public.handoff_rows hr where hr.batch_id = b.id and hr.n > after_n and (st is null or hr.status = st) order by hr.n limit lim) r), '[]'::jsonb) end);
end $$;

-- ------------------------------------------------------------------ pull
create or replace function public.agent_handoff_pull(p_batch text, p_limit integer, p_agent text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare b public.handoff_batches; who text := coalesce(nullif(btrim(p_agent), ''), 'agent'); lim integer := least(greatest(coalesce(p_limit, 50), 1), 100);
        mine integer; out jsonb;
begin
  -- a claim nobody finished in two hours goes back in line
  update public.handoff_rows set status = 'waiting', claimed_by = null, claimed_at = null
   where status = 'claimed' and claimed_at < now() - interval '2 hours';
  if nullif(btrim(coalesce(p_batch, '')), '') is not null then
    b := public.handoff_find(p_batch);
    if b.id is null then return jsonb_build_object('ok', false, 'reason', 'no such batch'); end if;
  else
    select h.* into b from public.handoff_batches h where h.status = 'ready'
       and exists (select 1 from public.handoff_rows r where r.batch_id = h.id and (r.status = 'waiting' or (r.status = 'claimed' and lower(r.claimed_by) = lower(who))))
     order by h.ready_at limit 1;
    if b.id is null then return jsonb_build_object('ok', true, 'rows', '[]'::jsonb, 'note', 'nothing is waiting to be loaded'); end if;
  end if;
  if b.status <> 'ready' then
    return jsonb_build_object('ok', false, 'reason', case b.status when 'open' then 'this batch is still being deposited: it is ready when the depositor marks it final' else 'this batch is ' || b.status end);
  end if;
  select count(*) into mine from public.handoff_rows where batch_id = b.id and status = 'claimed' and lower(claimed_by) = lower(who);
  if mine < lim then
    update public.handoff_rows set status = 'claimed', claimed_by = who, claimed_at = now()
     where id in (select r.id from public.handoff_rows r where r.batch_id = b.id and r.status = 'waiting' order by r.n limit lim - mine for update skip locked);
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('row_id', r.id, 'n', r.n, 'key', r.key, 'caller', r.caller, 'note', r.note, 'prospect', r.prospect) order by r.n), '[]'::jsonb)
    into out from (select * from public.handoff_rows hr where hr.batch_id = b.id and hr.status = 'claimed' and lower(hr.claimed_by) = lower(who) order by hr.n limit lim) r;
  return jsonb_build_object('ok', true, 'batch_id', b.code, 'title', b.title, 'instructions', b.instructions, 'deposited_by', b.deposited_by,
    'rows', out, 'counts', public.handoff_counts(b.id),
    'next', 'handoff_load loads these through the same duplicate guard as add_prospects and writes every result back by itself. A row you will not load: handoff_reject with the reason. Do not call add_prospects for these rows yourself.');
end $$;

-- ------------------------------------------------------------------ load
-- The server loads each row through agent_add_prospect (one card per property: an address we already have is
-- stacked, never duplicated) and writes the result on the row. A new card goes to the caller the row names.
create or replace function public.agent_handoff_load(p_batch text, p_row_ids uuid[], p_limit integer, p_agent text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  b public.handoff_batches; who text := coalesce(nullif(btrim(p_agent), ''), 'agent'); lim integer := least(greatest(coalesce(p_limit, 50), 1), 100);
  r public.handoff_rows; res jsonb; outc text; lid uuid; why text; mv jsonb;
  results jsonb := '[]'::jsonb; n_created integer := 0; n_stacked integer := 0; n_rejected integer := 0; n_error integer := 0; done boolean;
begin
  b := public.handoff_find(p_batch);
  if b.id is null then return jsonb_build_object('ok', false, 'reason', 'no such batch: handoff_batches lists them'); end if;
  if b.status <> 'ready' then return jsonb_build_object('ok', false, 'reason', 'this batch is ' || b.status); end if;
  update public.handoff_rows set status = 'waiting', claimed_by = null, claimed_at = null
   where batch_id = b.id and status = 'claimed' and claimed_at < now() - interval '2 hours';
  -- what to load: the rows named, else what this agent has claimed, else the next rows in line
  if p_row_ids is not null and cardinality(p_row_ids) > 0 then
    update public.handoff_rows set status = 'claimed', claimed_by = who, claimed_at = now()
     where batch_id = b.id and id = any (p_row_ids) and status = 'waiting';
  elsif not exists (select 1 from public.handoff_rows where batch_id = b.id and status = 'claimed' and lower(claimed_by) = lower(who)) then
    update public.handoff_rows set status = 'claimed', claimed_by = who, claimed_at = now()
     where id in (select x.id from public.handoff_rows x where x.batch_id = b.id and x.status = 'waiting' order by x.n limit lim for update skip locked);
  end if;
  for r in select * from public.handoff_rows hr where hr.batch_id = b.id and hr.status = 'claimed' and lower(hr.claimed_by) = lower(who)
              and (p_row_ids is null or cardinality(p_row_ids) = 0 or hr.id = any (p_row_ids)) order by hr.n limit lim loop
    begin
      res := public.agent_add_prospect(r.prospect, who);
      outc := case res->>'status' when 'created' then 'created' when 'rejected' then 'rejected' else 'stacked' end;
      lid := nullif(res->>'lead_id', '')::uuid;
      why := case when outc = 'rejected' then coalesce(res->>'reason', 'rejected by the loader')
                  when outc = 'stacked' then 'we already had this property: ' || coalesce(res->>'status', 'updated') end;
      mv := null;
      if outc = 'created' and r.caller is not null and lid is not null then
        mv := public.agent_reassign_card(lid, r.caller, 'hand-off ' || b.code, who);
      end if;
      update public.handoff_rows set status = outc, lead_id = lid, reason = why, done_by = who, done_at = now(), last_error = null,
             result = (res - 'interests') || case when mv is not null then jsonb_build_object('caller_set', mv) else '{}'::jsonb end
       where id = r.id;
      if outc = 'created' then n_created := n_created + 1; elsif outc = 'stacked' then n_stacked := n_stacked + 1; else n_rejected := n_rejected + 1; end if;
      results := results || jsonb_build_object('row_id', r.id, 'n', r.n, 'key', r.key, 'outcome', outc, 'lead_id', lid, 'reason', why,
        'phones_added', res->'phones_added', 'parcel_conflict', res->'parcel_conflict');
    exception when others then
      -- a row that breaks goes back in line twice, then is rejected with the error, so one bad row never stops a batch
      n_error := n_error + 1;
      if r.tries >= 2 then
        update public.handoff_rows set status = 'rejected', reason = 'the loader failed three times: ' || left(sqlerrm, 200), last_error = left(sqlerrm, 400),
               tries = tries + 1, done_by = who, done_at = now() where id = r.id;
        n_rejected := n_rejected + 1;
      else
        update public.handoff_rows set status = 'waiting', claimed_by = null, claimed_at = null, tries = tries + 1, last_error = left(sqlerrm, 400) where id = r.id;
      end if;
      results := results || jsonb_build_object('row_id', r.id, 'n', r.n, 'key', r.key, 'outcome', 'error', 'reason', left(sqlerrm, 200));
    end;
  end loop;
  done := public.handoff_finish(b.id);
  return jsonb_build_object('ok', true, 'batch_id', b.code, 'loaded', jsonb_array_length(results), 'created', n_created, 'stacked', n_stacked,
    'rejected', n_rejected, 'errors', n_error, 'results', results, 'counts', public.handoff_counts(b.id), 'batch_done', done,
    'next', case when done then 'the batch is done and its report is on the desk: post nothing more about it'
                 else 'call handoff_load again for the next rows' end);
end $$;

-- ------------------------------------------------------------------ reject
create or replace function public.agent_handoff_reject(p_row_id uuid, p_reason text, p_agent text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r public.handoff_rows; who text := coalesce(nullif(btrim(p_agent), ''), 'agent'); done boolean;
begin
  select * into r from public.handoff_rows where id = p_row_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such row'); end if;
  if r.status not in ('waiting', 'claimed') then return jsonb_build_object('ok', false, 'reason', 'this row is already ' || r.status); end if;
  if coalesce(btrim(p_reason), '') = '' then return jsonb_build_object('ok', false, 'reason', 'say why (reason)'); end if;
  update public.handoff_rows set status = 'rejected', reason = left(btrim(p_reason), 300), done_by = who, done_at = now() where id = p_row_id;
  done := public.handoff_finish(r.batch_id);
  return jsonb_build_object('ok', true, 'row_id', p_row_id, 'outcome', 'rejected', 'batch_done', done);
end $$;

revoke all on function public.handoff_find(text), public.handoff_counts(uuid), public.handoff_finish(uuid), public.agent_handoff_deposit(jsonb, text),
  public.agent_handoff_batches(jsonb, text), public.agent_handoff_pull(text, integer, text), public.agent_handoff_load(text, uuid[], integer, text),
  public.agent_handoff_reject(uuid, text, text) from public, anon, authenticated;
grant execute on function public.handoff_find(text), public.handoff_counts(uuid), public.handoff_finish(uuid), public.agent_handoff_deposit(jsonb, text),
  public.agent_handoff_batches(jsonb, text), public.agent_handoff_pull(text, integer, text), public.agent_handoff_load(text, uuid[], integer, text),
  public.agent_handoff_reject(uuid, text, text) to service_role;
