-- find_prospects melted the database (2026-10-29 3-4 PM CT: Muse called it 2,787 times in an hour, 3.5 s average,
-- 49 s worst; the send job then failed to start, ready_to_text timed out on 50 of 73 calls and first texts stopped).
-- The address filter ORed a text match with addr_key(addr_main(...)) of every card, so the index was never used and
-- each call normalized all 5,339 addresses. Same filters, same results: each filter now picks its card ids once
-- (indexed addr_key equality, one pass of ilike, an indexed phone lookup) and the filters are ANDed on those ids.
create or replace function public.agent_find(p jsonb) returns jsonb
language sql stable security definer set search_path = public as $function$
  with a as (select nullif(btrim(p->>'address'), '') as addr, nullif(btrim(p->>'name'), '') as nm,
                    nullif(right(regexp_replace(coalesce(p->>'phone', ''), '\D', '', 'g'), 10), '') as ph,
                    nullif(btrim(p->>'lead_id'), '') as lid),
  by_addr as (
    select l.id from public.leads l, a where a.addr is not null
       and public.addr_key(public.addr_main(l.property_address)) = public.addr_key(public.addr_main(a.addr))
    union
    select l.id from public.leads l, a where a.addr is not null and l.property_address ilike '%' || a.addr || '%'),
  by_name as (
    select l.id from public.leads l, a where a.nm is not null and l.owner_name ilike '%' || a.nm || '%'
    union
    select i.lead_id from public.interests i join public.people pe on pe.id = i.person_id, a
     where a.nm is not null and pe.name ilike '%' || a.nm || '%'),
  by_phone as (select c.lead_id from public.contacts c, a where a.ph is not null and c.value_normalized = a.ph)
  select coalesce(jsonb_agg(public.agent_card(x.id)), '[]'::jsonb) from (
    select l.id from public.leads l, a
     where (a.lid is null or l.id::text = a.lid)
       and (a.addr is null or l.id in (select id from by_addr))
       and (a.nm is null or l.id in (select id from by_name))
       and (a.ph is null or l.id in (select lead_id from by_phone))
       and (not coalesce((p->>'only_agent')::boolean, false) or l.wpie_owner_id < 0)
     order by l.updated_at desc limit least(coalesce((p->>'limit')::int, 20), 100)) x
$function$;
