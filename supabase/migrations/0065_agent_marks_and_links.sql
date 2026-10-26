-- Muse marks cards and links them (Colin 2026-10-26, Muse: "there's no dedicated mark tool"; "WPIE cards don't have
-- real cross-link fields").
--   agent_mark_card   dead, dnc, not_now (a date or a condition), hot, held (a named blocker), wrong_number,
--                     elderly, grief, and a note. The same belt moves the team's own buttons make.
--   lead_links        same_person, other_property, estate_contact, shared_phone, occupant, co_owner, between two
--                     cards, shown on both cards in agent_card.

create or replace function public.agent_mark_card(p_lead_id uuid, p_mark text, p_reason text, p_date timestamptz, p_phone text, p_agent text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  l    public.leads;
  who  text := 'Muse (' || coalesce(p_agent, 'agent') || ')';
  d    text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10);
  why  text := nullif(btrim(coalesce(p_reason, '')), '');
  phones text[];
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
      update public.leads set stage = case when stage in ('colin_call', 'walk_decision', 'walkthrough_booked', 'offer', 'under_contract', 'closed_won') then stage else 'colin_call' end,
             hot_at = coalesce(hot_at, now()) where id = p_lead_id;
      res := public.belt_event(p_lead_id, 'hot_reply', jsonb_strip_nulls(jsonb_build_object('reason', why, 'key', 'agent_hot:' || p_lead_id::text || ':' || to_char(now(), 'YYYYMMDDHH24MI'))), who);
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

-- ------------------------------------------------------------------ links between cards
create table if not exists public.lead_links (
  id          bigint generated always as identity primary key,
  lead_id     uuid not null references public.leads(id) on delete cascade,
  other_id    uuid not null references public.leads(id) on delete cascade,
  kind        text not null check (kind in ('same_person', 'other_property', 'estate_contact', 'shared_phone', 'occupant', 'co_owner', 'related')),
  note        text,
  added_by    text,
  created_at  timestamptz not null default now(),
  check (lead_id <> other_id),
  unique (lead_id, other_id, kind)
);
create index if not exists lead_links_other_idx on public.lead_links (other_id);
alter table public.lead_links enable row level security;
create policy lead_links_team_read on public.lead_links for select to authenticated using (public.is_team());

create or replace function public.agent_link_cards(p_lead_id uuid, p_other_id uuid, p_kind text, p_note text, p_agent text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if p_lead_id = p_other_id then return jsonb_build_object('ok', false, 'reason', 'a card cannot link to itself'); end if;
  if not exists (select 1 from public.leads where id = p_lead_id) or not exists (select 1 from public.leads where id = p_other_id) then
    return jsonb_build_object('ok', false, 'reason', 'no such card');
  end if;
  insert into public.lead_links (lead_id, other_id, kind, note, added_by) values (p_lead_id, p_other_id, p_kind, nullif(btrim(coalesce(p_note, '')), ''), p_agent)
  on conflict (lead_id, other_id, kind) do update set note = coalesce(excluded.note, lead_links.note);
  return jsonb_build_object('ok', true);
exception when check_violation then
  return jsonb_build_object('ok', false, 'reason', 'kind is one of: same_person, other_property, estate_contact, shared_phone, occupant, co_owner, related');
end $$;

create or replace function public.card_links(p_lead uuid) returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('lead_id', o.id, 'owner_name', o.owner_name, 'address', o.property_address, 'stage', o.stage,
           'kind', x.kind, 'note', x.note) order by x.created_at), '[]'::jsonb)
    from (select k.other_id as oid, k.kind, k.note, k.created_at from public.lead_links k where k.lead_id = p_lead
          union all
          select k.lead_id, k.kind, k.note, k.created_at from public.lead_links k where k.other_id = p_lead) x
    join public.leads o on o.id = x.oid
$$;

