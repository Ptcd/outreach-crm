-- 0328 (2026-11-26, Thanksgiving). Two faults Colin found on 432 W Hillcrest St (George M White):
--
-- 1. The deal sheet told Thalia "SAY THIS, ONCE $300". Her call notes said the seller wants "300k" and owes "40k";
--    text_offer_num stripped every non-digit, so "300k" read as $300 and became the seller's own number, which the sheet
--    never opens above. A k is a thousand and an m a million.
-- 2. "No text sending today" (Colin) paused campaign_control, which stops first texts, follow-ups and the day writer,
--    but an agent's send_reply (agent_start_reply) never looked at the pause: the server OK'd the rule's $157,700 for
--    Muse to text that morning. A pause Colin or the team made now holds the agents' replies too. A pause an agent
--    made (reason 'Muse (...') does not, as before: that agent can lift its own.

create or replace function public.text_offer_num(p jsonb) returns numeric
language sql immutable as $$
  with s as (
    select lower(replace(replace(p #>> '{}', ',', ''), ' ', '')) as t
     where p is not null and jsonb_typeof(p) <> 'null'
  ), n as (
    select nullif(substring(t from '[0-9]+(?:\.[0-9]+)?'), '')::numeric as v,
           case when t ~ '[0-9.](m|mil|million)([^a-z]|$)' then 1000000
                when t ~ '[0-9.](k|thousand)([^a-z]|$)' then 1000
                else 1 end as mult
      from s
  )
  select case when (select count(*) from s) = 0 then null else (select v * mult from n) end
$$;

create or replace function public.agent_start_reply(p_lead_id uuid, p_phone text, p_agent text)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  l public.leads;
  p text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10);
  li public.twilio_inbound;
  id uuid;
  who text;
  c public.campaign_control;
begin
  select * into c from public.campaign_control where campaign_control.id = 1;
  if coalesce(c.paused, false) and coalesce(c.pause_reason, '') not like 'Muse (%' then
    raise exception 'texting is paused (%): no agent text goes out until it is lifted', coalesce(c.pause_reason, 'no reason given');
  end if;
  select * into l from public.leads where leads.id = p_lead_id;
  if not found then raise exception 'no such card'; end if;
  if l.stage = 'dnc' then raise exception 'this card is closed (do not contact)'; end if;
  if exists (select 1 from public.suppressed_phones s where s.phone10 = p) then raise exception 'this phone opted out'; end if;
  who := public.caller_texting(p_lead_id);
  if who is not null then
    raise exception '% has texted this card themselves: the card is theirs now, leave it to them', who;
  end if;
  select * into li from public.twilio_inbound t where t.from10 = p and t.lead_id = p_lead_id order by t.received_at desc limit 1;
  if not found then raise exception 'they have not texted us from that phone: a first text or follow-up goes through queue_texts'; end if;
  insert into public.reply_drafts (phone10, our_number, lead_id, inbound_body, inbound_at, intent, kind, outcome, note, draft_source, status, notified_at)
  values (p, li.to_number, p_lead_id, li.body, now(), 'agent_reply', 'team', 'open', 'written by the sender agent (' || coalesce(p_agent, 'agent') || ')',
          'agent', 'awaiting_approval', now())
  returning reply_drafts.id into id;
  return id;
end $function$;
