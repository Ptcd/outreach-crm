-- 0249: a card is its caller's.
--
-- Colin 2026-11-17, on George White's card (432 W Hillcrest St, Thalia's): "why the fuck can Tyler see that card".
-- What happened: at 5:11 PM George called in and Thalia took it and set tomorrow's callback. At 5:22 PM Muse marked the
-- card hot with a comp note. A hot alert went, as every alert about a card did, to every registered phone and every
-- alert email: Tyler's phone is the only caller phone registered. At 5:41 PM Tyler opened the card from the alert and
-- texted George "Can we have a call in 30 minutes" from his own line, into Thalia's thread.
--
-- Colin ruled this on 2026-10-30 (0148): a card locks to the caller who had contact, permanently, "that's Adil's
-- customer". The lock was kept by the Power hour list and by nothing else. From here:
--   * An alert about a card (hot lead, a reply to approve, a new task, a package, an offer number) goes to the card's
--     caller and to the owners, and to nobody else. When that caller is off today the other caller is told. A card with
--     no caller still goes to everyone.
--   * A caller cannot text, dial or take over the thread of a card that is the other caller's. The server refuses and
--     says whose card it is. Two ways it is still theirs to work: the card's caller is off today, or they hold an open
--     task on the card (somebody gave them the work).
--   * The card's caller is leads.locked_to when that is a caller, else leads.assigned_to when that is a caller.
-- Colin and Muse (owners) are never refused. Nothing here touches a seller.

create or replace function public.card_caller(p_lead_id uuid) returns public.team_person
language sql stable security definer set search_path = public as $$
  select case
    when exists (select 1 from public.team_members m where m.person = l.locked_to and m.role = 'caller') then l.locked_to
    when exists (select 1 from public.team_members m where m.person = l.assigned_to and m.role = 'caller') then l.assigned_to
  end
  from public.leads l where l.id = p_lead_id
$$;