-- agent_card: the links, and the phones shared with other cards
create or replace function public.agent_card(p_lead uuid) returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'lead_id', l.id, 'owner_name', l.owner_name, 'owner_type', l.owner_type,
    'address', l.property_address, 'city', l.municipality, 'county', l.county, 'zip', l.property_zip,
    'property', jsonb_build_object('type', l.property_type, 'units', l.units, 'parcel', l.parcel_id, 'lane', l.lane, 'score', l.score),
    'mailing', jsonb_build_object('street', l.mailing_street, 'city', l.mailing_city, 'state', l.mailing_state, 'zip', l.mailing_zip),
    'mailing_state', l.mailing_state,
    'stage', l.stage, 'belt', l.belt, 'next_step', l.next_stop_say, 'next_step_at', l.next_stop_at,
    'named_date', l.named_date, 'named_event', l.named_event,
    'elderly_or_ill', l.elderly_or_ill, 'grief', l.grief, 'notes', l.notes,
    'source', coalesce(l.source, case when l.wpie_owner_id > 0 then 'laptop' end),
    'reasons', l.reasons_to_sell,
    'reason_details', (select jsonb_agg(jsonb_build_object('kind', r.kind, 'detail', r.detail, 'date', r.event_date, 'amount', r.amount, 'source', r.source))
                         from public.prospect_reasons r where r.lead_id = l.id),
    'phones', (select jsonb_agg(jsonb_build_object('phone', c.value_normalized, 'type', c.line_type, 'name', c.person_name,
                      'textable', c.status = 'ok' and not c.dnc_app and not c.suppressed and not c.dnc_vendor and c.dnc_scrub <> 'dnc'
                                  and public.agent_phone_ok(c.value_normalized, c.line_type),
                      'also_on', (select jsonb_agg(jsonb_build_object('lead_id', c2.lead_id, 'owner_name', l2.owner_name, 'address', l2.property_address))
                                    from public.contacts c2 join public.leads l2 on l2.id = c2.lead_id
                                   where c2.value_normalized = c.value_normalized and c2.lead_id <> l.id)))
                 from public.contacts c where c.lead_id = l.id and c.kind = 'phone'),
    'links', public.card_links(l.id),
    'conversation', (select jsonb_agg(x order by x->>'at') from (
        select jsonb_build_object('at', m.sent_at, 'who', case when m.direction = 'out' then 'us' else 'them' end,
                 'phone', case when m.direction = 'out' then m.to_number else m.from_number end,
                 'our_number', case when m.direction = 'out' then m.from_number else m.to_number end, 'text', m.body, 'status', m.status) x
          from public.messages m where m.lead_id = l.id and m.channel = 'sms'
        union all
        select jsonb_build_object('at', t.received_at, 'who', 'them', 'phone', t.from10, 'our_number', t.to_number, 'text', t.body,
                 'stop', t.is_opt_out)
          from public.twilio_inbound t where t.lead_id = l.id
           and not exists (select 1 from public.messages m2 where m2.lead_id = l.id and m2.direction = 'in' and m2.provider_sid = t.sid)) q),
    'calls', (select jsonb_agg(jsonb_build_object('at', m.sent_at, 'outcome', m.status, 'note', m.body) order by m.sent_at)
                from public.messages m where m.lead_id = l.id and m.channel = 'call'),
    'call_facts', l.call_facts,
    'what_we_know', coalesce((select jsonb_object_agg(k, v) from (
                 select distinct on (e.key) e.key as k, e.value as v
                   from public.reply_drafts d, jsonb_each(d.facts) e
                  where d.lead_id = l.id and d.facts is not null and jsonb_typeof(d.facts) = 'object'
                  order by e.key, d.inbound_at desc) f), '{}'::jsonb),
    'replied', exists (select 1 from public.twilio_inbound t where t.lead_id = l.id),
    'waiting', (select jsonb_agg(jsonb_build_object('text_id', p.id, 'step', p.step, 'goes_after', p.scheduled_at, 'status', p.send_status))
                  from public.planned_openers p where p.lead_id = l.id and p.send_status in ('planned', 'would_send', 'sending')))
  from public.leads l where l.id = p_lead
$$;

revoke all on function public.agent_mark_card(uuid, text, text, timestamptz, text, text), public.agent_link_cards(uuid, uuid, text, text, text),
  public.card_links(uuid), public.agent_card(uuid) from public, anon, authenticated;
grant execute on function public.agent_mark_card(uuid, text, text, timestamptz, text, text), public.agent_link_cards(uuid, uuid, text, text, text),
  public.card_links(uuid), public.agent_card(uuid) to service_role;
grant execute on function public.card_links(uuid) to authenticated;
