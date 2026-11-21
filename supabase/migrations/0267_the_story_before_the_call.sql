-- 0267: the story before the call.
--
-- Colin, 2026-11-20, the night after 991 Howard St was signed at $60,000: "I think we want it to figure out the
-- story of what's going on with the house ahead of time and then make a detailed script like I got for the Jason
-- call where I got a contract ... I offered and locked up the contract for 60k on this because I knew the real number
-- I had to clear was a 34k mortgage and maybe some estate shit."
--
-- The Howard St script was written by Muse into a package nobody else could see. It worked because it knew three
-- things before the phone rang: what was owed and to whom, which of that follows the house and which does not (a
-- claim filed in an estate does not), and what was still unknown (one $139,000 claim with no name on it), with a
-- question for each unknown and a close for each way it could turn out.
--
-- A call brief is that, on the card, for whoever makes the call:
--   story     what is going on with the house and the people, in plain words
--   owed      each thing owed: what kind, to whom, how much, where that was read, and whether it follows the house
--   to clear  worked by the server: what has to be paid at closing for the seller to hand over a clean title
--   unknowns  what is not known yet and decides the number: the questions the call exists to answer
--   script    the words, by section: the open, what is owed, the house, who decides, money, and a close for each way
--             the unknowns can turn out
-- Muse writes it. A yes asks for one (due 30 minutes after the yes: the comp comes first, 0266), and Colin or a
-- caller can ask for one on any card. The caller reads it on the card; a caller reads only their own cards.

alter table public.text_offer_rules add column if not exists yes_brief_minutes integer not null default 30;

create table if not exists public.call_briefs (
  lead_id      uuid primary key references public.leads(id) on delete cascade,
  status       text not null default 'wanted' check (status in ('wanted', 'ready')),
  wanted_at    timestamptz not null default now(),
  wanted_by    text,
  wanted_why   text,
  due_at       timestamptz,
  story        text,
  owed         jsonb not null default '[]'::jsonb,
  unknowns     jsonb not null default '[]'::jsonb,
  script       text,
  sources      text,
  to_clear     numeric,
  owed_total   numeric,
  written_by   text,
  written_at   timestamptz,
  version      integer not null default 0,
  updated_at   timestamptz not null default now()
);
create table if not exists public.call_brief_versions (
  id bigserial primary key, lead_id uuid not null references public.leads(id) on delete cascade, version integer not null,
  story text, owed jsonb, unknowns jsonb, script text, sources text, by text, at timestamptz not null default now()
);
alter table public.call_briefs enable row level security;
alter table public.call_brief_versions enable row level security;
drop policy if exists call_briefs_owner on public.call_briefs;
create policy call_briefs_owner on public.call_briefs for select using (public.is_owner());
drop policy if exists call_brief_versions_owner on public.call_brief_versions;
create policy call_brief_versions_owner on public.call_brief_versions for select using (public.is_owner());
grant select on public.call_briefs, public.call_brief_versions to authenticated, service_role;

-- what is owed, in one line a caller can read before dialing
create or replace function public.call_brief_owed_line(p_owed jsonb) returns text
language sql immutable as $fn$
  with x as (select e->>'kind' kind, nullif(e->>'creditor', '') creditor, nullif(e->>'amount', '')::numeric amount, coalesce(e->>'follows_house', 'unknown') f
               from jsonb_array_elements(case when jsonb_typeof(p_owed) = 'array' then p_owed else '[]'::jsonb end) e)
  select nullif(concat_ws(' ',
    case when exists (select 1 from x where f = 'yes')
         then 'Has to be paid at closing: ' || public.text_money(coalesce((select sum(amount) from x where f = 'yes'), 0))
              || ' (' || (select string_agg(kind || coalesce(' ' || public.text_money(amount), ', amount not known'), ', ') from x where f = 'yes') || ').' end,
    case when exists (select 1 from x where f = 'no')
         then 'Owed but does not follow the house: ' || public.text_money(coalesce((select sum(amount) from x where f = 'no'), 0)) || '.' end,
    case when exists (select 1 from x where f = 'unknown')
         then 'Not settled which way it falls: ' || (select string_agg(coalesce(creditor, kind) || coalesce(' ' || public.text_money(amount), ''), ', ') from x where f = 'unknown') || '.' end), '')
