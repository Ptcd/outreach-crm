-- A pass pings the caller too (Colin 2026-10-28: a walk-it pushed "Colin wants to walk it", a pass pushed nothing).
-- package_ready_claim now also hands the minute run a package Colin passed on in the last day, once; the push says to
-- close politely at the promised callback.
create or replace function public.package_ready_claim() returns jsonb language plpgsql security definer set search_path = public as $$
declare out jsonb; ids uuid[];
begin
  with c as (select d.id from public.deal_packages d
              where d.ready_pinged_at is null
                and (d.status in ('go_walk', 'number_ready')
                     or (d.status = 'declined' and d.colin_call = 'pass' and d.priced_at > now() - interval '1 day'))
              for update skip locked),
  u as (update public.deal_packages d set ready_pinged_at = now() from c where d.id = c.id returning d.id)
  select coalesce(array_agg(id), '{}') into ids from u;
  select coalesce(jsonb_agg(jsonb_build_object('package_id', d.id, 'lead_id', l.id, 'property_address', l.property_address, 'callback_at', d.callback_at,
           'created_by', d.created_by, 'colin_call', d.colin_call)), '[]'::jsonb) into out
    from public.deal_packages d join public.leads l on l.id = d.lead_id where d.id = any(ids);
  return out;
end $$;
