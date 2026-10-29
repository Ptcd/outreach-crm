-- A runaway loop locks itself out (2026-10-29 4:30 PM CT: with the per-minute budget live, Muse's find_prospects loop
-- kept firing, 488 calls in three minutes, 456 refused, each refusal still a database round trip). A key that makes
-- more than three times a tool's budget in five minutes is refused that tool for five minutes, with the time left in
-- the message. The budgets and the no-limit work tools are unchanged (0136).
create or replace function public.agent_rate_check(p_key_id uuid, p_tool text) returns text
language sql stable security definer set search_path = public as $$
  select case when lim is null then null
              when n5 > 3 * lim * 5 then
                format('LOCKED OUT: %s is refused for this key until %s (you made %s calls in five minutes against a budget of %s a minute). Stop the loop. Read desk_inbox. Pace or batch this work; the database serves the texts too.',
                       p_tool, to_char((newest + interval '5 minutes') at time zone 'America/Chicago', 'HH24:MI') || ' CT', n5, lim)
              when n < lim then null
              else format('rate limit: %s may be called %s times a minute per key (you made %s in the last minute). Wait %s seconds, and batch or pace this loop; the database serves the texts too. Read desk_inbox.',
                          p_tool, lim, n, greatest(1, 60 - extract(epoch from now() - oldest)::int)) end
    from (select public.agent_rate_limit(p_tool) as lim,
                 (select count(*) from public.agent_calls c where c.key_id = p_key_id and c.tool = p_tool and c.at > now() - interval '1 minute') as n,
                 (select min(c.at) from public.agent_calls c where c.key_id = p_key_id and c.tool = p_tool and c.at > now() - interval '1 minute') as oldest,
                 (select count(*) from public.agent_calls c where c.key_id = p_key_id and c.tool = p_tool and c.at > now() - interval '5 minutes') as n5,
                 (select max(c.at) from public.agent_calls c where c.key_id = p_key_id and c.tool = p_tool and c.at > now() - interval '5 minutes') as newest) x
$$;
