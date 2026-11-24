-- 0316: the assistant answers a Spanish-speaking seller in Spanish, and a seller does not ring 45 seconds into an empty room.
--
-- Colin 2026-11-24, after Juan (3524 Buckingham Rd, Sturtevant) called back at 11:12 and hung up on the assistant in five
-- seconds: every text in that thread since Nov 19 was in Spanish, and the assistant opened in English with "the automated
-- assistant for Colin's team" after 45 seconds of ringing nobody was there to answer. Of 21 calls the assistant took since
-- Nov 8, 17 were hang-ups, 14 inside 15 seconds. "Sure" to: Spanish when the card's thread is Spanish, open with the house,
-- and ring less when nobody is working.
--
--   phone_lang(digits)       'es' when most of the last texts with that phone, either way, read as Spanish; else 'en'.
--   callers_working(at)      a caller is inside their hours (caller_call_hours) and not off that day.
--   inbound_call_ring        the card carries lang; the answer carries staffed (the phone server rings 15 s, not 45, when false).

-- a text is Spanish when it has more Spanish words than English ones (short texts count: "Por favor", "Te daré 500$")
create or replace function public.text_is_spanish(p_body text) returns boolean language sql immutable as $fn$
  with w as (select x from regexp_split_to_table(lower(coalesce(p_body, '')), '[^[:alpha:]]+') x where x <> '')
  select (select count(*) from w where x = any (array['hola','gracias','casa','quiero','tengo','usted','ustedes','estoy','soy','eres',
            'vender','vendo','verdad','solo','nada','favor','papá','mamá','cuánto','cuanto','bueno','también','tambien','perdón',
            'mañana','número','numero','llamar','hablar','hablo','contigo','cuando','porque','pero','está','esta','esa','ese','qué',
            'sí','si','los','las','una','del','con','para','por','como','cómo','señor','señora','dime','daré','voy','vas','hacer',
            'tu','te','mi','que','el','la','es','de','y','lo','le','yo','muy','más','mas','aquí','bien','buenas','buenos','días']))
       > greatest(0, (select count(*) from w where x = any (array['the','you','is','are','i','my','it','not','and','to','of','for',
            'yes','what','house','sell','call','this','that','have','we','your','who','me','please','thanks','thank','no','do',
            'stop','home','property','wrong','number','sorry','in','on','at','be','will','can','just','would','am',
            -- French shares tu / es / de / la; its own words keep a French thread from reading as Spanish
            'vous','je','pas','qui','est','une','rien','des','gens','avec','autre','nous','mais','oui'])))
$fn$;

create or replace function public.phone_lang(p_digits text) returns text
language sql stable security definer set search_path = public as $fn$
  with d as (select right(regexp_replace(coalesce(p_digits, ''), '\D', '', 'g'), 10) as ph),
  t as (
    select body, at from (
      select d2.inbound_body as body, d2.inbound_at as at from public.reply_drafts d2, d
       where d2.phone10 = d.ph and d.ph <> '' and coalesce(btrim(d2.inbound_body), '') <> ''
      union all
      select m.body, m.sent_at from public.messages m, d
       where m.channel = 'sms' and d.ph <> '' and coalesce(btrim(m.body), '') <> ''
         and (right(regexp_replace(coalesce(m.to_number, ''), '\D', '', 'g'), 10) = d.ph
              or right(regexp_replace(coalesce(m.from_number, ''), '\D', '', 'g'), 10) = d.ph)) x
     order by at desc nulls last limit 8)
  select case when count(*) >= 2 and count(*) filter (where public.text_is_spanish(body)) * 2 >= count(*) then 'es' else 'en' end from t
$fn$;

create or replace function public.callers_working(p_at timestamptz default now()) returns boolean
language sql stable security definer set search_path = public as $fn$
  select exists (
    select 1 from public.caller_call_hours h
     where extract(isodow from p_at at time zone 'America/Chicago')::int = any (h.days)
       and (p_at at time zone 'America/Chicago')::time >= h.t_from and (p_at at time zone 'America/Chicago')::time < h.t_to
       and not public.caller_is_off(h.person, (p_at at time zone 'America/Chicago')::date))
$fn$;

create or replace function public.inbound_call_ring(p_digits text, p_at timestamp with time zone default now())
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  with d as (select right(regexp_replace(coalesce(p_digits, ''), '\D', '', 'g'), 10) as ph),
  last_dialer as (
    select lower(e.by) as who from public.belt_events e, d
     where e.event = 'human_call_started' and e.at > p_at - interval '60 minutes' and e.at <= p_at
       and right(regexp_replace(coalesce(e.payload->>'phone', ''), '\D', '', 'g'), 10) = d.ph and d.ph <> ''
       and lower(e.by) in ('thalia', 'adil', 'colin')
     order by e.at desc limit 1),
  card as (
    select l.id, l.owner_name, l.property_address, l.municipality, l.locked_to::text as who
      from public.contacts c join public.leads l on l.id = c.lead_id, d
     where c.kind = 'phone' and c.value_normalized = d.ph and d.ph <> ''
     order by (l.locked_to is not null) desc, l.locked_at desc nulls last limit 1),
  locked as (select who from card where who in ('thalia', 'adil', 'colin')),
  shift as (select public.on_shift_person(p_at)::text as who,
                   extract(isodow from p_at at time zone 'America/Chicago') between 1 and 5
                   and (p_at at time zone 'America/Chicago')::time >= time '16:00' and (p_at at time zone 'America/Chicago')::time < time '18:00' as power_hour),
  ring as (
    select case
      when (select who from last_dialer) is not null and (select who from locked) is distinct from 'colin' then array[(select who from last_dialer)]
      when (select who from locked) is not null then array[(select who from locked)]
      when (select power_hour from shift) then array['thalia', 'adil']
      when (select who from shift) = 'colin' then array['colin', 'thalia', 'adil']
      else array[(select who from shift)] end as who)
  select jsonb_build_object(
    'ring', to_jsonb((select who from ring)),
    'return_call', (select who from last_dialer) is not null and (select who from locked) is distinct from 'colin',
    'locked_to', (select who from locked),
    'dialed_by', (select who from last_dialer),
    -- 0316: a return call means someone was just dialing; otherwise a caller inside their hours
    'staffed', (select who from last_dialer) is not null or public.callers_working(p_at),
    'whatsapp', (select coalesce(jsonb_object_agg(m.person::text, m.alert_whatsapp), '{}'::jsonb)
                   from public.team_members m where m.person::text in (select unnest(r.who) from ring r) and m.alert_whatsapp is not null),
    'card', (select jsonb_build_object('lead_id', c.id, 'owner_name', c.owner_name, 'address', c.property_address, 'municipality', c.municipality,
                                       'lang', public.phone_lang(p_digits)) from card c))
$function$;

revoke all on function public.phone_lang(text), public.callers_working(timestamptz) from public, anon, authenticated;
grant execute on function public.phone_lang(text), public.callers_working(timestamptz) to service_role;
