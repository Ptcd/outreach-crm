-- 0289: an estate card is never greeted by name. Found on the first real run (74 Pioneer Ct, 2026-11-22): three
-- texts opened "Hi Russel" while the card's own probate note named Russel as the one who died. Across the open cards,
-- 113 have a text that greeted the person their probate note names, and 108 of those were still in the texting stages.
-- Marking those people deceased from the notes in bulk would get some living owners wrong (a probate for "Steven
-- Hall" sits on a card owned by "Shawn Steven Hall"), so the rule is on the greeting instead, where a wrong guess
-- costs nothing: a card with an estate or probate reason, or with anyone on it marked deceased, is written "Hi there"
-- and asked for the right person, never "are you the current owner".
--   * card_is_estate(lead): the test, used by the day's texts and by the sale text.
--   * A caller's card says so too (the page reads the same test through card_brief's reasons and the people list).

create or replace function public.card_is_estate(p_lead_id uuid) returns boolean
language sql stable security definer set search_path = public as $fn$
  select exists (select 1 from public.leads l where l.id = p_lead_id
                   and array_to_string(l.reasons_to_sell, ' ') ~* '(probate|estate|owner died|deceased|inherit)')
      or exists (select 1 from public.interests i where i.lead_id = p_lead_id and i.status = 'deceased')
$fn$;
revoke all on function public.card_is_estate(uuid) from public, anon;
grant execute on function public.card_is_estate(uuid) to authenticated, service_role;

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

CREATE OR REPLACE FUNCTION public.sale_first_text(p_lead_id uuid, p_voice text, p_day date)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select 'Hi ' || case when public.card_is_estate(l.id) then 'there' else public.text_first_name(l.owner_name) end || ', ' || coalesce(nullif(btrim(p_voice), ''), 'Thalia') || ' here about '
         || initcap(btrim(l.property_address)) || '. I know a sale date may be coming up. If selling before then and walking away with something would help, I''d like to talk. Would you be open to that? Reply STOP to opt out.'
    from public.leads l join public.card_sale_dates s on s.lead_id = l.id
   where l.id = p_lead_id and s.sale_date >= p_day + 14 and coalesce(btrim(l.property_address), '') <> ''
$function$;
