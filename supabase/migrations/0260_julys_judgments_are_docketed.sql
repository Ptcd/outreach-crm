-- 0260: July's judgments are docketed judgments, and say so.
--
-- Muse banked 3,519 money judgments on 2026-11-20 at 7:52 PM from the court's docketed-judgments report (searched by
-- docket date, July 2026; desk 317, 338 and the room). The rows carried no class code and nothing saying where they
-- came from. The laptop's rule for a money judgment was written for rows read off case filings: CV, or small claims
-- with the money-suit class code, because small claims is mostly evictions. Under it 2,654 of the 3,519 were being
-- skipped. Colin, 2026-11-20, on being shown that: "that seems dumb". A docketed judgment is a money judgment
-- whatever its case type: only money judgments are docketed (Wis. Stat. 806.10).
--
-- The rule itself is the laptop's (wpie/collectors/wi_court_cases.py: a row that says docketed counts). From now on
-- an agent says so on the row (court_rows_deposit, docketed: true; it rides in extra). This migration says it for the
-- batch already banked, and puts the ones skipped under the old rule back in line.

update public.court_rows
   set extra = coalesce(extra, '{}'::jsonb) || '{"docketed": true, "docketed_marked_by": "desk 0260: Muse deposited these from the docketed-judgments report, July 2026"}'::jsonb,
       state = case when state = 'skipped' then 'waiting' else state end,
       result_note = case when state = 'skipped' then null else result_note end,
       result_at = case when state = 'skipped' then null else result_at end,
       pulled_at = case when state = 'skipped' then null else pulled_at end,
       updated_at = now()
 where kind = 'money_judgment'
   and deposited_at >= '2026-11-21 01:45:00+00' and deposited_at < '2026-11-21 02:00:00+00'
   and filed between '2026-07-01' and '2026-07-31'
   and class_code is null
   and not coalesce((extra ->> 'docketed')::boolean, false);