-- Null when the person on this login may work the card; otherwise the words that say whose it is.
create or replace function public.card_not_yours(p_lead_id uuid, p_now timestamptz default now()) returns text
language plpgsql stable security definer set search_path = public as $$
declare me public.team_person := public.wpie_person(); cc public.team_person; nm text;
begin
  if coalesce(public.wpie_role()::text, '') <> 'caller' or me is null or p_lead_id is null then return null; end if;
  cc := public.card_caller(p_lead_id);
  if cc is null or cc = me then return null; end if;
  if public.caller_is_off(cc, (p_now at time zone 'America/Chicago')::date) then return null; end if;      -- covering for them today
  if exists (select 1 from public.tasks t where t.lead_id = p_lead_id and t.done_at is null and t.owner = me) then return null; end if;
  select coalesce(nullif(btrim(m.display_name), ''), initcap(cc::text)) into nm from public.team_members m where m.person = cc limit 1;
  nm := coalesce(nm, initcap(cc::text));
  return 'This is ' || nm || '''s card. Only ' || nm || ' or Colin calls or texts it. If the seller reached you, tell ' || nm || '.';
end $$;

-- Who is told about a card: everyone when it has no caller; otherwise the owners, its caller (the other callers who are
-- working when that caller is off today), and any caller holding an open task on it.
create or replace function public.card_tell(p_lead_id uuid, p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare cc public.team_person; today date := (p_now at time zone 'America/Chicago')::date; off_ boolean; people text[];
begin
  if p_lead_id is null then return jsonb_build_object('everyone', true); end if;
  cc := public.card_caller(p_lead_id);
  if cc is null then return jsonb_build_object('everyone', true); end if;
  off_ := public.caller_is_off(cc, today);
  select coalesce(array_agg(distinct x.person), '{}') into people from (
    select m.person::text as person from public.team_members m where m.role = 'owner'
    union all select cc::text where not off_
    union all select m.person::text from public.team_members m
               where off_ and m.role = 'caller' and m.person <> cc and not public.caller_is_off(m.person, today)
    union all select t.owner::text from public.tasks t join public.team_members m on m.person = t.owner and m.role = 'caller'
               where t.lead_id = p_lead_id and t.done_at is null
  ) x where x.person is not null;
  return jsonb_build_object('everyone', false, 'card_caller', cc::text, 'covering', off_, 'people', to_jsonb(people));
end $$;

-- the same, from a reply waiting for approval
create or replace function public.draft_card_tell(p_draft_id uuid, p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public as $$
  select public.card_tell((select d.lead_id from public.reply_drafts d where d.id = p_draft_id), p_now)
$$;

-- every registered phone with whose it is, so an alert can be sent to the right people only
create or replace function public.push_subscriptions_people() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth,
                                               'person', m.person::text, 'role', m.role::text)), '[]'::jsonb)
    from public.push_subscriptions s
    left join auth.users u on u.id = s.user_id
    left join public.team_members m on m.email = lower(u.email)
$$;

revoke all on function public.card_caller(uuid), public.card_not_yours(uuid, timestamptz), public.card_tell(uuid, timestamptz),
  public.draft_card_tell(uuid, timestamptz), public.push_subscriptions_people() from public, anon;
grant execute on function public.card_caller(uuid), public.card_not_yours(uuid, timestamptz) to authenticated, service_role;
grant execute on function public.card_tell(uuid, timestamptz), public.draft_card_tell(uuid, timestamptz), public.push_subscriptions_people() to service_role;

-- The three things a caller does to a seller from a card, each as it stood live on 2026-11-17 with the one check added.

CREATE OR REPLACE FUNCTION public.begin_human_call(p_lead_id uuid, p_phone text, p_source text, p_key text, p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
declare l public.leads; d text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10);
  gate jsonb; who text; person public.team_person; held jsonb; actor text; stale boolean := false; nope text;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  if p_source not in ('app', 'personal') then return jsonb_build_object('ok', false, 'reason', 'unknown call source', 'paused', false); end if;
  if coalesce(p_key, '') !~ '^[A-Za-z0-9_-]{8,100}$' then return jsonb_build_object('ok', false, 'reason', 'bad call key', 'paused', false); end if;

  -- Same first lock as the conveyor worker. Draft locks remain below every lead-state check.
  select * into l from public.leads where id = p_lead_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such lead', 'paused', false); end if;
  select tm.display_name, tm.person into who, person from public.team_members tm
   where lower(tm.email) = lower(auth.jwt() ->> 'email');
  if person is null then return jsonb_build_object('ok', false, 'reason', 'caller is not an active team member', 'paused', false); end if;
  actor := coalesce(who, person::text);
  -- 0249: a card is its caller's. The other caller does not dial it (unless its caller is off today, or they hold a task on it).
  nope := public.card_not_yours(p_lead_id, now());
  if nope is not null then return jsonb_build_object('ok', false, 'reason', nope, 'paused', l.human_takeover_at is not null); end if;

  -- Recheck every mutable authorization fact before recognizing an attempt key.
  if l.stage in ('dnc', 'dead', 'closed_no_contact', 'closed_won') or l.belt in ('dnc', 'dead') then
    return jsonb_build_object('ok', false, 'reason', 'this card is closed or do-not-contact', 'paused', false);
  end if;
  -- Do not trust the caller-supplied p_now for authorization; it exists for deterministic
  -- event timestamps in the existing RPC and must not let a client fast-forward the clock.
  if l.belt = 'not_now_dated' and l.named_date is not null and now() < l.named_date then
    return jsonb_build_object('ok', false, 'reason', 'the seller asked us to wait until the scheduled date',
      'paused', l.human_takeover_at is not null, 'not_before', l.named_date);
  end if;
  if not exists (select 1 from public.contacts c where c.lead_id = p_lead_id and c.kind = 'phone'
      and c.value_normalized = d) then
    return jsonb_build_object('ok', false, 'reason', 'that phone is not on this card', 'paused', l.human_takeover_at is not null);
  end if;
  gate := public.phone_is_blocked(d);
  if coalesce((gate->>'blocked')::boolean, true) then
    return jsonb_build_object('ok', false, 'reason', coalesce(gate->>'reason', 'phone block check failed'), 'paused', l.human_takeover_at is not null);
  end if;

  -- A call placed more than 12 hours ago with no outcome logged no longer blocks the next call (0231): the new call
  -- takes its place and the texts stay paused until an outcome is logged, as before. The earlier of the server clock
  -- and p_now: a client cannot fast-forward past the wait.
  stale := l.human_takeover_at is not null and l.human_takeover_key is distinct from p_key
           and l.human_takeover_at < least(now(), p_now) - interval '12 hours';
  if l.human_takeover_at is not null and not stale then
    if l.assigned_to is distinct from l.human_takeover_assigned_to then
      return jsonb_build_object('ok', false, 'reason', 'the card assignment changed after authorization', 'paused', true);
    end if;
    if l.human_takeover_key is distinct from p_key then
      return jsonb_build_object('ok', false, 'reason', 'another call is waiting for its outcome', 'paused', true);
    end if;
    if l.human_takeover_phone is distinct from d then
      return jsonb_build_object('ok', false, 'reason', 'the active call has a different destination', 'paused', true);
    end if;
    if l.human_takeover_by is distinct from actor then
      return jsonb_build_object('ok', false, 'reason', 'the active call belongs to another caller', 'paused', true);
    end if;
    return jsonb_build_object('ok', true, 'duplicate', true, 'paused', true, 'key', p_key);
  end if;
  if exists (select 1 from public.belt_events e where e.lead_id = p_lead_id
      and e.payload->>'key' = 'human_call:' || p_key) then
    return jsonb_build_object('ok', false, 'duplicate', true,
      'reason', 'that call authorization is no longer active', 'paused', false);
  end if;

  perform 1 from public.reply_drafts r where r.lead_id = p_lead_id and r.kind = 'belt'
    and r.status in ('queued', 'awaiting_approval', 'would_send', 'sending') for update;
  if exists (select 1 from public.reply_drafts r where r.lead_id = p_lead_id and r.kind = 'belt' and r.status = 'sending') then
    return jsonb_build_object('ok', false, 'reason', 'an automated text is already sending; check its result before calling', 'paused', false);
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'status', r.status)), '[]'::jsonb) into held
    from public.reply_drafts r where r.lead_id = p_lead_id and r.kind = 'belt'
      and r.status in ('queued', 'awaiting_approval', 'would_send');
  update public.leads set human_takeover_at = p_now, human_takeover_by = actor,
    human_takeover_phone = d, human_takeover_key = p_key,
    -- texts the abandoned call was already holding stay held with this one
    human_takeover_drafts = case when stale then coalesce(l.human_takeover_drafts, '[]'::jsonb) || held else held end,
    assigned_to = coalesce(assigned_to, person), human_takeover_assigned_to = coalesce(assigned_to, person)
   where id = p_lead_id;
  update public.reply_drafts set status = 'superseded', note = coalesce(note, '') || ' | human call ' || p_key, updated_at = p_now
   where lead_id = p_lead_id and kind = 'belt' and status in ('queued', 'awaiting_approval', 'would_send');
  update public.hot_alerts set called_at = p_now where lead_id = p_lead_id and called_at is null and created_at <= p_now;
  if stale then
    insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
      values (p_lead_id, 'human_call_abandoned', l.belt, l.belt, l.belt_step,
        jsonb_build_object('key', 'human_abandon:' || l.human_takeover_key, 'phone', l.human_takeover_phone, 'by', l.human_takeover_by,
          'started_at', l.human_takeover_at, 'reason', 'no outcome was logged in 12 hours; the next call takes its place'), p_now, actor);
  end if;
  insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
    values (p_lead_id, 'human_call_started', l.belt, l.belt, l.belt_step,
      jsonb_build_object('key', 'human_call:' || p_key, 'source', p_source, 'phone', d), p_now, actor);
  return jsonb_build_object('ok', true, 'duplicate', false, 'paused', true, 'key', p_key);
end $fn$;

CREATE OR REPLACE FUNCTION public.start_card_text(p_lead_id uuid, p_phone text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
declare
  l public.leads;
  p text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10);
  ours text;
  id uuid;
  nope text;
begin
  if not public.is_team() then raise exception 'not on the team'; end if;
  select * into l from public.leads where leads.id = p_lead_id;
  if not found then raise exception 'no such card'; end if;
  if l.stage = 'dnc' then raise exception 'this card is closed (do not contact)'; end if;
  -- 0249: a card is its caller's. George White, 2026-11-17: Tyler texted Thalia's seller from his own line.
  nope := public.card_not_yours(p_lead_id, now());
  if nope is not null then raise exception '%', nope; end if;
  if p !~ '^[2-9][0-9]{9}$' then raise exception 'not a phone number'; end if;
  if not exists (select 1 from public.contacts c where c.lead_id = p_lead_id and c.kind = 'phone'
                  and right(regexp_replace(coalesce(c.value_normalized, c.value), '\D', '', 'g'), 10) = p
                  and not coalesce(c.dnc_app, false) and c.status is distinct from 'bad') then
    raise exception 'that phone is not on this card';
  end if;
  if exists (select 1 from public.suppressed_phones s where s.phone10 = p) then raise exception 'this phone opted out'; end if;
  -- the caller's own line first (0203: Tyler and Thalia text from their own numbers), else our side of the latest text
  -- with this phone, else the latest number we texted the card from
  select c.number into ours from public.caller_numbers c where c.person = public.wpie_person();
  if ours is null then
    select case when m.direction = 'out' then m.from_number else m.to_number end into ours
      from public.messages m
     where m.lead_id = p_lead_id and m.channel = 'sms'
       and right(regexp_replace(coalesce(case when m.direction = 'out' then m.to_number else m.from_number end, ''), '\D', '', 'g'), 10) = p
     order by m.sent_at desc limit 1;
  end if;
  if ours is null then
    select m.from_number into ours from public.messages m
     where m.lead_id = p_lead_id and m.channel = 'sms' and m.direction = 'out' and m.from_number is not null
     order by m.sent_at desc limit 1;
  end if;
  if ours is null then raise exception 'we have never texted this card: no number to text from yet'; end if;
  insert into public.reply_drafts (phone10, our_number, lead_id, inbound_at, intent, kind, outcome, note, draft_source, status, notified_at)
  values (p, ours, p_lead_id, now(), 'team_text', 'team', 'open', 'typed on the card by ' || coalesce(public.wpie_person()::text, 'team'),
          'team', 'awaiting_approval', now())
  returning reply_drafts.id into id;
  return id;
end $fn$;

CREATE OR REPLACE FUNCTION public.thread_take(p_lead_id uuid, p_phone text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
declare p text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10); who public.team_person := public.wpie_person(); n integer;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  if who is null then return jsonb_build_object('ok', false, 'reason', 'no person on this login'); end if;
  if p !~ '^[0-9]{10}$' then return jsonb_build_object('ok', false, 'reason', 'not a phone'); end if;
  -- 0249: the other caller does not take over a thread on a card that is not theirs
  if p_lead_id is not null and public.card_not_yours(p_lead_id, now()) is not null then
    return jsonb_build_object('ok', false, 'reason', public.card_not_yours(p_lead_id, now()));
  end if;
  if p_lead_id is not null then perform public.lock_card_to(p_lead_id, who, 'took the text thread'); end if;
  insert into public.thread_owners (phone10, lead_id, person, taken_at, note) values (p, p_lead_id, who, now(), p_note)
  on conflict (phone10) do update set lead_id = coalesce(excluded.lead_id, public.thread_owners.lead_id), person = excluded.person, taken_at = now(), note = excluded.note;
  -- an automated reply or belt text already waiting for this phone is withdrawn; the person is answering now
  update public.reply_drafts set status = 'superseded', note = coalesce(note, '') || ' | ' || who::text || ' took the thread', updated_at = now()
   where phone10 = p and coalesce(draft_source, '') <> 'team' and status in ('queued', 'awaiting_approval', 'would_send');
  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'person', who, 'withdrawn', n);
end $fn$;
