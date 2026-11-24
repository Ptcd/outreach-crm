-- 0318: an agent can take back a "not the contact" mark (mark_card right_person).
--
-- Colin 2026-11-24, "Make it so grok can do this", on 8408 S Tuckaway Shores Dr: someone on an old number said Olivia
-- Wyne was her husband's ex-wife and not the owner, an agent marked Olivia wrong_person (interests.status
-- 'not_the_contact'), a later trace showed she is the owner and lives there, and no tool could undo the mark, so the
-- texting agent could not text her current cell. right_person puts that one person back to active on that one card.
--
-- It undoes only this card's marks (not_the_contact, closed). Deceased and do-not-contact are the record's word or the
-- seller's and follow the person onto every card: an agent never takes those back, they go on the desk. A card a seller
-- signed is Colin's. When the reopened person has a usable phone, card_after_person_change brings a card that died for
-- no contact back, and a card parked in data_fix for "no live person" goes back to where texting picks it up.

create or replace function public.agent_mark_person(p_lead_id uuid, p_mark text, p_interest_id uuid, p_phone text, p_reason text, p_agent text)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare
  who  text := 'Muse (' || coalesce(p_agent, 'agent') || ')';
  d    text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10);
  why  text := nullif(btrim(coalesce(p_reason, '')), '');
  iv   public.interests;
  pe   public.people;
  l    public.leads;
  n    integer;
  r    record;
  cards jsonb := '[]'::jsonb;
  res  text;
  owner_side boolean;
  live boolean;
