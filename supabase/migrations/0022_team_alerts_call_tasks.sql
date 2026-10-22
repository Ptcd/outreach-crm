-- The two "ask Colin" items a caller's guide still had, automated (Colin 2026-10-22: "Fuck that,
-- that should be automated"):
--   1. Hot-lead alerts reach the whole team: a web push to every subscribed phone (any team member
--      may now register one, not only Colin) at the same moments as the texts, and a text to each
--      member with an alert_phone on file (sent through pm-phone's /api/alert, which only accepts
--      numbers on its own ALERT_EXTRA_NUMBERS list). Colin's alert_phone stays null: pm-phone texts
--      his phone by default.
--   2. The daily call list (WPIE data/campaign/call_list_<date>.csv) lands on Today as tasks:
--      tasks.source_key = 'calls:<date>:<wpie_owner_id>' makes the sync's upsert idempotent.

alter table public.team_members add column if not exists alert_phone text;
comment on column public.team_members.alert_phone is
  'Phone that gets the hot-lead texts (E.164 or 10 digits). Null = push only. Colin''s stays null: pm-phone texts him by default. The number must also be in pm-phone''s ALERT_EXTRA_NUMBERS.';

-- Team members other than Colin who get the hot-lead texts, as [{person, phone}] (service_role).
create or replace function public.alert_recipients()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('person', m.person::text,
           'phone', '+1' || right(regexp_replace(m.alert_phone, '\D', '', 'g'), 10)) order by m.person), '[]'::jsonb)
    from public.team_members m
   where m.role <> 'owner' and length(regexp_replace(coalesce(m.alert_phone, ''), '\D', '', 'g')) in (10, 11)
$$;
revoke all on function public.alert_recipients() from public, anon, authenticated;
grant execute on function public.alert_recipients() to service_role;
grant select on public.team_members to service_role;

-- Any team member's phone may register for push (was Colin only); each person deletes their own.
create or replace function public.save_push_subscription(p_endpoint text, p_p256dh text, p_auth text, p_user_agent text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_team() then raise exception 'team only'; end if;
  if p_endpoint !~ '^https://' then raise exception 'not a push endpoint'; end if;
  insert into public.push_subscriptions (endpoint, p256dh, auth, user_id, user_agent)
  values (p_endpoint, p_p256dh, p_auth, auth.uid(), left(p_user_agent, 300))
  on conflict (endpoint) do update set p256dh = excluded.p256dh, auth = excluded.auth, user_id = excluded.user_id,
                                       user_agent = excluded.user_agent, failures = 0;
end $$;

create or replace function public.delete_push_subscription(p_endpoint text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_team() then raise exception 'team only'; end if;
  delete from public.push_subscriptions where endpoint = p_endpoint and (user_id = auth.uid() or public.is_owner());
end $$;

-- Call-list tasks: one per (list date, owner); a re-push updates the same row.
alter table public.tasks add column if not exists source_key text;
create unique index if not exists tasks_source_key_idx on public.tasks (source_key);
comment on column public.tasks.source_key is
  'Idempotency key for tasks the sync writes: calls:<list date>:<wpie_owner_id> for the daily call list. Null for tasks made in the app.';
