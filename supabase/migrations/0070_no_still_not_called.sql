-- No "still not called" repeat (Colin 2026-10-26: "why am i getting still not called texts"). A hot lead pings once;
-- Colin calls on his own schedule. The 15-minute second alert is gone; the row is closed off so it is never picked
-- up again.

create or replace function public.hot_claim(p_now timestamptz default now(), p_limit integer default 10)
returns jsonb language plpgsql security definer set search_path = public as $$
declare out jsonb := '[]'::jsonb; a record;
begin
  if public.in_quiet_hours(p_now) then return out; end if;
  for a in
    select h.* from public.hot_alerts h
     where h.resolved_at is null and h.alert1_at is null and h.called_at is null and h.created_at > p_now - interval '12 hours'
     order by h.created_at limit p_limit
     for update skip locked
  loop
    update public.hot_alerts set alert1_at = p_now, alert2_at = p_now, last_error = 'one ping only (no repeat since 2026-10-26)' where id = a.id;
    out := out || jsonb_build_object('id', a.id, 'n', 1, 'lead_id', a.lead_id, 'phone10', a.phone10, 'first_name', a.first_name,
                                     'address', a.address, 'body', a.body, 'is_test', a.is_test);
  end loop;
  return out;
end $$;

-- nothing already pinged once gets a repeat either
update public.hot_alerts set alert2_at = coalesce(alert2_at, now()), last_error = coalesce(last_error, 'one ping only (no repeat since 2026-10-26)')
 where alert1_at is not null and alert2_at is null;
