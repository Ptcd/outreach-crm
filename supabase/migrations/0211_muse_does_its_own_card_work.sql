-- 0211: Muse does its own card work (Colin 2026-11-09: "i dont want to have to approve posts, that defeats the purpose,
-- how do we remove me in the loop" ... "both"). Until now Muse posted five kinds of request to the desk and waited:
-- card owner assignments, call tasks for dated sheriff sales, stale task closures, duplicate person records and
-- duplicate cards. Each becomes an agent function with the rule the desk applied written into it, so the desk carries
-- only real questions. Every function says why it refused, in words, and writes a belt_events row for the card's history.
--
--   agent_reassign_card   Thalia or Adil (Tyler) only; the card's open calls go with it; a reason is required.
--   agent_add_call_task   a dated sheriff sale is callable only 14 or more days out (CLAUDE.md); the card needs a caller
--                         and a dialable phone; a card Muse itself held (belt hold_not_now) loses the hold's date, since
--                         the Power hour queue hides a card until that date; a seller's own date is never overridden;
--                         one open list task per card.
--   agent_close_task      a caller's own call-list task, never the belt's stop and never a callback the seller was
--                         promised while the card is live; allowed on a closed card, a card Muse holds, or a duplicate.
--   agent_merge_people    two records for one person on one card: the stricter status wins (deceased, do-not-contact,
--                         not the contact are never lost), phones move to the kept record, the dropped record goes
--                         only if it is on no other card.
--   agent_merge_cards     two cards for one property: same parcel or same address, and the duplicate has no texting
--                         thread, no deal and no promised callback (else link_cards); phones, people, notes and reasons
--                         move; a do-not-contact on the duplicate makes the kept card do-not-contact too; the duplicate
--                         is closed as a duplicate and its open tasks with it.

-- ---------------------------------------------------------------------------------------------------------------------
create or replace function public.agent_reassign_card(p_lead_id uuid, p_person text, p_why text, p_agent text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  l    public.leads;
  who  text := 'Muse (' || coalesce(p_agent, 'agent') || ')';
  why  text := nullif(btrim(coalesce(p_why, '')), '');
  to_p public.team_person;
  was  public.team_person;
  n    integer;
begin
  if lower(coalesce(p_person, '')) in ('tyler') then p_person := 'adil'; end if;
  if lower(coalesce(p_person, '')) not in ('thalia', 'adil') then
    return jsonb_build_object('ok', false, 'reason', 'a card belongs to Thalia or Adil (Tyler is adil in the app); Colin''s cards are not reassigned from here');
  end if;
  to_p := lower(p_person)::public.team_person;
  if why is null then return jsonb_build_object('ok', false, 'reason', 'say why the card moves (reason)'); end if;
  select * into l from public.leads where id = p_lead_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card'); end if;
  was := l.locked_to;
  if was is not distinct from to_p then return jsonb_build_object('ok', true, 'already', true, 'owner', to_p); end if;
  update public.leads set locked_to = to_p, locked_at = now(),
         assigned_to = case when assigned_to in ('thalia', 'adil') or assigned_to is null then to_p else assigned_to end,
         human_takeover_assigned_to = case when human_takeover_assigned_to in ('thalia', 'adil') then to_p else human_takeover_assigned_to end,
         updated_at = now()
   where id = p_lead_id;
  -- the card's open calls and callbacks go with it (Colin's own stay his), as card_reassign does
  update public.tasks set owner = to_p, updated_at = now(), notified_at = null
   where lead_id = p_lead_id and done_at is null and owner in ('thalia', 'adil') and owner <> to_p;
  get diagnostics n = row_count;
  insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
  values (p_lead_id, 'reassigned', l.belt, l.belt, l.belt_step, jsonb_build_object('from', was, 'to', to_p, 'why', why, 'tasks_moved', n), now(), who);
  insert into public.messages (lead_id, direction, channel, body, status, sent_at)
  values (p_lead_id, 'out', 'note', 'Card moved to ' || initcap(to_p::text) || coalesce(' from ' || initcap(was::text), '') || ' (' || who || '): ' || why, null, now());
  return jsonb_build_object('ok', true, 'from', was, 'to', to_p, 'tasks_moved', n);
end $$;
revoke all on function public.agent_reassign_card(uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.agent_reassign_card(uuid, text, text, text) to service_role;

-- ---------------------------------------------------------------------------------------------------------------------
create or replace function public.agent_add_call_task(p_lead_id uuid, p_sale_date date, p_why text, p_rank integer, p_owner text, p_agent text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  l      public.leads;
  who    text := 'Muse (' || coalesce(p_agent, 'agent') || ')';
  why    text := nullif(btrim(coalesce(p_why, '')), '');
  owner  public.team_person;
  tid    uuid;
  due    timestamptz;
  ttl    text;
  nt     text;
  today  date := (now() at time zone 'America/Chicago')::date;
  last_day date;
  cleared boolean := false;
  existing uuid;
begin
  if why is null then return jsonb_build_object('ok', false, 'reason', 'say why the caller should dial this card (reason)'); end if;
  select * into l from public.leads where id = p_lead_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card'); end if;
  if l.stage in ('dnc', 'dead', 'closed_no_contact', 'closed_won', 'under_contract', 'offer', 'walkthrough_booked') then
    return jsonb_build_object('ok', false, 'reason', 'the card is ' || l.stage::text || ': no call task on it');
  end if;
  -- the 14-day rule (CLAUDE.md): a sheriff sale inside two weeks is not a lead; nobody dials it
  if p_sale_date is not null and p_sale_date < today + 14 then
    return jsonb_build_object('ok', false, 'reason', 'sheriff sale ' || p_sale_date::text || ' is inside the 14-day window (today ' || today::text || '): not callable, do not spend time on it');
  end if;
  -- whose task: the card's caller; a card with no caller takes the owner you name and is locked to them
  if lower(coalesce(p_owner, '')) = 'tyler' then p_owner := 'adil'; end if;
  if l.locked_to in ('thalia', 'adil') then
    if p_owner is not null and lower(p_owner) <> l.locked_to::text then
      return jsonb_build_object('ok', false, 'reason', 'the card is ' || initcap(l.locked_to::text) || '''s: a task goes to the card''s caller (reassign_card first if it should move)');
    end if;
    owner := l.locked_to;
  elsif lower(coalesce(p_owner, '')) in ('thalia', 'adil') then
    owner := lower(p_owner)::public.team_person;
    perform public.lock_card_to(p_lead_id, owner, 'call task by ' || who);
  else
    return jsonb_build_object('ok', false, 'reason', 'the card has no caller: pass owner (thalia or adil) or reassign_card first');
  end if;
  -- what the Power hour queue would hide anyway
  if coalesce(l.elderly_or_ill, false) or coalesce(l.grief, false) then
    return jsonb_build_object('ok', false, 'reason', 'the card is marked ' || case when coalesce(l.elderly_or_ill, false) then 'elderly or ill' else 'grief' end || ': the queue never dials it; a person decides');
  end if;
  if l.human_takeover_at is not null then
    return jsonb_build_object('ok', false, 'reason', 'a caller took this thread (' || coalesce(l.human_takeover_by, 'a caller') || '): the queue shows only the belt''s own call for it');
  end if;
  if not exists (select 1 from public.contacts c where c.lead_id = p_lead_id and c.kind = 'phone' and c.status = 'ok' and c.value_normalized ~ '^[0-9]{10}$'
                   and not c.suppressed and not coalesce(c.dnc_app, false) and not coalesce(c.dnc_vendor, false) and coalesce(c.dnc_scrub, '') <> 'dnc'
                   and not exists (select 1 from public.suppressed_phones s where s.phone10 = c.value_normalized)) then
    return jsonb_build_object('ok', false, 'reason', 'no dialable phone on the card: load a confirmed number first (add_prospects), the queue would never show this task');
  end if;
  -- a date on the card: Muse's own hold loses its date (the hold, its reason and the belt stay); anyone else's date stands
  if l.named_date is not null and l.named_date > now() then
    if l.belt = 'hold_not_now' then
      update public.leads set named_date = null, updated_at = now() where id = p_lead_id;
      insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
      values (p_lead_id, 'named_date_cleared', l.belt, l.belt, l.belt_step,
              jsonb_build_object('was', l.named_date, 'reason', 'a call task on a held card: the queue hides a card until its date (' || why || ')'), now(), who);
      cleared := true;
    else
      return jsonb_build_object('ok', false, 'reason', 'the card has a date set by its belt ' || coalesce(l.belt, 'none') || ' (' || coalesce(l.named_event, 'no words') || '): not before ' || to_char(l.named_date at time zone 'America/Chicago', 'Mon DD') || '; that is the seller''s or Colin''s, not a hold of yours');
    end if;
  end if;
  -- one open list task per card
  select t.id into existing from public.tasks t where t.lead_id = p_lead_id and t.done_at is null and t.kind = 'call'
     and coalesce(t.source, '') in ('power_hour', 'power_hour_reserve', 'power_hour_after') order by t.due_at limit 1;
  if existing is not null then
    return jsonb_build_object('ok', true, 'already', true, 'task_id', existing, 'owner', owner, 'hold_date_cleared', cleared);
  end if;
  due := case when p_rank is not null then (today::timestamp + interval '12 hours') at time zone 'America/Chicago' + make_interval(mins => greatest(p_rank, 0)) else now() end;
  if p_sale_date is not null then
    last_day := p_sale_date - 14;
    ttl := 'Sheriff sale ' || to_char(p_sale_date, 'Mon DD') || ': last call day ' || to_char(last_day, 'Mon DD');
    nt := who || ' ' || today::text || ': ' || why || ' Sheriff sale ' || p_sale_date::text || '. Under the 14-day rule the last day to call is ' || last_day::text || '; after that do not dial, the sale is too close to do a deal.';
  else
    ttl := left(why, 80);
    nt := who || ' ' || today::text || ': ' || why;
  end if;
  if p_rank is not null then nt := nt || ' call list (#' || p_rank::text || ')'; end if;
  nt := nt || ' A logged call closes this task.';
  insert into public.tasks (lead_id, due_at, kind, owner, note, source, title, source_key, created_at, updated_at)
  values (p_lead_id, due, 'call', owner, left(nt, 1500), 'power_hour', ttl, 'agent:' || coalesce(p_agent, 'agent') || ':' || p_lead_id::text || ':' || today::text, now(), now())
  returning id into tid;
  insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
  values (p_lead_id, 'call_task_added', l.belt, l.belt, l.belt_step, jsonb_build_object('task_id', tid, 'owner', owner, 'sale_date', p_sale_date, 'rank', p_rank, 'why', why), now(), who);
  return jsonb_build_object('ok', true, 'task_id', tid, 'owner', owner, 'due_at', due, 'title', ttl, 'hold_date_cleared', cleared);
end $$;
revoke all on function public.agent_add_call_task(uuid, date, text, integer, text, text) from public, anon, authenticated;
grant execute on function public.agent_add_call_task(uuid, date, text, integer, text, text) to service_role;

-- ---------------------------------------------------------------------------------------------------------------------
create or replace function public.agent_close_task(p_task_id uuid, p_why text, p_agent text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  t    public.tasks;
  l    public.leads;
  who  text := 'Muse (' || coalesce(p_agent, 'agent') || ')';
  why  text := nullif(btrim(coalesce(p_why, '')), '');
  dup  boolean;
  closed_card boolean;
  held boolean;
begin
  if why is null then return jsonb_build_object('ok', false, 'reason', 'say why the task closes (reason)'); end if;
  select * into t from public.tasks where id = p_task_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such task'); end if;
  if t.done_at is not null then return jsonb_build_object('ok', true, 'already', true); end if;
  if t.owner not in ('thalia', 'adil') then return jsonb_build_object('ok', false, 'reason', 'not a caller''s task (owner ' || t.owner::text || '): Colin''s tasks are his'); end if;
  if coalesce(t.source, '') = 'belt' then return jsonb_build_object('ok', false, 'reason', 'the belt''s own stop: a logged call or the caller closes it, the belt then moves on'); end if;
  if t.lead_id is not null then select * into l from public.leads where id = t.lead_id; end if;
  closed_card := l.id is not null and l.stage in ('dead', 'dnc', 'closed_no_contact', 'closed_won', 'under_contract');
  held := l.id is not null and coalesce(l.belt, '') = 'hold_not_now';
  dup := t.kind = 'call' and exists (select 1 from public.tasks o where o.lead_id = t.lead_id and o.id <> t.id and o.done_at is null and o.kind = 'call' and o.owner = t.owner and coalesce(o.source, '') <> 'belt');
  if t.kind = 'callback' and not closed_card then
    return jsonb_build_object('ok', false, 'reason', 'a callback the seller was promised: only the caller closes it while the card is live');
  end if;
  if not coalesce(closed_card or held or dup, false) then
    return jsonb_build_object('ok', false, 'reason', 'the card is live (' || coalesce(l.stage::text, 'no card') || ', belt ' || coalesce(l.belt, 'none') || ') and this is its only call task: a stale task on a live card is the caller''s to close, or hold the card first (mark_card held)');
  end if;
  perform set_config('wpie.task_outcome', '1', true);   -- a closure is not a stop done: the belt does not move
  update public.tasks set done_at = now(), note = concat_ws(' | ', note, 'closed by ' || who || ': ' || why), updated_at = now() where id = t.id;
  perform set_config('wpie.task_outcome', '', true);
  if t.lead_id is not null then
    insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
    values (t.lead_id, 'task_closed', l.belt, l.belt, l.belt_step, jsonb_build_object('task_id', t.id, 'kind', t.kind, 'source', t.source, 'why', why,
            'because', case when closed_card then 'card ' || l.stage::text when dup then 'duplicate task' else 'card held' end), now(), who);
  end if;
  return jsonb_build_object('ok', true, 'task_id', t.id, 'because', case when closed_card then 'card ' || l.stage::text when dup then 'duplicate task' else 'card held' end);
end $$;
revoke all on function public.agent_close_task(uuid, text, text) from public, anon, authenticated;
grant execute on function public.agent_close_task(uuid, text, text) to service_role;

-- ---------------------------------------------------------------------------------------------------------------------
create or replace function public.agent_merge_people(p_lead_id uuid, p_keep_interest_id uuid, p_drop_interest_id uuid, p_why text, p_agent text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  who  text := 'Muse (' || coalesce(p_agent, 'agent') || ')';
  why  text := nullif(btrim(coalesce(p_why, '')), '');
  ki   public.interests;
  di   public.interests;
  kp   public.people;
  dp   public.people;
  elsewhere integer;
  moved integer;
  strict_status text;
begin
  if why is null then return jsonb_build_object('ok', false, 'reason', 'say why these are one person (reason)'); end if;
  if p_keep_interest_id = p_drop_interest_id then return jsonb_build_object('ok', false, 'reason', 'keep and drop are the same record'); end if;
  select * into ki from public.interests where id = p_keep_interest_id and lead_id = p_lead_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'keep_interest_id is not a person on this card'); end if;
  select * into di from public.interests where id = p_drop_interest_id and lead_id = p_lead_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'drop_interest_id is not a person on this card'); end if;
  if ki.person_id = di.person_id then return jsonb_build_object('ok', false, 'reason', 'both records already point at one person'); end if;
  select * into kp from public.people where id = ki.person_id for update;
  select * into dp from public.people where id = di.person_id for update;
  select count(*) into elsewhere from public.interests i where i.person_id = dp.id and i.lead_id <> p_lead_id;
  if elsewhere > 0 then
    return jsonb_build_object('ok', false, 'reason', 'the record you want dropped (' || dp.name || ') is on ' || elsewhere || ' other card(s): merge it there too, or leave both and link the cards');
  end if;
  -- the stricter status wins: a death, a do-not-contact or a not-the-contact is never lost in a merge
  strict_status := case when 'deceased' in (kp.status, dp.status) then 'deceased' when 'do_not_contact' in (kp.status, dp.status) then 'do_not_contact' else kp.status end;
  if strict_status <> kp.status then
    update public.people set status = strict_status, status_reason = coalesce(dp.status_reason, kp.status_reason), status_at = now(), updated_at = now() where id = kp.id;
  end if;
  if ki.status = 'active' and di.status <> 'active' then
    update public.interests set status = di.status, status_reason = di.status_reason, status_at = now() where id = ki.id;
  end if;
  update public.people set notes = concat_ws(' | ', notes, nullif(dp.notes, ''), 'also recorded as ' || dp.name || ' (merged by ' || who || ')'),
         mailing_street = coalesce(mailing_street, dp.mailing_street), mailing_city = coalesce(mailing_city, dp.mailing_city),
         mailing_state = coalesce(mailing_state, dp.mailing_state), mailing_zip = coalesce(mailing_zip, dp.mailing_zip), updated_at = now()
   where id = kp.id;
  -- the phones and emails move to the kept record (person_phones is a view over contacts)
  update public.contacts set person_id = kp.id, updated_at = now() where person_id = dp.id;
  get diagnostics moved = row_count;
  delete from public.interests where id = di.id;
  delete from public.people where id = dp.id and not exists (select 1 from public.interests i where i.person_id = dp.id) and not exists (select 1 from public.contacts c where c.person_id = dp.id);
  insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
  select p_lead_id, 'people_merged', l.belt, l.belt, l.belt_step,
         jsonb_build_object('kept', jsonb_build_object('person_id', kp.id, 'name', kp.name), 'dropped', jsonb_build_object('person_id', dp.id, 'name', dp.name), 'contacts_moved', moved, 'why', why), now(), who
    from public.leads l where l.id = p_lead_id;
  insert into public.messages (lead_id, direction, channel, body, status, sent_at)
  values (p_lead_id, 'out', 'note', 'Two records merged into one person: ' || kp.name || ' (kept) and ' || dp.name || ' (' || who || '): ' || why, null, now());
  return jsonb_build_object('ok', true, 'kept_person_id', kp.id, 'kept_name', kp.name, 'dropped_name', dp.name, 'contacts_moved', moved, 'status', strict_status);
end $$;
revoke all on function public.agent_merge_people(uuid, uuid, uuid, text, text) from public, anon, authenticated;
grant execute on function public.agent_merge_people(uuid, uuid, uuid, text, text) to service_role;

-- ---------------------------------------------------------------------------------------------------------------------
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
                or (public.addr_key(public.addr_main(k.property_address)) = public.addr_key(public.addr_main(d.property_address))
                    and coalesce(lower(k.municipality), '') = coalesce(lower(d.municipality), ''));
  if not same_property then
    return jsonb_build_object('ok', false, 'reason', 'not the same property (parcel or address and municipality differ): link_cards if they are related, merge nothing');
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
