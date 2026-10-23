-- A STOP closes every card it touches (Colin 2026-10-23: "every stop stops all further messaging, it should take
-- the entire card make it red and put it in a dnc state so in no way can we contact them").
--
-- Before: a texted STOP blocked the sender's phone and the same owner's other phones, but turned only the card the
-- text came in on to 'dnc'. A card of another owner that carried one of those phones (a relative's number from the
-- skip trace, the person behind two LLCs) stayed open with its other phones reachable: six such cards on 10-23.
--
-- Now: whenever a phone is blocked because someone asked to stop (a texted STOP, a removal reply, a do-not-contact
-- call, the voice line's dnc), every card that holds that phone goes to stage dnc and every phone on those cards is
-- blocked too (reason 'stop_card'). Those phones close the cards that share them in turn (the other owner's card
-- with the same number), whose own phones are blocked as 'stop_card_2' and spread no further: the STOP card and
-- every card sharing a phone with it, and no more.
-- A number blocked for any other reason (a carrier list, a dead line) closes nothing.

create or replace function public.close_cards_for_phone(p_phone text, p_next_reason text default 'stop_card')
returns integer language plpgsql security definer set search_path = public as $$
declare lid uuid; n int := 0;
begin
  -- Colin's test phone plays a sample owner: its STOP is reset by hand and never closes a real card
  if exists (select 1 from public.campaign_control where id = 1 and p_phone = any(coalesce(test_phones, '{}'))) then
    return 0;
  end if;
  for lid in
    select c.lead_id from public.contacts c where c.kind = 'phone' and c.value_normalized = p_phone and c.lead_id is not null
    union
    select i.lead_id from public.twilio_inbound i where i.from10 = p_phone and i.lead_id is not null
  loop
    update public.leads set stage = 'dnc' where id = lid and stage is distinct from 'dnc';
    insert into public.suppressed_phones (phone10, reason, source)
      select distinct c.value_normalized, p_next_reason, 'close_cards_for_phone' from public.contacts c
       where c.lead_id = lid and c.kind = 'phone' and c.value_normalized ~ '^[0-9]{10}$'
    on conflict (phone10) do nothing;
    update public.contacts set suppressed = true where lead_id = lid and kind = 'phone' and suppressed is distinct from true;
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function public.stop_closes_cards()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.reason in ('removal_reply', 'removal_reply_other_phone', 'stop_reply', 'dnc_call', 'voice_dnc') then
    perform public.close_cards_for_phone(new.phone10, 'stop_card');
  elsif new.reason = 'stop_card' then
    perform public.close_cards_for_phone(new.phone10, 'stop_card_2');   -- the last step: these spread no further
  end if;
  return null;
end $$;

drop trigger if exists stop_closes_cards on public.suppressed_phones;
create trigger stop_closes_cards after insert on public.suppressed_phones
  for each row execute function public.stop_closes_cards();

-- the phones already blocked because someone asked to stop
do $$
declare p text;
begin
  for p in select phone10 from public.suppressed_phones
            where reason in ('removal_reply', 'removal_reply_other_phone', 'stop_reply', 'dnc_call', 'voice_dnc')
  loop
    perform public.close_cards_for_phone(p, 'stop_card');
  end loop;
end $$;
