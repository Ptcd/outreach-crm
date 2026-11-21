-- 0273: the day's list never holds a text in an off caller's name, wherever the name comes from. 0272 blocked threads
-- whose own last text spoke as a caller who is off. A card's name can also come from a text to the same person on
-- another card (card_voice reads the person's phones), and two first texts in Thalia's name were still on Saturday
-- 2026-11-21's list after 0272. The builder now checks the name it is about to write: a row in an off caller's name
-- is not added, and one already listed and not yet sent is taken off.

create or replace function public.text_name_is_off(p_name text, p_day date) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select cc.day_rules_on from public.campaign_control cc where cc.id = 1), true)
     and exists (select 1 from public.team_members tm
                  where tm.person is not null and lower(split_part(tm.display_name, ' ', 1)) = lower(btrim(coalesce(p_name, '')))
                    and public.caller_is_off(tm.person, p_day))
$$;
revoke all on function public.text_name_is_off(text, date) from public, anon, authenticated;
grant execute on function public.text_name_is_off(text, date) to service_role;

CREATE OR REPLACE FUNCTION public.text_day_build(p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c       public.campaign_control;
  d       date := (p_now at time zone 'America/Chicago')::date;
  cap     integer;
  room    integer;
  n       integer;
  nxt     integer;
  added   jsonb := '{}'::jsonb;
  ph      record;
  best    boolean;
  left_out integer;
begin
  select * into c from public.campaign_control where id = 1;
  if coalesce(c.no_sundays, true) and extract(isodow from d) = 7 then
    return jsonb_build_object('day', d, 'built', false, 'why', 'Sunday: no texts');
  end if;
  -- a text carried over to a day its card's caller is off does not go (0238)
  perform public.caller_off_sweep(d);
  cap := coalesce(c.daily_cap, 400);
  best := c.day_best_first_day is not distinct from d;   -- 0262: a day the strongest cards go first
  drop table if exists _day_pool;
  create temp table _day_pool on commit drop as select * from public.text_pool(p_now) where block is null;

  delete from public.text_day t
   where t.day = d
     and not exists (select 1 from public.planned_openers po where po.lead_id = t.lead_id and po.step = t.step and po.plan_date = d and po.lane = 'agent'
                        and po.send_status not in ('withdrawn', 'skipped'))   -- a withdrawn text does not keep its row on the list (0237), nor one the send check refused (0257)
     and (not exists (select 1 from _day_pool p where p.lead_id = t.lead_id and p.step = t.step)
          or public.text_name_is_off(t.voice, d));   -- 0273: a row waiting in an off caller's name leaves too
  get diagnostics left_out = row_count;

  -- what the day has already spent: the list, and any text the agent queued for today that is not on it
  select count(*) into n from public.text_day t where t.day = d;
  room := cap - n - (select count(*) from public.planned_openers po
                      where po.plan_date = d and po.lane = 'agent' and po.send_status in ('planned', 'would_send', 'sending', 'sent', 'delivered', 'undelivered', 'failed', 'uncertain')
                        and not exists (select 1 from public.text_day t where t.day = d and t.lead_id = po.lead_id and t.step = po.step));
  select coalesce(max(t.ord), 0) into nxt from public.text_day t where t.day = d;

  for ph in
    select * from (values
      -- 0262: on a best-first day every tier A, B or C text that is ready goes on the list before anything weaker
      (0, 'best_first', 'first', array[1], case when best then 100000 else 0 end, array['A', 'B', 'C']),
      (1, 'best_followups_2_3', 'followup', array[2, 3], case when best then 100000 else 0 end, array['A', 'B', 'C']),
      (2, 'best_next_numbers', 'next_number', array[1], case when best then 100000 else 0 end, array['A', 'B', 'C']),
      (3, 'best_followups_4_5', 'followup', array[4, 5], case when best then 100000 else 0 end, array['A', 'B', 'C']),
      (4, 'first_floor', 'first', array[1], greatest(0, coalesce(c.day_first_floor, 140) - (select count(*) from public.text_day t where t.day = d and t.kind = 'first')::int), null::text[]),
      (5, 'followups_2_3', 'followup', array[2, 3], 100000, null::text[]),
      (6, 'next_numbers', 'next_number', array[1], 100000, null::text[]),
      (7, 'followups_4_5', 'followup', array[4, 5], 100000, null::text[]),
      (8, 'more_first', 'first', array[1], 100000, null::text[])) as v(n, name, kind, steps, quota, tiers)
     order by n
  loop
    exit when room <= 0;
    continue when ph.quota <= 0;
    with pick as (
      select p.*, row_number() over (order by case when ph.tiers is null then 9 else case p.tier when 'A' then 1 when 'B' then 2 else 3 end end, p.step, p.ord) as rn from _day_pool p
       where p.kind = ph.kind and p.step = any (ph.steps)
         and (ph.tiers is null or p.tier = any (ph.tiers))
         and not exists (select 1 from public.text_day t where t.day = d and t.lead_id = p.lead_id)
       order by case when ph.tiers is null then 9 else case p.tier when 'A' then 1 when 'B' then 2 else 3 end end, p.step, p.ord limit least(room, ph.quota))
    insert into public.text_day (day, lead_id, step, kind, phone, voice, tier, need_why, due_day, ord, listed_at)
    select d, k.lead_id, k.step, k.kind, k.phone, public.card_voice(k.lead_id), k.tier, k.need_why, k.due_day, nxt + k.rn, p_now from pick k
     where not public.text_name_is_off(public.card_voice(k.lead_id), d)   -- 0273
    on conflict (day, lead_id, step) do nothing;
    get diagnostics n = row_count;
    room := room - n;
    nxt := nxt + n;
    added := added || jsonb_build_object(ph.name, n);
  end loop;

  update public.campaign_control set day_last_build_at = p_now where id = 1;
  insert into public.text_day_runs (day, at, kind, summary)
  values (d, p_now, 'build', jsonb_build_object('added', added, 'left_the_list', left_out, 'room_left', greatest(room, 0), 'cap', cap,
          'listed', (select count(*) from public.text_day t where t.day = d)));
  return jsonb_build_object('day', d, 'built', true, 'cap', cap, 'added', added, 'left_the_list', left_out,
    'listed', (select count(*) from public.text_day t where t.day = d), 'room_left', greatest(room, 0));
end $function$;
