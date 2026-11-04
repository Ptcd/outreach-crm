-- 0174: the daily canary's test card locks to Thalia, so the split (0168) does not move its first stop to Adil and
-- page Colin for nothing. Found by the migration tests after 0173.

CREATE OR REPLACE FUNCTION public.belt_canary(p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare lid uuid; ph text; steps jsonb := '[]'::jsonb; res jsonb; l public.leads; tid uuid; ok boolean; why text;
  mon timestamptz := public.belt_slide(p_now + interval '1 day', 'America/Chicago', 'call', 10);
begin
  select coalesce(test_phones[1], '2627770909') into ph from public.campaign_control where id = 1;
  insert into public.leads (owner_name, property_address, municipality, mailing_state, lane, stage, notes)
  values ('BELT CANARY (test card)', '1234 N Test St, Milwaukee', 'Milwaukee', 'WI', 'flip', 'opener_sent', 'canary: deleted at the end of the test')
  returning id into lid;
  -- the canary's card is Thalia's (0174): the 50/50 split (0168) would hand it to whoever is behind and the
  -- thalia_task check would fail on alternate days
  update public.leads set locked_to = 'thalia', locked_at = now() where id = lid;
  insert into public.contacts (lead_id, kind, value, value_normalized, line_type, source) values (lid, 'phone', ph, ph, 'mobile', 'canary');
  begin
    -- 1. interest -> said yes, not booked; Thalia's call now
    res := public.belt_event(lid, 'inbound_text', jsonb_build_object('intent', 'interested', 'kind', 'candidate', 'outcome', 'open', 'said', 'yes, call me', 'interest', true), 'canary', p_now);
    select * into l from public.leads where id = lid;
    steps := public.belt_canary_step(steps, 'yes_unbooked', l.belt = 'yes_unbooked' and l.belt_step = 1 and l.next_stop_who = 'thalia_call' and l.next_stop_at is not null,
               coalesce(l.belt, 'null') || '/' || l.belt_step || '/' || coalesce(l.next_stop_who, 'null'));
    select id into tid from public.tasks where lead_id = lid and source = 'belt' and done_at is null;
    steps := public.belt_canary_step(steps, 'thalia_task', tid is not null and (select owner from public.tasks where id = tid) = 'thalia', coalesce(tid::text, 'no task'));
    -- 2. no answer -> the auto text an hour later
    res := public.belt_event(lid, 'stop_done', jsonb_build_object('outcome', 'no_answer', 'task_id', tid), 'canary', p_now);
    select * into l from public.leads where id = lid;
    steps := public.belt_canary_step(steps, 'no_answer', l.belt = 'yes_unbooked' and l.belt_step = 2 and l.next_stop_who = 'auto_text' and l.unanswered_count = 1,
               coalesce(l.belt, 'null') || '/' || l.belt_step || '/' || coalesce(l.next_stop_who, 'null') || '/unanswered ' || l.unanswered_count);
    steps := public.belt_canary_step(steps, 'task_logged', (select done_at from public.tasks where id = tid) is not null, 'the stop task closed');
    -- 3. the text, dry, with the switch forced for the test: a dry_sent draft, then step 3 (a call at another band)
    res := public.belt_claim_text(lid, true, true, l.next_stop_at + interval '1 minute');
    -- since 0064 the texting agent (Muse) writes every text: the belt skips its own text on purpose and moves on
    steps := public.belt_canary_step(steps, 'dry_text',
               case when (select agent_runs_texting from public.campaign_control where id = 1)
                    then res->>'outcome' = 'skipped' and res->>'reason' = 'the texting agent writes the texts'
                    else res->>'outcome' = 'dry_sent' and (res->>'body') like 'Colin here%' and (res->>'body') like '%STOP%' and (res->>'body') like '%N Test St%' end,
               coalesce(res::text, 'null'));
    select * into l from public.leads where id = lid;
    steps := public.belt_canary_step(steps, 'after_text', l.belt = 'yes_unbooked' and l.belt_step = 3 and l.next_stop_who = 'thalia_call'
               and l.unanswered_count = case when (select agent_runs_texting from public.campaign_control where id = 1) then 1 else 2 end,
               coalesce(l.belt, 'null') || '/' || l.belt_step || '/' || coalesce(l.next_stop_who, 'null') || '/unanswered ' || l.unanswered_count);
    -- 4. a call back booked -> call_booked with the slot, the reminder the morning of
    res := public.belt_event(lid, 'next_step', jsonb_build_object('kind', 'callback', 'at', mon), 'canary', p_now);
    select * into l from public.leads where id = lid;
    steps := public.belt_canary_step(steps, 'call_booked', l.belt = 'call_booked' and l.named_date = mon and l.next_stop_who = 'auto_text' and l.next_stop_at < mon,
               coalesce(l.belt, 'null') || '/' || coalesce(l.next_stop_who, 'null') || '/' || coalesce(l.next_stop_at::text, 'null'));
    -- 5. the walk-through booked -> visit_booked, Colin visits at the slot
    res := public.belt_event(lid, 'next_step', jsonb_build_object('kind', 'walk', 'at', mon + interval '1 day'), 'canary', p_now);
    select * into l from public.leads where id = lid;
    steps := public.belt_canary_step(steps, 'visit_booked', l.belt = 'visit_booked' and l.stage = 'walkthrough_booked'
               and exists (select 1 from public.tasks t where t.lead_id = lid and t.source = 'belt' and t.done_at is null and t.kind = 'visit' and t.owner = 'colin'),
               coalesce(l.belt, 'null') || '/' || l.stage::text);
    -- 6. STOP is final: nothing moves a DNC card
    res := public.belt_event(lid, 'stop', '{}'::jsonb, 'canary', p_now);
    res := public.belt_event(lid, 'inbound_text', jsonb_build_object('intent', 'interested', 'interest', true), 'canary', p_now);
    select * into l from public.leads where id = lid;
    steps := public.belt_canary_step(steps, 'dnc_final', l.belt = 'dnc' and l.next_stop_at is null and not exists (select 1 from public.tasks t where t.lead_id = lid and t.done_at is null), coalesce(l.belt, 'null'));
  exception when others then
    steps := public.belt_canary_step(steps, 'error', false, sqlerrm);
  end;
  delete from public.reply_drafts where lead_id = lid;
  delete from public.leads where id = lid;
  ok := not exists (select 1 from jsonb_array_elements(steps) x where not (x->>'ok')::boolean);
  select x->>'step' || ': ' || (x->>'detail') into why from jsonb_array_elements(steps) x where not (x->>'ok')::boolean limit 1;
  insert into public.belt_health (at, kind, ok, checks, summary) values (p_now, 'canary', ok, jsonb_build_object('steps', steps), coalesce(why, 'canary passed: a test card moved through its belts and was deleted'));
  update public.campaign_control set belt_canary_date = (p_now at time zone 'America/Chicago')::date where id = 1;
  return jsonb_build_object('ok', ok, 'why', why, 'steps', steps);
end $function$;
