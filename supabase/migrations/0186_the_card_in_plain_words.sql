-- 0186: the caller's card in plain words (Colin 2026-11-04: "build the full shit so the system isnt stupid anymore", after
-- the Thalia/Adil walkthrough). What this adds, all for the two callers working a seller over months:
--   leads.say_next      "when you call back, say": one line set at the close, shown on the card, the call row and Power hour
--   leads.rest_until    a card the caller rests herself ("quiet until March, wake me sooner if a record lands or they text"):
--                       parked_at is set with a wake date; the 0183/0185 wake triggers clear it early; it comes back on its own
--   next_plain()        what happens next and when, in words ("Your call Tue Nov 18, 10 AM. Then: a text at 30 days...")
--   card_brief()        one call for the top of the card: next in words, say line, why, the last three touches, the next two
--   card_say_next / card_rest / card_unrest / card_nudge / nudge_done   the caller's own controls
--   my_piles            carries lane, say_next, reasons, phones (search by phone), touches, last words, promise, nudge,
--                       next_plain, and a Resting pile; a card Colin parked stays hidden, a card the caller rested stays visible
--   power_dial_queue    carries say_next and next_plain; a rested card is out until it wakes
--   my_day              nudges waiting, cards resting

alter table public.leads add column if not exists say_next text;
alter table public.leads add column if not exists rest_until timestamptz;
create index if not exists leads_rest_until_idx on public.leads (rest_until) where rest_until is not null;

-- the wake (0183/0185) also clears a rest
create or replace function public.unpark_on_event() returns trigger
language plpgsql security definer set search_path = public as $$
declare lead uuid := (to_jsonb(new) ->> 'lead_id')::uuid; ev text := to_jsonb(new) ->> 'event';
begin
  if lead is null then return new; end if;
  update public.leads
     set parked_at = null, rest_until = null,
         parked_why = concat_ws(' | ', parked_why, to_char(now() at time zone 'America/Chicago', 'YYYY-MM-DD') || ' woke: ' || tg_argv[0]
                      || case when tg_table_name = 'belt_events' and ev is not null then ' (' || ev || ')' else '' end)
   where id = lead and parked_at is not null;
  return new;
end $$;

