-- A number the carrier says is dead is a bad number on the card (Colin 2026-10-26: "track cards with bad phone numbers
-- and compile a database of them to give to a skiptracer"). Until now only a "wrong number" reply marked a phone bad;
-- a text that bounced (30003 unreachable, 30005 unknown or not in service, 30006 a landline or a carrier that cannot
-- take texts) left the phone at "ok", so 94 dead numbers still looked usable. Now the bounce marks it, with the code,
-- and the re-trace list (wpie/skiptrace/retrace.py) picks up every card left with no usable mobile.

create or replace function public.bounce_marks_phone_bad() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.send_status = 'undelivered' and new.error_code in ('30003', '30005', '30006')
     and (tg_op = 'INSERT' or old.send_status is distinct from new.send_status or old.error_code is distinct from new.error_code) then
    update public.contacts
       set status = 'bad',
           line_type = case when new.error_code = '30006' then coalesce(line_type, 'landline') else line_type end,
           note = concat_ws('; ', note, 'carrier ' || new.error_code || ' on ' || to_char(coalesce(new.sent_at, now()) at time zone 'America/Chicago', 'Mon DD')
                  || case new.error_code when '30003' then ' (unreachable)' when '30005' then ' (not in service)' else ' (cannot take texts)' end)
     where kind = 'phone' and value_normalized = right(regexp_replace(coalesce(new.phone, ''), '\D', '', 'g'), 10) and status <> 'bad';
  end if;
  return new;
end $$;
drop trigger if exists bounce_marks_phone_bad on public.planned_openers;
create trigger bounce_marks_phone_bad after insert or update of send_status, error_code on public.planned_openers
  for each row execute function public.bounce_marks_phone_bad();

-- the ones already bounced
update public.contacts c
   set status = 'bad',
       line_type = case when p.error_code = '30006' then coalesce(c.line_type, 'landline') else c.line_type end,
       note = concat_ws('; ', c.note, 'carrier ' || p.error_code || ' on ' || to_char(coalesce(p.sent_at, p.send_updated_at) at time zone 'America/Chicago', 'Mon DD'))
  from (select distinct on (right(phone, 10)) right(phone, 10) ph, error_code, sent_at, send_updated_at
          from public.planned_openers where send_status = 'undelivered' and error_code in ('30003', '30005', '30006')
         order by right(phone, 10), send_updated_at desc) p
 where c.kind = 'phone' and c.value_normalized = p.ph and c.status <> 'bad';
