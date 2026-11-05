-- 0191: the door runs as service_role (agent-mcp calls the database with the service key). 0190 revoked
-- agent_phones_wanted and phones_wanted_sweep from everyone and granted nobody back, so Muse's first call came back
-- "permission denied for function agent_phones_wanted" (Muse 2026-11-05). Same grant as every other agent_* function.
grant execute on function public.agent_phones_wanted(text, integer, text, text, boolean) to service_role;
grant execute on function public.phones_wanted_sweep() to service_role;
