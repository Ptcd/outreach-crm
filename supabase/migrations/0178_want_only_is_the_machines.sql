-- 0178: a "want", with nothing to go on, is the machine's, not a caller's (Colin 2026-11-04: "for lane 3s... 6 months?
-- never?" -> a text every quarter, one human call a year, and the records decide when it is a lead again). The
-- not-now-with-a-condition ladder was: a text at 30 days, COLIN's call at 90, a text at 180, then dormant (three quarterly
-- texts, then rest). Now the 90-day call is the card's caller's (their one human touch), and the dormant ladder ends
-- with the caller's "still yours?" call about a year on, after two quarterly texts. The card wakes early on its own
-- the day a new public record lands on the house (belt_on_wpie_event). Nothing here makes a caller's check-back:
-- those come only from a date the seller named (not_now_dated, 0170).

update public.belt_steps set who = 'thalia_call'
 where belt = 'not_now_condition' and step = 2 and who = 'colin_call';

-- dormant: two quarterly texts, then the caller's call about a year after the card went quiet
update public.belt_steps set who = 'thalia_call', template_key = null,
       say = 'We spoke a while back about {street}; is it still yours, and has anything changed?'
 where belt = 'dormant' and step = 3;

-- open stops already waiting on Colin at the 90-day mark go to the card's caller
update public.tasks t set owner = l.locked_to, updated_at = now()
  from public.leads l
 where l.id = t.lead_id and t.done_at is null and t.source = 'belt' and t.owner = 'colin'
   and l.belt = 'not_now_condition' and l.belt_step = 2 and l.locked_to in ('thalia', 'adil');
update public.leads set next_stop_who = 'thalia_call'
 where belt = 'not_now_condition' and belt_step = 2 and next_stop_who = 'colin_call' and locked_to in ('thalia', 'adil');
