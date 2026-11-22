-- 0300: three first texts tested against each other, in the one place a first text is written.
-- Colin 2026-11-22 pasted them: A "Do you still own the house on {Street} in {City}?", B "I'm a local buyer looking
-- around {City}. Would you ever consider selling the house on {Street}?", C "Are you the right person to talk to about
-- the house on {Street} in {City}? No rush at all." All with the caller's name and a STOP line, a street name in normal
-- case with no house number, the town, and at most 160 characters.
-- Thirty days of the current wording ("Are you the current owner of 515 KASE ST?"): 68% delivered, and of those 19%
-- answer, 13% say STOP and 1.9% open up. The server writes the day's first texts (text_day_backstop), so the test is
-- there and nowhere else: an agent that also queued them would only be refused as already planned.
-- campaign_control.opener_test switches it; off as shipped. The arm is on the text (variant OA / OB / OC, template
-- opener_test_1) and tools/opener_test.py reads the result.

alter table public.campaign_control add column if not exists opener_test boolean not null default false;

-- "33 S CONCORD RD" -> "S Concord Rd"; nothing when there is a unit or no street name to say
create or replace function public.text_street_name(p_address text) returns text
language plpgsql immutable as $fn$
declare a text := btrim(regexp_replace(coalesce(p_address, ''), '\s+', ' ', 'g')); s text;
begin
  if a = '' or a ~* '(\m(unit|apt|apartment|ste|suite|lot|bldg|trlr)\M|#)' then return null; end if;
  -- the house number: 515, 91E, 2825-2827, W5436, N52W37031, "S 7325"
  s := regexp_replace(a, '^(([NSEW] ?[0-9]+ ?([NSEW] ?[0-9]+)?)|([0-9]+[A-Za-z]?(-[0-9]+)?( ?1/2)?))\s+', '', 'i');
  if s = a or s = '' or s !~ '[A-Za-z]' then return null; end if;
  s := public.belt_street(s);
  s := regexp_replace(s, '^(Sth|Ush|Hwy|Sr|Us Hwy|State Hwy|Us)\s+([0-9]+)$', 'Hwy \2', 'i');
  s := regexp_replace(s, '^(Cth|Cty Hwy|Cty Rd|Co Rd|Cty Trk|Ctth)\s+([A-Za-z]{1,3})$', 'County Rd \2', 'i');
  if s ~* '^County Rd ' then s := 'County Rd ' || upper(substring(s from 11)); end if;
  s := regexp_replace(s, '^Us ', 'US ');
  if length(s) < 3 or length(s) > 40 or s ~ '[0-9]{5}' then return null; end if;      -- a town or a ZIP run into the street
  return s;
end $fn$;

-- "CITY OF OSHKOSH" -> "Oshkosh"; "Fond Du Lac" -> "Fond du Lac"; nothing when there is no town on the card
create or replace function public.text_city(p_municipality text) returns text
language plpgsql immutable as $fn$
declare m text := btrim(regexp_replace(coalesce(p_municipality, ''), '\s+', ' ', 'g'));
begin
  m := regexp_replace(m, '^(city|village|town|township|c|v|t) of ', '', 'i');
  m := regexp_replace(m, '\s*\((city|village|town)\)$', '', 'i');
  if m = '' or m ~ '[0-9]' or length(m) > 30 then return null; end if;
  m := initcap(lower(m));
  m := replace(replace(m, ' Du ', ' du '), ' Of ', ' of ');
  m := regexp_replace(m, '^Mt\.? ', 'Mt ');
  if m ~ '^Mc[a-z]' then m := 'Mc' || upper(substr(m, 3, 1)) || substr(m, 4); end if;
  return m;
end $fn$;

