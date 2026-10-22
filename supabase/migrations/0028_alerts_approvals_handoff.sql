-- Colin 2026-10-22, on the operator's manual: a spot in Settings where Thalia and Adil set the email (and
-- phone) hot pings go to; they approve the day's texts and the agent's drafts themselves; and they hand
-- Colin a viable seller with one button that pings him.
--   team_members.alert_email + set_my_alerts()     the Settings page; alert_email_recipients() for the server
--   approve_day / withdraw_day / skip_reply         any team member, not only the owner (the switches stay his)
--   handoff_to_colin(lead, note)                    assigns Colin, opens his task, notes the thread, pings him
--   log_call                                        accepts 'no_answer' and 'reached_no_decision' (the call queue)

alter table public.team_members add column if not exists alert_email text;
comment on column public.team_members.alert_email is 'Hot-lead and needs-you emails go here (Settings page); null = none.';

create or replace function public.set_my_alerts(p_phone text, p_email text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare d text; e text;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  d := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  if length(d) = 11 and left(d, 1) = '1' then d := right(d, 10); end if;
  if d <> '' and length(d) <> 10 then return jsonb_build_object('ok', false, 'reason', 'A phone number is 10 digits.'); end if;
  e := lower(btrim(coalesce(p_email, '')));
  if e <> '' and e !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then return jsonb_build_object('ok', false, 'reason', 'That is not an email address.'); end if;
  update public.team_members set alert_phone = nullif(d, ''), alert_email = nullif(e, '')
   where lower(email) = lower(auth.jwt() ->> 'email');
  if not found then return jsonb_build_object('ok', false, 'reason', 'not on the team'); end if;
  return jsonb_build_object('ok', true, 'phone', nullif(d, ''), 'email', nullif(e, ''));
end $$;
revoke all on function public.set_my_alerts(text, text) from public, anon;
grant execute on function public.set_my_alerts(text, text) to authenticated;

-- Everyone with an alert email on file, Colin included: hot leads and needs-you drafts are emailed to them.
create or replace function public.alert_email_recipients()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('person', m.person::text, 'email', m.alert_email) order by m.person), '[]'::jsonb)
    from public.team_members m
   where coalesce(m.alert_email, '') ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'
$$;
revoke all on function public.alert_email_recipients() from public, anon, authenticated;
grant execute on function public.alert_email_recipients() to service_role;

-- Callers approve the day's texts and the agent's drafts (Colin 2026-10-22: "they approve the texts and drafts").
create or replace function public.approve_day(p_date date, p_except uuid[] default '{}')
returns jsonb language plpgsql security definer set search_path = public as $$
declare who text; n_ok integer; n_skip integer;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  select display_name into who from public.team_members where lower(email) = lower(auth.jwt() ->> 'email');
  update public.planned_openers set decision = 'skipped', decided_by = auth.uid(), decided_by_name = who,
         decided_at = now(), decision_note = coalesce(decision_note, 'left out of approve-all')
   where plan_date = p_date and decision = 'pending' and send_status in ('planned', 'would_send') and id = any(p_except);
  get diagnostics n_skip = row_count;
  update public.planned_openers set decision = 'approved', decided_by = auth.uid(), decided_by_name = who, decided_at = now()
   where plan_date = p_date and decision = 'pending' and send_status in ('planned', 'would_send') and not (id = any(p_except));
  get diagnostics n_ok = row_count;
  insert into public.opener_send_events (plan_date, event, reason, actor)
  values (p_date, 'approved_all', format('%s approved, %s left out', n_ok, n_skip), who);
  return jsonb_build_object('approved', n_ok, 'skipped', n_skip);
end $$;

create or replace function public.withdraw_day(p_date date)
returns jsonb language plpgsql security definer set search_path = public as $$
declare who text; n integer;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  select display_name into who from public.team_members where lower(email) = lower(auth.jwt() ->> 'email');
  with w as (
    update public.planned_openers set send_status = 'withdrawn', send_reason = 'withdrawn by ' || coalesce(who, 'the team'),
           send_updated_at = now()
     where plan_date = p_date and send_status in ('planned', 'would_send')
    returning id, plan_date, wpie_owner_id, attempt)
  insert into public.opener_send_events (opener_id, plan_date, wpie_owner_id, attempt, event, reason, actor)
  select id, plan_date, wpie_owner_id, attempt, 'withdrawn', 'withdrawn in the app', who from w;
  get diagnostics n = row_count;
  return jsonb_build_object('withdrawn', n);
end $$;

