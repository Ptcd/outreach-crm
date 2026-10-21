-- Stuck sends (2026-10-21 18:30, first live pass): a row claimed 'sending' whose result never got
-- written back (the text went out, the sid was lost). Each pass now starts by reconciling rows
-- that have been 'sending' for over two minutes against Twilio's own record:
--   found at Twilio -> record_send_result('sent', sid) (+ its delivery status), as if it had worked
--   not found       -> release_stuck_opener: back to 'planned' (it was claimed once and never sent,
--                      so sending it later cannot double-text), logged as 'released'
-- Pacing and pause rules are unchanged.

create or replace function public.stuck_sending(p_older_than_seconds integer default 120, p_now timestamptz default now())
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'phone', p.phone, 'body', p.body, 'claimed_at', p.claimed_at,
                                               'wpie_owner_id', p.wpie_owner_id) order by p.claimed_at), '[]'::jsonb)
    from public.planned_openers p
   where p.send_status = 'sending' and p.provider_sid is null and p.claim_mode = 'live'
     and p.claimed_at < p_now - make_interval(secs => p_older_than_seconds)
$$;

create or replace function public.release_stuck_opener(p_id uuid, p_reason text, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare o public.planned_openers;
begin
  select * into o from public.planned_openers where id = p_id for update;
  if not found or o.send_status <> 'sending' or o.provider_sid is not null then
    return jsonb_build_object('ok', false, 'reason', 'not_stuck');
  end if;
  update public.planned_openers
     set send_status = 'planned', claim_mode = null, claimed_at = null, send_reason = left(p_reason, 300), send_updated_at = p_now
   where id = p_id;
  insert into public.opener_send_events (opener_id, plan_date, wpie_owner_id, attempt, event, reason, actor, at)
  values (o.id, o.plan_date, o.wpie_owner_id, o.attempt, 'released', left(p_reason, 300), 'server', p_now);
  return jsonb_build_object('ok', true);
end $$;

revoke all on function public.stuck_sending(integer, timestamptz), public.release_stuck_opener(uuid, text, timestamptz)
  from public, anon, authenticated;
grant execute on function public.stuck_sending(integer, timestamptz), public.release_stuck_opener(uuid, text, timestamptz)
  to service_role;
