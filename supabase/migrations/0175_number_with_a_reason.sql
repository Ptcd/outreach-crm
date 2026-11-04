-- 0175: Colin's number carries a reason, and the callback card carries the line (Colin 2026-11-04: "in the email I
-- press a button, then have a page where I set our number, and that makes the callback populate in her calls with info
-- for her to give the number"). package_price keeps the number and the reason (number_note) and now writes the whole
-- callback script onto the promised callback: Rick's framing, a ceiling with a reason attributed to Colin, said once,
-- "not an offer", then the three outcomes. The task's reminder is re-armed so the caller's phone pings before the
-- callback. followup_done closes only the one callback it was given (it used to close every callback on the card).

create or replace function public.callback_script(p_number numeric, p_reason text, p_their_number text default null) returns text
language sql immutable as $$
  select 'Say once, as a ceiling, not an offer: "Colin looked at it. '
      || coalesce(nullif(btrim(p_reason), '') || '. ', '')
      || case when nullif(btrim(coalesce(p_their_number, '')), '') is not null and p_their_number ~ '\d'
              then 'He can''t be at ' || btrim(p_their_number) || '; he''d be closer to '
              else 'He can''t be anywhere near what it would list for; he''d be closer to ' end
      || '$' || to_char(round(p_number), 'FM999,999,999') || '. Does that still work?" Then silence; count to five. '
      || 'If they push: "That''s not an offer, I''m just saying he''d have to be under that." '
      || 'Could work: book Colin''s walk. "I''d need Y": ask "Why doesn''t that work?" then "How''d you get to Y?", write it word for word, '
      || '"Colin will look at that and I''ll get back to you." No: their words in the notes, set a check-back. '
      || 'Never defend the number, explain it, go up, or offer anything in between.'
$$;

create or replace function public.package_price(p_id uuid, p_number numeric, p_note text, p_grade text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d public.deal_packages; script text;
begin
  if not public.is_owner() then raise exception 'only Colin sets the number'; end if;
  select * into d from public.deal_packages where id = p_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such package'); end if;
  if d.status not in ('waiting_value', 'waiting_number', 'counter', 'number_ready', 'go_walk') then return jsonb_build_object('ok', false, 'reason', 'this package is ' || d.status); end if;
  if p_number is null or p_number <= 0 then return jsonb_build_object('ok', false, 'reason', 'the number is in dollars'); end if;
  update public.deal_packages set our_number = p_number, number_note = nullif(btrim(coalesce(p_note, '')), ''), grade = coalesce(nullif(p_grade, ''), grade),
         priced_at = now(), status = 'number_ready', ready_pinged_at = null where id = p_id;
  script := public.callback_script(p_number, p_note, d.their_number);
  update public.tasks set note = 'Callback: Colin''s number is ready, non-firm (package ' || left(p_id::text, 8) || '). ' || script,
         title = 'Callback: give Colin''s number', notified_at = null, updated_at = now()
   where lead_id = d.lead_id and kind = 'callback' and done_at is null;
  update public.leads set notes = concat_ws(' | ', notes, to_char(now() at time zone 'America/Chicago', 'YYYY-MM-DD') || ' Colin set a non-firm number for the callback'
         || coalesce(' (' || nullif(btrim(p_note), '') || ')', ''))
   where id = d.lead_id;
  return jsonb_build_object('ok', true, 'script', script);
end $$;

-- followup_done: a promised callback closes on its own, not every callback on the card
create or replace function public.followup_done(p_task_id uuid, p_outcome text default 'done', p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare t public.tasks; who text; res jsonb;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  select * into t from public.tasks where id = p_task_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such follow-up'); end if;
  if t.done_at is not null then return jsonb_build_object('ok', true, 'already', true); end if;
  if not public.task_is_mine(t) then return jsonb_build_object('ok', false, 'reason', 'not your follow-up'); end if;
  who := coalesce(public.wpie_person()::text, 'team');
  if t.source in ('belt', 'call_list', 'after_stop') then
    res := public.belt_stop_done(t.id, coalesce(nullif(p_outcome, 'done'), 'reached'), p_note, null);
    return coalesce(res, '{}'::jsonb) || jsonb_build_object('ok', true, 'task_id', t.id, 'via', 'belt');
  end if;
  update public.tasks set done_at = now(), note = concat_ws(' | ', note, nullif(btrim(p_note), '')), updated_at = now() where id = t.id;
  if t.lead_id is not null and nullif(btrim(p_note), '') is not null then
    insert into public.messages (lead_id, direction, channel, body, status, created_by, sent_at)
    values (t.lead_id, 'out', 'note', case when t.kind = 'callback' then 'Callback done (' else 'Follow-up done (' end || initcap(who) || '): ' || btrim(p_note), null, auth.uid(), now());
  end if;
  return jsonb_build_object('ok', true, 'task_id', t.id, 'via', case when t.kind = 'callback' then 'callback' else 'plain' end);
end $$;
