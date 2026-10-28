-- The belt alarm on Today (Colin 2026-10-28: "fix this"): three false alarms.
--   * the daily canary failed every day since 0064: its "dry text" step expected the belt to draft a text, but the texting
--     agent writes every text now and the belt skips its own on purpose. With agent texting on, the skip is the pass.
--   * "1 live card has no next stop" and "2 cards moved outside the belt" were the TEST CALL NOTES card (screenshots):
--     TEST cards no longer count in either.
--   * the "laptop has not pushed" check read leads.synced_at, which the push now touches only when a card changes
--     (sync_hash): it also reads planned_openers.synced_at, re-sent every push.

create or replace view public.cards_no_stop as
SELECT id AS lead_id,
    owner_name,
    property_address,
    stage,
    belt,
    belt_step,
    assigned_to,
    belt_entered_at,
    updated_at
   FROM leads l
  WHERE owner_name !~~* 'TEST %' AND next_stop_at IS NULL AND (belt IS NOT NULL AND (belt <> ALL (ARRAY['dead'::text, 'dnc'::text, 'too_high_or_listed'::text, 'cold_texts'::text])) AND NOT (belt = 'dormant'::text AND dormant_round >= 3) OR belt IS NULL AND (stage = ANY (ARRAY['reply_received'::lead_stage, 'ai_qualifying'::lead_stage, 'handoff'::lead_stage, 'colin_call'::lead_stage, 'walk_decision'::lead_stage, 'walkthrough_booked'::lead_stage, 'offer'::lead_stage, 'follow_up'::lead_stage, 'human_owned'::lead_stage])));

CREATE OR REPLACE FUNCTION public.belt_health_check(p_now timestamp with time zone DEFAULT now(), p_extra jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare c jsonb; fails text[] := '{}'; n_nostop int; n_unlogged int; n_failed int; n_stuck int; n_direct int; last_push timestamptz; hour_ct int;
  swing jsonb := '[]'::jsonb; prevc jsonb; cur jsonb; b record; canary record; ok boolean; summary text; counts jsonb;
begin
  select count(*) into n_nostop from public.cards_no_stop;
  select count(*) into n_unlogged from public.tasks t where t.source in ('belt', 'call_list') and t.done_at is null and t.due_at < p_now - interval '24 hours';
  select count(*) into n_failed from public.reply_drafts d where d.kind = 'belt' and d.status = 'failed' and d.updated_at > p_now - interval '24 hours';
  select count(*) into n_stuck from public.reply_drafts d where d.kind = 'belt' and ((d.status = 'queued' and d.created_at < p_now - interval '1 hour') or (d.status = 'sending' and d.updated_at < p_now - interval '10 minutes'));
  select count(*) into n_direct from public.belt_direct_writes w where w.at > p_now - interval '24 hours'
     and not exists (select 1 from public.leads tl where tl.id = w.lead_id and tl.owner_name ilike 'TEST %');
  -- the push writes only changed cards (sync_hash, 2026-10-28), so a quiet hour leaves leads.synced_at old: the
  -- planned openers are re-sent on every push and carry the heartbeat
  select greatest((select max(synced_at) from public.leads), (select max(synced_at) from public.planned_openers)) into last_push;
  hour_ct := extract(hour from p_now at time zone 'America/Chicago')::int;
  select coalesce(jsonb_object_agg(belt, n), '{}'::jsonb) into counts from public.belt_counts;
  select h.checks->'counts' into prevc from public.belt_health h where h.kind = 'run' and h.at <= p_now - interval '23 hours' and h.at > p_now - interval '26 hours' order by h.at desc limit 1;
  if prevc is not null then
    for b in select key, value::int as n from jsonb_each_text(counts) loop
      if coalesce((prevc->>b.key)::int, 0) >= 20 and abs(b.n - (prevc->>b.key)::int) > 0.25 * (prevc->>b.key)::int then
        swing := swing || jsonb_build_object('belt', b.key, 'was', (prevc->>b.key)::int, 'now', b.n);
      end if;
    end loop;
  end if;
  select h.ok, h.at into canary from public.belt_health h where h.kind = 'canary' order by h.at desc limit 1;
  if n_nostop > 0 then fails := array_append(fails, format('%s live card(s) have no next stop', n_nostop)); end if;
  if n_unlogged > 0 then fails := array_append(fails, format('%s stop(s) sit unlogged more than a day after they were due', n_unlogged)); end if;
  if n_failed > 0 then fails := array_append(fails, format('%s belt text(s) failed to send in the last day', n_failed)); end if;
  if n_stuck > 0 then fails := array_append(fails, format('%s belt text(s) stuck in the queue for over an hour', n_stuck)); end if;
  if n_direct > 0 then fails := array_append(fails, format('%s card(s) were moved outside the belt in the last day', n_direct)); end if;
  if jsonb_array_length(swing) > 0 then fails := array_append(fails, format('a belt gained or lost over a quarter of its cards in a day: %s', swing::text)); end if;
  if hour_ct between 8 and 20 and extract(isodow from p_now at time zone 'America/Chicago') < 7
     and (last_push is null or last_push < p_now - interval '2 hours') then
    fails := array_append(fails, 'the laptop has not pushed in over 2 hours');
  end if;
  if canary.at is null or canary.at < p_now - interval '26 hours' then fails := array_append(fails, 'the daily canary has not run');
  elsif not canary.ok then fails := array_append(fails, 'the daily canary FAILED: a belt is broken'); end if;
  ok := cardinality(fails) = 0;
  c := jsonb_build_object('no_stop', n_nostop, 'unlogged', n_unlogged, 'texts_failed', n_failed, 'texts_stuck', n_stuck, 'direct_writes', n_direct,
         'swings', swing, 'last_push_at', last_push, 'canary_ok', canary.ok, 'canary_at', canary.at, 'counts', counts, 'fails', to_jsonb(fails)) || coalesce(p_extra, '{}'::jsonb);
  summary := case when ok then format('All belts moving: %s cards on belts, %s stop(s) overdue',
                   (select coalesce(sum(n), 0) from public.belt_counts where belt not in ('dead', 'dnc')), (select coalesce(sum(overdue), 0) from public.belt_counts))
                  else array_to_string(fails, '; ') end;
  insert into public.belt_health (at, kind, ok, checks, summary) values (p_now, 'run', ok, c, summary);
  update public.campaign_control set belt_last_run_at = p_now where id = 1;
  delete from public.belt_health where at < p_now - interval '14 days';
  return jsonb_build_object('ok', ok, 'summary', summary, 'checks', c);
end $function$;

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
