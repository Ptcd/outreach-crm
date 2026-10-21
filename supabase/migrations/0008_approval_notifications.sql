-- Approval notifications (Colin 2026-10-21: "how can we have sam notify me easily when it needs
-- my approval", "i have android"). ONLY for a real reply waiting for Colin (reply_drafts
-- kind = 'candidate', status = 'awaiting_approval'), never for routine replies:
--   * one web push per draft (and one email backup), as soon as it is drafted;
--   * one reminder push if it is still waiting 2 hours later;
--   * nothing between quiet_start and quiet_end (Central): it waits for 8am.
-- The claim functions mark a draft notified in the same transaction that hands it out, so the
-- webhook and the 1-minute timer can never both notify it.

create table public.push_subscriptions (
  endpoint    text primary key,
  p256dh      text not null,
  auth        text not null,
  user_id     uuid,
  user_agent  text,
  created_at  timestamptz not null default now(),
  last_ok_at  timestamptz,
  failures    integer not null default 0
);
alter table public.push_subscriptions enable row level security;
grant select on public.push_subscriptions to authenticated;
create policy push_read_own on public.push_subscriptions for select to authenticated using (user_id = auth.uid());

alter table public.reply_drafts
  add column notified_at timestamptz,
  add column reminded_at timestamptz;

-- Colin's phone registers here (owner only); the same endpoint is updated, never duplicated.
create or replace function public.save_push_subscription(p_endpoint text, p_p256dh text, p_auth text, p_user_agent text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_owner() then raise exception 'only Colin (owner) can turn on notifications'; end if;
  if p_endpoint !~ '^https://' then raise exception 'not a push endpoint'; end if;
  insert into public.push_subscriptions (endpoint, p256dh, auth, user_id, user_agent)
  values (p_endpoint, p_p256dh, p_auth, auth.uid(), left(p_user_agent, 300))
  on conflict (endpoint) do update set p256dh = excluded.p256dh, auth = excluded.auth, user_id = excluded.user_id,
                                       user_agent = excluded.user_agent, failures = 0;
end $$;

create or replace function public.delete_push_subscription(p_endpoint text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_owner() then raise exception 'only Colin (owner)'; end if;
  delete from public.push_subscriptions where endpoint = p_endpoint;
end $$;

-- Drafts to notify now. p_kind 'first': never notified; 'reminder': notified 2+ hours ago, not
-- reminded, still waiting. Nothing in quiet hours. Each row is marked in this transaction.
create or replace function public.notify_claim(p_kind text, p_now timestamptz default now(), p_limit integer default 20)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  out jsonb := '[]'::jsonb;
  d record;
begin
  if p_kind not in ('first', 'reminder') then raise exception 'unknown kind %', p_kind; end if;
  if public.in_quiet_hours(p_now) then return out; end if;
  for d in
    select r.* from public.reply_drafts r
     where r.kind = 'candidate' and r.status = 'awaiting_approval'
       and ((p_kind = 'first' and r.notified_at is null)
         or (p_kind = 'reminder' and r.notified_at is not null and r.reminded_at is null and r.notified_at <= p_now - interval '2 hours'))
     order by r.inbound_at
     limit p_limit
     for update skip locked
  loop
    if p_kind = 'first' then
      update public.reply_drafts set notified_at = p_now where id = d.id;
    else
      update public.reply_drafts set reminded_at = p_now where id = d.id;
    end if;
    out := out || jsonb_build_object(
      'id', d.id, 'kind', p_kind, 'is_test', d.is_test, 'phone10', d.phone10, 'inbound_body', d.inbound_body,
      'inbound_at', d.inbound_at, 'intent', d.intent, 'note', d.note, 'body', d.body,
      'owner_name', case when d.is_test then (select c.test_owner_name from public.campaign_control c where c.id = 1)
                         else (select l.owner_name from public.leads l where l.id = d.lead_id) end,
      'property_address', case when d.is_test then (select c.test_property_address from public.campaign_control c where c.id = 1)
                               else (select l.property_address from public.leads l where l.id = d.lead_id) end,
      'thread', coalesce((select jsonb_agg(jsonb_build_object('who', z.who, 'body', z.body, 'at', z.at) order by z.at) from (
          select 'them' as who, x.body, x.received_at as at from public.twilio_inbound x
           where x.from10 = d.phone10 and x.received_at <= d.inbound_at
          union all
          select 'us', s.sent_body, s.sent_at from public.reply_drafts s where s.phone10 = d.phone10 and s.status = 'sent'
          union all
          select case when m.direction = 'out' then 'us' else 'them' end, m.body, m.sent_at
            from public.messages m where m.lead_id = d.lead_id and m.channel = 'sms' and m.provider_sid is not null
        ) z where z.body is not null), '[]'::jsonb));
  end loop;
  return out;
end $$;

-- A push service said the subscription is gone (404/410): forget it. Other failures are counted.
create or replace function public.push_result(p_endpoint text, p_ok boolean, p_gone boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_gone then
    delete from public.push_subscriptions where endpoint = p_endpoint;
  elsif p_ok then
    update public.push_subscriptions set last_ok_at = now(), failures = 0 where endpoint = p_endpoint;
  else
    update public.push_subscriptions set failures = failures + 1 where endpoint = p_endpoint;
  end if;
end $$;

revoke all on function public.save_push_subscription(text, text, text, text), public.delete_push_subscription(text) from public, anon;
grant execute on function public.save_push_subscription(text, text, text, text), public.delete_push_subscription(text) to authenticated;
revoke all on function public.notify_claim(text, timestamptz, integer), public.push_result(text, boolean, boolean) from public, anon, authenticated;
grant execute on function public.notify_claim(text, timestamptz, integer), public.push_result(text, boolean, boolean) to service_role;
grant select, insert, update, delete on public.push_subscriptions to service_role;
