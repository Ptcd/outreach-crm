-- 0248: the Research Board is weekly, and a job with no tick for more than two weeks is flagged.
--
-- Colin 2026-11-17, reading "14 of 20 done for Nov 26" on the 17th: "It should be weekly for each, and you should have
-- an agent flag when we're falling behind on a category for more than 2 weeks." Eleven of the fourteen ticks had been
-- copied in on 2026-11-10 from a status report; a monthly tick on a weekly or nightly job stays green all month after
-- the job stops. So:
--   1. A tick is a WEEK (Monday to Sunday, Central) in which the job ran end to end: research_week_ticks. The monthly
--      ticks are carried over into the week they were made; research_ticks is kept and no longer written.
--   2. Every job is expected weekly: the Monthly and Rides-rotation cadences now say Weekly.
--   3. Behind = two whole weeks with no tick (the week under way never counts against a job). A job never ticked
--      counts from the board's first week, 2026-11-09.
--   4. The flag is the server's, every Monday morning: one text to Colin (ops_alerts), one desk post for everyone,
--      and a line in agent_attention for Muse until the job is ticked. The board shows it in red.

create table if not exists public.research_week_ticks (
  job_id      integer not null references public.research_jobs(id),
  week        date not null check (extract(isodow from week) = 1),   -- the Monday, Central
  done        boolean not null default false,
  note        text,
  by          text,
  at          timestamptz not null default now(),
  primary key (job_id, week)
);
alter table public.research_week_ticks enable row level security;
drop policy if exists research_week_ticks_team_read on public.research_week_ticks;
create policy research_week_ticks_team_read on public.research_week_ticks for select using (public.is_team());

create or replace function public.research_week(p_now timestamptz default now()) returns date language sql stable as $$
  select date_trunc('week', (p_now at time zone 'America/Chicago'))::date
$$;
create or replace function public.research_first_week() returns date language sql immutable as $$ select date '2026-11-09' $$;

-- the monthly ticks, each in the week it was made
insert into public.research_week_ticks (job_id, week, done, note, by, at)
select t.job_id, greatest(public.research_week(t.at), public.research_first_week()), t.done, t.note, t.by, t.at from public.research_ticks t
on conflict (job_id, week) do nothing;

update public.research_jobs set cadence = 'Weekly' where cadence = 'Monthly';
update public.research_jobs set cadence = 'Weekly (rides the rotation)' where cadence = 'Rides rotation';

-- one row per job: the last week it ran end to end and how many whole weeks have gone by without a tick since
create or replace function public.research_standing(p_now timestamptz default now())
returns table (job_id integer, last_done date, weeks_missed integer) language sql stable security definer set search_path = public as $$
  select j.id, t.last_done,
         case when t.last_done is null then greatest(0, (public.research_week(p_now) - public.research_first_week()) / 7)
              else greatest(0, (public.research_week(p_now) - t.last_done) / 7 - 1) end
    from public.research_jobs j
    left join lateral (select max(w.week) as last_done from public.research_week_ticks w
                        where w.job_id = j.id and w.done and w.week <= public.research_week(p_now)) t on true
$$;
revoke all on function public.research_standing(timestamptz) from public, anon, authenticated;
grant execute on function public.research_standing(timestamptz) to service_role;

create or replace function public.research_behind(p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('job', j.id, 'key', j.key, 'priority', j.priority, 'category', j.category, 'what', left(j.job, 160),
           'last_ran_week_of', s.last_done, 'weeks_with_no_tick', s.weeks_missed, 'status', j.status) order by j.sort), '[]'::jsonb)
    from public.research_jobs j join public.research_standing(p_now) s on s.job_id = j.id
   where s.weeks_missed >= 2
$$;
revoke all on function public.research_behind(timestamptz) from public, anon, authenticated;
grant execute on function public.research_behind(timestamptz) to service_role;

