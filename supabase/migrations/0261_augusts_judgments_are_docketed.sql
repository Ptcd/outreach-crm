-- 0261: August's judgments are docketed judgments too.
--
-- Muse banked August from the same docketed-judgments report at 9:07 PM on 2026-11-20 (room line 20), minutes before
-- the door learned the docketed field (0260, deployed 9:10 PM). 2,753 rows, no class code, none saying where they
-- came from; the next tie pass would have skipped the small-claims ones exactly as July's were. Same mark as 0260,
-- for every unmarked row of that evening's deposits from the report (no class code, banked by Muse). A row banked
-- from now on says docketed itself.

update public.court_rows
   set extra = coalesce(extra, '{}'::jsonb) || '{"docketed": true, "docketed_marked_by": "desk 0261: Muse deposited these from the docketed-judgments report on 2026-11-20"}'::jsonb,
       state = case when state = 'skipped' then 'waiting' else state end,
       result_note = case when state = 'skipped' then null else result_note end,
       result_at = case when state = 'skipped' then null else result_at end,
       pulled_at = case when state = 'skipped' then null else pulled_at end,
       updated_at = now()
 where kind = 'money_judgment'
   and deposited_at >= '2026-11-21 01:45:00+00' and deposited_at < '2026-11-21 03:20:00+00'
   and lower(deposited_by) = 'muse'
   and class_code is null
   and not coalesce((extra ->> 'docketed')::boolean, false);
