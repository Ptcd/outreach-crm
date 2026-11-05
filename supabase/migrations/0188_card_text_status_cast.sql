-- 0188: a text from the card failed for Adil on 2026-11-04 with "invalid input value for enum contact_status: ''":
-- start_card_text compared the phone's status with coalesce(c.status, '') and the empty string cannot be cast to the
-- enum. 'is distinct from' says the same thing without the cast.

CREATE OR REPLACE FUNCTION public.start_card_text(p_lead_id uuid, p_phone text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  l public.leads;
  p text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10);
  ours text;
  id uuid;
begin
  if not public.is_team() then raise exception 'not on the team'; end if;
  select * into l from public.leads where leads.id = p_lead_id;
  if not found then raise exception 'no such card'; end if;
  if l.stage = 'dnc' then raise exception 'this card is closed (do not contact)'; end if;
  if p !~ '^[2-9][0-9]{9}$' then raise exception 'not a phone number'; end if;
  if not exists (select 1 from public.contacts c where c.lead_id = p_lead_id and c.kind = 'phone'
                  and right(regexp_replace(coalesce(c.value_normalized, c.value), '\D', '', 'g'), 10) = p
                  and not coalesce(c.dnc_app, false) and c.status is distinct from 'bad') then
    raise exception 'that phone is not on this card';
  end if;
  if exists (select 1 from public.suppressed_phones s where s.phone10 = p) then raise exception 'this phone opted out'; end if;
  -- our side of the latest text with this phone, else the latest number we texted the card from
  select case when m.direction = 'out' then m.from_number else m.to_number end into ours
    from public.messages m
   where m.lead_id = p_lead_id and m.channel = 'sms'
     and right(regexp_replace(coalesce(case when m.direction = 'out' then m.to_number else m.from_number end, ''), '\D', '', 'g'), 10) = p
   order by m.sent_at desc limit 1;
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
end $function$;
