-- 0264: files and images in the room.
--
-- Colin, 2026-11-20: "Make it so files and images can be uploaded in the chat". A caller with a screenshot of what the
-- app is doing, a photo of a house, a letter a seller sent; Colin with a contract page; an agent with a list.
--
-- A file belongs to a line. Whoever may read the line may open its files, and nobody else: a caller sees only their
-- own lines and the lines written to them by name (0263), so the same holds for what is attached. The files sit in a
-- private bucket. Nobody reads the bucket directly: a signed-in person goes through the server function room-file
-- and an agent through the door, and both ask these functions who may have what. A link is good for 10 minutes.
--
-- How a file gets on a line: room_file_new gives it a place and an id; the bytes are put there on a one-time upload
-- link; the line is then written naming the file ids (room_post p_files). A file put up and never named on a line
-- stays its uploader's alone.

do $$
begin
  if exists (select 1 from information_schema.tables where table_schema = 'storage' and table_name = 'buckets') then
    insert into storage.buckets (id, name, public, file_size_limit) values ('room', 'room', false, 26214400)
    on conflict (id) do update set public = false, file_size_limit = 26214400;
  end if;
end $$;

create table if not exists public.room_files (
  id           uuid primary key default gen_random_uuid(),
  message_id   bigint references public.room_messages(id) on delete cascade,
  path         text not null unique,
  name         text not null,
  mime         text,
  size         bigint,
  uploaded_by  text not null check (uploaded_by in ('desk', 'muse', 'muse 2', 'colin', 'thalia', 'adil')),
  at           timestamptz not null default now()
);
create index if not exists room_files_message on public.room_files (message_id);
alter table public.room_files enable row level security;
drop policy if exists room_files_owner_read on public.room_files;
create policy room_files_owner_read on public.room_files for select using (public.is_owner());
grant select on public.room_files to authenticated, service_role;

-- who a signed-in person is in the room, from their login's email (the server function asks this)
create or replace function public.room_who_email(p_email text) returns text
language sql stable security definer set search_path = public as $fn$
  select public.room_who((select m.person::text from public.team_members m where lower(m.email) = lower(btrim(coalesce(p_email, ''))) limit 1))
$fn$;
revoke all on function public.room_who_email(text) from public, anon, authenticated;
grant execute on function public.room_who_email(text) to service_role;

-- a place and an id for a file about to be put up
create or replace function public.room_file_new(p_who text, p_name text, p_mime text default null, p_size bigint default null) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare me text := public.room_who(p_who); nm text := btrim(coalesce(p_name, '')); safe text; fid uuid := gen_random_uuid(); pth text;
begin
  if me is null then return jsonb_build_object('ok', false, 'reason', 'the room is the desk, Muse, Muse 2, Colin and the callers'); end if;
  -- the name as given is kept for people to read; the stored path gets a plain one
  nm := left(regexp_replace(nm, '[\r\n\t]+', ' ', 'g'), 200);
  if nm = '' then return jsonb_build_object('ok', false, 'reason', 'the file needs a name'); end if;
  if coalesce(p_size, 0) > 26214400 then return jsonb_build_object('ok', false, 'reason', 'too big: a file in the room is 25 MB at most'); end if;
  if (select count(*) from public.room_files f where f.uploaded_by = me and f.at > now() - interval '1 hour') >= 60 then
    return jsonb_build_object('ok', false, 'reason', 'sixty files in an hour is the limit: wait a little');
  end if;
  safe := nullif(regexp_replace(regexp_replace(nm, '[^A-Za-z0-9._-]+', '_', 'g'), '^[._]+', ''), '');
  pth := replace(me, ' ', '_') || '/' || fid::text || '/' || coalesce(left(safe, 120), 'file');
  insert into public.room_files (id, path, name, mime, size, uploaded_by) values (fid, pth, nm, nullif(btrim(coalesce(p_mime, '')), ''), p_size, me);
  return jsonb_build_object('ok', true, 'file_id', fid, 'path', pth, 'name', nm);
