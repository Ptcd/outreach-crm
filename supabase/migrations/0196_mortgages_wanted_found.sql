-- 0196: agent_mortgages_wanted failed on its first call (Muse, 2026-11-07 evening: 'column reference "found" is
-- ambiguous'). Inside a plpgsql function the bare word found is also the function's own FOUND status variable, so
-- the counts query's "and found" could mean either. Every reference to the column is qualified now; the function
-- otherwise stands as 0195 wrote it. agent_mortgage_add only uses FOUND the plpgsql way and sets the column by name,
-- which is not ambiguous, so it is left alone.

create or replace function public.agent_mortgages_wanted(p_agent text, p_limit integer default 50, p_county text default null,
                                                         p_counts_only boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare ids integer[]; out jsonb; counts jsonb;
begin
  select jsonb_build_object(
           'open', count(*) filter (where mw.done_at is null and (mw.claimed_at is null or mw.claimed_at < now() - interval '2 days')),
           'open_real_need', count(*) filter (where mw.done_at is null and mw.need = 'real need' and (mw.claimed_at is null or mw.claimed_at < now() - interval '2 days')),
           'claimed', count(*) filter (where mw.done_at is null and mw.claimed_at >= now() - interval '2 days'),
           'yours', count(*) filter (where mw.done_at is null and mw.claimed_by = p_agent and mw.claimed_at >= now() - interval '2 days'),
           'done_7d', count(*) filter (where mw.done_at > now() - interval '7 days'),
           'found_7d', count(*) filter (where mw.done_at > now() - interval '7 days' and mw.found is true),
           'by_county', (select coalesce(jsonb_object_agg(c.county, c.n), '{}'::jsonb) from (
               select x.county, count(*) n from public.mortgages_wanted x where x.done_at is null group by x.county order by n desc limit 30) c))
    into counts from public.mortgages_wanted mw;
  if coalesce(p_counts_only, false) then return jsonb_build_object('counts', counts, 'parcels', '[]'::jsonb); end if;
  with pick as (
    select w.wpie_property_id from public.mortgages_wanted w
     where w.done_at is null and (w.claimed_at is null or w.claimed_at < now() - interval '2 days' or w.claimed_by = p_agent)
       and (p_county is null or w.county = p_county)
     order by (w.need = 'real need') desc, (w.index_url is not null) desc, w.listed_on, w.wpie_property_id
     limit greatest(1, least(coalesce(p_limit, 50), 200))
     for update skip locked),
  u as (update public.mortgages_wanted w set claimed_by = p_agent, claimed_at = now(), updated_at = now()
          from pick where w.wpie_property_id = pick.wpie_property_id returning w.wpie_property_id)
  select coalesce(array_agg(u.wpie_property_id), '{}') into ids from u;
  select coalesce(jsonb_agg(jsonb_build_object(
           'wpie_property_id', w.wpie_property_id, 'parcel', w.parcel_id, 'address', w.property_address, 'city', w.municipality,
           'county', w.county, 'owner_name', w.owner_name, 'equity_grade', w.equity_grade, 'equity_line', w.equity_line,
           'need', w.need, 'why', w.why, 'index_url', w.index_url, 'index_notes', w.index_notes, 'card', w.lead_id)
           order by (w.need = 'real need') desc, (w.index_url is not null) desc, w.listed_on, w.wpie_property_id), '[]'::jsonb)
    into out from public.mortgages_wanted w where w.wpie_property_id = any(ids);
  return jsonb_build_object('counts', counts, 'parcels', out);
end $$;
revoke all on function public.agent_mortgages_wanted(text, integer, text, boolean) from public, anon, authenticated;
grant execute on function public.agent_mortgages_wanted(text, integer, text, boolean) to service_role;