$fn$;

-- ---------------------------------------------------------------- asking for one
create or replace function public.call_brief_want(p_lead_id uuid, p_by text, p_why text, p_due timestamptz default null) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare r public.text_offer_rules; b public.call_briefs; due timestamptz;
begin
  select * into r from public.text_offer_rules where id = 1;
  due := coalesce(p_due, now() + make_interval(mins => coalesce(r.yes_brief_minutes, 30)));
  select * into b from public.call_briefs where lead_id = p_lead_id;
  if found and b.status = 'ready' and b.written_at > now() - interval '14 days' then
    return jsonb_build_object('ok', true, 'already', true, 'status', 'ready', 'written_at', b.written_at);
  end if;
  insert into public.call_briefs (lead_id, status, wanted_at, wanted_by, wanted_why, due_at)
  values (p_lead_id, 'wanted', now(), nullif(btrim(coalesce(p_by, '')), ''), nullif(btrim(coalesce(p_why, '')), ''), due)
  on conflict (lead_id) do update set status = 'wanted', wanted_at = now(), wanted_by = excluded.wanted_by, wanted_why = excluded.wanted_why,
         due_at = least(coalesce(public.call_briefs.due_at, excluded.due_at), excluded.due_at), updated_at = now()
   where public.call_briefs.status <> 'wanted' or public.call_briefs.due_at is null or public.call_briefs.due_at > excluded.due_at;
  return jsonb_build_object('ok', true, 'status', 'wanted', 'due_at', due);
end $fn$;
revoke all on function public.call_brief_want(uuid, text, text, timestamptz) from public, anon, authenticated;
grant execute on function public.call_brief_want(uuid, text, text, timestamptz) to service_role;

-- Colin or the card's caller asks for one from the card
create or replace function public.call_brief_ask(p_lead_id uuid, p_why text default null) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare who text;
begin
  perform public.card_guard(p_lead_id);   -- 0250: a card is its caller's
  if not public.is_team() then raise exception 'team only'; end if;
  select display_name into who from public.team_members where lower(email) = lower(auth.jwt() ->> 'email');
  return public.call_brief_want(p_lead_id, coalesce(who, 'the team'), coalesce(nullif(btrim(p_why), ''), 'asked for from the card'));
end $fn$;
revoke all on function public.call_brief_ask(uuid, text) from public, anon;
grant execute on function public.call_brief_ask(uuid, text) to authenticated, service_role;

