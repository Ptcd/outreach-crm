-- Walk gate, round 2 (adopted by Colin 2026-10-20). Source: WPIE
-- docs/SELLER_QUALIFICATION_LOGIC.md and research/acquisition-system/others_analysis/SYNTHESIS.md.
--
-- Two new hard stops, both for owners behind on payments:
--   sheriff_inside_14_days  a sheriff/foreclosure sale less than 14 days out (WPIE's 14-day rule)
--   payoff_above_number     loan payoff plus arrears above Colin's own number
-- Existing ids keep their meaning, widened in the app's labels: listed_active now includes
-- anything signed with another buyer; elderly_without_family now includes serious illness and
-- any memory or capacity trouble.

alter table public.gate_scores drop constraint if exists gate_scores_hard_stops_check;
alter table public.gate_scores add constraint gate_scores_hard_stops_check check (hard_stops <@ array[
  'dnc_or_no_contact', 'listed_active', 'no_authority', 'elderly_without_family',
  'hold_lane_no_financials', 'sheriff_inside_14_days', 'payoff_above_number']::text[]);
