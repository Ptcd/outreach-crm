-- An in-app call that never reached the phone company must not leave the card paused (Colin
-- 2026-10-23: "im not on a call and if a page closes the call should be cut off"). pm-phone claims an
-- attempt (0041) before it emits <Dial>, so an app call with no claim never rang anyone: releasing it
-- is safe. A claimed call did reach the phone company and still needs its outcome logged, and a
-- personal-phone call has no provider claim at all, so neither is ever released here.
--
-- Two doors, one rule (release_unclaimed_call_core):
--   release_unclaimed_human_call  the browser, the moment its call fails or ends
--   sweep_unclaimed_human_calls   every minute, for a page that closed or lost its connection

create or replace function public.release_unclaimed_call_core(p_lead_id uuid, p_key text, p_reason text,
  p_actor text, p_now timestamptz)
returns jsonb language plpgsql security definer set search_path = public as $$
declare l public.leads; d record; src text;
begin
  -- Same first lock as begin_human_call and claim_human_call_provider: a claim racing this release
  -- waits for it and then finds no active authorization.
  select * into l from public.leads where id = p_lead_id for update;
  if not found then return jsonb_build_object('ok', false, 'released', false, 'reason', 'no such lead'); end if;
  if l.human_takeover_at is null then return jsonb_build_object('ok', true, 'released', false, 'reason', 'not paused'); end if;
  if l.human_takeover_key is distinct from p_key then
    return jsonb_build_object('ok', false, 'released', false, 'reason', 'that is not the active call');
  end if;
  select e.payload->>'source' into src from public.belt_events e
   where e.lead_id = p_lead_id and e.event = 'human_call_started' and e.payload->>'key' = 'human_call:' || p_key
   order by e.at desc limit 1;
  if src is distinct from 'app' then
    return jsonb_build_object('ok', true, 'released', false, 'reason', 'a personal-phone call: log its outcome');
  end if;
  if exists (select 1 from public.human_call_provider_claims c where c.attempt_key = p_key) then
    return jsonb_build_object('ok', true, 'released', false, 'reason', 'the call was placed: log its outcome');
  end if;
  -- Exactly what resume_human_call does: held belt texts go back to where they were.
  for d in select x->>'id' as id, x->>'status' as status from jsonb_array_elements(coalesce(l.human_takeover_drafts, '[]'::jsonb)) x loop
    update public.reply_drafts set status = d.status,
      note = regexp_replace(coalesce(note, ''), ' \| human call ' || p_key || '$', ''), updated_at = p_now
      where id = d.id::uuid and lead_id = p_lead_id and status = 'superseded';
  end loop;
  update public.leads set human_takeover_at = null, human_takeover_by = null,
    human_takeover_phone = null, human_takeover_key = null, human_takeover_drafts = null,
    human_takeover_assigned_to = null where id = p_lead_id;
  insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
    values (p_lead_id, 'human_call_resumed', l.belt, l.belt, l.belt_step,
      jsonb_build_object('key', 'human_resume:' || p_key, 'reason', p_reason), p_now, p_actor);
  return jsonb_build_object('ok', true, 'released', true);
end $$;
revoke all on function public.release_unclaimed_call_core(uuid, text, text, text, timestamptz) from public, anon, authenticated;

create or replace function public.release_unclaimed_human_call(p_lead_id uuid, p_key text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare who text;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  select tm.display_name into who from public.team_members tm where lower(tm.email) = lower(auth.jwt() ->> 'email');
  return public.release_unclaimed_call_core(p_lead_id, p_key, 'the call never reached the phone company', coalesce(who, 'team'), now());
end $$;
revoke all on function public.release_unclaimed_human_call(uuid, text) from public, anon;
grant execute on function public.release_unclaimed_human_call(uuid, text) to authenticated;

create or replace function public.sweep_unclaimed_human_calls(p_older_than_seconds integer default 180, p_now timestamptz default now())
returns integer language plpgsql security definer set search_path = public as $$
declare r record; v jsonb; n integer := 0;
begin
  for r in select id, human_takeover_key as key from public.leads
            where human_takeover_at is not null and human_takeover_key is not null
              and human_takeover_at < p_now - make_interval(secs => p_older_than_seconds) loop
    v := public.release_unclaimed_call_core(r.id, r.key,
      'released automatically: the call never reached the phone company', 'system', p_now);
    if coalesce((v->>'released')::boolean, false) then n := n + 1; end if;
  end loop;
  return n;
end $$;
revoke all on function public.sweep_unclaimed_human_calls(integer, timestamptz) from public, anon, authenticated;
grant execute on function public.sweep_unclaimed_human_calls(integer, timestamptz) to service_role;

do $do$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if exists (select 1 from cron.job where jobname = 'wpie-release-unclaimed-calls') then
      perform cron.unschedule('wpie-release-unclaimed-calls');
    end if;
    perform cron.schedule('wpie-release-unclaimed-calls', '* * * * *', 'select public.sweep_unclaimed_human_calls(180)');
  end if;
end
$do$;