-- what the card shows
create or replace function public.call_brief(p_lead_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $fn$
declare b public.call_briefs;
begin
  perform public.card_guard(p_lead_id);   -- 0250: a card is its caller's
  if not public.is_team() then raise exception 'team only'; end if;
  select * into b from public.call_briefs where lead_id = p_lead_id;
  if not found then return jsonb_build_object('status', 'none'); end if;
  return jsonb_build_object('status', b.status, 'wanted_at', b.wanted_at, 'wanted_by', b.wanted_by, 'due_at', b.due_at,
    'late', b.status = 'wanted' and b.due_at < now(),
    'story', b.story, 'owed', b.owed, 'owed_line', public.call_brief_owed_line(b.owed), 'to_clear', b.to_clear, 'owed_total', b.owed_total,
    'unknowns', b.unknowns, 'script', b.script, 'sources', b.sources, 'written_by', b.written_by, 'written_at', b.written_at, 'version', b.version);
end $fn$;
revoke all on function public.call_brief(uuid) from public, anon;
grant execute on function public.call_brief(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------- the agent writes it
create or replace function public.agent_call_brief_set(p jsonb, p_agent text) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare lid uuid; l public.leads; b public.call_briefs; e jsonb; owed jsonb := '[]'::jsonb; amt numeric; kind text; f text; i integer := 0; v integer;
        story text := btrim(coalesce(p->>'story', '')); script text := btrim(coalesce(p->>'script', '')); unk jsonb;
begin
  begin lid := nullif(p->>'lead_id', '')::uuid; exception when others then lid := null; end;
  if lid is null then return jsonb_build_object('ok', false, 'reason', 'lead_id is the card'); end if;
  select * into l from public.leads where id = lid;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card'); end if;
  if length(story) < 60 then return jsonb_build_object('ok', false, 'reason', 'story: say what is going on with the house and the people, in plain words (a few sentences): who owns it, why they might sell, what is pressing'); end if;
  if length(script) < 300 then return jsonb_build_object('ok', false, 'reason', 'script: the words for the call, by section (open, what is owed, the house, who decides, money, and a close for each way the unknowns can turn out)'); end if;
  if length(script) > 20000 or length(story) > 6000 then return jsonb_build_object('ok', false, 'reason', 'too long: a story is 6,000 characters at most and a script 20,000'); end if;
  if jsonb_typeof(p->'owed') is distinct from 'array' then
    return jsonb_build_object('ok', false, 'reason', 'owed is a list, one row for each thing owed: kind, creditor, amount, basis, follows_house. Send an empty list only with nothing_owed_found: true');
  end if;
  if jsonb_array_length(p->'owed') = 0 and coalesce((p->>'nothing_owed_found')::boolean, false) is not true then
    return jsonb_build_object('ok', false, 'reason', 'owed is empty: if you looked (the mortgage records, the tax roll, the court) and found nothing owed, say nothing_owed_found: true and say where you looked in sources');
  end if;
  for e in select * from jsonb_array_elements(p->'owed') loop
    i := i + 1;
    kind := lower(btrim(coalesce(e->>'kind', '')));
    if kind not in ('mortgage', 'tax', 'judgment', 'lien', 'estate_claim', 'utility', 'hoa', 'other') then
      return jsonb_build_object('ok', false, 'reason', 'owed row ' || i || ': kind is mortgage, tax, judgment, lien, estate_claim, utility, hoa or other');
    end if;
    begin amt := nullif(regexp_replace(coalesce(e->>'amount', ''), '[^0-9.]', '', 'g'), '')::numeric; exception when others then amt := null; end;
    f := lower(btrim(coalesce(e->>'follows_house', 'unknown')));
    if f in ('true', 't') then f := 'yes'; elsif f in ('false', 'f') then f := 'no'; end if;
    if f not in ('yes', 'no', 'unknown') then
      return jsonb_build_object('ok', false, 'reason', 'owed row ' || i || ': follows_house is yes (a lien on the house: it is paid at closing), no (owed by the person or the estate but not secured on the house) or unknown');
    end if;
    if coalesce(btrim(e->>'basis'), '') = '' then
      return jsonb_build_object('ok', false, 'reason', 'owed row ' || i || ': basis says where the figure was read (the seller said it, the court record, the register of deeds, the tax roll) or that it is an estimate');
    end if;
    owed := owed || jsonb_build_object('kind', kind, 'creditor', nullif(btrim(coalesce(e->>'creditor', '')), ''), 'amount', amt, 'basis', btrim(e->>'basis'),
                                       'follows_house', f, 'note', nullif(btrim(coalesce(e->>'note', '')), ''));
  end loop;
  unk := case when jsonb_typeof(p->'unknowns') = 'array' then p->'unknowns' else '[]'::jsonb end;
  select * into b from public.call_briefs where lead_id = lid for update;
  v := coalesce(b.version, 0) + 1;
  insert into public.call_briefs (lead_id, status, wanted_at, story, owed, unknowns, script, sources, to_clear, owed_total, written_by, written_at, version, updated_at)
  values (lid, 'ready', coalesce(b.wanted_at, now()), story, owed, unk, script, nullif(btrim(coalesce(p->>'sources', '')), ''),
          (select sum((x->>'amount')::numeric) from jsonb_array_elements(owed) x where x->>'follows_house' = 'yes'),
          (select sum((x->>'amount')::numeric) from jsonb_array_elements(owed) x),
          coalesce(nullif(btrim(p_agent), ''), 'agent'), now(), v, now())
  on conflict (lead_id) do update set status = 'ready', story = excluded.story, owed = excluded.owed, unknowns = excluded.unknowns, script = excluded.script,
         sources = excluded.sources, to_clear = excluded.to_clear, owed_total = excluded.owed_total, written_by = excluded.written_by,
         written_at = excluded.written_at, version = excluded.version, updated_at = now();
  insert into public.call_brief_versions (lead_id, version, story, owed, unknowns, script, sources, by)
  values (lid, v, story, owed, unk, script, nullif(btrim(coalesce(p->>'sources', '')), ''), coalesce(nullif(btrim(p_agent), ''), 'agent'));
  perform public.yes_sheet_to_task(lid);
  select * into b from public.call_briefs where lead_id = lid;
  return jsonb_build_object('ok', true, 'lead_id', lid, 'version', v, 'to_clear', b.to_clear, 'owed_total', b.owed_total, 'owed_line', public.call_brief_owed_line(b.owed));
end $fn$;
revoke all on function public.agent_call_brief_set(jsonb, text) from public, anon, authenticated;
grant execute on function public.agent_call_brief_set(jsonb, text) to service_role;

-- the cards waiting for one, the most pressing first, each with what the card already knows
create or replace function public.agent_call_briefs_wanted(p_limit integer default 20) returns jsonb
language sql stable security definer set search_path = public as $fn$
  select coalesce(jsonb_agg(x.j order by x.due_at), '[]'::jsonb) from (
    select b.due_at, jsonb_build_object('lead_id', l.id, 'owner_name', l.owner_name, 'address', l.property_address, 'municipality', l.municipality,
        'county', l.county, 'caller', public.room_name(public.card_caller(l.id)::text), 'wanted_by', b.wanted_by, 'why', b.wanted_why,
        'due_at', b.due_at, 'late', b.due_at < now(), 'reasons_to_sell', l.reasons_to_sell,
        'their_last_words', (select left(t.body, 400) from public.twilio_inbound t where t.lead_id = l.id and not coalesce(t.is_opt_out, false) order by t.received_at desc limit 1),
        'records', (select jsonb_build_object('value_used', e.value_used, 'value_source', e.value_source, 'tax_years_behind', e.tax_years_behind, 'tax_owed', e.tax_owed,
                      'judgment_amount', e.judgment_amount, 'in_rem_amount', e.in_rem_amount, 'mortgage_balance_est', e.mortgage_balance_est,
                      'mortgage_source', e.mortgage_source, 'last_sale_date', e.last_sale_date, 'last_sale_price', e.last_sale_price, 'equity_line', e.equity_line)
                    from public.equity_inputs e where e.lead_id = l.id limit 1),
        'comp', (select jsonb_build_object('arv', o.arv, 'sqft', o.sqft, 'lao', o.lao, 'mao', o.mao) from public.text_offers o where o.lead_id = l.id and o.status = 'open' limit 1)) as j
      from public.call_briefs b join public.leads l on l.id = b.lead_id
     where b.status = 'wanted' and not public.card_is_closed(l.stage)
     order by b.due_at limit least(greatest(coalesce(p_limit, 20), 1), 50)) x
$fn$;
revoke all on function public.agent_call_briefs_wanted(integer) from public, anon, authenticated;
grant execute on function public.agent_call_briefs_wanted(integer) to service_role;

create or replace function public.agent_call_brief_get(p_lead_id uuid) returns jsonb
language sql stable security definer set search_path = public as $fn$
  select coalesce((select jsonb_build_object('ok', true, 'lead_id', b.lead_id, 'status', b.status, 'due_at', b.due_at, 'story', b.story, 'owed', b.owed,
      'owed_line', public.call_brief_owed_line(b.owed), 'to_clear', b.to_clear, 'owed_total', b.owed_total, 'unknowns', b.unknowns, 'script', b.script,
      'sources', b.sources, 'written_by', b.written_by, 'written_at', b.written_at, 'version', b.version)
    from public.call_briefs b where b.lead_id = p_lead_id), jsonb_build_object('ok', true, 'status', 'none'))
$fn$;
revoke all on function public.agent_call_brief_get(uuid) from public, anon, authenticated;
grant execute on function public.agent_call_brief_get(uuid) to service_role;

-- ---------------------------------------------------------------- the call task says the story is there
-- the task's first lines: NUMBER (0266) and now STORY, each replaced in place when it changes
create or replace function public.yes_sheet_to_task(p_lead_id uuid) returns integer
language plpgsql security definer set search_path = public as $fn$
declare sheet text := public.yes_call_sheet(p_lead_id); b public.call_briefs; story text; head text; n integer;
begin
  select * into b from public.call_briefs where lead_id = p_lead_id;
  story := case
    when b.lead_id is null then null
    when b.status = 'ready' then 'STORY: ' || coalesce(public.call_brief_owed_line(b.owed) || ' ', '') || 'The full story and the script are on the card: read them before you dial.'
    when b.due_at >= now() then 'STORY: Muse is writing the story and a script for this call, on the card by ' || to_char(b.due_at at time zone 'America/Chicago', 'FMHH12:MI AM') || '.'
    else 'STORY: no story written yet. Ask what is owed on the house and to whom, and who has to sign.' end;
  head := concat_ws(E'\n', sheet, story);
  update public.tasks t
     set note = case when head = '' then regexp_replace(coalesce(t.note, ''), '^((NUMBER|STORY): [^\n]*\n)+', '')
                     else head || E'\n' || regexp_replace(coalesce(t.note, ''), '^((NUMBER|STORY): [^\n]*\n)+', '') end,
         updated_at = now()
   where t.lead_id = p_lead_id and t.done_at is null and t.source = 'belt' and t.title like 'Said yes%'
     and t.note is distinct from (case when head = '' then regexp_replace(coalesce(t.note, ''), '^((NUMBER|STORY): [^\n]*\n)+', '')
                                       else head || E'\n' || regexp_replace(coalesce(t.note, ''), '^((NUMBER|STORY): [^\n]*\n)+', '') end);
  get diagnostics n = row_count;
  return n;
end $fn$;
revoke all on function public.yes_sheet_to_task(uuid) from public, anon, authenticated;
grant execute on function public.yes_sheet_to_task(uuid) to service_role;

create or replace function public.yes_task_gets_sheet() returns trigger
language plpgsql security definer set search_path = public as $fn$
declare sheet text; b public.call_briefs; story text;
begin
  if new.lead_id is null or new.source is distinct from 'belt' or coalesce(new.title, '') not like 'Said yes%' then return new; end if;
  begin
    if coalesce(new.note, '') ~ '^(NUMBER|STORY): ' then return new; end if;
    sheet := public.yes_call_sheet(new.lead_id);
    select * into b from public.call_briefs where lead_id = new.lead_id;
    story := case
      when b.lead_id is null then null
      when b.status = 'ready' then 'STORY: ' || coalesce(public.call_brief_owed_line(b.owed) || ' ', '') || 'The full story and the script are on the card: read them before you dial.'
      when b.due_at >= now() then 'STORY: Muse is writing the story and a script for this call, on the card by ' || to_char(b.due_at at time zone 'America/Chicago', 'FMHH12:MI AM') || '.'
      else 'STORY: no story written yet. Ask what is owed on the house and to whom, and who has to sign.' end;
    if concat_ws(E'\n', sheet, story) <> '' then new.note := concat_ws(E'\n', sheet, story) || E'\n' || coalesce(new.note, ''); end if;
  exception when others then
    null;
  end;
  return new;
end $fn$;

-- ---------------------------------------------------------------- a yes asks for the story too
create or replace function public.yes_opens_comp() returns trigger
language plpgsql security definer set search_path = public as $fn$
declare r public.text_offer_rules; o public.text_offers; words text; ph text; due timestamptz;
begin
  begin
    if new.belt is distinct from 'yes_unbooked' or old.belt is not distinct from 'yes_unbooked' then return null; end if;
    if new.stage::text in ('dnc', 'dead', 'under_contract', 'closed_won') then return null; end if;
    select * into r from public.text_offer_rules where id = 1;
    due := now() + make_interval(mins => coalesce(r.yes_comp_minutes, 10));
    select * into o from public.text_offers where lead_id = new.id and status = 'open' order by opened_at desc limit 1;
    if found then
      -- an offer is already open (they asked for a number earlier): with no value yet, its comp is wanted now too
      if o.arv is null and (o.comp_due_at is null or o.comp_due_at > due) then
        update public.text_offers set comp_due_at = due, trigger = 'yes_to_selling' where id = o.id;
      end if;
    else
      select t.body, t.from10 into words, ph from public.twilio_inbound t
       where t.lead_id = new.id and not coalesce(t.is_opt_out, false) order by t.received_at desc limit 1;
      insert into public.text_offers (lead_id, opened_by, trigger, trigger_text, phone, comp_due_at)
      values (new.id, 'system', 'yes_to_selling', left(coalesce(nullif(btrim(words), ''), 'said yes'), 600), ph, due);
    end if;
    -- 0267: and the story and script for the call, after the comp
    perform public.call_brief_want(new.id, 'system', 'the seller said yes: a caller is about to phone them');
    perform public.yes_sheet_to_task(new.id);
  exception when others then
    null;                                          -- a card's move to "said yes" is never lost to this
  end;
  return null;
end $fn$;

-- the cards already on a yes: their stories are asked for after their comps, Tyler's first
do $$
declare c record; k integer := 0;
begin
  for c in
    select l.id, o.comp_due_at from public.leads l join public.text_offers o on o.lead_id = l.id and o.status = 'open' and o.trigger = 'yes_to_selling'
     where l.belt = 'yes_unbooked' and not public.card_is_closed(l.stage) and l.owner_name not ilike 'TEST %'
       and not exists (select 1 from public.call_briefs b where b.lead_id = l.id)
     order by o.comp_due_at
  loop
    k := k + 1;
    perform public.call_brief_want(c.id, 'system', 'the seller said yes: a caller is about to phone them', greatest(c.comp_due_at, now()) + interval '20 minutes');
    perform public.yes_sheet_to_task(c.id);
  end loop;
  raise notice 'stories asked for % card(s) already on a yes', k;
end $$;

-- ---------------------------------------------------------------- Muse is told on every tool call
CREATE OR REPLACE FUNCTION public.agent_attention(p_agent text, p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
declare
  who text := case when lower(coalesce(p_agent, '')) like 'muse 2%' then 'muse 2' when lower(coalesce(p_agent, '')) like 'muse%' then 'muse' else lower(coalesce(p_agent, '')) end;
  last_read timestamptz; unread integer := 0; latest text; steps jsonb := '[]'::jsonb; n_late integer := 0; out jsonb := '{}'::jsonb;
  d date := (p_now at time zone 'America/Chicago')::date;
  is_sunday boolean := extract(isodow from (p_now at time zone 'America/Chicago')::date) = 7;
  c public.campaign_control; opened boolean := false; n_replies integer := 0; oldest timestamptz; behind jsonb; room jsonb; n_briefs integer := 0; n_briefs_late integer := 0; brief_due timestamptz;
begin
  -- the desk: posts for this agent (or everyone) by someone else since it last read the desk
  select max(c2.at) into last_read from public.agent_calls c2 join public.agent_keys k on k.id = c2.key_id
   where lower(k.name) = lower(p_agent) and c2.tool = 'desk_inbox' and c2.ok;
  select count(*), (array_agg(m.topic order by m.id desc))[1] into unread, latest from public.desk_messages m
   where m.for_whom in (who, 'all') and m.author <> who and m.at > coalesce(last_read, p_now - interval '2 days') and m.at > p_now - interval '7 days';
  if unread > 0 then
    out := out || jsonb_build_object('desk', unread::text || ' post' || case when unread = 1 then '' else 's' end || ' for you on the desk since you last read it'
      || coalesce(' (' || to_char(last_read at time zone 'America/Chicago', 'Dy HH12:MI AM') || ' Central)', '') || ', the newest: "' || left(coalesce(latest, ''), 140) || '". Read desk_inbox now.');
  end if;
  -- the room (0259): lines from the desk, the other agent or Colin since this agent last read it
  if who in ('muse', 'muse 2') then
    room := public.room_unread(who);
    if (room ->> 'unread')::int > 0 then
      out := out || jsonb_build_object('room', (room ->> 'unread') || case when (room ->> 'unread')::int = 1 then ' new line' else ' new lines' end
        || ' in the room' || case when (room ->> 'for_you')::int > 0 then ' (' || (room ->> 'for_you') || ' to you by name)' else '' end
        || ', the newest from ' || coalesce(room ->> 'latest_by', '?') || ': "' || left(coalesce(room ->> 'latest', ''), 160) || '". Read chat_read now and answer with chat_post.');
    end if;
  end if;
  -- the story and script before a call (0267): cards a caller is about to phone with nothing written yet
  if who = 'muse' then
    select count(*), count(*) filter (where b.due_at < p_now), min(b.due_at) into n_briefs, n_briefs_late, brief_due
      from public.call_briefs b where b.status = 'wanted';
    if n_briefs > 0 then
      out := out || jsonb_build_object('briefs', n_briefs::text || ' card' || case when n_briefs = 1 then '' else 's' end
        || ' about to be called need the story and a script' || case when n_briefs_late > 0 then ' (' || n_briefs_late::text || ' late)' else '' end
        || ', the first due ' || to_char(brief_due at time zone 'America/Chicago', 'Dy FMHH12:MI AM')
        || ' Central. Read call_briefs_wanted, work out what is going on with each house and what the seller has to clear, and write it with call_brief_set.');
    end if;
  end if;
  if who = 'muse' then
    -- a Sunday that was opened (0240) says so here: the rules text says "never on Sunday" and nothing else tells the agent
    select * into c from public.campaign_control where id = 1;
    opened := is_sunday and c.sunday_open_day is not distinct from d;
    if opened then
      out := out || jsonb_build_object('sunday', 'Today is a Sunday that was opened for texting'
        || coalesce(' by ' || nullif(trim(c.sunday_open_by), ''), '') || coalesce(' (' || nullif(trim(c.sunday_open_why), '') || ')', '')
        || '. For today only the "never on Sunday" rule is off: work the day''s list and answer replies (replies_waiting, send_reply) as on a weekday, 10 AM to 7 PM in the owner''s time zone, under every other rule as it stands. It closes itself on Monday; a Sunday with no line like this one is shut.');
    end if;
    -- people who wrote back and have had no answer (not on a Sunday that is shut: nothing sends then)
    if not is_sunday or opened then
      select count(*), min(r.received_at) into n_replies, oldest from public.replies_waiting_rows(1) r
       where r.received_at < p_now - interval '20 minutes';
      if n_replies > 0 then
        out := out || jsonb_build_object('replies', n_replies::text || case when n_replies = 1 then ' person' else ' people' end
          || ' texted back in the last day and ' || case when n_replies = 1 then 'has' else 'have' end || ' had no answer, the oldest since '
          || to_char(oldest at time zone 'America/Chicago', 'Dy HH12:MI AM') || ' Central. Read replies_waiting now and answer each with send_reply; one that needs no answer (a wrong number, a house already sold) is closed with mark_card.');
      end if;
    end if;
    -- the offer path: steps that are this agent's (only the texting agent has them)
    select coalesce(jsonb_agg(jsonb_build_object('offer_id', o.id, 'lead_id', o.lead_id, 'address', l.property_address, 'step', v.j->>'step',
             'due_at', v.j->>'due_at', 'late', (v.j->>'late')::boolean, 'do', v.j->>'say') order by v.j->>'due_at'), '[]'::jsonb),
           count(*) filter (where (v.j->>'late')::boolean)
      into steps, n_late
      from public.text_offers o join public.leads l on l.id = o.lead_id cross join lateral (select public.text_offer_view(o, p_now) as j) v
     where o.status = 'open' and v.j->>'who' = 'muse';
    if jsonb_array_length(steps) > 0 then
      out := out || jsonb_build_object('offers', jsonb_build_object(
        'say', jsonb_array_length(steps)::text || ' seller' || case when jsonb_array_length(steps) = 1 then '' else 's' end || ' asked for a number and the next step is yours'
               || case when n_late > 0 then ' (' || n_late::text || ' late)' else '' end
               || '. Each row says what to do; record it with offer_update, and read offer_worklist for the whole list. If those tools are not in your tool list, list the tools again or start a new session: they were added on 2026-11-13. The how is in texting_rules ("The offer by text") and desk post 254.',
        'steps', steps));
    end if;
    -- the Research Board (0248): jobs with no tick for two whole weeks
    select public.research_behind(p_now) into behind;
    if jsonb_array_length(behind) > 0 then
      out := out || jsonb_build_object('research', jsonb_build_object(
        'say', jsonb_array_length(behind)::text || ' research job' || case when jsonb_array_length(behind) = 1 then ' has' else 's have' end
               || ' had no tick on the Research Board for more than two weeks. The board is weekly now: run each one end to end (pull, verification, cards in WPIE) and tick the week with research_board_set (job, done true, a note saying what ran; leave week out for this week). A job that cannot run gets a status saying what blocks it, not a tick. Colin is told about this list every Monday.',
        'behind', behind));
    end if;
  end if;
  return case when out = '{}'::jsonb then null else out end;
end $fn$;
