-- A text that arrives after the thread was closed (a STOP, a wrong number, a no, a do-not-contact call,
-- a dead lead) is not a conversation. Colin 2026-10-22, on a "Reply needs you" email for "No problem, have
-- a good day" sent after "Wrong number, STOP" and our goodbye: "Why did I get this" / "Fix it".
--   reply_closed_state(sid)     how the thread was closed BEFORE this text arrived, or null if it is open
--   reply_record_after_close    records the text as decided (kind after_close, no draft, no email, no push),
--                               marks its Inbox copy seen, and, when the text shows interest, opens one
--                               call task for Colin: after a STOP we never text, but a person may call
-- The reply agent (replyAgent.ts step 2) calls these before deciding a claimed text.

alter table public.reply_drafts drop constraint if exists reply_drafts_kind_check;
alter table public.reply_drafts add constraint reply_drafts_kind_check
  check (kind in ('removal', 'routine', 'candidate', 'after_close'));

create or replace function public.reply_closed_state(p_sid text)
returns text language plpgsql stable security definer set search_path = public as $$
declare t public.twilio_inbound; r text; st text;
begin
  select * into t from public.twilio_inbound where sid = p_sid;
  if not found then return null; end if;
  -- a removal or a do-not-contact call suppressed the phone before this text came in
  select reason into r from public.suppressed_phones s where s.phone10 = t.from10 and s.added_at < t.received_at limit 1;
  if r is not null then return case when r like 'dnc%' then 'dnc' else 'stop' end; end if;
  -- an earlier text on this phone was decided as a removal, a wrong number or a no
  select case when d.kind = 'removal' then 'stop' when d.outcome = 'wrong_number' then 'wrong_number'
              when d.outcome = 'not_interested' then 'not_interested' end into st
    from public.reply_drafts d
   where d.phone10 = t.from10 and d.inbound_at < t.received_at
     and (d.kind = 'removal' or d.outcome in ('wrong_number', 'not_interested'))
   order by d.inbound_at desc limit 1;
  if st is not null then return st; end if;
  -- the lead itself was closed (by a call outcome, or the sync) before this text
  select case l.stage::text when 'dnc' then 'dnc' when 'dead' then 'dead' when 'closed_no_contact' then 'dead' end into st
    from public.leads l where l.id = t.lead_id and l.stage_changed_at < t.received_at;
  return st;
end $$;
revoke all on function public.reply_closed_state(text) from public, anon, authenticated;
grant execute on function public.reply_closed_state(text) to service_role;

create or replace function public.reply_record_after_close(p_sid text, p_state text, p_interest boolean, p_note text default null,
  p_rules_version text default null, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare t public.twilio_inbound; did uuid; tid uuid;
begin
  select * into t from public.twilio_inbound where sid = p_sid;
  if not found then return jsonb_build_object('ok', false, 'reason', 'unknown_inbound'); end if;
  insert into public.reply_drafts (inbound_sid, phone10, our_number, lead_id, inbound_body, inbound_at, intent, kind, outcome,
                                   note, body, draft_source, status, rules_version, created_at, updated_at)
  values (t.sid, t.from10, t.to_number, t.lead_id, t.body, t.received_at, 'after_close', 'after_close', p_state,
          coalesce(p_note, 'after the thread was closed (' || p_state || ')'), null, 'none', 'no_reply', p_rules_version, p_now, p_now)
  on conflict (inbound_sid) do nothing
  returning id into did;
  if did is null then return jsonb_build_object('ok', false, 'reason', 'already_decided'); end if;
  -- the Inbox copy (synced from the ledger, no provider sid) is nothing to read: mark it seen
  update public.messages m set seen_at = coalesce(m.seen_at, p_now)
   where m.lead_id = t.lead_id and m.direction = 'in' and m.channel = 'sms' and m.seen_at is null
     and m.body = t.body and m.sent_at between t.received_at - interval '1 day' and t.received_at + interval '1 day';
  update public.leads set last_inbound_at = greatest(coalesce(last_inbound_at, t.received_at), t.received_at) where id = t.lead_id;
  if p_interest and t.lead_id is not null then
    insert into public.tasks (lead_id, due_at, kind, owner, note, source, title, quote, reply_inbound_sid, phone10, created_by)
    values (t.lead_id, p_now, 'call', 'colin'::public.team_person,
            'They wrote back after the thread was closed (' || p_state || '). A STOP is final for texts; a person may call.',
            'after_stop', 'Wrote back after STOP: call, never text', left(coalesce(t.body, ''), 500), t.sid, t.from10, null)
    on conflict (reply_inbound_sid) do nothing
    returning id into tid;
  end if;
  return jsonb_build_object('ok', true, 'id', did, 'task_id', tid);
end $$;
revoke all on function public.reply_record_after_close(text, text, boolean, text, text, timestamptz) from public, anon, authenticated;
grant execute on function public.reply_record_after_close(text, text, boolean, text, text, timestamptz) to service_role;

-- An Inbox copy that syncs after the decision is born seen.
create or replace function public.messages_seen_if_after_close() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.direction = 'in' and new.channel = 'sms' and new.seen_at is null and new.lead_id is not null and exists (
       select 1 from public.reply_drafts d
        where d.lead_id = new.lead_id and d.kind = 'after_close' and d.inbound_body = new.body
          and new.sent_at between d.inbound_at - interval '1 day' and d.inbound_at + interval '1 day') then
    new.seen_at := now();
  end if;
  return new;
end $$;
drop trigger if exists messages_seen_if_after_close on public.messages;
create trigger messages_seen_if_after_close before insert on public.messages
  for each row execute function public.messages_seen_if_after_close();
