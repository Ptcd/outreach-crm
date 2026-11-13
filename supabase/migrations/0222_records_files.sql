-- Records files between the agent and the laptop (Colin 2026-11-13: the portals "should be being handled by the agent
-- or muse if we can get it access to all the data"; "Muse can happily do sign ins").
--
-- Until now a clerk's file lived only on the laptop: the agent saw a reply's words and the NAMES of its attachments, and
-- had no way to hand a file back. Two cities had released documents in a records portal (NextRequest), which shows them
-- only to the signed-in requester, and nothing brought them in.
--
-- The laptop reaches the database and nothing else, so a file crosses on a signed link the door makes:
--   to_laptop  the agent downloaded a file (a portal release): records_file_upload gives a link to PUT it to,
--              records_file_done marks it ready with a link the laptop can read, and the laptop's bridge copies it under
--              data/records/received and adds it as a reply on the town's request (the muni intake agent then reads it).
--   to_agent   the agent wants to open an attachment the laptop holds: records_file_get asks, the laptop PUTs the file up
--              on its next pass (about 10 minutes), and the next records_file_get returns a link to read it.
-- records_portals is the worklist: every portal request by town, number and where it stands by its notices.

do $$
begin
  if exists (select 1 from information_schema.tables where table_schema = 'storage' and table_name = 'buckets') then
    insert into storage.buckets (id, name, public) values ('records', 'records', false) on conflict (id) do nothing;
  end if;
end $$;

create table if not exists public.records_files (
  id           uuid primary key default gen_random_uuid(),
  request_id   uuid references public.records_requests (id) on delete set null,
  reply_id     uuid references public.records_replies (id) on delete set null,
  name         text not null,
  direction    text not null check (direction in ('to_laptop', 'to_agent')),
  status       text not null default 'waiting' check (status in ('waiting', 'ready', 'done', 'failed')),
  storage_path text not null,
  url          text,                 -- to_laptop + ready: the link the laptop reads; to_agent + waiting: the link the laptop writes to
  bytes        integer,
  sha256       text,
  portal       text,
  number       text,
  note         text,
  by           text,
  error        text,
  created_at   timestamptz not null default now(),
  ready_at     timestamptz,
  done_at      timestamptz
);
create index if not exists records_files_open on public.records_files (direction, status);
create unique index if not exists records_files_one_ask on public.records_files (reply_id, name) where direction = 'to_agent';
alter table public.records_files enable row level security;      -- no policies: the door and the laptop only
revoke all on public.records_files from public, anon, authenticated;
grant select, insert, update on public.records_files to service_role;

-- the agent has a file for a request: a row and the path to put it at
create or replace function public.records_file_new(p_request_id uuid, p_name text, p_portal text, p_number text, p_note text, p_agent text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare q public.records_requests; nm text := left(regexp_replace(btrim(coalesce(p_name, '')), '[^A-Za-z0-9._ -]', '_', 'g'), 120); f public.records_files;
begin
  select * into q from public.records_requests where id = p_request_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such request: pass request_id from records_portals or records_list'); end if;
  if nm = '' or nm !~ '\.[A-Za-z0-9]{2,5}$' then return jsonb_build_object('ok', false, 'reason', 'filename: the file''s own name with its extension (list.xlsx, response.pdf)'); end if;
  insert into public.records_files (request_id, name, direction, storage_path, portal, number, note, by)
  values (q.id, nm, 'to_laptop', 'in/' || gen_random_uuid()::text || '/' || nm, nullif(btrim(coalesce(p_portal, '')), ''),
          nullif(btrim(coalesce(p_number, '')), ''), nullif(btrim(coalesce(p_note, '')), ''), coalesce(p_agent, 'agent'))
  returning * into f;
  return jsonb_build_object('ok', true, 'file_id', f.id, 'path', f.storage_path, 'office', q.name);
end $$;

-- the agent wants to read an attachment the laptop holds
create or replace function public.records_file_want(p_reply_id uuid, p_name text, p_agent text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare rp public.records_replies; f public.records_files; names jsonb; nm text;
begin
  select * into rp from public.records_replies where id = p_reply_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such reply: pass reply_id from records_replies'); end if;
  select coalesce(jsonb_agg(a ->> 'name'), '[]'::jsonb) into names from jsonb_array_elements(coalesce(rp.attachments, '[]'::jsonb)) a;
  select a ->> 'name' into nm from jsonb_array_elements(coalesce(rp.attachments, '[]'::jsonb)) a
   where a ->> 'name' = p_name or lower(a ->> 'name') = lower(btrim(coalesce(p_name, ''))) limit 1;
  if nm is null then return jsonb_build_object('ok', false, 'reason', 'that reply has no attachment by that name', 'attachments', names); end if;
  select * into f from public.records_files where reply_id = rp.id and name = nm and direction = 'to_agent';
  if not found then
    insert into public.records_files (request_id, reply_id, name, direction, storage_path, by)
    values (rp.request_id, rp.id, nm, 'to_agent',
            'out/' || rp.id::text || '/' || regexp_replace(nm, '[^A-Za-z0-9._ -]', '_', 'g'), coalesce(p_agent, 'agent'))
    returning * into f;
  elsif f.status = 'failed' then
    update public.records_files set status = 'waiting', error = null, url = null where id = f.id returning * into f;
  end if;
  return jsonb_build_object('ok', true, 'file_id', f.id, 'path', f.storage_path, 'status', f.status, 'has_url', f.url is not null, 'error', f.error);
end $$;

-- the door and the laptop move a file along
create or replace function public.records_file_mark(p_id uuid, p_status text, p_url text default null, p_bytes integer default null,
  p_sha256 text default null, p_error text default null, p_reply_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare f public.records_files;
begin
  if p_status not in ('waiting', 'ready', 'done', 'failed') then return jsonb_build_object('ok', false, 'reason', 'status is waiting, ready, done or failed'); end if;
  update public.records_files set status = p_status, url = case when p_status = 'done' then null else coalesce(p_url, url) end,
         bytes = coalesce(p_bytes, bytes), sha256 = coalesce(p_sha256, sha256), error = p_error, reply_id = coalesce(p_reply_id, reply_id),
         ready_at = case when p_status = 'ready' then now() else ready_at end, done_at = case when p_status = 'done' then now() else done_at end
   where id = p_id returning * into f;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such file'); end if;
  return jsonb_build_object('ok', true, 'file_id', f.id, 'status', f.status, 'direction', f.direction, 'path', f.storage_path, 'name', f.name);
end $$;

-- The portal worklist. A portal (NextRequest, JustFOIA, GovQA) mails a notice and keeps the documents behind the
-- requester's sign-in, so the notices are all the mailbox ever gets: one item per town and request number, where it
-- stands by its latest notice, the portal's address, and how many files from it have been brought in.
create or replace function public.records_portals() returns jsonb language sql stable security definer set search_path = public as $$
  with n as (
    select rp.request_id, q.name as office, q.county, lower(rp.from_addr) as frm, rp.subject, rp.received_at, rp.body,
           coalesce((regexp_match(rp.subject, '#\s*([0-9]{2,4}-[0-9]{2,6})'))[1], (regexp_match(rp.subject, '\m([A-Z]{2}[0-9]{4}-[0-9]{2,5})\M'))[1],
                    (regexp_match(rp.body, '#\s*([0-9]{2,4}-[0-9]{2,6})'))[1], '') as number
      from public.records_replies rp left join public.records_requests q on q.id = rp.request_id
     where split_part(lower(rp.from_addr), '@', 2) ~ '(nextrequest\.com|justfoia\.com|govqa\.us|mycusthelp\.net)$'),
  g as (
    select request_id, number, max(office) as office, max(county) as county, max(split_part(frm, '@', 2)) as portal,
           max(received_at) as last_notice,
           bool_or(subject ~* 'released') as released, bool_or(subject ~* 'completed') as completed,
           bool_or(subject ~* 'invoice') as invoice, bool_or(subject ~* 'closed') as closed,
           coalesce(max('https://' || lower((regexp_match(body, 'https?://([a-z0-9.-]+\.(?:nextrequest|justfoia)\.com)', 'i'))[1]))
                      filter (where body ~* 'https?://[a-z0-9.-]+\.(nextrequest|justfoia)\.com'),
                    max('https://' || split_part(frm, '@', 1) || '.justfoia.com') filter (where frm like '%justfoia.com')) as site
      from n group by request_id, number)
  select coalesce(jsonb_agg(jsonb_build_object(
      'request_id', g.request_id, 'office', g.office, 'county', g.county, 'portal', g.portal, 'number', nullif(g.number, ''),
      'state', case when g.invoice then 'invoice: a fee, Colin decides' when g.released then 'documents released'
                    when g.completed then 'completed' when g.closed then 'closed' else 'submitted' end,
      'last_notice', g.last_notice::date, 'site', g.site,
      'files_brought_in', (select count(*) from public.records_files f where f.request_id = g.request_id and f.direction = 'to_laptop'
                             and f.status in ('ready', 'done') and coalesce(f.number, '') = g.number)
                        + (select count(*) from public.records_replies r2 where r2.request_id = g.request_id and r2.message_id like 'portal:%'
                             and r2.subject like '%#' || g.number || '%' and g.number <> ''),
      'waiting', (g.released or g.completed) and not g.invoice
                 and not exists (select 1 from public.records_files f where f.request_id = g.request_id and f.direction = 'to_laptop'
                                   and f.status in ('ready', 'done') and coalesce(f.number, '') = g.number)
                 and not exists (select 1 from public.records_replies r2 where r2.request_id = g.request_id and r2.message_id like 'portal:%'))
      order by (g.released or g.completed) desc, g.last_notice), '[]'::jsonb)
    from g
$$;

revoke all on function public.records_file_new(uuid, text, text, text, text, text), public.records_file_want(uuid, text, text),
  public.records_file_mark(uuid, text, text, integer, text, text, uuid), public.records_portals() from public, anon, authenticated;
grant execute on function public.records_file_new(uuid, text, text, text, text, text), public.records_file_want(uuid, text, text),
  public.records_file_mark(uuid, text, text, integer, text, text, uuid), public.records_portals() to service_role;
