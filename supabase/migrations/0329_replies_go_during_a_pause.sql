-- 0329 (2026-11-26). Colin, the same afternoon: "you're blocking muse from replying to stuff". 0328 made Colin's pause
-- refuse an agent's reply too; he wants replies to sellers who wrote in to keep going while the campaign is paused.
-- agent_start_reply is back to its body before 0328 (no pause check). The pause still stops first texts, follow-ups
-- and the day writer (claim_next_opener, text_day_backstop). The k/m reading from 0328 stays.

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
begin
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
