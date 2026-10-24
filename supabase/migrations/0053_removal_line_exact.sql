-- 0050 read any sent text containing "you won't hear from me again" as a removal. On 2026-10-24 a conditional
-- question ("Do you know who owns 448 E Bank St now ...? If not, no worries at all, and you won't hear from me
-- again.") to a person who never asked to stop blocked her phone and closed the owner's whole card red, with seven
-- more phones. Only the removal confirmations themselves count now: the agent's DNC line ("Done - you won't hear from
-- me again..."), the hostile line ("Understood, and sorry to have bothered you. I won't reach out again."), the
-- Spanish DNC line, or any sent text that STARTS with "Done - you won't hear from me again".

create or replace function public.removal_line_blocks() returns trigger
language plpgsql security definer set search_path = public as $$
declare said text;
begin
  if new.status <> 'sent' or (tg_op = 'UPDATE' and old.status = 'sent') or new.is_test then return new; end if;
  said := lower(btrim(coalesce(new.sent_body, new.body, '')));
  if said like 'done - you won''t hear from me again%' or said like 'done, you won''t hear from me again%'
     or said like 'understood, and sorry to have bothered you. i won''t reach out again%'
     or said like 'listo - no le volveré a escribir%' then
    insert into public.suppressed_phones (phone10, reason, source)
    values (new.phone10, 'removal_reply', 'reply_agent')
    on conflict (phone10) do nothing;
  end if;
  return new;
end $$;
