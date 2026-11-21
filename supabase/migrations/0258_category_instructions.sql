-- 0258: category instructions: one how-to-run document for each Research Board job.
--
-- Muse, desk 323, 2026-11-20, from Colin: the instructions for running each category should live IN WPIE, beside the
-- Research Board, one document per board job. Until now the board carried a status note per job and nothing else;
-- the method for each category lived in files in an agent's own workspace, where nobody else could read it.
--
-- A document belongs to a board job (20 of them). It is written whole each time and every version is kept, so an edit
-- that went wrong can be read back. Colin edits it on the Research page; an agent reads and writes it through the door
-- (category_instructions, category_instructions_set). Callers can read it. It is not the weekly tick and not the
-- status note: those stay where they are.

create table if not exists public.research_docs (
  job_id      integer primary key references public.research_jobs(id) on delete cascade,
  body        text not null default '',
  version     integer not null default 0,
  updated_at  timestamptz not null default now(),
  updated_by  text
);
create table if not exists public.research_doc_versions (
  id       bigserial primary key,
  job_id   integer not null references public.research_jobs(id) on delete cascade,
  version  integer not null,
  body     text not null,
  by       text,
  at       timestamptz not null default now(),
  unique (job_id, version)
);
alter table public.research_docs enable row level security;
alter table public.research_doc_versions enable row level security;
drop policy if exists research_docs_team_read on public.research_docs;
create policy research_docs_team_read on public.research_docs for select using (public.is_team());
drop policy if exists research_doc_versions_team_read on public.research_doc_versions;
create policy research_doc_versions_team_read on public.research_doc_versions for select using (public.is_team());
grant select on public.research_docs, public.research_doc_versions to authenticated, service_role;

-- the one writer. p_base_version: the version the writer read; when it is given and the document has moved on, the
-- write is refused instead of burying someone else's edit.
create or replace function public.research_doc_write(p_job text, p_body text, p_by text, p_base_version integer default null) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare j public.research_jobs; d public.research_docs; v integer; body text := coalesce(p_body, '');
begin
  select * into j from public.research_jobs where key = lower(btrim(coalesce(p_job, ''))) or id::text = btrim(coalesce(p_job, ''));
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no such job: pass its number (1-20) or key', 'keys', (select jsonb_agg(key order by sort) from public.research_jobs));
  end if;
  if length(body) > 200000 then return jsonb_build_object('ok', false, 'reason', 'too long: a document holds up to 200,000 characters'); end if;
  if nullif(btrim(body), '') is null then return jsonb_build_object('ok', false, 'reason', 'the document is empty: send the whole text'); end if;
  select * into d from public.research_docs where job_id = j.id for update;
  if p_base_version is not null and coalesce(d.version, 0) <> p_base_version then
    return jsonb_build_object('ok', false, 'reason', 'the document changed since you read it: read it again, then write', 'version', coalesce(d.version, 0),
                              'updated_by', d.updated_by, 'updated_at', d.updated_at);
  end if;
  if d.job_id is not null and d.body = body then
    return jsonb_build_object('ok', true, 'job', j.key, 'version', d.version, 'unchanged', true);
  end if;
  v := coalesce(d.version, 0) + 1;
  insert into public.research_docs (job_id, body, version, updated_at, updated_by) values (j.id, body, v, now(), nullif(btrim(coalesce(p_by, '')), ''))
  on conflict (job_id) do update set body = excluded.body, version = excluded.version, updated_at = excluded.updated_at, updated_by = excluded.updated_by;
  insert into public.research_doc_versions (job_id, version, body, by) values (j.id, v, body, nullif(btrim(coalesce(p_by, '')), ''));
  return jsonb_build_object('ok', true, 'job', j.key, 'version', v, 'chars', length(body));
end $fn$;
revoke all on function public.research_doc_write(text, text, text, integer) from public, anon, authenticated;
grant execute on function public.research_doc_write(text, text, text, integer) to service_role;

-- Colin, on the Research page
create or replace function public.research_doc_save(p_job text, p_body text, p_base_version integer default null) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare who text;
begin
  if not public.is_owner() then raise exception 'only Colin (owner) edits the instructions here; an agent writes them through the door'; end if;
  select display_name into who from public.team_members where lower(email) = lower(auth.jwt() ->> 'email');
  return public.research_doc_write(p_job, p_body, coalesce(who, 'Colin'), p_base_version);
end $fn$;
revoke all on function public.research_doc_save(text, text, integer) from public, anon;
grant execute on function public.research_doc_save(text, text, integer) to authenticated, service_role;

-- an agent, through the door
create or replace function public.agent_research_doc_set(p_job text, p_body text, p_agent text, p_base_version integer default null) returns jsonb
language sql security definer set search_path = public as $fn$
  select public.research_doc_write(p_job, p_body, coalesce(nullif(btrim(coalesce(p_agent, '')), ''), 'agent'), p_base_version)
$fn$;
revoke all on function public.agent_research_doc_set(text, text, text, integer) from public, anon, authenticated;
grant execute on function public.agent_research_doc_set(text, text, text, integer) to service_role;

-- the folder: every job, and whether it has a document
create or replace function public.research_docs_index() returns jsonb
language sql stable security definer set search_path = public as $fn$
  select case when not (public.is_team() or auth.uid() is null) then '[]'::jsonb else coalesce((
    select jsonb_agg(jsonb_build_object('id', j.id, 'key', j.key, 'category', j.category, 'job', j.job,
                                        'written', d.job_id is not null, 'chars', coalesce(length(d.body), 0), 'version', coalesce(d.version, 0),
                                        'updated_at', d.updated_at, 'updated_by', d.updated_by) order by j.sort)
      from public.research_jobs j left join public.research_docs d on d.job_id = j.id), '[]'::jsonb) end
$fn$;
revoke all on function public.research_docs_index() from public, anon;
grant execute on function public.research_docs_index() to authenticated, service_role;

-- one document, whole
create or replace function public.research_doc(p_job text) returns jsonb
language plpgsql stable security definer set search_path = public as $fn$
declare j public.research_jobs; d public.research_docs;
begin
  if not (public.is_team() or auth.uid() is null) then raise exception 'team only'; end if;
  select * into j from public.research_jobs where key = lower(btrim(coalesce(p_job, ''))) or id::text = btrim(coalesce(p_job, ''));
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no such job: pass its number (1-20) or key', 'keys', (select jsonb_agg(key order by sort) from public.research_jobs));
  end if;
  select * into d from public.research_docs where job_id = j.id;
  return jsonb_build_object('ok', true, 'id', j.id, 'key', j.key, 'category', j.category, 'job', j.job, 'written', d.job_id is not null,
                            'body', coalesce(d.body, ''), 'version', coalesce(d.version, 0), 'updated_at', d.updated_at, 'updated_by', d.updated_by);
end $fn$;
revoke all on function public.research_doc(text) from public, anon;
grant execute on function public.research_doc(text) to authenticated, service_role;
