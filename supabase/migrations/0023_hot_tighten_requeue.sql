-- Hot alerts, tightened (Colin 2026-10-22, on Martin at 2469 S Howell Av: "this came in hot after that
-- yes which doesn't make much sense, we don't even know that they want to sell"). The trigger itself
-- lives in hotLeads.ts; here:
--   * a later reply that says no (not interested, sold, listed...), a removal or a wrong number
--     resolves that lead's open hot alerts: no 15-minute repeat, not on the 7 PM list
--   * a text the agent claimed but never decided (the run died in between, e.g. during a deploy) is
--     put back for the next run instead of being lost

alter table public.hot_alerts
  add column if not exists resolved_at timestamptz,
  add column if not exists resolved_reason text;

create or replace function public.hot_resolve(p_phone10 text, p_lead_id uuid, p_reason text, p_now timestamptz default now())
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  update public.hot_alerts set resolved_at = p_now, resolved_reason = left(p_reason, 200)
   where resolved_at is null and called_at is null
     and (phone10 = p_phone10 or (p_lead_id is not null and lead_id = p_lead_id));
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.reply_requeue_lost(p_now timestamptz default now())
returns integer language plpgsql security definer set search_path = public as $$
declare n integer; nums text[];
begin
  select c.reply_numbers into nums from public.campaign_control c where c.id = 1;
  update public.twilio_inbound i set processed_at = null
   where i.processed_at < p_now - interval '2 minutes' and i.processed_at > p_now - interval '6 hours'
     and i.to_number = any(nums)
     and not exists (select 1 from public.reply_drafts d where d.inbound_sid = i.sid);
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.hot_claim(p_now timestamptz default now(), p_limit integer default 10)
returns jsonb language plpgsql security definer set search_path = public as $$
declare out jsonb := '[]'::jsonb; a record; called boolean;
begin
  if public.in_quiet_hours(p_now) then return out; end if;
  for a in
    select h.* from public.hot_alerts h
     where h.resolved_at is null and ((h.alert1_at is null and h.created_at > p_now - interval '12 hours' and h.called_at is null)
        or (h.alert1_at is not null and h.alert2_at is null and h.alert1_at <= p_now - interval '15 minutes'
            and h.created_at > p_now - interval '12 hours'))
     order by h.created_at limit p_limit
     for update skip locked
  loop
    called := a.called_at is not null;
    if a.alert1_at is null then
      update public.hot_alerts set alert1_at = p_now where id = a.id;
      out := out || jsonb_build_object('id', a.id, 'n', 1, 'lead_id', a.lead_id, 'phone10', a.phone10, 'first_name', a.first_name,
                                       'address', a.address, 'body', a.body, 'is_test', a.is_test);
    elsif not coalesce(called, false) then
      update public.hot_alerts set alert2_at = p_now where id = a.id;
      out := out || jsonb_build_object('id', a.id, 'n', 2, 'lead_id', a.lead_id, 'phone10', a.phone10, 'first_name', a.first_name,
                                       'address', a.address, 'body', a.body, 'is_test', a.is_test);
    else
      update public.hot_alerts set alert2_at = p_now, last_error = 'called - no second alert' where id = a.id;
    end if;
  end loop;
  return out;
end $$;

create or replace function public.hot_digest(p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare c public.campaign_control; today date := (p_now at time zone 'America/Chicago')::date; out jsonb;
begin
  if extract(hour from p_now at time zone 'America/Chicago') < 19 then return null; end if;
  select * into c from public.campaign_control where id = 1 for update;
  if c.hot_digest_date = today then return null; end if;
  update public.campaign_control set hot_digest_date = today where id = 1;
  select coalesce(jsonb_agg(jsonb_build_object('first_name', x.first_name, 'address', x.address, 'phone10', x.phone10,
                                               'lead_id', x.lead_id) order by x.created_at), '[]'::jsonb) into out
    from (select distinct on (coalesce(h.lead_id::text, h.phone10)) h.* from public.hot_alerts h
          where (h.created_at at time zone 'America/Chicago')::date = today and not h.is_test and h.called_at is null and h.resolved_at is null
          order by coalesce(h.lead_id::text, h.phone10), h.created_at) x;
  return out;
end $$;

revoke all on function public.hot_resolve(text, uuid, text, timestamptz), public.reply_requeue_lost(timestamptz) from public, anon, authenticated;
grant execute on function public.hot_resolve(text, uuid, text, timestamptz), public.reply_requeue_lost(timestamptz) to service_role;
