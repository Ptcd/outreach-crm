-- No 7 PM "hot lead not called yet" list (Colin 2026-10-26, after "why did this come" about a card Muse marked hot at
-- noon and he had already passed on). Same rule as 0070's "one ping, no repeat": the only hot text is the one Muse
-- sends when it marks a card hot; nothing nags about it afterwards. hot_digest stays so the alert run keeps working,
-- and always returns an empty list (nothing to send).
create or replace function public.hot_digest(p_now timestamptz default now())
returns jsonb language sql stable security definer set search_path = public as $$
  select '[]'::jsonb
$$;
revoke all on function public.hot_digest(timestamptz) from public, anon, authenticated;
grant execute on function public.hot_digest(timestamptz) to service_role;