end $fn$;
revoke all on function public.room_file_new(text, text, text, bigint) from public, anon, authenticated;
grant execute on function public.room_file_new(text, text, text, bigint) to service_role;

-- may this reader have this file, and where is it. The uploader always may; anyone else only through the line it is on.
create or replace function public.room_file_for(p_file_id uuid, p_who text) returns jsonb
language plpgsql stable security definer set search_path = public as $fn$
declare me text := public.room_who(p_who); f public.room_files; m public.room_messages;
begin
  if me is null then return jsonb_build_object('ok', false, 'reason', 'not in the room'); end if;
  select * into f from public.room_files where id = p_file_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such file'); end if;
  if f.uploaded_by <> me then
    if f.message_id is null then return jsonb_build_object('ok', false, 'reason', 'no such file'); end if;
    select * into m from public.room_messages where id = f.message_id;
    if not public.room_can_see(m, me) then return jsonb_build_object('ok', false, 'reason', 'no such file'); end if;
  end if;
  return jsonb_build_object('ok', true, 'file_id', f.id, 'path', f.path, 'name', f.name, 'mime', f.mime, 'size', f.size);
end $fn$;
revoke all on function public.room_file_for(uuid, text) from public, anon, authenticated;
grant execute on function public.room_file_for(uuid, text) to service_role;

-- ---------------------------------------------------------------- a line may carry files
-- the old four-argument writer goes first: two writers with the same first four arguments cannot be told apart
drop function if exists public.room_post(text, text, text[], bigint);
create or replace function public.room_post(p_author text, p_body text, p_to text[] default null, p_reply_to bigint default null,
                                            p_files uuid[] default null) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare me text := public.room_who(p_author); v_body text := btrim(coalesce(p_body, '')); tos text[] := '{}'; t text; w text; mid bigint; dup bigint;
        parent public.room_messages; fids uuid[] := coalesce(p_files, '{}'); n_files integer; n_att integer;
begin
  if me is null then return jsonb_build_object('ok', false, 'reason', 'the room is the desk, Muse, Muse 2, Colin and the callers'); end if;
  n_files := coalesce(array_length(fids, 1), 0);
  if n_files > 8 then return jsonb_build_object('ok', false, 'reason', 'eight files on one line at most: send the rest on the next line'); end if;
  if n_files > 0 and (select count(*) from public.room_files f where f.id = any (fids) and f.uploaded_by = me and f.message_id is null) <> n_files then
    return jsonb_build_object('ok', false, 'reason', 'a file named in files is not one you put up, or is already on a line');
  end if;
  if v_body = '' and n_files = 0 then return jsonb_build_object('ok', false, 'reason', 'say something: body is empty'); end if;
  if v_body = '' then
    v_body := (select 'Sent ' || string_agg(f.name, ', ' order by f.at, f.id) from public.room_files f where f.id = any (fids));
    v_body := left(v_body, 2000);
  end if;
  if length(v_body) > 2000 then
    return jsonb_build_object('ok', false, 'reason', 'too long for the room (' || length(v_body) || ' characters; a line holds 2,000). Put the report on the desk and say here that it is there.');
  end if;
  foreach t in array coalesce(p_to, '{}') loop
    if lower(btrim(coalesce(t, ''))) in ('', 'all', 'everyone') then continue; end if;
    w := public.room_who(t);
    if w is null then return jsonb_build_object('ok', false, 'reason', 'nobody in the room is called "' || left(t, 40) || '": name desk, muse, muse 2, colin, thalia or tyler, or leave it out'); end if;
    if public.room_is_caller(me) and public.room_is_caller(w) and w <> me then
      return jsonb_build_object('ok', false, 'reason', 'this line is for the desk, Muse or Colin: a caller does not write to the other caller here');
    end if;
    if w <> me and not (w = any (tos)) then tos := array_append(tos, w); end if;
  end loop;
  -- a caller who names nobody is asking whoever can help: Muse and the desk
  if public.room_is_caller(me) and tos = '{}' then tos := array['muse', 'desk']; end if;
  if p_reply_to is not null then
    select * into parent from public.room_messages where id = p_reply_to;
    if not found or not public.room_can_see(parent, me) then
      return jsonb_build_object('ok', false, 'reason', 'reply_to names a line that is not in the room');
    end if;
  end if;
  -- the same words twice inside two minutes is one line (a client that retried); a line with files is always its own
  if n_files = 0 then
    select m.id into dup from public.room_messages m where m.author = me and m.body = v_body and m.at > now() - interval '2 minutes' order by m.id desc limit 1;
    if dup is not null then return jsonb_build_object('ok', true, 'id', dup, 'already', true); end if;
  end if;
  insert into public.room_messages (author, to_whom, body, reply_to) values (me, tos, v_body, p_reply_to) returning id into mid;
  if n_files > 0 then
    update public.room_files set message_id = mid where id = any (fids) and uploaded_by = me and message_id is null;
    get diagnostics n_att = row_count;
  end if;
  return jsonb_build_object('ok', true, 'id', mid, 'files', coalesce(n_att, 0), 'to', case when tos = '{}' then 'everyone'
    else (select string_agg(public.room_name(x), ', ') from unnest(tos) x) end);
