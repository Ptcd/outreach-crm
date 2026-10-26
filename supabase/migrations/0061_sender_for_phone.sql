-- The number someone already knows (2026-10-26, three new numbers join the opener pool): a phone we texted before
-- keeps getting texts from the number its thread is on; only a phone never texted is spread across the pool.
create or replace function public.sender_for_phone(p_phone text) returns text
language sql stable security definer set search_path = public as $$
  select x.f from (
    select m.from_number f, m.sent_at at from public.messages m
     where m.direction = 'out' and m.channel = 'sms' and m.from_number ~ '^\+1[0-9]{10}$'
       and right(regexp_replace(coalesce(m.to_number, ''), '\D', '', 'g'), 10) = right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10)
    union all
    select p.from_number, coalesce(p.sent_at, p.claimed_at) from public.planned_openers p
     where p.from_number ~ '^\+1[0-9]{10}$' and p.send_status in ('sent', 'delivered', 'undelivered')
       and right(regexp_replace(coalesce(p.phone, ''), '\D', '', 'g'), 10) = right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10)
  ) x order by x.at desc nulls last limit 1
$$;
revoke all on function public.sender_for_phone(text) from public, anon, authenticated;
grant execute on function public.sender_for_phone(text) to service_role;
