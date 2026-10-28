-- Waiting texts whose day passed (Muse 2026-10-28: "40 step-2 follow-ups have been sitting in an already-waiting state
-- since Oct 26 ... They never enter a day's queue and never send - and queue_texts refuses a fresh copy because they
-- exist").
--
-- Why: the sender (claim_next_opener) only takes a text planned for today and inside the window stamped on it the day
-- it was planned. A text that missed its day (the cap was reached, the window closed) stayed "planned" for good: never
-- sent, and blocking a new copy for that card and step.
-- Now, every 5 minutes:
--   * a follow-up (step 2-5) still waiting from an earlier day moves to today: today's date, today's window in the
--     recipient's time zone (Sunday skipped when Sundays are off), sent first as follow-ups are. If a newer copy for the
--     same card and step is already waiting, the old one is withdrawn instead (never two).
--   * a first text still waiting from an earlier day is withdrawn ("its day passed"): the laptop and Muse plan first
--     texts afresh each day, so releasing old ones could send a card two first texts.
--   * a greeting that took a word for a name ("Hey Hi,", "Hey Hello,") is fixed on the way.

create or replace function public.release_stale_texts(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  c public.campaign_control;
  today date;
  r record;
  tz text;
  d date;
  ws timestamptz;
  we timestamptz;
  b text;
  moved integer := 0;
  dup integer := 0;
  firsts integer := 0;
begin
  select * into c from public.campaign_control where id = 1;
  today := (p_now at time zone c.timezone)::date;

  -- first texts from an earlier day: withdrawn
  update public.planned_openers set send_status = 'withdrawn', send_reason = 'its day passed unsent: first texts are planned afresh each day',
         send_updated_at = p_now
   where step = 1 and plan_date < today and send_status in ('planned', 'would_send') and claim_mode is null;
  get diagnostics firsts = row_count;

  for r in select * from public.planned_openers p
            where p.step > 1 and p.plan_date < today and p.send_status in ('planned', 'would_send') and p.claim_mode is null
            order by p.plan_date, p.id
  loop
    if exists (select 1 from public.planned_openers n where n.lead_id = r.lead_id and n.step = r.step and n.id <> r.id
                 and n.send_status in ('planned', 'would_send', 'sending')
                 and (n.plan_date > r.plan_date or (n.plan_date = r.plan_date and n.id > r.id)))
       or exists (select 1 from public.planned_openers n where n.plan_date = today and n.wpie_owner_id = r.wpie_owner_id and n.attempt = r.attempt) then
      update public.planned_openers set send_status = 'withdrawn', send_reason = 'its day passed; a newer copy is waiting', send_updated_at = p_now where id = r.id;
      dup := dup + 1;
      continue;
    end if;
    tz := public.agent_tz(coalesce(r.governing_state, 'WI'));
    ws := null;
    for i in 0..8 loop
      d := (p_now at time zone tz)::date + i;
      if c.no_sundays and extract(isodow from d) = 7 then continue; end if;
      we := (d + c.window_end) at time zone tz;
      if we > p_now then ws := (d + c.window_start) at time zone tz; exit; end if;
    end loop;
    if ws is null then continue; end if;
    b := regexp_replace(r.body, '^Hey (Hi|Hello|There|Owner|Unknown),\s*', 'Hi, ', 'i');
    update public.planned_openers set plan_date = (ws at time zone c.timezone)::date, window_start_utc = ws, window_end_utc = we,
           scheduled_at = greatest(coalesce(r.scheduled_at, ws), ws), body = b,
           body_sha256 = encode(sha256(convert_to(b, 'UTF8')), 'hex'), segments = case when length(b) <= 160 then 1 else 2 end,
           send_updated_at = p_now,
           decision_note = concat_ws('; ', decision_note, 'moved from ' || r.plan_date::text || ': its day passed unsent')
     where id = r.id;
    moved := moved + 1;
  end loop;
  return jsonb_build_object('followups_moved_to_today', moved, 'withdrawn_newer_copy_waiting', dup, 'first_texts_withdrawn', firsts);
end $$;
revoke all on function public.release_stale_texts(timestamptz) from public, anon, authenticated;
grant execute on function public.release_stale_texts(timestamptz) to service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if exists (select 1 from cron.job where jobname = 'wpie-release-stale-texts') then
      perform cron.unschedule('wpie-release-stale-texts');
    end if;
    perform cron.schedule('wpie-release-stale-texts', '*/5 * * * *', 'select public.release_stale_texts()');
  end if;
end $$;