CREATE OR REPLACE FUNCTION public.text_day_backstop(p_now timestamp with time zone DEFAULT now(), p_limit integer DEFAULT 150)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  estate   boolean := false;
  c        public.campaign_control;
  d        date := (p_now at time zone 'America/Chicago')::date;
  r        record;
  body     text;
  nm       text;
  variant  text;
  tmpl     text;
  res      jsonb;
  ok       integer := 0;
  no       jsonb := '{}'::jsonb;
  why      text;
  ws       timestamptz;
  stop_at  timestamptz;
  start_at timestamptz;
  last_at  timestamptz;
  left_n   integer;
  gap      integer;
  k        integer;
  st       text;
  city     text;
  arm      integer;
  tb       text;
begin
  select * into c from public.campaign_control where id = 1;
  if not coalesce(c.day_backstop, false) then return jsonb_build_object('ran', false, 'why', 'the backstop is off'); end if;
  if coalesce(c.paused, false) then return jsonb_build_object('ran', false, 'why', 'texting is paused'); end if;
  if (p_now at time zone 'America/Chicago')::time < c.day_backstop_after then return jsonb_build_object('ran', false, 'why', 'before the backstop hour'); end if;
  ws := (d + c.window_start) at time zone c.timezone;
  stop_at := (d + c.window_end) at time zone c.timezone - interval '50 minutes';

  drop table if exists _day_rows;
  create temp table _day_rows on commit drop as
    select t.lead_id, t.step, t.kind, t.phone, t.voice, t.ord, btrim(l.property_address) as address, l.owner_name, coalesce(l.owner_type, '') as owner_type,
           (select ct.person_name from public.contacts ct where ct.lead_id = t.lead_id and ct.value_normalized = t.phone limit 1) as person_name
      from public.text_day t join public.leads l on l.id = t.lead_id
     -- text 5 has no settled wording, and a first text to someone we have texted before (another card, another
     -- number) takes no intro: those rows wait for a person or the sender agent
     where t.day = d and coalesce(btrim(l.property_address), '') <> ''
       and t.step <= 4 and t.server_note is null
       and not (t.step = 1 and t.kind <> 'next_number' and public.card_texted_before(t.lead_id))
       and not exists (select 1 from public.planned_openers po where po.lead_id = t.lead_id and po.step = t.step
                        and right(regexp_replace(po.phone, '\D', '', 'g'), 10) = t.phone
                        and po.send_status in ('planned', 'would_send', 'sending', 'sent', 'delivered', 'undelivered', 'failed', 'uncertain'));
  select count(*) into left_n from _day_rows;
  if left_n = 0 then return jsonb_build_object('ran', true, 'queued', 0, 'left', 0); end if;

  -- the drip: what is left, spread evenly over what is left of the window, after the last text the server itself has
  -- waiting (a text someone else queued for later in the day does not hold the drip up)
  select max(po.scheduled_at) into last_at from public.planned_openers po
   where po.plan_date = d and po.lane = 'agent' and po.send_status in ('planned', 'would_send') and po.decided_by_name = 'Muse (the day)';
  start_at := greatest(p_now + interval '30 seconds', ws, coalesce(last_at + interval '20 seconds', ws));
  if start_at >= stop_at then return jsonb_build_object('ran', false, 'why', 'the sending window is closing', 'left', left_n); end if;
  gap := least(180, greatest(20, floor(extract(epoch from (stop_at - start_at)) / left_n)))::int;
  k := case when start_at > p_now + interval '20 minutes' then 0
            else least(left_n, greatest(1, p_limit), floor(extract(epoch from (p_now + interval '20 minutes' - start_at)) / gap)::int + 1) end;

  for r in select * from _day_rows order by ord limit k loop
    nm := public.text_first_name(coalesce(r.person_name, r.owner_name));
    -- 0289: an estate card is never greeted by name. The name on the record is very often the person who died
    estate := public.card_is_estate(r.lead_id);
    if estate then nm := 'there'; end if;
    variant := case r.step when 1 then 'V4' when 2 then 'G' when 3 then 'F3' else 'F4' end;
    tmpl := 'day_backstop';
    body := case when r.step = 1 then public.sale_first_text(r.lead_id, r.voice, d) end;
    if body is not null then
      variant := 'S'; tmpl := 'sale_date';
    else
      body := case
        when r.step = 1 and (nm = 'there' or nm <> public.text_first_name(r.owner_name) or r.owner_type in ('llc', 'trust', 'estate', 'corporation', 'entity'))
          then 'Hi ' || nm || ', this is ' || r.voice || '. Are you the right person to ask about ' || r.address || '? Reply STOP to opt out.'
        when r.step = 1 then 'Hi ' || nm || ', this is ' || r.voice || '. Are you the current owner of ' || r.address || '? Reply STOP to opt out.'
        when r.step = 2 and estate then 'Hi there, ' || r.voice || ' again about ' || r.address || '. Just checking I have the right person for it.'
        when r.step = 2 then 'Hi ' || nm || ', ' || r.voice || ' again about ' || r.address || '. Still the owner there? Just checking I have the right place.'
        when r.step = 3 then 'Hi ' || nm || ', ' || r.voice || ' again, following up on ' || r.address || '. Is this still the best number to reach you at?'
        else 'Hi ' || nm || ', ' || r.voice || ' again. Just checking in about ' || r.address || '. Is this still a good number for you?' end;
    end if;
    -- 0300: the opener test (Colin 2026-11-22). Only a first text to a living owner by name, at a plain house address in
    -- a named town; an estate, a company, a sale date, a unit and a next number keep the wording they had. The arm is
    -- fixed by the card, so a card written twice gets the same text.
    if coalesce(c.opener_test, false) and r.step = 1 and r.kind <> 'next_number' and variant = 'V4' and not estate and nm <> 'there'
       and nm = public.text_first_name(r.owner_name) and r.owner_type not in ('llc', 'trust', 'estate', 'corporation', 'entity') then
      st := public.text_street_name(r.address);
      select public.text_city(l.municipality) into city from public.leads l where l.id = r.lead_id;
      if st is not null and city is not null then
        arm := abs(hashtext(r.lead_id::text)) % 3;
        tb := case arm
          when 0 then 'Hi ' || nm || ', this is ' || r.voice || '. Do you still own the house on ' || st || ' in ' || city || '? Reply STOP to opt out.'
          when 1 then 'Hi ' || nm || ', ' || r.voice || ' here. I''m a local buyer looking around ' || city || '. Would you ever consider selling the house on ' || st || '? Reply STOP to opt out.'
          else 'Hi ' || nm || ', this is ' || r.voice || '. Are you the right person to talk to about the house on ' || st || ' in ' || city || '? No rush at all. Reply STOP to opt out.' end;
        if length(tb) <= 160 then
          body := tb; variant := case arm when 0 then 'OA' when 1 then 'OB' else 'OC' end; tmpl := 'opener_test_1';
        end if;
      end if;
    end if;
    res := public.agent_queue_text(r.lead_id, r.phone, body, r.step, start_at + make_interval(secs => gap * ok), 'the day', p_now, variant, tmpl, null, null);
    if res ->> 'status' = 'queued' then ok := ok + 1;
    else
      why := left(coalesce(res ->> 'reason', 'refused'), 200);
      update public.text_day set server_note = why where day = d and lead_id = r.lead_id and step = r.step;
      why := left(why, 60);
      no := no || jsonb_build_object(why, coalesce((no ->> why)::int, 0) + 1);
    end if;
  end loop;
  if ok > 0 or no <> '{}'::jsonb then
    insert into public.text_day_runs (day, at, kind, summary)
    values (d, p_now, 'backstop', jsonb_build_object('queued', ok, 'refused', no, 'left', left_n - ok, 'seconds_apart', gap));
  end if;
  return jsonb_build_object('ran', true, 'queued', ok, 'refused', no, 'left', left_n - ok, 'seconds_apart', gap);
end $function$;
