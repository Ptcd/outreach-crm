-- Hot pings come from the texting agent only (Colin 2026-10-26: "i dont want hot texts anymore unless muse is sending
-- them to me, im getting notified for junk"). With agent_runs_texting on, the reply agent's own hot read records
-- nothing, so nothing pings. A mark_card hot writes the alert instead, with the agent's reason as the words, and the
-- same alert path (a text, a push, an email) carries it to Colin.

create or replace function public.hot_record(p_sid text, p_lead_id uuid, p_phone10 text, p_first_name text, p_address text, p_body text,
  p_is_test boolean default false, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if (select agent_runs_texting from public.campaign_control where id = 1) and p_sid not like 'agent:%' then
    return jsonb_build_object('ok', false, 'reason', 'the texting agent decides what is hot');
  end if;
  insert into public.hot_alerts (inbound_sid, lead_id, phone10, first_name, address, body, is_test, created_at)
  values (p_sid, p_lead_id, p_phone10, nullif(btrim(coalesce(p_first_name, '')), ''), nullif(btrim(coalesce(p_address, '')), ''),
          left(coalesce(p_body, ''), 500), coalesce(p_is_test, false), p_now)
  on conflict (inbound_sid) do nothing
  returning hot_alerts.id into v_id;
  if v_id is not null and p_lead_id is not null then
    update public.leads set hot_at = p_now where leads.id = p_lead_id;
  end if;
  return jsonb_build_object('ok', v_id is not null, 'id', v_id);
end $$;

-- mark_card hot: the card moves as before, and the alert is written with the agent's reason
create or replace function public.agent_mark_card(p_lead_id uuid, p_mark text, p_reason text, p_date timestamptz, p_phone text, p_agent text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  l    public.leads;
  who  text := 'Muse (' || coalesce(p_agent, 'agent') || ')';
  d    text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10);
  why  text := nullif(btrim(coalesce(p_reason, '')), '');
  phones text[];
  ph   text;
  res  jsonb;
begin
  select * into l from public.leads where id = p_lead_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card'); end if;
  if l.stage = 'dnc' and p_mark <> 'note' then return jsonb_build_object('ok', false, 'reason', 'this card is do-not-contact: it stays that way'); end if;
  case p_mark
    when 'note' then
      if why is null then return jsonb_build_object('ok', false, 'reason', 'a note needs words'); end if;
      update public.leads set notes = concat_ws(' | ', notes, 'Muse: ' || why), updated_at = now() where id = p_lead_id;
      return jsonb_build_object('ok', true, 'mark', 'note');
    when 'dead' then
      update public.leads set stage = 'dead', dead_reason = coalesce(why, 'not interested (texting agent)') where id = p_lead_id;
      res := public.belt_event(p_lead_id, 'move', jsonb_build_object('belt', 'dead', 'reason', coalesce(why, 'not interested (texting agent)')), who);
    when 'dnc' then
      select array_agg(distinct c.value_normalized) into phones from public.contacts c
       where c.lead_id = p_lead_id and c.kind = 'phone' and c.value_normalized ~ '^[0-9]{10}$';
      phones := coalesce(phones, '{}');
      if d ~ '^[0-9]{10}$' and not d = any(phones) then phones := array_append(phones, d); end if;
      insert into public.suppressed_phones (phone10, reason, source) select distinct p, 'dnc_agent', 'agent' from unnest(phones) p on conflict (phone10) do nothing;
      update public.contacts set suppressed = true, dnc_app = true where value_normalized = any(phones);
      update public.leads set stage = 'dnc', dead_reason = coalesce(why, 'asked not to be contacted') where id = p_lead_id;
      res := public.belt_event(p_lead_id, 'move', jsonb_build_object('belt', 'dnc', 'reason', coalesce(why, 'asked not to be contacted')), who);
    when 'not_now' then
      if p_date is not null then
        if p_date < now() then return jsonb_build_object('ok', false, 'reason', 'the check-back date cannot be in the past'); end if;
        update public.leads set stage = 'follow_up', next_action = 'Check back', next_action_at = p_date where id = p_lead_id;
        res := public.belt_event(p_lead_id, 'named_date', jsonb_strip_nulls(jsonb_build_object('named_date', p_date, 'named_event', why, 'reason', why)), who);
      else
        if why is null then return jsonb_build_object('ok', false, 'reason', 'not now needs a date, or the thing that has to change (reason)'); end if;
        update public.leads set stage = 'follow_up', named_event = left(why, 200), next_action = 'Check back', next_action_at = coalesce(next_action_at, now() + interval '30 days') where id = p_lead_id;
        res := public.belt_event(p_lead_id, 'move', jsonb_build_object('belt', 'not_now_condition', 'reason', why), who);
      end if;
    when 'hot' then
      if why is null then return jsonb_build_object('ok', false, 'reason', 'hot needs the reason in their words: Colin reads it on his phone'); end if;
      update public.leads set stage = case when stage in ('colin_call', 'walk_decision', 'walkthrough_booked', 'offer', 'under_contract', 'closed_won') then stage else 'colin_call' end,
             hot_at = coalesce(hot_at, now()) where id = p_lead_id;
      res := public.belt_event(p_lead_id, 'hot_reply', jsonb_strip_nulls(jsonb_build_object('reason', why, 'key', 'agent_hot:' || p_lead_id::text || ':' || to_char(now(), 'YYYYMMDDHH24MI'))), who);
      select c.value_normalized into ph from public.contacts c where c.lead_id = p_lead_id and c.kind = 'phone'
        and (d = '' or c.value_normalized = d) and c.status = 'ok' order by (c.value_normalized = d) desc, c.created_at limit 1;
      perform public.hot_record('agent:' || p_lead_id::text || ':' || to_char(now(), 'YYYYMMDDHH24MI'), p_lead_id, coalesce(ph, d, ''),
        split_part(l.owner_name, ' ', 1), l.property_address, 'Muse: ' || why, false, now());
    when 'held' then
      if why is null then return jsonb_build_object('ok', false, 'reason', 'held needs the blocker (reason)'); end if;
      update public.leads set named_event = left(why, 200), next_action = 'Waiting on: ' || left(why, 120) where id = p_lead_id;
      res := public.belt_event(p_lead_id, 'move', jsonb_strip_nulls(jsonb_build_object('belt', 'hold_not_now', 'reason', why, 'named_date', p_date)), who);
    when 'wrong_number' then
      if d !~ '^[0-9]{10}$' then return jsonb_build_object('ok', false, 'reason', 'wrong_number needs the phone'); end if;
      update public.contacts set status = 'bad', note = concat_ws('; ', note, 'wrong number (texting agent)') where lead_id = p_lead_id and value_normalized = d;
      if not exists (select 1 from public.contacts c where c.lead_id = p_lead_id and c.kind = 'phone' and c.status = 'ok' and not c.suppressed and not c.dnc_app) then
        update public.leads set stage = 'data_fix' where id = p_lead_id and stage in ('postcard_mailed', 'opener_queued', 'opener_sent', 'reply_received');
      end if;
      res := jsonb_build_object('ok', true, 'phone_marked_bad', d);
    when 'elderly', 'grief' then
      res := public.belt_event(p_lead_id, 'flag', jsonb_strip_nulls(jsonb_build_object(case p_mark when 'elderly' then 'elderly_or_ill' else 'grief' end, true, 'reason', why)), who);
    else
      return jsonb_build_object('ok', false, 'reason', 'mark is one of: dead, dnc, not_now, hot, held, wrong_number, elderly, grief, note');
  end case;
  if why is not null and p_mark <> 'note' then
    update public.leads set notes = concat_ws(' | ', notes, 'Muse (' || p_mark || '): ' || why), updated_at = now() where id = p_lead_id;
  end if;
  return coalesce(res, '{}'::jsonb) || jsonb_build_object('mark', p_mark,
    'card', (select jsonb_build_object('stage', x.stage, 'belt', x.belt, 'next_step_at', x.next_stop_at) from public.leads x where x.id = p_lead_id));
end $$;

revoke all on function public.hot_record(text, uuid, text, text, text, text, boolean, timestamptz),
  public.agent_mark_card(uuid, text, text, timestamptz, text, text) from public, anon, authenticated;
grant execute on function public.hot_record(text, uuid, text, text, text, text, boolean, timestamptz),
  public.agent_mark_card(uuid, text, text, timestamptz, text, text) to service_role;
