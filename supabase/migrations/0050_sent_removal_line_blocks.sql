-- A sent "you won't hear from me again" is a removal (2026-10-24): "Its my parents home. Leave it alone." was read as
-- a relative's reply, the team approved the removal line by hand, and the phone was never blocked or the card closed.
-- Whatever path sends one of the removal lines (the agent's own, the hostile line, the Spanish one, or a person's
-- approval of a draft that says it), the phone goes on suppressed_phones as a removal reply, which closes every card
-- it touches, red (0046). Test phones stay exempt there.

create or replace function public.removal_line_blocks() returns trigger
language plpgsql security definer set search_path = public as $$
declare said text;
begin
  if new.status <> 'sent' or (tg_op = 'UPDATE' and old.status = 'sent') or new.is_test then return new; end if;
  said := lower(coalesce(new.sent_body, new.body, ''));
  if said like '%you won''t hear from me again%' or said like '%i won''t reach out again%'
     or said like '%no le volveré a escribir%' then
    insert into public.suppressed_phones (phone10, reason, source)
    values (new.phone10, 'removal_reply', 'reply_agent')
    on conflict (phone10) do nothing;
  end if;
  return new;
end $$;

drop trigger if exists removal_line_blocks on public.reply_drafts;
create trigger removal_line_blocks after insert or update of status on public.reply_drafts
  for each row execute function public.removal_line_blocks();

-- one-time: every removal line already sent
insert into public.suppressed_phones (phone10, reason, source)
select distinct d.phone10, 'removal_reply', 'reply_agent'
  from public.reply_drafts d
 where d.status = 'sent' and not d.is_test and d.phone10 ~ '^[0-9]{10}$'
   and (lower(coalesce(d.sent_body, d.body, '')) like '%you won''t hear from me again%'
        or lower(coalesce(d.sent_body, d.body, '')) like '%i won''t reach out again%'
        or lower(coalesce(d.sent_body, d.body, '')) like '%no le volveré a escribir%')
on conflict (phone10) do nothing;
