-- 0214: a per-key tool list (Colin 2026-11-10 through Muse's desk post 180: "Muse 2 gets a DOOR, not a login", a second
-- seat on the helper scoped to desk_inbox, desk_post, find_prospects, add_prospects and mark_card, nothing else).
-- Scopes are too coarse for that: the marks scope also holds reassign_card, add_call_task, close_task, merge_people,
-- merge_cards and the research board; the prospects scope holds the whole intake side. So a key may carry an explicit
-- list of tool names: null means every tool in its scopes (every existing key), a list means those and nothing else,
-- checked by the door after the scope check. Colin sets it with set_agent_key_tools; list_agent_keys shows it.

alter table public.agent_keys add column if not exists tools text[];

create or replace function public.agent_key_check(p_key text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare k public.agent_keys;
begin
  select * into k from public.agent_keys
   where key_sha256 = encode(sha256(convert_to(coalesce(p_key, ''), 'UTF8')), 'hex') and revoked_at is null;
  if not found then return jsonb_build_object('ok', false); end if;
  update public.agent_keys set last_used_at = now() where id = k.id;
  return jsonb_build_object('ok', true, 'id', k.id, 'name', k.name, 'role', k.role, 'scopes', to_jsonb(public.agent_scopes_for(k.role, k.scopes)), 'tools', to_jsonb(k.tools));
end $$;

create or replace function public.set_agent_key_tools(p_id uuid, p_tools text[]) returns text[]
language plpgsql security definer set search_path = public as $$
declare out text[];
begin
  if not public.is_owner() then raise exception 'only Colin changes what an agent key may do'; end if;
  -- null = every tool in its scopes; an empty list is a mistake, not a key that does nothing
  if p_tools is not null and cardinality(p_tools) = 0 then raise exception 'pass the tool names, or null for every tool in the key scopes'; end if;
  update public.agent_keys set tools = p_tools where id = p_id returning tools into out;
  return out;
end $$;
revoke all on function public.set_agent_key_tools(uuid, text[]) from public, anon;
grant execute on function public.set_agent_key_tools(uuid, text[]) to authenticated, service_role;

drop function if exists public.list_agent_keys();
create function public.list_agent_keys()
returns table(id uuid, name text, role text, key_hint text, created_at timestamptz, last_used_at timestamptz, revoked_at timestamptz, scopes text[], calls_24h bigint, refused_24h bigint, tools text[])
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_owner() then raise exception 'only Colin can see agent keys'; end if;
  return query select k.id, k.name, k.role, k.key_hint, k.created_at, k.last_used_at, k.revoked_at,
                      public.agent_scopes_for(k.role, k.scopes),
                      (select count(*) from public.agent_calls c where c.key_id = k.id and c.at > now() - interval '24 hours'),
                      (select count(*) from public.agent_calls c where c.key_id = k.id and c.at > now() - interval '24 hours' and not c.ok),
                      k.tools
                 from public.agent_keys k order by k.created_at desc;
end $$;
grant execute on function public.list_agent_keys() to authenticated, service_role;

-- Muse 2 signs the desk as itself and is addressed as itself (post 180: provenance never confused with Muse's)
alter table public.desk_messages drop constraint if exists desk_messages_author_check;
alter table public.desk_messages add constraint desk_messages_author_check check (author = any (array['desk', 'muse', 'colin', 'dots', 'muse 2']));
alter table public.desk_messages drop constraint if exists desk_messages_for_whom_check;
alter table public.desk_messages add constraint desk_messages_for_whom_check check (for_whom = any (array['desk', 'muse', 'colin', 'dots', 'all', 'muse 2']));