begin
  if p_mark not in ('deceased', 'dnc', 'wrong_person', 'right_person') then
    return jsonb_build_object('ok', false, 'reason', 'a person mark is deceased, dnc, wrong_person or right_person');
  end if;
  if p_interest_id is not null then
    select * into iv from public.interests i where i.id = p_interest_id and i.lead_id = p_lead_id;
    if not found then return jsonb_build_object('ok', false, 'reason', 'no such person on this card (interest_id)'); end if;
  elsif d ~ '^[0-9]{10}$' then
    select count(distinct c.person_id) into n from public.contacts c where c.lead_id = p_lead_id and c.value_normalized = d and c.person_id is not null;
    if n = 0 then return jsonb_build_object('ok', false, 'reason', 'that phone is not on this card'); end if;
    if n > 1 then
      return jsonb_build_object('ok', false, 'reason', 'that phone is shared by ' || (select string_agg(distinct pe2.name, ' and ') from public.contacts c
        join public.people pe2 on pe2.id = c.person_id where c.lead_id = p_lead_id and c.value_normalized = d) || ': say which (interest_id)');
    end if;
    select i.* into iv from public.interests i where i.lead_id = p_lead_id
       and i.person_id = (select c.person_id from public.contacts c where c.lead_id = p_lead_id and c.value_normalized = d and c.person_id is not null limit 1);
  else
    return jsonb_build_object('ok', false, 'reason', 'which person? pass interest_id or their phone');
  end if;
  select * into pe from public.people where id = iv.person_id;
  owner_side := iv.role in ('owner_of_record', 'co_owner') and pe.kind <> 'entity';

  if p_mark = 'right_person' then
    if why is null or length(why) < 12 then
      return jsonb_build_object('ok', false, 'reason', 'say in reason what shows they are connected after all (the trace, the county record, what they said on a live number)');
    end if;
    select * into l from public.leads where id = p_lead_id;
    if l.locked_to::text = 'colin' then return jsonb_build_object('ok', false, 'reason', 'this card is Colin''s: post it on the desk'); end if;
    if pe.status <> 'active' or iv.status in ('deceased', 'do_not_contact') then
      return jsonb_build_object('ok', false, 'reason', pe.name || ' is marked ' || case when pe.status <> 'active' then pe.status else iv.status end
        || ' (' || coalesce(nullif(coalesce(pe.status_reason, iv.status_reason), ''), 'no reason given')
        || '). That follows the person onto every card and is not taken back from the door: post it on the desk with what shows otherwise.');
    end if;
    if iv.status = 'active' then
      return jsonb_build_object('ok', true, 'mark', p_mark, 'person', pe.name, 'interest_id', iv.id, 'note', 'already active on this card: nothing changed');
    end if;
    update public.interests
       set status = 'active', status_reason = null, status_at = now(),
           notes = concat_ws(E'\n', nullif(notes, ''), to_char(now() at time zone 'America/Chicago', 'YYYY-MM-DD') || ' ' || who
                   || ': reopened (was ' || iv.status || coalesce(': ' || nullif(iv.status_reason, ''), '') || '). ' || left(why, 300))
     where id = iv.id;
    res := public.card_after_person_change(p_lead_id, who);
    live := exists (select 1 from public.contacts c where c.lead_id = p_lead_id and c.person_id = pe.id and c.kind = 'phone'
                      and c.status::text = 'ok' and not c.suppressed and not c.dnc_app and public.phone_person_block(c.value_normalized) is null);
    -- a card parked for "no live person" goes back to where texting and the call list pick it up
    select * into l from public.leads where id = p_lead_id for update;
    if live and l.stage::text = 'data_fix' then
      update public.leads
         set stage = case when exists (select 1 from public.messages m where m.lead_id = p_lead_id and m.direction = 'out' and m.channel = 'sms')
                          then 'follow_up'::public.lead_stage else 'opener_queued'::public.lead_stage end,
             named_event = null, reopened_at = now(), reopened_reason = pe.name || ' is the right person after all'
       where id = p_lead_id;
      res := coalesce(res, 'out of data_fix');
    end if;
    update public.leads set notes_log = concat_ws(' | ', nullif(notes_log, ''), who || ' (right person, ' || pe.name || '): ' || left(why, 300)), updated_at = now()
     where id = p_lead_id;
    select * into l from public.leads where id = p_lead_id;
    return jsonb_build_object('ok', true, 'mark', p_mark, 'person', pe.name, 'person_id', pe.id, 'interest_id', iv.id, 'was', iv.status,
      'has_usable_phone', live, 'cards', jsonb_build_array(jsonb_build_object('lead_id', p_lead_id, 'result', res, 'stage', l.stage)),
      'next', case when live then 'The person is open on this card again. A number that was never theirs is mark_card wrong_number with phone, not wrong_person.'
                   else 'Open again, but no usable phone of theirs is on this card: load one with add_prospects.' end);
  end if;

  if p_mark = 'wrong_person' then
    update public.interests set status = 'not_the_contact', status_reason = coalesce(why, 'not the right person (texting agent)'), status_at = now() where id = iv.id;
  else
    update public.people set status = case p_mark when 'deceased' then 'deceased' else 'do_not_contact' end,
           status_reason = coalesce(why, case p_mark when 'deceased' then 'died' else 'asked not to be contacted' end), status_at = now(), updated_at = now()
     where id = pe.id;
    update public.interests set status = case p_mark when 'deceased' then 'deceased' else 'do_not_contact' end,
           status_reason = coalesce(why, p_mark), status_at = now() where person_id = pe.id;
    if p_mark = 'dnc' and d ~ '^[0-9]{10}$' then
      insert into public.suppressed_phones (phone10, reason, source) values (d, 'dnc_agent', 'agent') on conflict (phone10) do nothing;
      update public.contacts set suppressed = true, dnc_app = true where value_normalized = d;
    end if;
  end if;
  -- an owner who says stop closes the property too (nobody is texted about a house its owner said stop on)
  if p_mark = 'dnc' and owner_side then
    perform public.agent_mark_card(p_lead_id, 'dnc', coalesce(why, pe.name || ' asked not to be contacted'), null, nullif(d, ''), p_agent);
  end if;
  for r in select distinct i.lead_id from public.interests i where i.person_id = pe.id and (p_mark <> 'wrong_person' or i.lead_id = p_lead_id) loop
    res := public.card_after_person_change(r.lead_id, who);
    cards := cards || jsonb_build_object('lead_id', r.lead_id, 'result', res,
      'stage', (select l2.stage from public.leads l2 where l2.id = r.lead_id));
  end loop;
  update public.leads set notes = concat_ws(' | ', notes, 'Muse (' || p_mark || ', ' || pe.name || '): ' || coalesce(why, '')), updated_at = now() where id = p_lead_id;
  return jsonb_build_object('ok', true, 'mark', p_mark, 'person', pe.name, 'person_id', pe.id, 'interest_id', iv.id, 'cards', cards);
end $function$;

revoke all on function public.agent_mark_person(uuid, text, uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.agent_mark_person(uuid, text, uuid, text, text, text) to service_role;
