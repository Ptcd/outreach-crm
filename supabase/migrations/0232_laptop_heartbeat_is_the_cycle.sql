-- 0232: the laptop's heartbeat is its cycle, not a changed card.
--
-- belt_health_check failed with "the laptop has not pushed in over 2 hours" 81 times in three days while the
-- 10-minute live cycle ran clean every time: it read the newest synced_at on cards and planned texts, which the
-- laptop only stamps when a row changes. The cycle pushes the record verdicts (text_fitness) every pass; that is
-- the heartbeat.

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
  -- the laptop's heartbeat is its 10-minute cycle, which pushes the record verdicts every pass (0232). Cards and planned
  -- texts are stamped only when one changes, so a quiet morning read as "the laptop has not pushed".
  select greatest((select max(synced_at) from public.leads), (select max(synced_at) from public.planned_openers),
                  (select max(pushed_at) from public.text_fitness)) into last_push;
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