-- the board, for the page (team) and the door (service role). 'months' stays, empty, for a page that was open when
-- this landed; nothing reads it after that.
create or replace function public.research_board() returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'week', to_char(public.research_week(now()), 'YYYY-MM-DD'),
    'weeks', (select jsonb_agg(to_char(w, 'YYYY-MM-DD') order by w desc)
                from generate_series(greatest(public.research_first_week(), public.research_week(now()) - 49), public.research_week(now()), interval '7 days') w),
    'months', '[]'::jsonb,
    'jobs', (select coalesce(jsonb_agg(jsonb_build_object('id', j.id, 'key', j.key, 'priority', j.priority, 'category', j.category, 'job', j.job, 'data', j.data,
               'source', j.source, 'cadence', j.cadence, 'status', j.status, 'status_at', j.status_at, 'status_by', j.status_by,
               'last_done', s.last_done, 'weeks_missed', s.weeks_missed, 'behind', s.weeks_missed >= 2,
               'ticks', (select coalesce(jsonb_object_agg(to_char(t.week, 'YYYY-MM-DD'), jsonb_build_object('done', t.done, 'note', t.note, 'by', t.by, 'at', t.at)), '{}'::jsonb)
                           from public.research_week_ticks t where t.job_id = j.id)) order by j.sort), '[]'::jsonb)
               from public.research_jobs j join public.research_standing(now()) s on s.job_id = j.id),
    'legs', jsonb_build_array('foreclosure_cv', 'probate_pr', 'tax', 'need_signal', 'sale_refresh'),
    'counties', (select coalesce(jsonb_agg(jsonb_build_object('county', c.county,
                   'legs', (select coalesce(jsonb_object_agg(t.leg, jsonb_build_object('done', t.done, 'note', t.note, 'by', t.by, 'at', t.at)), '{}'::jsonb)
                              from public.research_county_ticks t where t.county = c.county)) order by c.sort), '[]'::jsonb) from public.research_counties c),
    'as_of', now())
$$;
grant execute on function public.research_board() to authenticated, service_role;

