-- "Not now" takes the date they gave (Codex's day-in-the-life walk, 2026-10-22, step 5: Log this call had no
-- date field, so a two-weeks-out "not now" got the generic 30 days). log_call gains p_when: for not_now it is
-- the day they named, written to leads.named_date BEFORE the call row lands, so the belt's call_logged
-- hook (0031) puts the card on "Not now, with a date" with that date, never before it. No date: 30 days
-- and the condition belt, as before. The 4-argument log_call is dropped so the RPC name stays unambiguous.
drop function if exists public.log_call(uuid, text, text, text);

create or replace function public.log_call(p_lead_id uuid, p_phone text, p_outcome text, p_note text default null,
  p_when timestamptz default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare who text; d text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10); l public.leads;
  phones text[]; label text;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  if p_outcome not in ('interested', 'not_now', 'not_interested', 'wrong_number', 'dnc', 'no_answer', 'reached_no_decision') then
    return jsonb_build_object('ok', false, 'reason', 'pick an outcome');
  end if;
  if p_outcome = 'not_now' and p_when is not null and p_when <= now() then
    return jsonb_build_object('ok', false, 'reason', 'the check-back date has to be ahead of today');
  end if;
  select * into l from public.leads where id = p_lead_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such lead'); end if;
  select display_name into who from public.team_members where lower(email) = lower(auth.jwt() ->> 'email');
  label := case p_outcome when 'interested' then 'Interested' when 'not_now' then 'Not now' when 'not_interested' then 'Not interested'
                          when 'wrong_number' then 'Wrong number' when 'no_answer' then 'No answer'
                          when 'reached_no_decision' then 'Reached, no decision' else 'Do not contact' end;
  if p_outcome = 'not_now' and p_when is not null then
    -- the date they named, on the card before the call row fires the belt
    update public.leads set named_date = p_when where id = p_lead_id;
    label := label || ' until ' || to_char(p_when at time zone 'America/Chicago', 'Mon DD');
  end if;
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
           next_action_at = coalesce(p_when, next_action_at, now() + interval '30 days') where id = p_lead_id;
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
  return jsonb_build_object('ok', true, 'outcome', p_outcome, 'until', p_when);
end $$;
revoke all on function public.log_call(uuid, text, text, text, timestamptz) from public, anon;
grant execute on function public.log_call(uuid, text, text, text, timestamptz) to authenticated;
