-- 0152: the next number after a closed conversation (Colin 2026-10-31). The Lammey card was refused a first text
-- to its next number because a prank number had replied, so the card sat in ai_qualifying; next_phone_problem only
-- allowed four early stages. Any open stage now qualifies when every reply came from a closed (bad) phone, and a call
-- that reached someone on a good phone refuses, so a real conversation is never talked over by a new first text.

-- next_phone_problem: from 0084_door_interests.sql
CREATE OR REPLACE FUNCTION public.next_phone_problem(p_lead_id uuid, p_phone10 text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  l      public.leads;
  phones text[];
  bad    text[];
  firsts integer;
begin
  select * into l from public.leads where id = p_lead_id;
  if not found then return 'no such card'; end if;
  -- 0152 (Colin 2026-10-31: "when a number is closed, the next number in line gets texted"): a card that is talking
  -- only because the WRONG person answered (a prank number, a stranger) is open for the next phone too; the checks
  -- below still refuse whenever a good phone replied or was reached by a call. Closed or booked cards never.
  if l.stage::text in ('dnc', 'dead', 'closed_no_contact', 'closed_won', 'under_contract', 'walkthrough_booked', 'offer') then
    return 'a first text is for a new card';
  end if;
  select coalesce(array_agg(distinct ct.value_normalized), '{}'),
         coalesce(array_agg(distinct ct.value_normalized) filter (where ct.status::text in ('bad', 'dead')), '{}')
    into phones, bad
    from public.contacts ct join public.leads ll on ll.id = ct.lead_id
   where ll.wpie_owner_id = l.wpie_owner_id and ct.kind = 'phone' and ct.value_normalized is not null;
  -- a phone whose people on this card are all closed (deceased, do not contact, not the contact) is done with, like a
  -- bad one: the next person on the card may have their first text (0083, one person at a time)
  bad := bad || coalesce((select array_agg(distinct ct.value_normalized) from public.contacts ct
     where ct.lead_id = p_lead_id and ct.kind = 'phone' and ct.person_id is not null
       and not exists (select 1 from public.contacts c2 join public.interests i on i.person_id = c2.person_id and i.lead_id = p_lead_id
                         join public.people pe on pe.id = c2.person_id
                        where c2.lead_id = p_lead_id and c2.value_normalized = ct.value_normalized and i.status = 'active' and pe.status = 'active')), '{}');
  with f as (
    select right(regexp_replace(p.phone, '\D', '', 'g'), 10) ph, p.send_status st from public.planned_openers p
     where p.wpie_owner_id = l.wpie_owner_id and p.step = 1 and p.send_status = any(public.opener_live_statuses())
    union all
    select right(regexp_replace(m.to_number, '\D', '', 'g'), 10), m.status from public.messages m
     where m.lead_id = p_lead_id and m.direction = 'out' and m.is_opener and m.provider_sid is not null)
  select count(*) into firsts from f;
  if firsts = 0 then return 'a first text is for a new card'; end if;
  if exists (select 1 from public.planned_openers p where p.wpie_owner_id = l.wpie_owner_id and p.step = 1
               and p.send_status = any(public.opener_live_statuses()) and right(regexp_replace(p.phone, '\D', '', 'g'), 10) = p_phone10)
     or exists (select 1 from public.messages m where m.lead_id = p_lead_id and m.direction = 'out' and m.is_opener and m.provider_sid is not null
               and right(regexp_replace(m.to_number, '\D', '', 'g'), 10) = p_phone10) then
    return 'this phone already had its first text';
  end if;
  if exists (select 1 from public.planned_openers p where p.wpie_owner_id = l.wpie_owner_id and p.step = 1
               and p.send_status in ('sending', 'sent', 'delivered', 'uncertain')
               and not (right(regexp_replace(p.phone, '\D', '', 'g'), 10) = any(bad)))
     or exists (select 1 from public.messages m where m.lead_id = p_lead_id and m.direction = 'out' and m.is_opener and m.provider_sid is not null
               and coalesce(m.status, '') not in ('undelivered', 'failed')
               and not (right(regexp_replace(m.to_number, '\D', '', 'g'), 10) = any(bad))) then
    return 'an earlier first text may have arrived (wait for its delivery result, or mark that phone wrong_number)';
  end if;
  if exists (select 1 from public.twilio_inbound t where t.from10 = any(phones) and not (t.from10 = any(bad)))
     or exists (select 1 from public.messages m where m.lead_id = p_lead_id and m.direction = 'in' and m.channel = 'sms'
                  and not (right(regexp_replace(coalesce(m.from_number, ''), '\D', '', 'g'), 10) = any(bad))) then
    return 'they texted back from a good phone';
  end if;
  -- someone on a phone that is still good was reached by a call: the card needs a person's decision first (0152)
  if exists (select 1 from public.messages m where m.lead_id = p_lead_id and m.channel = 'call'
               and m.status in ('interested', 'reached_no_decision', 'not_now', 'not_interested')
               and not (right(regexp_replace(coalesce(m.from_number, ''), '\D', '', 'g'), 10) = any(bad))) then
    return 'someone on a good phone was reached by a call: decide on the card first';
  end if;
  return null;
end $function$;