end $fn$;
revoke all on function public.room_post(text, text, text[], bigint, uuid[]) from public, anon, authenticated;
grant execute on function public.room_post(text, text, text[], bigint, uuid[]) to service_role;

create or replace function public.room_line(m public.room_messages, p_who text) returns jsonb
language sql stable as $fn$
  select jsonb_build_object('id', m.id, 'at', m.at, 'at_central', to_char(m.at at time zone 'America/Chicago', 'Dy Mon FMDD FMHH12:MI AM'),
    'from', public.room_name(m.author), 'from_caller', public.room_is_caller(m.author),
    'to', case when m.to_whom = '{}' then 'everyone' else (select string_agg(public.room_name(x), ', ') from unnest(m.to_whom) x) end,
    'for_you', m.author <> p_who and (m.to_whom = '{}' or p_who = any (m.to_whom)), 'body', m.body, 'reply_to', m.reply_to,
    'files', coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'name', f.name, 'mime', f.mime, 'size', f.size) order by f.at, f.id)
                         from public.room_files f where f.message_id = m.id), '[]'::jsonb))
$fn$;

drop function if exists public.room_say(text, text[], bigint);
create or replace function public.room_say(p_body text, p_to text[] default null, p_reply_to bigint default null, p_files uuid[] default null) returns jsonb
language plpgsql security definer set search_path = public as $fn$
begin
  if not public.is_owner() then raise exception 'only Colin writes in the room from the app'; end if;
  return public.room_post(coalesce(public.room_who(public.wpie_person()::text), 'colin'), p_body, p_to, p_reply_to, p_files);
end $fn$;
revoke all on function public.room_say(text, text[], bigint, uuid[]) from public, anon;
grant execute on function public.room_say(text, text[], bigint, uuid[]) to authenticated, service_role;

drop function if exists public.room_ask(text, bigint);
create or replace function public.room_ask(p_body text, p_reply_to bigint default null, p_files uuid[] default null) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare me text := public.room_who(public.wpie_person()::text);
begin
  if not public.room_is_caller(me) then raise exception 'this is the callers'' help line; Colin writes on the Room page'; end if;
  return public.room_post(me, p_body, null, p_reply_to, p_files);
end $fn$;
revoke all on function public.room_ask(text, bigint, uuid[]) from public, anon;
grant execute on function public.room_ask(text, bigint, uuid[]) to authenticated, service_role;

-- Muse 2's key lists its tools one by one: the room's file tool goes on it
update public.agent_keys set tools = tools || array['chat_file_upload']
 where name = 'Muse 2' and tools is not null and 'chat_post' = any (tools) and not ('chat_file_upload' = any (tools));
