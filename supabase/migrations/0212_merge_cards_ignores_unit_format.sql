-- 0212: merge_cards treats "#3E", "Unit 3E" and "Apt 3E" as one unit (Muse desk post 173, 2026-11-09: the Lewis cards on
-- N Prospect Ave, one written "#3E" and one ", Unit 3E", refused as different properties). addr_key keeps the unit
-- tokens, so the two keys differed only by the word UNIT. The same-property test now compares the address key with the
-- unit designator words removed (UNIT, APT, STE, SUITE, NO, NUMBER), so the unit itself (3E) must still agree.
-- agent_merge_cards is otherwise 0211.

create or replace function public.addr_key_unitless(p text) returns text language sql immutable as $$
  select nullif(btrim(regexp_replace(regexp_replace(coalesce(public.addr_key(p), ''), '\m(UNIT|APT|STE|SUITE|NO|NUMBER)\M', '', 'g'), '\s+', ' ', 'g')), '')
$$;

create or replace function public.agent_merge_cards(p_keep_lead_id uuid, p_drop_lead_id uuid, p_why text, p_agent text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  who  text := 'Muse (' || coalesce(p_agent, 'agent') || ')';
  why  text := nullif(btrim(coalesce(p_why, '')), '');
  k    public.leads;
  d    public.leads;
  same_property boolean;
  phones_moved integer := 0;
  people_moved integer := 0;
  tasks_closed integer := 0;
  made_dnc boolean := false;
begin
  if why is null then return jsonb_build_object('ok', false, 'reason', 'say why these are one property (reason)'); end if;
  if p_keep_lead_id = p_drop_lead_id then return jsonb_build_object('ok', false, 'reason', 'keep and drop are the same card'); end if;
  select * into k from public.leads where id = p_keep_lead_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card (keep)'); end if;
  select * into d from public.leads where id = p_drop_lead_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card (drop)'); end if;
  same_property := (k.parcel_id is not null and d.parcel_id is not null and k.county is not distinct from d.county and k.parcel_id = d.parcel_id)
                or (public.addr_key_unitless(public.addr_main(k.property_address)) = public.addr_key_unitless(public.addr_main(d.property_address))
                    and coalesce(lower(k.municipality), '') = coalesce(lower(d.municipality), ''));
  if not same_property then
    return jsonb_build_object('ok', false, 'reason', 'not the same property (parcel or address and municipality differ; a unit must agree too): link_cards if they are related, merge nothing');
  end if;
  if d.stage in ('under_contract', 'closed_won', 'offer', 'walkthrough_booked', 'handoff', 'colin_call', 'walk_decision') then
    return jsonb_build_object('ok', false, 'reason', 'the duplicate is in a deal (' || d.stage::text || '): keep it, close the other one instead, or ask');
  end if;
  if exists (select 1 from public.messages m where m.lead_id = d.id and m.channel = 'sms' and m.provider_sid is not null)
     or exists (select 1 from public.twilio_inbound ti where ti.lead_id = d.id)
     or exists (select 1 from public.tasks t where t.lead_id = d.id and t.done_at is null and t.kind = 'callback') then
    return jsonb_build_object('ok', false, 'reason', 'the duplicate has a texting thread or a promised callback: link_cards (same_person) and keep both, a merge would cut the conversation off');
  end if;
  -- a stop on the duplicate is a stop on the property
  if d.stage = 'dnc' and k.stage <> 'dnc' then
    perform public.belt_event(k.id, 'move', jsonb_build_object('belt', 'dnc', 'reason', 'do-not-contact on duplicate card ' || d.id::text), who);
    update public.leads set stage = 'dnc' where id = k.id and stage <> 'dnc';
    made_dnc := true;
  end if;
  -- people the kept card does not have (before the phones: contacts_person links a moved phone to a person already on the card by name)
  insert into public.interests (lead_id, person_id, role, status, status_reason, status_at, notes, source, created_at)
  select k.id, i.person_id, i.role, i.status, i.status_reason, i.status_at, i.notes, coalesce(i.source, 'merged from duplicate card'), now()
    from public.interests i where i.lead_id = d.id and not exists (select 1 from public.interests j where j.lead_id = k.id and j.person_id = i.person_id);
  get diagnostics people_moved = row_count;
  -- phones and emails the kept card does not have
  update public.contacts c set lead_id = k.id, updated_at = now()
   where c.lead_id = d.id
     and not exists (select 1 from public.contacts c2 where c2.lead_id = k.id and coalesce(c2.value_normalized, c2.value) = coalesce(c.value_normalized, c.value));
  get diagnostics phones_moved = row_count;
  -- reasons and notes
  update public.leads set
         reasons_to_sell = coalesce((select array_agg(distinct r) from unnest(coalesce(k.reasons_to_sell, '{}') || coalesce(d.reasons_to_sell, '{}')) r), '{}'),
         notes = concat_ws(' | ', notes, 'Merged from duplicate card ' || d.id::text || ' (' || coalesce(d.owner_name, '') || '): ' || left(coalesce(d.notes, ''), 1500)),
         elderly_or_ill = coalesce(elderly_or_ill, false) or coalesce(d.elderly_or_ill, false),
         grief = coalesce(grief, false) or coalesce(d.grief, false),
         updated_at = now()
   where id = k.id;
  insert into public.prospect_reasons (lead_id, kind, detail, event_date, amount, source)
  select k.id, r.kind, r.detail, r.event_date, r.amount, r.source from public.prospect_reasons r
   where r.lead_id = d.id and not exists (select 1 from public.prospect_reasons q where q.lead_id = k.id and q.kind = r.kind and q.detail is not distinct from r.detail);
  insert into public.lead_links (lead_id, other_id, kind, note, added_by) values (k.id, d.id, 'same_person', 'duplicate card merged in', who)
  on conflict (lead_id, other_id, kind) do nothing;
  -- the duplicate closes, its open tasks with it
  perform set_config('wpie.task_outcome', '1', true);
  update public.tasks set done_at = now(), note = concat_ws(' | ', note, 'closed: duplicate card merged into ' || k.id::text || ' by ' || who), updated_at = now()
   where lead_id = d.id and done_at is null;
  get diagnostics tasks_closed = row_count;
  perform set_config('wpie.task_outcome', '', true);
  if d.stage <> 'dnc' then
    update public.leads set stage = 'dead', dead_reason = 'duplicate of card ' || k.id::text || ' (' || why || ')', updated_at = now() where id = d.id;
    perform public.belt_event(d.id, 'move', jsonb_build_object('belt', 'dead', 'reason', 'duplicate of card ' || k.id::text), who);
  end if;
  insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
  values (k.id, 'cards_merged', k.belt, k.belt, k.belt_step, jsonb_build_object('duplicate', d.id, 'phones_moved', phones_moved, 'people_moved', people_moved, 'tasks_closed', tasks_closed, 'made_dnc', made_dnc, 'why', why), now(), who);
  insert into public.messages (lead_id, direction, channel, body, status, sent_at)
  values (k.id, 'out', 'note', 'Duplicate card merged in (' || who || '): ' || phones_moved || ' phone(s), ' || people_moved || ' person record(s). ' || why, null, now());
  return jsonb_build_object('ok', true, 'kept', k.id, 'closed', d.id, 'phones_moved', phones_moved, 'people_moved', people_moved, 'tasks_closed', tasks_closed, 'made_dnc', made_dnc);
end $$;
revoke all on function public.agent_merge_cards(uuid, uuid, text, text) from public, anon, authenticated;
grant execute on function public.agent_merge_cards(uuid, uuid, text, text) to service_role;
