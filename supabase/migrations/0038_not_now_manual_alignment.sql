-- The operator manual promises that an exact "Not now" date is quiet until that day.
-- The original dated belt included a permission text four days early, which contradicted that promise.
-- Replace that cadence with the date call and one seven-day retry, and migrate active cards without
-- leaving an old queued pre-date text behind.

-- A provider-uncertain text must be reconciled before this migration. Never relabel a send that may
-- already have reached a seller.
do $$
begin
  if exists (
    select 1
      from public.reply_drafts d
      join public.leads l on l.id = d.lead_id
     where l.belt = 'not_now_dated' and d.kind = 'belt' and d.status = 'sending'
  ) then
    raise exception 'resolve in-flight not-now text before migration 0038';
  end if;
end $$;

delete from public.belt_steps where belt = 'not_now_dated';
insert into public.belt_steps
  (belt, step, who, anchor, delay_hours, fallback_hours, call_hour, other_band, template_key, say)
values
  ('not_now_dated', 1, 'colin_call', 'named', 0, null, 10, false, null,
   'You mentioned {event} for {street}; how did it go?'),
  ('not_now_dated', 2, 'colin_call', 'named', 168, null, null, false, null,
   'You mentioned {event} for {street}; anything changed?');

update public.belt_rules
   set meaning = 'They named an exact date; no contact before it'
 where belt = 'not_now_dated';

do $$
declare r record; new_step integer;
begin
  for r in
    select id, belt_step
      from public.leads
     where belt = 'not_now_dated'
       and named_date is not null
       and stage not in ('dnc', 'dead', 'closed_no_contact', 'closed_won')
     order by id
     for update
  loop
    -- Old step 1 was the pre-date text; old step 2 was the exact-date call; old step 3
    -- was the seven-day retry. Preserve that progress while renumbering the two quiet stops.
    new_step := case when r.belt_step >= 3 then 2 else 1 end;
    perform set_config('wpie.in_belt_event', '1', true);

    update public.reply_drafts
       set status = 'superseded',
           note = concat_ws(' | ', nullif(note, ''), 'belt: exact-date manual alignment'),
           updated_at = now()
     where lead_id = r.id and kind = 'belt'
       and status in ('queued', 'awaiting_approval', 'would_send');

    update public.tasks
       set done_at = coalesce(done_at, now()),
           note = concat_ws(' ', nullif(note, ''), '[belt: exact-date manual alignment]')
     where lead_id = r.id and source = 'belt' and done_at is null;

    perform public.belt_enter(
      r.id, 'not_now_dated', new_step, 'manual_reconcile',
      jsonb_build_object('from_step', r.belt_step, 'reason', 'wait until exact seller date'),
      'migration 0038', now()
    );

    -- belt task source keys are intentionally stable across a reschedule. If an old step-1
    -- approval task owned that key, belt_enter reuses its row; correct its semantic kind too.
    update public.tasks
       set kind = 'call'
     where lead_id = r.id and source = 'belt' and done_at is null
       and source_key = format('belt:%s:not_now_dated:%s:%s', r.id,
         (select belt_round from public.leads where id = r.id), new_step);
    perform set_config('wpie.in_belt_event', '', true);
  end loop;
end $$;
