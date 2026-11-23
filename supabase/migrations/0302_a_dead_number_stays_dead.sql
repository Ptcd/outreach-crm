-- 0302: a number the carrier already called dead is dead on every card it lands on, not only the one it bounced on.
-- Colin 2026-11-22: "When we text dead lines we know that and they get marked as dead on the cards right?" Mostly:
-- since 0071 a bounce (30003 unreachable, 30005 not in service, 30006 cannot take texts) marks the phone bad on every
-- card that held it at that moment. But a phone row made afterwards (an agent loading the same number again, a merge,
-- a new card for the owner) started out "ok": 20 such rows on the bounced cards themselves, and 27 dead numbers
-- sitting as good on other cards. Now a phone row that arrives with a number that bounced dead, and was never
-- delivered to since, is marked bad as it lands, with the carrier's code and date.

create or replace function public.phone_dead_note(p_phone10 text) returns text
language sql stable security definer set search_path = public as $fn$
  select 'carrier ' || p.error_code || ' on ' || to_char(coalesce(p.sent_at, p.send_updated_at) at time zone 'America/Chicago', 'Mon DD')
         || case p.error_code when '30003' then ' (unreachable)' when '30005' then ' (not in service)' else ' (cannot take texts)' end
    from public.planned_openers p
   where right(regexp_replace(coalesce(p.phone, ''), '\D', '', 'g'), 10) = p_phone10
     and p.send_status = 'undelivered' and p.error_code in ('30003', '30005', '30006')
     and not exists (select 1 from public.planned_openers d
                      where right(regexp_replace(coalesce(d.phone, ''), '\D', '', 'g'), 10) = p_phone10
                        and d.send_status = 'delivered' and coalesce(d.sent_at, d.send_updated_at) > coalesce(p.sent_at, p.send_updated_at))
   order by coalesce(p.sent_at, p.send_updated_at) desc limit 1
$fn$;
revoke all on function public.phone_dead_note(text) from public, anon, authenticated;
grant execute on function public.phone_dead_note(text) to service_role;

create or replace function public.contacts_dead_on_arrival() returns trigger
language plpgsql security definer set search_path = public as $fn$
declare why text;
begin
  if new.kind = 'phone' and coalesce(new.status::text, 'ok') = 'ok' and new.value_normalized ~ '^[0-9]{10}$' then
    why := public.phone_dead_note(new.value_normalized);
    if why is not null then
      new.status := 'bad';
      if why like '%30006%' then new.line_type := coalesce(new.line_type, 'landline'); end if;
      new.note := concat_ws('; ', new.note, why);
    end if;
  end if;
  return new;
end $fn$;
drop trigger if exists contacts_dead_on_arrival on public.contacts;
create trigger contacts_dead_on_arrival before insert or update of value_normalized on public.contacts
  for each row execute function public.contacts_dead_on_arrival();

-- the ones already sitting as good
update public.contacts c
   set status = 'bad',
       line_type = case when x.why like '%30006%' then coalesce(c.line_type, 'landline') else c.line_type end,
       note = concat_ws('; ', c.note, x.why), updated_at = now()
  from (select distinct c2.value_normalized as p10, public.phone_dead_note(c2.value_normalized) as why
          from public.contacts c2 where c2.kind = 'phone' and c2.status = 'ok' and c2.value_normalized ~ '^[0-9]{10}$'
           and exists (select 1 from public.planned_openers p where p.send_status = 'undelivered' and p.error_code in ('30003', '30005', '30006')
                        and right(regexp_replace(coalesce(p.phone, ''), '\D', '', 'g'), 10) = c2.value_normalized)) x
 where x.why is not null and c.kind = 'phone' and c.value_normalized = x.p10 and c.status = 'ok';
