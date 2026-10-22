-- 0026 follow-up: a thread the laptop's reply brain closed (reply_threads.outcome close_dnc /
-- close_wrong_number / close_not_interested, synced from WPIE) before the server agent ever decided a
-- text on that phone has no reply_drafts row, and if the lead's stage was not moved it still read as open.
-- Count it as closed when the thread's last inbound came before this text. Also match the Inbox copy
-- with both bodies trimmed, so a trailing space between the ledger copy and the Twilio copy still matches.

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
  -- the laptop's reply brain closed the thread (synced) before this text
  select case th.outcome when 'close_dnc' then 'stop' when 'close_wrong_number' then 'wrong_number'
              when 'close_not_interested' then 'not_interested' end into st
    from public.reply_threads th
   where th.phone10 = t.from10 and th.outcome in ('close_dnc', 'close_wrong_number', 'close_not_interested')
     and th.last_inbound_at is not null and th.last_inbound_at < t.received_at;
  if st is not null then return st; end if;
  -- the lead itself was closed (by a call outcome, or the sync) before this text
  select case l.stage::text when 'dnc' then 'dnc' when 'dead' then 'dead' when 'closed_no_contact' then 'dead' end into st
    from public.leads l where l.id = t.lead_id and l.stage_changed_at < t.received_at;
  return st;
end $$;

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
  update public.messages m set seen_at = coalesce(m.seen_at, p_now)
   where m.lead_id = t.lead_id and m.direction = 'in' and m.channel = 'sms' and m.seen_at is null
     and btrim(coalesce(m.body, '')) = btrim(coalesce(t.body, ''))
     and m.sent_at between t.received_at - interval '1 day' and t.received_at + interval '1 day';
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

create or replace function public.messages_seen_if_after_close() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.direction = 'in' and new.channel = 'sms' and new.seen_at is null and new.lead_id is not null and exists (
       select 1 from public.reply_drafts d
        where d.lead_id = new.lead_id and d.kind = 'after_close'
          and btrim(coalesce(d.inbound_body, '')) = btrim(coalesce(new.body, ''))
          and new.sent_at between d.inbound_at - interval '1 day' and d.inbound_at + interval '1 day') then
    new.seen_at := now();
  end if;
  return new;
end $$;
