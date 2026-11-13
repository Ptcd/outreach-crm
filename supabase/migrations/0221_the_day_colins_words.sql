-- The day (0219): the name and intro rules, corrected to Colin's own rulings once they were on the desk (post 198,
-- Muse's record of 2026-11-10; 0219 had encoded them from a summary).
--
--   1. "One name per seller ... it follows the person across all their cards and numbers." 0219 kept the name per
--      CARD. card_voice now reads the texts sent to any phone on the card and to any other phone of the same people,
--      on any card.
--   2. "it also only needs to contain the intro on the first text to a person": never repeated on a follow-up or on a
--      first text to that person's next number. 0219 required the intro on every step 1, which would have refused a
--      correct next-number text. It is now required only when nobody on the card has had a text from us.
--   3. The backstop no longer writes a first text to anyone we have texted before (a next number, a second card):
--      its only first-text wording carries the intro.
-- Unchanged: a text signed with another name than the thread's is refused; a first text to a number carries the STOP
-- line; a follow-up carries none. Where a thread already shows two names, the name stays the one the seller saw last,
-- so nobody sees another change.

-- every phone of the people on this card: the card's own, and the same people's phones on other cards
create or replace function public.card_person_phones(p_lead_id uuid) returns setof text
language sql stable security definer set search_path = public as $$
  select c.value_normalized from public.contacts c where c.lead_id = p_lead_id and c.kind = 'phone' and c.value_normalized is not null
  union
  select c2.value_normalized from public.contacts c join public.contacts c2 on c2.person_id = c.person_id and c2.kind = 'phone'
   where c.lead_id = p_lead_id and c.person_id is not null and c2.value_normalized is not null
$$;

-- has anyone on this card had a text from us, on this card or another
create or replace function public.card_texted_before(p_lead_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.messages m
     where m.direction = 'out' and m.channel = 'sms' and m.provider_sid is not null
       and coalesce(m.status, '') not in ('undelivered', 'failed')
       and (m.lead_id = p_lead_id or m.to_number in (select '+1' || p from public.card_person_phones(p_lead_id) p)))
$$;

create or replace function public.card_voice(p_lead_id uuid) returns text language sql stable security definer set search_path = public as $$
  select coalesce(
    (select public.text_speaker(m.body) from public.messages m
      where m.direction = 'out' and m.channel = 'sms' and m.provider_sid is not null
        and (m.lead_id = p_lead_id or m.to_number in (select '+1' || p from public.card_person_phones(p_lead_id) p))
        and public.text_speaker(m.body) is not null
      order by m.sent_at desc nulls last limit 1),
    (select split_part(tm.display_name, ' ', 1) from public.team_members tm join public.leads l on l.locked_to = tm.person
      where l.id = p_lead_id and coalesce(tm.display_name, '') <> '' limit 1),
    'Thalia')
$$;

create or replace function public.text_rule_problem(p_lead_id uuid, p_body text, p_step integer, p_now timestamptz default now())
returns text language plpgsql stable security definer set search_path = public as $$
declare
  voice text;
  other text;
  rb    text;
begin
  if not coalesce((select cc.day_rules_on from public.campaign_control cc where cc.id = 1), true) then return null; end if;
  voice := public.card_voice(p_lead_id);
  select k.name into other from public.text_voices() k(name)
   where lower(k.name) <> lower(voice)
     and (coalesce(p_body, '') ~* ('(this is|this|my name is|it''s|its)\s+' || k.name || '\M')
          or coalesce(p_body, '') ~* ('\m' || k.name || '\s+(here|again)\M'))
   limit 1;
  if other is not null then
    return 'this person hears from ' || voice || ', not ' || other || ': one name per seller, across their cards and numbers (Colin 2026-11-10)';
  end if;
  if coalesce(p_step, 1) = 0 then return null; end if;
  -- the intro belongs on the first text to a person, and only there (Colin 2026-11-10)
  if coalesce(p_step, 1) = 1 and public.text_speaker(p_body) is null and not public.card_texted_before(p_lead_id) then
    return 'the first text to a person says who is writing: this card speaks as ' || voice;
  end if;
  if coalesce(p_step, 1) > 1 and position('STOP' in coalesce(p_body, '')) > 0 then
    return 'a follow-up carries no STOP line: only a first text to a number does (Colin 2026-11-10)';
  end if;
  rb := public.card_record_block(p_lead_id, (p_now at time zone 'America/Chicago')::date);
  if rb is not null then
    return 'the records say no text for this card: ' || rb
           || case rb when 'want_not_need' then ' (a want is not a need: Colin 2026-11-07)'
                      when 'actively_listed' then ' (a listed property is not a lead)'
                      when 'sheriff_sale_inside_14d' then ' (a sale inside 14 days is not a lead)'
                      when 'record_verdict_stale' then ' (the laptop has not judged this card in a week)'
                      when 'no_record_verdict' then ' (the laptop has no record verdict for this owner)'
                      else '' end;
  end if;
  return null;
