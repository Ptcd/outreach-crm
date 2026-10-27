-- The three cards a wrong person's stop closed before 0089 (Colin 2026-10-27: "add these ones to do not contact for
-- that phone number, keep card open"): "Wrong number, STOP" (Michael Ranic, 10-22), "the number you found ... doesn't
-- belong to her. please remove" (Geri Peterson, 10-22), "this isn't Nora number ... leave me alone" (Nora Vazquez,
-- 10-27). The wrong person's phone stays blocked for good (reason wrong_person_stop) and is marked bad; the owner's
-- other phones, blocked only because of that stop, are unblocked; the card leaves DNC the wrong-number way (data_fix,
-- off the belt), so the next-phone rule reaches the owner. The laptop's own list was put back the same day.
do $$
declare
  r record;
  others text[];
begin
  for r in select * from (values
      ('135d6080-5ef0-4e76-b660-ff39e2f63827'::uuid, '7155843763'),
      ('3cd946f4-5e6a-4c38-a950-c7cab5d2a865'::uuid, '4147501377'),
      ('40658f07-4896-42f3-be5e-9cd2a5d78c3a'::uuid, '4143228092')) v(lead_id, wrong)
  loop
    update public.suppressed_phones set reason = 'wrong_person_stop' where phone10 = r.wrong;
    update public.contacts set status = 'bad', note = concat_ws('; ', note, 'not the owner, asked us to stop (put back 2026-10-27)')
     where lead_id = r.lead_id and kind = 'phone' and value_normalized = r.wrong;
    select coalesce(array_agg(c.value_normalized), '{}') into others from public.contacts c
     where c.lead_id = r.lead_id and c.kind = 'phone' and c.value_normalized <> r.wrong;
    -- only the blocks that this stop spread; a phone with its own stop, or on another card, keeps its block
    delete from public.suppressed_phones s
     where s.phone10 = any(others) and s.reason in ('removal_reply_other_phone', 'stop_card', 'stop_card_2')
       and not exists (select 1 from public.reply_drafts d where d.phone10 = s.phone10 and d.kind = 'removal')
       and not exists (select 1 from public.contacts x where x.value_normalized = s.phone10 and x.lead_id <> r.lead_id);
    update public.contacts c set suppressed = false
     where c.lead_id = r.lead_id and c.kind = 'phone' and c.value_normalized = any(others) and c.suppressed
       and not exists (select 1 from public.suppressed_phones s where s.phone10 = c.value_normalized);
    insert into public.belt_events (lead_id, event, from_belt, to_belt, step, payload, at, by)
      select l.id, 'move', l.belt, null, 0, jsonb_build_object('reason', 'a wrong person''s stop: that phone only, the card stays open (Colin 2026-10-27)',
             'phone', r.wrong), now(), 'colin'
        from public.leads l where l.id = r.lead_id;
    perform set_config('wpie.in_belt_event', '1', true);
    update public.leads set stage = 'data_fix', belt = null, belt_step = 0, next_stop_at = null, next_stop_who = null, next_stop_say = null
     where id = r.lead_id and stage = 'dnc';
    perform set_config('wpie.in_belt_event', '', true);
  end loop;
end $$;