-- a tick or a status note on a job. The second argument was a month; it is now any day of the week being ticked, and
-- left out it is this week.
drop function if exists public.agent_research_set(text, date, boolean, text, text, text);
create function public.agent_research_set(p_job text, p_week date, p_done boolean, p_note text, p_status text, p_agent text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare j public.research_jobs; who text := coalesce(p_agent, 'agent'); w date; this_week date := public.research_week(now());
begin
  select * into j from public.research_jobs where key = lower(coalesce(p_job, '')) or id::text = coalesce(p_job, '');
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such job: pass its number (1-20) or key', 'keys', (select jsonb_agg(key order by sort) from public.research_jobs)); end if;
  if p_status is null and p_done is null and nullif(btrim(coalesce(p_note, '')), '') is null then
    return jsonb_build_object('ok', false, 'reason', 'pass done (true: the job ran end to end that week; false: it did not) and/or a note for the week, or a status');
  end if;
  if p_status is not null then
    update public.research_jobs set status = left(btrim(p_status), 400), status_at = now(), status_by = who where id = j.id;
  end if;
  if p_done is not null or nullif(btrim(coalesce(p_note, '')), '') is not null then
    w := case when p_week is null then this_week else date_trunc('week', p_week)::date end;
    if w > this_week then return jsonb_build_object('ok', false, 'reason', 'that week has not started: a tick is for a week the job already ran in'); end if;
    if w < public.research_first_week() then return jsonb_build_object('ok', false, 'reason', 'the board starts the week of 2026-11-09'); end if;
    insert into public.research_week_ticks (job_id, week, done, note, by, at) values (j.id, w, coalesce(p_done, false), nullif(btrim(coalesce(p_note, '')), ''), who, now())
    on conflict (job_id, week) do update set done = coalesce(p_done, research_week_ticks.done), note = coalesce(nullif(btrim(coalesce(p_note, '')), ''), research_week_ticks.note), by = who, at = now();
  end if;
  return jsonb_build_object('ok', true, 'job', j.key, 'week', w, 'done', p_done, 'status', case when p_status is not null then left(btrim(p_status), 400) else j.status end);
end $$;
revoke all on function public.agent_research_set(text, date, boolean, text, text, text) from public, anon, authenticated;
grant execute on function public.agent_research_set(text, date, boolean, text, text, text) to service_role;

-- The Monday flag: once a week, when a new week has just put a job two whole weeks behind (or left it there).
create table if not exists public.research_flags (
  week        date primary key,
  at          timestamptz not null default now(),
  jobs        jsonb not null,
  desk_id     bigint,
  ops_id      bigint
);
alter table public.research_flags enable row level security;
drop policy if exists research_flags_team_read on public.research_flags;
create policy research_flags_team_read on public.research_flags for select using (public.is_team());

create or replace function public.research_behind_words(p_behind jsonb) returns text language sql immutable as $$
  select string_agg((b->>'category') || ' (job ' || (b->>'job') || ', ' || case when b->>'last_ran_week_of' is null then 'never ticked'
           else 'last ran the week of ' || to_char((b->>'last_ran_week_of')::date, 'Mon FMDD') end || ')', '; ' order by (b->>'job')::int)
    from jsonb_array_elements(coalesce(p_behind, '[]'::jsonb)) b
$$;

create or replace function public.research_behind_flag(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w date := public.research_week(p_now); behind jsonb := public.research_behind(p_now); n integer; words text; d jsonb; o bigint; body text;
begin
  n := jsonb_array_length(behind);
  if n = 0 then return jsonb_build_object('ok', true, 'week', w, 'behind', 0); end if;
  if exists (select 1 from public.research_flags where week = w) then return jsonb_build_object('ok', true, 'week', w, 'behind', n, 'already_flagged', true); end if;
  insert into public.research_flags (week, jobs) values (w, behind);
  words := public.research_behind_words(behind);
  insert into public.ops_alerts (text, created_at)
  values (left('Research behind: ' || n::text || ' job' || case when n = 1 then ' has' else 's have' end || ' had no tick for more than two weeks: ' || words, 290)
          || '. The Research page has the list.', p_now)
  returning id into o;
  select string_agg('- ' || (b->>'priority') || ' job ' || (b->>'job') || ', ' || (b->>'category') || ': '
           || case when b->>'last_ran_week_of' is null then 'never ticked' else 'last ran the week of ' || to_char((b->>'last_ran_week_of')::date, 'Mon FMDD') end
           || ', ' || (b->>'weeks_with_no_tick') || ' whole weeks with no tick. Status on the board: ' || coalesce(b->>'status', 'none'), E'\n' order by (b->>'job')::int)
    into body from jsonb_array_elements(behind) b;
  d := public.desk_post('desk', 'all', 'note', 'Research board: ' || n::text || ' job' || case when n = 1 then '' else 's' end || ' behind more than two weeks',
    'The Research Board is weekly (app 0248, Colin 2026-11-17): every job is ticked each week it ran end to end, and a job with two whole weeks and no tick is flagged here, to Colin by text, and to Muse on every tool call until it is ticked.' || E'\n\n'
    || body || E'\n\n' || 'Whoever owns the job: run it end to end and tick the week (research_board_set: job, done true, a note saying what ran). If it cannot run, write the status saying what blocks it; that is not a tick and the job stays on this list.',
    null, null);
  update public.research_flags set ops_id = o, desk_id = (d->>'id')::bigint where week = w;
  return jsonb_build_object('ok', true, 'week', w, 'behind', n, 'desk_id', d->>'id', 'ops_id', o);
end $$;
revoke all on function public.research_behind_flag(timestamptz) from public, anon, authenticated;
grant execute on function public.research_behind_flag(timestamptz) to service_role;

do $do$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if exists (select 1 from cron.job where jobname = 'wpie-research-behind') then
      perform cron.unschedule('wpie-research-behind');
    end if;
    -- Monday 15:07 UTC: 9:07 AM Central in winter, 10:07 in summer
    perform cron.schedule('wpie-research-behind', '7 15 * * 1', 'select public.research_behind_flag()');
  end if;
end
$do$;

-- agent_attention: from 0242, plus the research line for the texting agent's lanes.
create or replace function public.agent_attention(p_agent text, p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  who text := case when lower(coalesce(p_agent, '')) like 'muse 2%' then 'muse 2' when lower(coalesce(p_agent, '')) like 'muse%' then 'muse' else lower(coalesce(p_agent, '')) end;
  last_read timestamptz; unread integer := 0; latest text; steps jsonb := '[]'::jsonb; n_late integer := 0; out jsonb := '{}'::jsonb;
  d date := (p_now at time zone 'America/Chicago')::date;
  is_sunday boolean := extract(isodow from (p_now at time zone 'America/Chicago')::date) = 7;
  c public.campaign_control; opened boolean := false; n_replies integer := 0; oldest timestamptz; behind jsonb;
begin
  -- the desk: posts for this agent (or everyone) by someone else since it last read the desk
  select max(c2.at) into last_read from public.agent_calls c2 join public.agent_keys k on k.id = c2.key_id
   where lower(k.name) = lower(p_agent) and c2.tool = 'desk_inbox' and c2.ok;
  select count(*), (array_agg(m.topic order by m.id desc))[1] into unread, latest from public.desk_messages m
   where m.for_whom in (who, 'all') and m.author <> who and m.at > coalesce(last_read, p_now - interval '2 days') and m.at > p_now - interval '7 days';
  if unread > 0 then
    out := out || jsonb_build_object('desk', unread::text || ' post' || case when unread = 1 then '' else 's' end || ' for you on the desk since you last read it'
      || coalesce(' (' || to_char(last_read at time zone 'America/Chicago', 'Dy HH12:MI AM') || ' Central)', '') || ', the newest: "' || left(coalesce(latest, ''), 140) || '". Read desk_inbox now.');
  end if;
  if who = 'muse' then
    -- a Sunday that was opened (0240) says so here: the rules text says "never on Sunday" and nothing else tells the agent
    select * into c from public.campaign_control where id = 1;
    opened := is_sunday and c.sunday_open_day is not distinct from d;
    if opened then
      out := out || jsonb_build_object('sunday', 'Today is a Sunday that was opened for texting'
        || coalesce(' by ' || nullif(trim(c.sunday_open_by), ''), '') || coalesce(' (' || nullif(trim(c.sunday_open_why), '') || ')', '')
        || '. For today only the "never on Sunday" rule is off: work the day''s list and answer replies (replies_waiting, send_reply) as on a weekday, 10 AM to 7 PM in the owner''s time zone, under every other rule as it stands. It closes itself on Monday; a Sunday with no line like this one is shut.');
    end if;
    -- people who wrote back and have had no answer (not on a Sunday that is shut: nothing sends then)
    if not is_sunday or opened then
      select count(*), min(r.received_at) into n_replies, oldest from public.replies_waiting_rows(1) r
       where r.received_at < p_now - interval '20 minutes';
      if n_replies > 0 then
        out := out || jsonb_build_object('replies', n_replies::text || case when n_replies = 1 then ' person' else ' people' end
          || ' texted back in the last day and ' || case when n_replies = 1 then 'has' else 'have' end || ' had no answer, the oldest since '
          || to_char(oldest at time zone 'America/Chicago', 'Dy HH12:MI AM') || ' Central. Read replies_waiting now and answer each with send_reply; one that needs no answer (a wrong number, a house already sold) is closed with mark_card.');
      end if;
    end if;
    -- the offer path: steps that are this agent's (only the texting agent has them)
    select coalesce(jsonb_agg(jsonb_build_object('offer_id', o.id, 'lead_id', o.lead_id, 'address', l.property_address, 'step', v.j->>'step',
             'due_at', v.j->>'due_at', 'late', (v.j->>'late')::boolean, 'do', v.j->>'say') order by v.j->>'due_at'), '[]'::jsonb),
           count(*) filter (where (v.j->>'late')::boolean)
      into steps, n_late
      from public.text_offers o join public.leads l on l.id = o.lead_id cross join lateral (select public.text_offer_view(o, p_now) as j) v
     where o.status = 'open' and v.j->>'who' = 'muse';
    if jsonb_array_length(steps) > 0 then
      out := out || jsonb_build_object('offers', jsonb_build_object(
        'say', jsonb_array_length(steps)::text || ' seller' || case when jsonb_array_length(steps) = 1 then '' else 's' end || ' asked for a number and the next step is yours'
               || case when n_late > 0 then ' (' || n_late::text || ' late)' else '' end
               || '. Each row says what to do; record it with offer_update, and read offer_worklist for the whole list. If those tools are not in your tool list, list the tools again or start a new session: they were added on 2026-11-13. The how is in texting_rules ("The offer by text") and desk post 254.',
        'steps', steps));
    end if;
    -- the Research Board (0248): jobs with no tick for two whole weeks
    select public.research_behind(p_now) into behind;
    if jsonb_array_length(behind) > 0 then
      out := out || jsonb_build_object('research', jsonb_build_object(
        'say', jsonb_array_length(behind)::text || ' research job' || case when jsonb_array_length(behind) = 1 then ' has' else 's have' end
               || ' had no tick on the Research Board for more than two weeks. The board is weekly now: run each one end to end (pull, verification, cards in WPIE) and tick the week with research_board_set (job, done true, a note saying what ran; leave week out for this week). A job that cannot run gets a status saying what blocks it, not a tick. Colin is told about this list every Monday.',
        'behind', behind));
    end if;
  end if;
  return case when out = '{}'::jsonb then null else out end;
end $$;
revoke all on function public.agent_attention(text, timestamptz) from public, anon, authenticated;
grant execute on function public.agent_attention(text, timestamptz) to service_role;
