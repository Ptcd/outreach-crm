-- Instant replies (Colin 2026-10-21: "what are our options for instant replies?"): Twilio's
-- incoming-message webhook for the WPIE Mail Replies messaging service calls the
-- reply-inbound Edge Function, which records the text at once (a STOP takes effect before
-- Twilio gets its answer) and decides it in the background. The 1-minute reply-agent timer
-- stays as the catch-up for anything the webhook missed.
--
-- A routine reply (fixed line) waits a natural 45-90 seconds so it does not read as a bot
-- firing back in two seconds, and never goes in quiet hours (it waits for quiet_end plus the
-- same delay). Colin's own approvals go when he taps (or at quiet_end), with no extra delay.

alter table public.campaign_control
  add column auto_reply_delay_min integer not null default 45 check (auto_reply_delay_min >= 0),
  add column auto_reply_delay_max integer not null default 90,
  add constraint auto_reply_delay_order check (auto_reply_delay_max >= auto_reply_delay_min);

-- When a routine reply recorded now may go.
create or replace function public.auto_reply_at(p_now timestamptz default now())
returns timestamptz language sql volatile security definer set search_path = public as $$
  select (case when public.in_quiet_hours(p_now) then public.quiet_hours_end(p_now) else p_now end)
         + make_interval(secs => c.auto_reply_delay_min + floor(random() * (c.auto_reply_delay_max - c.auto_reply_delay_min + 1)))
    from public.campaign_control c where c.id = 1
$$;

-- The soonest queued reply, so the webhook can wait for it and send it itself.
create or replace function public.reply_next_due()
returns timestamptz language sql stable security definer set search_path = public as $$
  select min(coalesce(send_after, now())) from public.reply_drafts where status = 'queued'
$$;

-- reply_record_decision: a queued routine reply now gets the natural delay (0004 queued it for
-- immediate sending outside quiet hours). Same body otherwise.
create or replace function public.reply_record_decision(p_sid text, p_intent text, p_kind text, p_removal boolean,
  p_outcome text, p_body text, p_draft_source text, p_note text, p_rules_version text, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  t public.twilio_inbound;
  c public.campaign_control;
  st text;
  did uuid;
  owner_phones text[];
  oid bigint;
begin
  select * into t from public.twilio_inbound where sid = p_sid;
  if not found then return jsonb_build_object('ok', false, 'reason', 'unknown_inbound'); end if;
  select * into c from public.campaign_control where id = 1;
  update public.reply_drafts set status = 'superseded', updated_at = p_now
   where phone10 = t.from10 and status in ('awaiting_approval', 'would_send', 'queued') and inbound_at < t.received_at;

  st := case
    when p_body is null or btrim(p_body) = '' then case when p_kind = 'candidate' then 'awaiting_approval' else 'no_reply' end
    when p_kind = 'candidate' then 'awaiting_approval'
    when c.routine_enabled then 'queued'
    else 'would_send' end;
  insert into public.reply_drafts (inbound_sid, phone10, our_number, lead_id, inbound_body, inbound_at, intent, kind, outcome,
                                   note, body, draft_source, status, send_after, rules_version, created_at, updated_at)
  values (t.sid, t.from10, t.to_number, t.lead_id, t.body, t.received_at, p_intent, p_kind, p_outcome, p_note,
          nullif(btrim(coalesce(p_body, '')), ''), p_draft_source, st,
          case when st = 'queued' then public.auto_reply_at(p_now) else null end,
          p_rules_version, p_now, p_now)
  on conflict (inbound_sid) do nothing
  returning id into did;
  if did is null then return jsonb_build_object('ok', false, 'reason', 'already_decided'); end if;

  oid := (select l.wpie_owner_id from public.leads l where l.id = t.lead_id);
  if p_removal then
    select coalesce(array_agg(distinct ct.value_normalized), '{}') into owner_phones
      from public.contacts ct join public.leads l on l.id = ct.lead_id
     where ct.kind = 'phone' and ct.value_normalized is not null and (ct.value_normalized = t.from10 or l.wpie_owner_id = oid);
    owner_phones := array_append(owner_phones, t.from10);
    insert into public.suppressed_phones (phone10, reason, source)
      select distinct p, case when p = t.from10 then 'removal_reply' else 'removal_reply_other_phone' end, 'reply_agent'
        from unnest(owner_phones) p where p ~ '^[0-9]{10}$'
    on conflict (phone10) do nothing;
    update public.contacts set suppressed = true where value_normalized = any(owner_phones);
    update public.leads set stage = 'dnc' where id = t.lead_id;
  elsif p_outcome = 'wrong_number' then
    update public.contacts set status = 'bad', note = coalesce(note || '; ', '') || 'wrong number (reply agent)'
     where value_normalized = t.from10 and lead_id = t.lead_id;
    update public.leads set stage = 'data_fix' where id = t.lead_id and stage in ('postcard_mailed', 'opener_queued', 'opener_sent', 'reply_received');
  elsif p_outcome = 'not_interested' then
    update public.leads set stage = 'dead', dead_reason = coalesce(nullif(p_note, ''), 'not interested')
     where id = t.lead_id and stage in ('postcard_mailed', 'opener_queued', 'opener_sent', 'reply_received', 'ai_qualifying');
  else
    update public.leads set stage = case when p_kind = 'candidate' then 'reply_received'::public.lead_stage else 'ai_qualifying'::public.lead_stage end
     where id = t.lead_id and stage in ('postcard_mailed', 'opener_queued', 'opener_sent');
  end if;
  update public.leads set last_inbound_at = greatest(coalesce(last_inbound_at, t.received_at), t.received_at) where id = t.lead_id;
  return jsonb_build_object('ok', true, 'id', did, 'status', st);
end $$;

revoke all on function public.auto_reply_at(timestamptz), public.reply_next_due() from public, anon, authenticated;
grant execute on function public.auto_reply_at(timestamptz), public.reply_next_due() to service_role;
