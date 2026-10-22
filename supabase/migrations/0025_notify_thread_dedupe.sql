-- The "needs you" email showed Colin's pitch twice in the thread (Martin, 2026-10-22): the thread
-- joined sent replies from reply_drafts AND the same replies as logged in messages. Each text now
-- appears once: messages that are a sent reply or a synced copy of an inbound text are left out, and
-- any remaining exact repeat from the same side within the hour is dropped.

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
        select z0.*, row_number() over (partition by z0.who, btrim(z0.body), date_trunc('hour', z0.at) order by z0.at) as rn from (
          select 'them' as who, x.body, x.received_at as at from public.twilio_inbound x
           where x.from10 = d.phone10 and x.received_at <= d.inbound_at
          union all
          select 'us', s.sent_body, s.sent_at from public.reply_drafts s where s.phone10 = d.phone10 and s.status = 'sent'
          union all
          select case when m.direction = 'out' then 'us' else 'them' end, m.body, m.sent_at
            from public.messages m where m.lead_id = d.lead_id and m.channel = 'sms' and m.provider_sid is not null
              -- the same text again: a sent reply is also logged in messages, an inbound text is also synced
              and not exists (select 1 from public.reply_drafts s2 where s2.provider_sid = m.provider_sid)
              and not exists (select 1 from public.twilio_inbound x2 where x2.sid = m.provider_sid)
        ) z0 where z0.body is not null
        -- and anything else that is the same words from the same side within the same hour
        ) z where z.rn = 1), '[]'::jsonb));
  end loop;
  return out;
end $$;