end $$;

create or replace function public.text_day_backstop(p_now timestamptz default now(), p_limit integer default 150) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  c    public.campaign_control;
  d    date := (p_now at time zone 'America/Chicago')::date;
  r    record;
  body text;
  nm   text;
  res  jsonb;
  ok   integer := 0;
  no   jsonb := '{}'::jsonb;
  why  text;
begin
  select * into c from public.campaign_control where id = 1;
  if not coalesce(c.day_backstop, false) then return jsonb_build_object('ran', false, 'why', 'the backstop is off'); end if;
  if (p_now at time zone 'America/Chicago')::time < c.day_backstop_after then return jsonb_build_object('ran', false, 'why', 'before the backstop hour'); end if;
  for r in
    select t.*, l.property_address, l.owner_name,
           (select ct.person_name from public.contacts ct where ct.lead_id = t.lead_id and ct.value_normalized = t.phone limit 1) as person_name
      from public.text_day t join public.leads l on l.id = t.lead_id
     -- first texts to a new person and follow-ups 2 and 3 only: the next number, and texts 4 and 5, have no settled wording
     where t.day = d and t.step <= 3 and t.kind <> 'next_number' and coalesce(btrim(l.property_address), '') <> ''
       -- a first text to someone we have texted before (another card, another number) takes no intro, and the settled
       -- first-text wording is the intro: those rows wait for a person to write them
       and not (t.step = 1 and public.card_texted_before(t.lead_id))
       and not exists (select 1 from public.planned_openers po where po.lead_id = t.lead_id and po.step = t.step
                        and right(regexp_replace(po.phone, '\D', '', 'g'), 10) = t.phone
                        and po.send_status in ('planned', 'would_send', 'sending', 'sent', 'delivered', 'undelivered', 'failed', 'uncertain'))
     order by t.ord limit greatest(1, least(p_limit, 400))
  loop
    nm := public.text_first_name(coalesce(r.person_name, r.owner_name));
    body := case
      when r.step = 1 and nm = 'there' then 'Hi there, this is ' || r.voice || '. Are you the right person to ask about ' || btrim(r.property_address) || '? Reply STOP to opt out.'
      when r.step = 1 then 'Hi ' || nm || ', this is ' || r.voice || '. Are you the current owner of ' || btrim(r.property_address) || '? Reply STOP to opt out.'
      when r.step = 2 then 'Hi ' || nm || ', ' || r.voice || ' again about ' || btrim(r.property_address) || '. Still the owner there? Just checking I have the right place.'
      else 'Hi ' || nm || ', ' || r.voice || ' again, following up on ' || btrim(r.property_address) || '. Is this still the best number to reach you at?' end;
    res := public.agent_queue_text(r.lead_id, r.phone, body, r.step, null, 'the day', p_now,
                                   case r.step when 1 then 'V4' when 2 then 'G' else 'F3' end, 'day_backstop', null, null);
    if res ->> 'status' = 'queued' then ok := ok + 1;
    else
      why := left(coalesce(res ->> 'reason', 'refused'), 60);
      no := no || jsonb_build_object(why, coalesce((no ->> why)::int, 0) + 1);
    end if;
  end loop;
  insert into public.text_day_runs (day, at, kind, summary) values (d, p_now, 'backstop', jsonb_build_object('queued', ok, 'refused', no));
  return jsonb_build_object('ran', true, 'queued', ok, 'refused', no);
end $$;

revoke all on function public.card_person_phones(uuid), public.card_texted_before(uuid), public.card_voice(uuid),
  public.text_rule_problem(uuid, text, integer, timestamptz), public.text_day_backstop(timestamptz, integer) from public, anon, authenticated;
grant execute on function public.card_person_phones(uuid), public.card_texted_before(uuid), public.card_voice(uuid),
  public.text_rule_problem(uuid, text, integer, timestamptz), public.text_day_backstop(timestamptz, integer) to service_role;
grant execute on function public.card_voice(uuid) to authenticated;
