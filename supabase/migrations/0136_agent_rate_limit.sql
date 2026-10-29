-- A per-key, per-tool rate limit at the door (2026-10-29: Muse's find_prospects loop ran 2,787 calls an hour and pinned
-- the database; the send job could not start and first texts stopped for the afternoon). The door asks
-- agent_rate_check before every tools/call; a key over its budget for that tool gets a refusal that names the
-- budget and when to retry, and the call is logged like any refusal. Budgets per minute, per key:
--   find_prospects 30, ready_to_text 10, todays_queue 10, text_results 10, sending_status 20, pipe_counts 6,
--   desk_inbox 20, records_log 20, everything else 120. The sender's own paths (queue_texts, send_reply, mark_card,
--   call_next) have no limit: those are the work.
create index if not exists agent_calls_key_tool_at_idx on public.agent_calls (key_id, tool, at desc);

create or replace function public.agent_rate_limit(p_tool text) returns integer language sql immutable as $$
  select case p_tool
    when 'find_prospects' then 30
    when 'ready_to_text' then 10
    when 'todays_queue' then 10
    when 'text_results' then 10
    when 'test_results' then 10
    when 'sending_status' then 20
    when 'pipe_counts' then 6
    when 'pipe_queue' then 20
    when 'desk_inbox' then 20
    when 'records_log' then 20
    when 'records_list' then 20
    when 'records_overview' then 10
    when 'queue_texts' then null when 'send_reply' then null when 'mark_card' then null when 'mark_person' then null
    when 'call_next' then null when 'withdraw_texts' then null when 'desk_post' then null when 'desk_decide' then null
    when 'add_prospects' then null when 'pipe_close' then null when 'pipe_claim' then null
    else 120 end
$$;

create or replace function public.agent_rate_check(p_key_id uuid, p_tool text) returns text
language sql stable security definer set search_path = public as $$
  select case when lim is null then null
              when n < lim then null
              else format('rate limit: %s may be called %s times a minute per key (you made %s in the last minute). Wait %s seconds, and batch or pace this loop; the database serves the texts too.',
                          p_tool, lim, n, greatest(1, 60 - extract(epoch from now() - oldest)::int)) end
    from (select public.agent_rate_limit(p_tool) as lim,
                 (select count(*) from public.agent_calls c where c.key_id = p_key_id and c.tool = p_tool and c.at > now() - interval '1 minute') as n,
                 (select min(c.at) from public.agent_calls c where c.key_id = p_key_id and c.tool = p_tool and c.at > now() - interval '1 minute') as oldest) x
$$;
revoke all on function public.agent_rate_check(uuid, text) from public, anon, authenticated;
grant execute on function public.agent_rate_check(uuid, text) to service_role;