-- a rest that ran out: the card is awake again (the lists already treat an expired rest as awake; this tidies the row)
create or replace function public.wake_rested(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  update public.leads set parked_at = null, rest_until = null,
         parked_why = concat_ws(' | ', parked_why, to_char(p_now at time zone 'America/Chicago', 'YYYY-MM-DD') || ' woke: the rest ran out')
   where parked_at is not null and rest_until is not null and rest_until <= p_now;
  get diagnostics n = row_count;
  return n;
end $$;

-- what happens next and when, in a caller's words
create or replace function public.next_plain(p_belt text, p_next_at timestamptz, p_next_who text, p_next_say text, p_named_date timestamptz, p_named_event text, p_me team_person default null)
returns text language plpgsql immutable as $$
declare who text; first text; ladder text; d text;
begin
  d := case when p_next_at is null then null else to_char(p_next_at at time zone 'America/Chicago', 'Dy Mon FMDD, FMHH:MI AM') end;
  who := case p_next_who
           when 'thalia_call' then case when p_me = 'thalia' then 'Your call' else 'Thalia''s call' end
           when 'adil_call' then case when p_me = 'adil' then 'Your call' else 'Adil''s call' end
           when 'owner_call' then 'The booked call'
           when 'colin_call' then 'Colin''s call'
           when 'colin_visit' then 'Colin''s walk'
           when 'auto_text' then 'A text from the machine'
           when 'draft_text' then 'A text (drafted, Colin taps it)'
           else null end;
  first := case when p_next_at is not null and who is not null then who || ' ' || d
                     || case when p_next_say is not null and p_next_say <> '' then ': "' || left(p_next_say, 120) || '"' else '' end
                when p_belt in ('cold_texts') then 'The texts are working it'
                when p_belt in ('dead', 'dnc') then 'Closed'
                when p_belt is null then 'Not on a ladder yet: your next step puts it on one'
                else 'Resting: nothing scheduled' end;
  ladder := case p_belt
    when 'cold_texts' then 'Then: text 2 at day 4, text 3 at day 18, one call from the caller after that.'
    when 'hold_not_now' then 'Then: Colin''s check-in on the day they named' || coalesce(' (' || p_named_event || ')', '') || ', and again 6 months on.'
    when 'not_now_dated' then 'Then: your call on the date they gave' || coalesce(' (' || p_named_event || ')', '') || ', one more a week after.'
    when 'not_now_condition' then 'Then: a text at 30 days about ' || coalesce(p_named_event, 'what they named') || ', your call at 90, a text at 180, quarterly after; the records wake it sooner.'
    when 'dormant' then 'Then: a text every 90 days; a "still yours?" call about a year on.'
    when 'needs_family' then 'Then: your call the day after they talk to the family, a text a week on, Colin at 30 days.'
    when 'estate_waiting' then 'Then: Colin''s calls at 3 days, 30, 90 and 180; a text at a year.'
    when 'elderly' then 'Then: Colin''s call on the day they named, then every 90 days, family on the line.'
    when 'yes_unbooked' then 'Then: a text in an hour, your call again in 2 days, a text at 2 weeks.'
    when 'replied_quiet' then 'Then: a text tomorrow, your call in 4 days, a text at 18 days.'
    when 'questions_quiet' then 'Then: a text tomorrow, your call in 4 days, a text at 18 days.'
    when 'after_call_quiet' then 'Then: Colin''s call in 3 days, a text at 10 days, Colin''s call at 30.'
    when 'call_booked' then 'A text the morning of, then the call at the slot.'
    when 'visit_booked' then 'A text the morning of, then Colin at the house.'
    when 'call_missed' then 'Then: one more try within the hour, a text, a try the next day, a text at a week.'
    when 'visit_missed' then 'Then: one more try within the hour, a text, a try the next day, a text at a week.'
    when 'offer_out' then 'Then: Colin''s call in 2 days, a text, Colin''s call at a week, a text at 30 days.'
    when 'after_visit_quiet' then 'Then: Colin''s call in 2 days, a text, Colin''s call at a week, a text at 30 days.'
    when 'too_high_or_listed' then 'Then: nothing until the listing ends or the records change; then it comes back.'
    else '' end;
  return btrim(first || '. ' || ladder);
end $$;

-- the top of the card, in one call
create or replace function public.card_brief(p_lead_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare l public.leads; me team_person; res jsonb;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  me := public.wpie_person();
  select * into l from public.leads where id = p_lead_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card'); end if;
  select jsonb_build_object(
    'ok', true,
    'lane', l.lane,
    'say_next', l.say_next,
    'next_plain', public.next_plain(l.belt, l.next_stop_at, l.next_stop_who, l.next_stop_say, l.named_date, l.named_event, me),
    'mine_next', (select jsonb_build_object('task_id', t.id, 'due_at', t.due_at, 'kind', t.kind, 'note', t.note, 'owner', t.owner, 'source', t.source)
                    from public.tasks t where t.lead_id = l.id and t.done_at is null and t.kind in ('call', 'callback', 'visit', 'text', 'other')
                   order by t.due_at nulls last limit 1),
    'why', jsonb_build_object(
       'reasons', l.reasons_to_sell,
       'motivation', (select lm.lines from public.lead_motivation lm where lm.lead_id = l.id),
       'last_words', (select left(mi.body, 240) from public.messages mi where mi.lead_id = l.id and mi.direction = 'in' and mi.channel = 'sms' order by mi.sent_at desc limit 1),
       'last_call', (select left(regexp_replace(coalesce(lc.body, ''), '^Call \([^)]*\) from \d+:\s*', ''), 240) from public.messages lc
                       where lc.lead_id = l.id and lc.channel = 'call' and lc.status is distinct from 'inbound_missed' order by lc.sent_at desc limit 1),
       'promise', (select pm.note from public.tasks pm where pm.lead_id = l.id and pm.source = 'mine' and pm.done_at is null order by pm.due_at limit 1)),
    'touches', (select coalesce(jsonb_agg(x order by x.at desc), '[]'::jsonb) from (
                  select m.sent_at at, m.channel, m.direction, coalesce(m.status, '') status, left(m.body, 140) body
                    from public.messages m where m.lead_id = l.id and m.channel in ('call', 'sms', 'note') order by m.sent_at desc limit 3) x),
    'touches_total', (select count(*) from public.messages m where m.lead_id = l.id and m.channel in ('call', 'sms')),
    'planned', (select coalesce(jsonb_agg(y order by y.at), '[]'::jsonb) from (
                  select t.due_at at, t.kind what, coalesce(t.title, t.note) words, t.owner::text who from public.tasks t
                   where t.lead_id = l.id and t.done_at is null and t.due_at is not null and t.kind <> 'nudge'
                  union all
                  select l.next_stop_at, 'belt', l.next_stop_say, l.next_stop_who where l.next_stop_at is not null and l.next_stop_at > now()
                  order by 1 limit 2) y),
    'rest', case when l.parked_at is not null then jsonb_build_object('until', l.rest_until, 'why', l.parked_why, 'by_colin', l.rest_until is null) end,
    'nudges', (select coalesce(jsonb_agg(jsonb_build_object('task_id', n.id, 'from', n.title, 'text', n.note, 'at', n.created_at, 'to', n.owner) order by n.created_at desc), '[]'::jsonb)
                 from public.tasks n where n.lead_id = l.id and n.kind = 'nudge' and n.done_at is null),
    'locked_to', l.locked_to, 'belt', l.belt, 'stage', l.stage)
  into res;
  return res;
end $$;

-- "when you call back, say": the caller's one line
create or replace function public.card_say_next(p_lead_id uuid, p_text text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare l public.leads; me team_person;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  me := public.wpie_person();
  select * into l from public.leads where id = p_lead_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card'); end if;
  if not public.is_owner() and l.locked_to is distinct from me then return jsonb_build_object('ok', false, 'reason', 'not your card'); end if;
  update public.leads set say_next = nullif(btrim(p_text), ''), updated_at = now() where id = p_lead_id;
  return jsonb_build_object('ok', true, 'say_next', nullif(btrim(p_text), ''));
end $$;

-- rest a card (the caller's own): quiet until a day, awake sooner when a text, a call or a record lands (0183)
create or replace function public.card_rest(p_lead_id uuid, p_until timestamptz, p_why text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare l public.leads; me team_person; by_name text;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  me := public.wpie_person(); by_name := initcap(coalesce(me::text, 'team'));
  select * into l from public.leads where id = p_lead_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card'); end if;
  if not public.is_owner() and l.locked_to is distinct from me then return jsonb_build_object('ok', false, 'reason', 'not your card'); end if;
  if p_until is null or p_until <= now() then return jsonb_build_object('ok', false, 'reason', 'a day in the future'); end if;
  if p_until > now() + interval '18 months' then return jsonb_build_object('ok', false, 'reason', 'at most 18 months'); end if;
  if l.belt in ('call_booked', 'visit_booked') or l.hot_at > now() - interval '14 days' then return jsonb_build_object('ok', false, 'reason', 'a booked or hot card does not rest'); end if;
  update public.leads set parked_at = now(), rest_until = p_until,
         parked_why = concat_ws(' | ', parked_why, to_char(now() at time zone 'America/Chicago', 'YYYY-MM-DD') || ' rested by ' || by_name
                      || ' until ' || to_char(p_until at time zone 'America/Chicago', 'Mon FMDD, YYYY') || coalesce(': ' || nullif(btrim(p_why), ''), ''))
   where id = p_lead_id;
  insert into public.messages (lead_id, direction, channel, body, status, created_by, sent_at)
  values (p_lead_id, 'out', 'note', 'Resting until ' || to_char(p_until at time zone 'America/Chicago', 'Mon FMDD, YYYY') || coalesce(': ' || nullif(btrim(p_why), ''), '')
          || ' (' || by_name || '). Wakes sooner on a text, a call or a new record.', null, auth.uid(), now());
  return jsonb_build_object('ok', true, 'rest_until', p_until);
end $$;

create or replace function public.card_unrest(p_lead_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare l public.leads; me team_person;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  me := public.wpie_person();
  select * into l from public.leads where id = p_lead_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card'); end if;
  if not public.is_owner() and l.locked_to is distinct from me then return jsonb_build_object('ok', false, 'reason', 'not your card'); end if;
  if l.parked_at is not null and l.rest_until is null and not public.is_owner() then return jsonb_build_object('ok', false, 'reason', 'Colin parked this one'); end if;
  update public.leads set parked_at = null, rest_until = null,
         parked_why = concat_ws(' | ', parked_why, to_char(now() at time zone 'America/Chicago', 'YYYY-MM-DD') || ' woke: ' || initcap(coalesce(me::text, 'team')) || ' took it back')
   where id = p_lead_id;
  return jsonb_build_object('ok', true);
end $$;

-- a heads-up to the other caller (or Colin) on a card, without routing through anyone: a task of kind 'nudge' they see on
-- Today and on the card, pushed like a reminder
create or replace function public.card_nudge(p_lead_id uuid, p_to team_person, p_text text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me team_person; t public.tasks; by_name text;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  me := public.wpie_person(); by_name := initcap(coalesce(me::text, 'team'));
  if p_to is null or p_to = me then return jsonb_build_object('ok', false, 'reason', 'pick the other person'); end if;
  if nullif(btrim(p_text), '') is null then return jsonb_build_object('ok', false, 'reason', 'say something'); end if;
  if not exists (select 1 from public.leads where id = p_lead_id) then return jsonb_build_object('ok', false, 'reason', 'no such card'); end if;
  insert into public.tasks (lead_id, due_at, kind, owner, note, created_by, source, title)
  values (p_lead_id, now(), 'nudge', p_to, btrim(p_text), auth.uid(), 'nudge', 'Heads-up from ' || by_name)
  returning * into t;
  insert into public.messages (lead_id, direction, channel, body, status, created_by, sent_at)
  values (p_lead_id, 'out', 'note', 'Heads-up to ' || initcap(p_to::text) || ' from ' || by_name || ': ' || btrim(p_text), null, auth.uid(), now());
  return jsonb_build_object('ok', true, 'task_id', t.id);
end $$;

create or replace function public.nudge_done(p_task_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t public.tasks; me team_person;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  me := public.wpie_person();
  select * into t from public.tasks where id = p_task_id and kind = 'nudge';
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such heads-up'); end if;
  if not public.is_owner() and t.owner is distinct from me then return jsonb_build_object('ok', false, 'reason', 'not yours'); end if;
  update public.tasks set done_at = now(), updated_at = now() where id = p_task_id;
  return jsonb_build_object('ok', true);
end $$;

-- the heads-ups waiting for me (Today's badge and list)
create or replace function public.my_nudges() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('task_id', t.id, 'lead_id', t.lead_id, 'from', t.title, 'text', t.note, 'at', t.created_at,
           'owner_name', l.owner_name, 'address', l.property_address) order by t.created_at desc), '[]'::jsonb)
    from public.tasks t join public.leads l on l.id = t.lead_id
   where t.kind = 'nudge' and t.done_at is null and t.owner = public.wpie_person() and public.is_team();
$$;

grant execute on function public.next_plain(text, timestamptz, text, text, timestamptz, text, team_person) to authenticated, service_role;
grant execute on function public.card_brief(uuid) to authenticated, service_role;
grant execute on function public.card_say_next(uuid, text) to authenticated, service_role;
grant execute on function public.card_rest(uuid, timestamptz, text) to authenticated, service_role;
grant execute on function public.card_unrest(uuid) to authenticated, service_role;
grant execute on function public.card_nudge(uuid, team_person, text) to authenticated, service_role;
grant execute on function public.nudge_done(uuid) to authenticated, service_role;
grant execute on function public.my_nudges() to authenticated, service_role;
grant execute on function public.wake_rested(timestamptz) to service_role;


-- my_piles, power_dial_queue and my_day, regenerated from the live definitions
CREATE OR REPLACE FUNCTION public.my_piles(p_person team_person DEFAULT NULL::team_person)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare who public.team_person; eod timestamptz; res jsonb;
begin
  if not public.is_team() then raise exception 'only the team'; end if;
  who := coalesce(p_person, public.wpie_person());
  if who is distinct from public.wpie_person()
     and coalesce((select role::text from public.team_members where person = public.wpie_person() limit 1), '') <> 'owner' then
    who := public.wpie_person();
  end if;
  eod := (date_trunc('day', now() at time zone 'America/Chicago') + interval '1 day') at time zone 'America/Chicago';
  with ppl as (
    select tm.person, u.id uid from public.team_members tm join auth.users u on lower(u.email) = tm.email where tm.person = who
  ), mine as (
    select id lead_id, 'your card' why from public.leads where locked_to = who
    union select id, 'assigned' from public.leads where assigned_to = who
    union select id, 'took the texts' from public.leads where human_takeover_assigned_to = who or lower(coalesce(human_takeover_by, '')) = who::text
    union select lead_id, 'built the package' from public.deal_packages where created_by = who
    union select m.lead_id, 'logged a call' from public.messages m join ppl on ppl.uid = m.created_by where m.channel = 'call' and m.lead_id is not null
    union select lead_id, 'call on their list' from public.tasks
           where owner = who and done_at is null and lead_id is not null and coalesce(source, '') not in ('power_hour', 'power_hour_after')
  ), cards as (
    select l.id, l.owner_name, l.property_address, l.municipality, l.county, l.stage::text stage, l.belt, l.next_stop_at, l.next_stop_say,
           l.named_date, l.named_event, l.hot_at, l.locked_to,
           l.lane, l.say_next, l.reasons_to_sell, l.rest_until, l.parked_at, l.parked_why, l.next_stop_who,
           (select string_agg(c3.value_normalized, ' ') from public.contacts c3 where c3.lead_id = l.id and c3.kind = 'phone') phones,
           (select count(*) from public.messages mt where mt.lead_id = l.id and mt.channel in ('call', 'sms')) touches,
           (select left(mi.body, 160) from public.messages mi where mi.lead_id = l.id and mi.direction = 'in' and mi.channel = 'sms' order by mi.sent_at desc limit 1) last_words,
           (select left(coalesce(nz.note, nz.title), 200) from public.tasks nz where nz.lead_id = l.id and nz.kind = 'nudge' and nz.owner = who and nz.done_at is null order by nz.created_at desc limit 1) nudge,
           (select left(coalesce(pm.note, ''), 200) from public.tasks pm where pm.lead_id = l.id and pm.source = 'mine' and pm.owner = who and pm.done_at is null order by pm.due_at limit 1) promise,
           (select string_agg(distinct m2.why, ', ') from mine m2 where m2.lead_id = l.id) why,
           t.id task_id, t.due_at task_due, t.kind task_kind, t.source task_source, coalesce(t.title, left(t.note, 140)) task_what,
           pk.status pkg,
           (l.human_takeover_assigned_to = who
            or exists (select 1 from public.deal_packages d2 where d2.lead_id = l.id)
            or exists (select 1 from public.messages m3 where m3.lead_id = l.id and m3.channel = 'call'
                        and m3.status in ('interested', 'reached_no_decision', 'not_now', 'inbound_answered'))
            or l.stage in ('reply_received', 'ai_qualifying', 'handoff', 'colin_call', 'walk_decision', 'human_owned')) talked,
           lm.tier,
           (lc.sent_at is not null) dialed,
           lc.sent_at last_call_at, left(regexp_replace(coalesce(lc.body, ''), '^Call \([^)]*\) from \d+:\s*', ''), 220) last_call
      from public.leads l
      left join public.lead_motivation lm on lm.lead_id = l.id
      left join lateral (select x.* from public.tasks x where x.lead_id = l.id and x.owner = who and x.done_at is null
                          order by x.due_at nulls last limit 1) t on true
      left join lateral (select d.status from public.deal_packages d where d.lead_id = l.id order by d.created_at desc limit 1) pk on true
      left join lateral (select mm.sent_at, mm.body from public.messages mm where mm.lead_id = l.id and mm.channel = 'call' and mm.status is distinct from 'inbound_missed'
                          order by mm.sent_at desc limit 1) lc on true
     where l.id in (select lead_id from mine)
       -- a card Colin parked is hidden; a card the caller rested (rest_until) stays, in the Resting pile until it wakes (0186)
       and (l.parked_at is null or l.rest_until is not null)
  ), piled as (
    select c.*,
      case
        when c.stage in ('dead', 'dnc', 'closed_won', 'closed_no_contact', 'mail_only') then 'closed'
        when c.parked_at is not null and c.rest_until > now() then 'resting'
        when c.task_due is not null and c.task_due < eod then 'call_now'
        when c.belt in ('call_booked', 'visit_booked', 'visit_missed', 'call_missed', 'offer_out') or c.stage in ('walkthrough_booked', 'offer', 'under_contract')
             or (c.hot_at is not null and c.hot_at > now() - interval '14 days') then 'booked'
        when c.pkg in ('waiting_value', 'waiting_number', 'counter') then 'colin'
        when c.task_due is not null and c.task_due < now() + interval '7 days' then 'this_week'
        when c.task_due is not null or (c.next_stop_at is not null and c.next_stop_at > now())
             or c.belt in ('not_now_dated', 'not_now_condition', 'needs_family', 'elderly', 'estate_waiting', 'hold_not_now', 'dormant', 'too_high_or_listed') then 'later'
        when c.talked then 'no_step'
        when c.dialed then 'tried'
        else 'not_called'
      end pile,
      coalesce(c.task_due, case when c.next_stop_at > now() then c.next_stop_at end, case when c.named_date > now() then c.named_date end) next_at
    from cards c
  )
  select jsonb_build_object('person', who, 'cards', coalesce(jsonb_agg(jsonb_build_object(
           'lead_id', id, 'owner_name', owner_name, 'address', property_address, 'municipality', municipality, 'county', county,
           'stage', stage, 'belt', belt, 'pile', pile, 'next_at', next_at,
           'next_what', coalesce(task_what, case when next_stop_at > now() then next_stop_say end),
           'last_call_at', last_call_at, 'last_call', nullif(last_call, ''), 'why', why, 'locked_to', locked_to, 'tier', tier,
           'task_id', task_id, 'task_kind', task_kind, 'task_source', task_source,
           'lane', lane, 'say_next', say_next, 'reasons', reasons_to_sell, 'phones', phones, 'touches', touches, 'last_words', last_words,
           'nudge', nudge, 'promise', promise, 'rest_until', case when parked_at is not null then rest_until end, 'rest_why', case when parked_at is not null then parked_why end,
           'next_plain', public.next_plain(belt, next_stop_at, next_stop_who, next_stop_say, named_date, named_event, who),
           'walk_at', case when belt in ('visit_booked', 'call_booked') or stage = 'walkthrough_booked' then named_date end, 'named_event', named_event, 'hot_at', hot_at)
         order by array_position(array['call_now','booked','colin','this_week','later','no_step','tried','not_called','resting','closed'], pile),
                  case when pile in ('no_step', 'tried', 'not_called') then null else next_at end nulls last,
                  case when pile = 'not_called' then coalesce(tier, 'Z') end, last_call_at desc nulls last), '[]'::jsonb))
    into res from piled;
  return res;
end $function$;

CREATE OR REPLACE FUNCTION public.power_dial_queue(p_limit integer DEFAULT 80, p_now timestamp with time zone DEFAULT now(), p_test boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with me as (select public.is_team() as ok),
  -- the phones a person's status blocks (phone_person_block, 0084), computed once for the whole queue instead of once
  -- per contact per card: as a per-row call it stopped using the index and the queue took minutes (2026-10-29)
  blocked as (
    select distinct c.value_normalized as ph from public.contacts c join public.people pe on pe.id = c.person_id
     where pe.status = 'do_not_contact'
        or (pe.status = 'deceased' and not exists (select 1 from public.contacts c2 join public.people p2 on p2.id = c2.person_id
                                                    where c2.value_normalized = c.value_normalized and p2.status = 'active'))),
  dialed as (
    select m.lead_id, count(*) filter (where m.sent_at > p_now - interval '7 days') as dials_7d, count(*) as dials_total, max(m.sent_at) as last_dial,
           count(*) filter (where (m.sent_at at time zone 'America/Chicago')::date = (p_now at time zone 'America/Chicago')::date) as dials_today
      -- our dials only: a logged call is stored as 'in' with its outcome; their own calls to us are 'inbound...'
      from public.messages m where m.channel = 'call' and coalesce(m.status, '') not like 'inbound%' group by m.lead_id),
  reached as (
    select distinct m.lead_id from public.messages m
     where m.channel = 'call' and coalesce(m.status, '') not in ('no_answer', 'voicemail', 'inbound_missed', 'missed', 'busy', 'failed', 'canceled', 'blocked')),
  first_text as (
    select distinct on (m.lead_id) m.lead_id, right(regexp_replace(m.to_number, '\D', '', 'g'), 10) as phone, m.sent_at
      from public.messages m
     where m.direction = 'out' and m.channel = 'sms' and m.is_opener and m.provider_sid is not null and coalesce(m.status, '') not in ('undelivered', 'failed')
     order by m.lead_id, m.sent_at),
  texts as (
    select m.lead_id, count(*) as n, max(m.sent_at) as last_at from public.messages m
     where m.direction = 'out' and m.channel = 'sms' and m.provider_sid is not null group by m.lead_id),
  -- a seller who called us and nobody picked up, not called back since (the same rule as Today's Missed calls box)
  missed as (
    select distinct on (ic.lead_id) ic.lead_id, ic.from10 as missed_phone, ic.created_at as missed_at, ic.voicemail,
           nullif(substring(m.body from 'Voicemail: "(.*)"'), '') as vm_words
      from public.inbound_calls ic left join public.messages m on m.id = ic.message_id
     where ic.lead_id is not null and ic.created_at > p_now - interval '48 hours'
       and (ic.status in ('missed', 'blocked', 'no_answer', 'busy', 'failed') or ic.voicemail)
       -- a caller whose number is on the stop list ("erase my number") is never a callback, on any of the card's numbers
       and not exists (select 1 from public.suppressed_phones s where s.phone10 = ic.from10)
       -- the voicemail was read (0118): an upset caller, a stop, the wrong person or someone who isn't a seller is never a
       -- callback; a voicemail not read yet waits up to 10 minutes so nobody calls a caller who was angry
       and coalesce(ic.vm_verdict, '') not in ('stop', 'wrong_person', 'upset', 'not_seller')
       and not (ic.voicemail and ic.vm_verdict is null and ic.created_at > p_now - interval '10 minutes')
       and not exists (select 1 from public.messages o where o.lead_id = ic.lead_id and o.channel = 'call' and o.sent_at > ic.created_at
                         and coalesce(o.status, '') not like 'inbound%')
     order by ic.lead_id, ic.created_at desc),
  due_tasks as (
    select distinct on (t.lead_id) t.lead_id, t.id as task_id, t.title, t.due_at, t.source as task_source, t.kind as task_kind, t.note as task_note, t.quote as reply_words,
           nullif(t.phone10, '') as reply_phone, t.created_at as task_at from public.tasks t
     where t.done_at is null and t.lead_id is not null
       and ((t.kind = 'call' and t.due_at <= p_now + interval '12 hours')
         -- a callback promised to a seller comes up from 15 minutes before its time (0124)
         or (t.kind = 'callback' and t.due_at <= p_now + interval '15 minutes'))
       and t.owner in ('thalia', 'adil')
       -- a callback promised by one caller is that caller's (Colin 2026-10-30): on a caller's own login only their own come up
       and (t.kind <> 'callback' or public.wpie_person() not in ('thalia', 'adil') or t.owner = public.wpie_person())
       -- a power-hour set is loaded per caller (Colin 2026-11-03: "50 in each and then followups"): only its caller sees it
       and (coalesce(t.source, '') not in ('power_hour', 'power_hour_after') or public.wpie_person() not in ('thalia', 'adil') or t.owner = public.wpie_person())
     order by t.lead_id, (t.kind = 'callback') desc, (t.source = 'call_next') desc, t.due_at),
  pool as (
    select l.*, dt.task_id, dt.title as task_title, dt.reply_words, dt.task_at, dt.due_at as task_due, (dt.task_source = 'call_next') as replied,
           mc.missed_at, mc.voicemail as missed_voicemail, mc.vm_words, mc.missed_phone,
           coalesce(mc.missed_phone, dt.reply_phone, ft.phone) as thread_phone, ft.sent_at as first_text_at,
           coalesce(tx.n, 0) as texts_sent, tx.last_at as last_text_at, coalesce(d.dials_7d, 0) as dials_7d, coalesce(d.dials_total, 0) as dials_total, d.last_dial, coalesce(d.dials_today, 0) as dials_today,
           dt.task_source, case when mc.lead_id is not null then -3 when dt.task_kind = 'callback' then -2 when dt.task_source = 'call_next' then -1
                when dt.task_id is not null then 0 else 1 end as src, dt.task_note
      from public.leads l
      left join missed mc on mc.lead_id = l.id
      left join due_tasks dt on dt.lead_id = l.id
      left join first_text ft on ft.lead_id = l.id
      left join texts tx on tx.lead_id = l.id
      left join dialed d on d.lead_id = l.id
     where (select ok from me)
       -- a card on another caller's screen right now is theirs (two callers in Power hour, 0120)
       -- a card locked to the other caller, or with the other caller's open callback, is not mine to dial (0148)
       and (public.wpie_person() not in ('thalia', 'adil') or l.locked_to is null or l.locked_to = public.wpie_person())
       and not exists (select 1 from public.tasks cb where cb.lead_id = l.id and cb.kind = 'callback' and cb.done_at is null
                         and public.wpie_person() in ('thalia', 'adil') and cb.owner <> public.wpie_person())
       and not exists (select 1 from public.power_claims pc where pc.lead_id = l.id and pc.until > p_now
                         and pc.person is distinct from public.wpie_person())
       -- a walkthrough runs on TEST cards only, and the real queue never shows them
       and (l.owner_name ilike 'TEST %') = coalesce(p_test, false)
       -- a seller who called us comes first, whatever the card's stage or dial count (Colin 2026-10-28: "should
       -- automatically be top of the list to call"); only a dead or do-not-contact card is left out
       and (((mc.lead_id is not null or dt.task_kind = 'callback') and l.stage not in ('dnc', 'dead', 'closed_no_contact')) or (
           (dt.task_id is not null or (l.stage = 'opener_sent' and ft.sent_at < p_now - interval '3 days')
            or (coalesce(p_test, false) and l.stage = 'opener_sent'))   -- a TEST card needs no task and no texts
       and l.stage not in ('dnc', 'dead', 'closed_no_contact', 'closed_won', 'under_contract', 'walkthrough_booked', 'offer')
       and not coalesce(l.elderly_or_ill, false) and not coalesce(l.grief, false)
       -- a caller's due follow-up call (the belt's) still comes up when a caller took the text thread (0163)
       and (l.human_takeover_at is null or dt.task_source in ('belt', 'mine'))
       and (l.named_date is null or l.named_date <= p_now)
        and (l.parked_at is null or (l.rest_until is not null and l.rest_until <= p_now))   -- parked (0182) or rested by the caller (0186) until it wakes
       -- four numbers a sitting (Thalia 2026-11-04, Colin: 'do what thalia asked for'): after four dials on a card in a day the
       -- card leaves today's queue and comes back the next day at its next untried number; a seller who called us, or a
       -- promised callback, is never capped
       and (mc.lead_id is not null or dt.task_kind = 'callback' or coalesce(d.dials_today, 0) < 4)
       -- someone who just texted back with a bit of interest (Muse's call_next) is called next, whatever the dial rules say
       -- and a seller who texted back gets the follow-up call the belt set for them (Colin 2026-11-03: "behind them any followups needed")
       and (dt.task_source in ('call_next', 'belt', 'mine', 'power_hour', 'power_hour_after') or (
            coalesce(d.dials_7d, 0) < 3
        and (d.last_dial is null or d.last_dial < p_now - interval '2 days')
        and (dt.task_id is not null or l.id not in (select lead_id from reached))
        and not exists (select 1 from public.twilio_inbound ti where ti.lead_id = l.id)
        and not exists (select 1 from public.messages mi where mi.lead_id = l.id and mi.direction = 'in' and mi.channel = 'sms')))))
       and extract(hour from (p_now at time zone public.agent_tz(coalesce(l.mailing_state, 'WI')))) between 9 and 19),
  pick as (
    select p.*, ph.value_normalized as phone, ph.line_type, ph.person_name as phone_person,
           (select count(*) from public.contacts c2 where c2.lead_id = p.id and c2.kind = 'phone' and c2.status = 'ok' and not c2.suppressed
              and not exists (select 1 from public.messages m where m.lead_id = p.id and m.channel = 'call' and coalesce(m.status, '') not like 'inbound%'
                              and right(regexp_replace(coalesce(m.to_number, ''), '\D', '', 'g'), 10) = c2.value_normalized and (m.sent_at at time zone 'America/Chicago')::date = (p_now at time zone 'America/Chicago')::date)) - 1 as other_phones
      from pool p
      cross join lateral (
        select c.value_normalized, c.line_type, c.person_name from public.contacts c
         where c.lead_id = p.id and c.kind = 'phone' and c.status = 'ok' and c.value_normalized ~ '^[0-9]{10}$'
           and not c.suppressed and not coalesce(c.dnc_app, false)
           and (c.value_normalized = p.missed_phone or (not coalesce(c.dnc_vendor, false) and coalesce(c.dnc_scrub, '') <> 'dnc'))
           and not exists (select 1 from public.suppressed_phones s where s.phone10 = c.value_normalized)
           and not exists (select 1 from blocked b where b.ph = c.value_normalized)
           -- a number already dialed today is not offered again today (0184), except to call a seller back
           and (p.src <= -2 or (true and not exists (select 1 from public.messages m where m.lead_id = p.id and m.channel = 'call' and coalesce(m.status, '') not like 'inbound%'
                              and right(regexp_replace(coalesce(m.to_number, ''), '\D', '', 'g'), 10) = c.value_normalized and (m.sent_at at time zone 'America/Chicago')::date = (p_now at time zone 'America/Chicago')::date)))
         order by (c.value_normalized = p.thread_phone) desc,
                  (c.person_id is not null and exists (select 1 from public.interests i where i.lead_id = p.id and i.person_id = c.person_id
                     and i.role in ('owner_of_record', 'co_owner', 'personal_representative', 'trustee') and i.status = 'active')) desc,
                  (c.line_type = 'mobile') desc, c.created_at
         limit 1) ph
     order by p.src, p.missed_at desc nulls last, (coalesce(p.task_source, '') = 'power_hour') desc,
              case when p.task_source = 'power_hour' then p.task_due end nulls last, p.task_at nulls last, cardinality(p.reasons_to_sell) desc, p.first_text_at nulls last, p.id
     limit greatest(1, least(coalesce(p_limit, 80), 200)))
  select coalesce(jsonb_agg(jsonb_build_object(
      'lead_id', id, 'task_id', task_id, 'source', case when src = -3 then 'missed_call' when src = -2 then 'callback' when src = -1 then 'replied'
        when task_source = 'checkin' then 'checkin' when src = 0 then 'call_list' else 'texted_silent' end, 'why', task_title,
      'missed_at', missed_at, 'voicemail', missed_voicemail, 'voicemail_words', vm_words,
      'reply', reply_words, 'task_note', task_note,
      -- the card's latest package: what Colin decided, so the caller says the right thing (0124)
      'package', (select jsonb_build_object('id', d.id, 'status', d.status, 'colin_call', d.colin_call, 'colin_asks', d.colin_asks,
                    'caller_answers', d.caller_answers, 'callback_at', d.callback_at, 'number_note', d.number_note,
                    'our_number', d.our_number, 'their_number', d.their_number)
                    from public.deal_packages d where d.lead_id = pick.id order by d.created_at desc limit 1),
      'owner_name', owner_name, 'address', property_address, 'municipality', municipality, 'mailing_state', mailing_state,
      'reasons', reasons_to_sell, 'lane', lane, 'stage', stage,
      'texts_sent', texts_sent, 'first_text_at', first_text_at, 'last_text_at', last_text_at,
      'dials_7d', dials_7d, 'dials_total', dials_total, 'last_dial', last_dial, 'dials_today', dials_today,
      'phone', phone, 'line_type', line_type, 'phone_person', phone_person, 'other_phones', greatest(other_phones, 0),
      'say_next', say_next, 'next_plain', public.next_plain(belt, next_stop_at, next_stop_who, next_stop_say, named_date, named_event, public.wpie_person()))
      order by src, missed_at desc nulls last, (coalesce(task_source, '') = 'power_hour') desc,
        case when task_source = 'power_hour' then task_due end nulls last, task_at nulls last, cardinality(reasons_to_sell) desc, first_text_at nulls last, id), '[]'::jsonb)
    from pick
$function$;

CREATE OR REPLACE FUNCTION public.my_day(p_person team_person DEFAULT NULL::team_person, p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare who public.team_person; day_start timestamptz; uid uuid;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  who := coalesce(p_person, public.wpie_person());
  if who is distinct from public.wpie_person() and not public.is_owner() then who := public.wpie_person(); end if;
  day_start := date_trunc('day', p_now at time zone 'America/Chicago') at time zone 'America/Chicago';
  select u.id into uid from public.team_members m join auth.users u on lower(u.email) = m.email where m.person = who limit 1;
  return jsonb_build_object(
    'person', who,
    'dials', (select count(*) from public.messages m where m.channel = 'call' and m.created_by = uid and m.sent_at >= day_start and m.sent_at <= p_now
                and m.status is distinct from 'inbound_missed'),
    'reached', (select count(*) from public.messages m where m.channel = 'call' and m.created_by = uid and m.sent_at >= day_start and m.sent_at <= p_now
                  and m.status in ('interested', 'reached_no_decision', 'not_now', 'not_interested', 'inbound_answered')),
    'packages', (select count(*) from public.deal_packages d where d.created_by = who and d.created_at >= day_start and d.created_at <= p_now),
    'done', (select count(*) from public.tasks t where t.owner = who and t.done_at >= day_start and t.done_at <= p_now),
    'set', (select count(*) from public.task_moves x where x.by = who::text and x.at >= day_start and x.at <= p_now)
          + (select count(*) from public.tasks t where t.source = 'mine' and t.owner = who and t.created_at >= day_start and t.created_at <= p_now),
    'nudges', (select count(*) from public.tasks t where t.owner = who and t.done_at is null and t.kind = 'nudge'),
    'resting', (select count(*) from public.leads l where l.locked_to = who and l.parked_at is not null and l.rest_until > p_now),
    'left_today', (select count(*) from public.tasks t where t.owner = who and t.done_at is null and t.kind in ('call', 'callback', 'visit')
                     and t.due_at < day_start + interval '1 day' and coalesce(t.source, '') not in ('power_hour_reserve')));
end $function$;