create or replace function public.skip_reply(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare who text;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  select display_name into who from public.team_members where lower(email) = lower(auth.jwt() ->> 'email');
  update public.reply_drafts set status = 'skipped', decided_by = who, decided_at = now(), updated_at = now()
   where id = p_id and status in ('awaiting_approval', 'would_send', 'no_reply', 'queued', 'dry_sent');
end $$;

alter policy openers_decide on public.planned_openers using (public.is_team()) with check (public.is_team());

-- "How do they hand me a good viable card?" One button: Colin gets the card, a task with the caller's one-line
-- read, a note in the thread, and a ping (text + push) through the hot-alert path.
create or replace function public.handoff_to_colin(p_lead_id uuid, p_note text, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare who text; l public.leads; ph text; tid uuid; first text; key text;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  if nullif(btrim(coalesce(p_note, '')), '') is null then return jsonb_build_object('ok', false, 'reason', 'Say why in one line.'); end if;
  select display_name into who from public.team_members where lower(email) = lower(auth.jwt() ->> 'email');
  select * into l from public.leads where id = p_lead_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such lead'); end if;
  select c.value_normalized into ph from public.contacts c
   where c.lead_id = p_lead_id and c.kind = 'phone' and c.value_normalized ~ '^[0-9]{10}$' and not c.suppressed and c.status = 'ok'
   order by c.created_at limit 1;
  key := 'handoff:' || p_lead_id || ':' || extract(epoch from p_now)::bigint;
  update public.leads set assigned_to = 'colin',
         stage = case when stage in ('walkthrough_booked', 'offer', 'under_contract', 'closed_won', 'dead', 'dnc') then stage else 'colin_call' end,
         next_action = 'Colin: ' || left(btrim(p_note), 80), next_action_at = p_now
   where id = p_lead_id;
  insert into public.tasks (lead_id, due_at, kind, owner, note, source, title, quote, phone10, source_key, created_by)
  values (p_lead_id, p_now, 'call', 'colin', btrim(p_note), 'handoff', 'From ' || coalesce(who, 'the team') || ': worth a look',
          left(btrim(p_note), 500), ph, key, auth.uid())
  returning id into tid;
  insert into public.messages (lead_id, direction, channel, body, sent_at, seen_at)
  values (p_lead_id, 'out', 'note', 'Handed to Colin by ' || coalesce(who, 'the team') || ': ' || btrim(p_note), p_now, p_now);
  first := initcap(split_part(coalesce(l.owner_name, ''), ' ', 1));
  perform public.hot_record(key, p_lead_id, coalesce(ph, ''), first, l.property_address,
          coalesce(who, 'The team') || ' hands off: ' || btrim(p_note), false, p_now);
  return jsonb_build_object('ok', true, 'task_id', tid);
end $$;
revoke all on function public.handoff_to_colin(uuid, text, timestamptz) from public, anon;
grant execute on function public.handoff_to_colin(uuid, text, timestamptz) to authenticated;

-- The call queue logs a dial that reached nobody, and a conversation that ended with no decision.
create or replace function public.log_call(p_lead_id uuid, p_phone text, p_outcome text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare who text; d text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10); l public.leads;
  phones text[]; label text;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  if p_outcome not in ('interested', 'not_now', 'not_interested', 'wrong_number', 'dnc', 'no_answer', 'reached_no_decision') then
    return jsonb_build_object('ok', false, 'reason', 'pick an outcome');
  end if;
  select * into l from public.leads where id = p_lead_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such lead'); end if;
  select display_name into who from public.team_members where lower(email) = lower(auth.jwt() ->> 'email');
  label := case p_outcome when 'interested' then 'Interested' when 'not_now' then 'Not now' when 'not_interested' then 'Not interested'
                          when 'wrong_number' then 'Wrong number' when 'no_answer' then 'No answer'
                          when 'reached_no_decision' then 'Reached, no decision' else 'Do not contact' end;
  insert into public.messages (lead_id, direction, channel, body, from_number, sent_at, seen_at, status)
  values (p_lead_id, 'in', 'call', format('Call (%s)%s: %s%s', coalesce(who, 'team'),
            case when d ~ '^[0-9]{10}$' then ' from ' || d else '' end, label,
            coalesce(E'\n' || nullif(btrim(coalesce(p_note, '')), ''), '')),
          case when d ~ '^[0-9]{10}$' then '+1' || d end, now(), now(), p_outcome);
  update public.leads set call_facts = jsonb_set(call_facts, '{last_call}', jsonb_build_object('value', p_outcome, 'at', now(), 'by', who))
   where id = p_lead_id;

  if p_outcome in ('interested', 'reached_no_decision') then
    update public.leads set stage = case when stage in ('walkthrough_booked', 'offer', 'under_contract', 'closed_won') then stage else 'colin_call' end
     where id = p_lead_id;
  elsif p_outcome = 'no_answer' then
    null;   -- nothing learned: the stage and the next date stand
  elsif p_outcome = 'not_now' then
    update public.leads set stage = 'follow_up', next_action = coalesce(next_action, 'Check back'),
           next_action_at = coalesce(next_action_at, now() + interval '30 days') where id = p_lead_id;
  elsif p_outcome = 'not_interested' then
    update public.leads set stage = 'dead', dead_reason = coalesce(nullif(btrim(coalesce(p_note, '')), ''), 'Not interested (call)') where id = p_lead_id;
  elsif p_outcome = 'wrong_number' then
    if d ~ '^[0-9]{10}$' then
      update public.contacts set status = 'bad' where lead_id = p_lead_id and value_normalized = d;
    end if;
    update public.leads set stage = 'data_fix' where id = p_lead_id;
  else
    select array_agg(distinct c.value_normalized) into phones from public.contacts c
     where c.lead_id = p_lead_id and c.kind = 'phone' and c.value_normalized ~ '^[0-9]{10}$';
    phones := coalesce(phones, '{}');
    if d ~ '^[0-9]{10}$' and not d = any(phones) then phones := array_append(phones, d); end if;
    insert into public.suppressed_phones (phone10, reason, source)
      select distinct p, 'dnc_call', 'app' from unnest(phones) p
    on conflict (phone10) do nothing;
    update public.contacts set suppressed = true, dnc_app = true where value_normalized = any(phones);
    update public.leads set stage = 'dnc' where id = p_lead_id;
  end if;
  return jsonb_build_object('ok', true, 'outcome', p_outcome);
end $$;
