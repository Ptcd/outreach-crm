-- Sent replies are logged on the lead's thread with source_key 'reply:<draft id>' (was the old
-- agent name). Existing rows are renamed; nothing else changes.

create or replace function public.reply_record_result(p_id uuid, p_status text, p_sid text default null,
  p_error_code text default null, p_reason text default null, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare d public.reply_drafts;
begin
  if p_status not in ('sent', 'failed', 'uncertain') then raise exception 'unknown result %', p_status; end if;
  select * into d from public.reply_drafts where id = p_id for update;
  if not found or d.status <> 'sending' then return jsonb_build_object('ok', false, 'reason', 'not sending'); end if;
  update public.reply_drafts set status = p_status, provider_sid = p_sid, error_code = p_error_code,
         sent_at = case when p_status = 'sent' then p_now end, updated_at = p_now,
         note = case when p_reason is null then note else coalesce(note, '') || ' | ' || p_reason end
   where id = p_id;
  if p_status = 'sent' and d.lead_id is not null then
    insert into public.messages (lead_id, direction, channel, body, from_number, to_number, provider_sid, source_key, status, sent_at, created_by)
    values (d.lead_id, 'out', 'sms', d.sent_body, d.our_number, '+1' || d.phone10, p_sid, 'reply:' || d.id, 'sent', p_now, null)
    on conflict (source_key) do nothing;
  end if;
  return jsonb_build_object('ok', true);
end $$;

update public.messages set source_key = 'reply:' || substr(source_key, 5) where source_key like 'sam:%';
