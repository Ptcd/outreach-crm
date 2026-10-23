-- A lead marked do not contact gets no more drafted replies waiting on a person (Colin 2026-10-23: a "Maybe why?"
-- draft for RANDAL R WEYER stayed in Needs you after his call was logged dnc). Three guards:
--   1. reply_claim_send refuses Approve on a draft whose lead is dnc (and marks it skipped);
--   2. the Inbox badge (reply_waiting) does not count such drafts, and the app's Needs you list leaves them out;
--   3. a one-time sweep skips the ones waiting now.
-- No trigger on leads: the belt router moves leads and drafts in the same statements, and a trigger there changed
-- what the reply agent records (the PGlite suite caught it).
-- Deliberately NOT 'dead' / closed, and NOT the routine replies the agent queues itself: a "not interested" or a
-- wrong number moves the lead to dead in the same run that queues its polite answer, and a no that names a number
-- still goes to Colin as a draft. A removal confirmation always goes.

create or replace function public.lead_is_dnc(p_lead uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.leads l where l.id = p_lead and (l.stage = 'dnc' or l.belt = 'dnc'))
$$;

-- drafts already waiting for Approve on a dnc lead
update public.reply_drafts d
   set status = 'skipped', decided_by = coalesce(d.decided_by, 'system'), decided_at = coalesce(d.decided_at, now()),
       updated_at = now(), note = coalesce(d.note, '') || ' | lead marked do not contact (0044 sweep)'
 where d.kind <> 'removal' and d.lead_id is not null and public.lead_is_dnc(d.lead_id)
   and d.status in ('awaiting_approval', 'would_send', 'no_reply', 'dry_sent');

-- reply_claim_send as live on 2026-10-23, plus the closed-lead guard
CREATE OR REPLACE FUNCTION public.reply_claim_send(p_id uuid, p_mode text, p_body text, p_actor text, p_dry boolean, p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
declare
  d public.reply_drafts;
  c public.campaign_control;
  b text;
begin
  select * into d from public.reply_drafts where id = p_id for update;
  if not found then return jsonb_build_object('outcome', 'refused', 'reason', 'no such draft'); end if;
  select * into c from public.campaign_control where id = 1;
  if p_mode = 'auto' then
    if d.status <> 'queued' then return jsonb_build_object('outcome', 'refused', 'reason', 'not queued'); end if;
    if not c.routine_enabled then return jsonb_build_object('outcome', 'refused', 'reason', 'routine replies are off'); end if;
    if d.send_after is not null and d.send_after > p_now then return jsonb_build_object('outcome', 'queued', 'reason', 'quiet hours'); end if;
  elsif p_mode = 'approve' then
    if d.status not in ('awaiting_approval', 'would_send', 'no_reply', 'dry_sent') then
      return jsonb_build_object('outcome', 'refused', 'reason', 'already ' || d.status);
    end if;
  else
    raise exception 'unknown mode %', p_mode;
  end if;
  -- Approve never texts a lead marked do not contact; a removal confirmation still goes (0044)
  if p_mode = 'approve' and d.kind <> 'removal' and d.lead_id is not null and public.lead_is_dnc(d.lead_id) then
    update public.reply_drafts set status = 'skipped', note = coalesce(note, '') || ' | lead marked do not contact',
           updated_at = p_now where id = d.id;
    return jsonb_build_object('outcome', 'refused', 'reason', 'this lead is marked do not contact');
  end if;
  b := btrim(coalesce(case when p_mode = 'approve' then p_body end, d.body, ''));
  if b = '' then return jsonb_build_object('outcome', 'refused', 'reason', 'empty reply'); end if;
  if length(b) > 480 then return jsonb_build_object('outcome', 'refused', 'reason', 'over 480 characters'); end if;
  -- a newer text from them makes this reply stale
  if exists (select 1 from public.twilio_inbound i where i.from10 = d.phone10 and i.received_at > d.inbound_at) then
    update public.reply_drafts set status = 'superseded', updated_at = p_now where id = d.id;
    return jsonb_build_object('outcome', 'refused', 'reason', 'they texted again after this draft - see the newer one');
  end if;
  -- after a removal only the removal confirmation itself may go
  if d.kind <> 'removal' and exists (select 1 from public.suppressed_phones s where s.phone10 = d.phone10) then
    update public.reply_drafts set status = 'skipped', note = coalesce(note, '') || ' | phone opted out', updated_at = p_now where id = d.id;
    return jsonb_build_object('outcome', 'refused', 'reason', 'this phone opted out');
  end if;
  if public.in_quiet_hours(p_now) then
    update public.reply_drafts set status = 'queued', body = b, send_after = public.quiet_hours_end(p_now),
           decided_by = coalesce(p_actor, decided_by), decided_at = coalesce(decided_at, p_now), updated_at = p_now
     where id = d.id;
    return jsonb_build_object('outcome', 'queued', 'reason', 'quiet hours - goes at ' || to_char(public.quiet_hours_end(p_now) at time zone c.timezone, 'HH24:MI'));
  end if;
  if p_dry then
    update public.reply_drafts set status = 'dry_sent', sent_body = b, decided_by = coalesce(p_actor, decided_by),
           decided_at = p_now, updated_at = p_now, note = coalesce(note, '') || ' | would send (live sending is off)'
     where id = d.id;
    return jsonb_build_object('outcome', 'dry_sent', 'body', b);
  end if;
  update public.reply_drafts set status = 'sending', sent_body = b, decided_by = coalesce(p_actor, decided_by),
         decided_at = coalesce(decided_at, p_now), updated_at = p_now where id = d.id;
  return jsonb_build_object('outcome', 'send', 'id', d.id, 'to', '+1' || d.phone10, 'from', d.our_number, 'body', b);
end $$;


-- the Inbox badge: drafts on a do-not-contact lead are not waiting for anyone
create or replace view public.reply_waiting with (security_invoker = true) as
  select (select count(*) from public.reply_drafts d
           where d.status = 'awaiting_approval' and not (d.lead_id is not null and public.lead_is_dnc(d.lead_id)))::integer
           as drafts_waiting,
         (select count(*) from public.reply_drafts where status = 'would_send')::integer as routine_would_send,
         (select count(*) from public.reply_drafts where status = 'queued')::integer as queued,
         (select count(*) from public.tasks where source = 'reply' and done_at is null)::integer as tasks_open;

-- the first version of this migration (live for an hour on 2026-10-23) also had these
drop trigger if exists close_drafts_on_terminal on public.leads;
drop function if exists public.close_drafts_on_terminal();
drop function if exists public.lead_is_closed(uuid);
