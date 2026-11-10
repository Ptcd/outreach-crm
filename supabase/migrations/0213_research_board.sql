-- 0213: the Research Board (Colin 2026-11-10, through Muse's desk posts 174 and 175): where every research source stands,
-- one page in WPIE that Muse's jobs and the desk both tick and Colin only reads. Twenty source jobs in priority order,
-- a monthly tick Nov 2026 - Oct 2027 (a tick means the job ran end to end that month: pull, verification, cards in
-- WPIE; in progress is a note, not a tick), and a county view: 21 buy-box counties x five legs. Seeded with the status
-- Muse reported on 2026-11-10 and only the ticks it listed as done.

create table if not exists public.research_jobs (
  id          integer primary key,
  key         text not null unique,
  priority    text not null,                 -- P1 | P2 | P3
  category    text not null,
  job         text not null,                 -- what the job is, in one line
  data        text,                          -- the data that must be attributed
  source      text,                          -- source / portal
  cadence     text not null,
  status      text,                          -- the current status note (in progress, blocked, ...)
  status_at   timestamptz,
  status_by   text,
  sort        integer not null
);
create table if not exists public.research_ticks (
  job_id      integer not null references public.research_jobs(id),
  month       date not null,                 -- the first of the month
  done        boolean not null default false,
  note        text,
  by          text,
  at          timestamptz not null default now(),
  primary key (job_id, month)
);
create table if not exists public.research_counties (
  county      text primary key,
  sort        integer not null
);
create table if not exists public.research_county_ticks (
  county      text not null references public.research_counties(county),
  leg         text not null check (leg in ('foreclosure_cv', 'probate_pr', 'tax', 'need_signal', 'sale_refresh')),
  done        boolean not null default false,
  note        text,
  by          text,
  at          timestamptz not null default now(),
  primary key (county, leg)
);
alter table public.research_jobs enable row level security;
alter table public.research_ticks enable row level security;
alter table public.research_counties enable row level security;
alter table public.research_county_ticks enable row level security;
drop policy if exists research_jobs_team_read on public.research_jobs;
create policy research_jobs_team_read on public.research_jobs for select using (public.is_team());
drop policy if exists research_ticks_team_read on public.research_ticks;
create policy research_ticks_team_read on public.research_ticks for select using (public.is_team());
drop policy if exists research_counties_team_read on public.research_counties;
create policy research_counties_team_read on public.research_counties for select using (public.is_team());
drop policy if exists research_county_ticks_team_read on public.research_county_ticks;
create policy research_county_ticks_team_read on public.research_county_ticks for select using (public.is_team());

-- the twenty jobs (post 174, with post 175's amendment to jobs 2 and 3)
insert into public.research_jobs (id, key, priority, category, job, data, source, cadence, status, status_at, status_by, sort) values
 (1, 'foreclosure_cv', 'P1', 'Foreclosure', 'WCCA foreclosure (CV) fresh filing pulls, staggered weekly: Mon Milwaukee/Bayfield/Door, Tue Waukesha/Vilas/Sawyer, Wed Kenosha/Rock, Thu Racine/Walworth/Washington, Fri Dane/Brown/Winnebago, Sat Fond du Lac/Marathon/Outagamie, Sun La Crosse/Oneida/Eau Claire/Sheboygan.', 'county + case, owner/defendant, address, parcel, filing date, plaintiff, judgment when published, sale date when set', 'WCCA', 'Weekly', 'DONE: backfill complete all 21 counties, rotation live since 2026-11-09', '2026-11-10', 'Muse', 1),
 (2, 'sale_refresh', 'P1', 'Foreclosure/sales', 'Sheriff-sale date refresh for EVERY card in the store (about 10,300): sheriff lists, Auction.com, Xome, legal notices. Weekly full-store sweep: sales are set weeks out and adjourn on weekly cycles; daily wastes lanes, monthly misses the 15-30-day sprint band.', 'confirmed sale date/time, address, case, opening bid if published, status confirmed/adjourned/cancelled/stayed', 'sheriff lists, Auction.com, Xome, legal notices', 'Weekly', 'DONE: first full refresh 2026-11-09, 132 confirmed sales', '2026-11-10', 'Muse', 2),
 (3, 'post_sale_rechecks', 'P1', 'Foreclosure/sales', 'Post-sale rechecks: the main job is DELETING cards. Sold at sale: card killed the same pass (the seller no longer owns it, all cadence stops). Adjourned: the new date is stamped and the property re-enters screening. Cancelled or dismissed: the card stays and is re-graded without the sale leg.', 'sale outcome per case', 'sheriff results, WCCA, Register of Deeds', 'Per sale', 'DONE: running (Johnson/Stinson 2026-11-09; more scheduled Nov 11-13)', '2026-11-10', 'Muse', 3),
 (4, 'probate_pr', 'P1', 'Probate', 'WCCA probate (PR) pulls; trace the PR or special administrator only, never the decedent; deed pull whenever no PR is appointed.', 'decedent, PR name, case, address/parcel, appointment status', 'WCCA', 'Monthly', 'DONE: backfill ran end to end (Milwaukee June detail lane hCaptcha-blocked)', '2026-11-10', 'Muse', 4),
 (5, 'tax_delinquent', 'P2', 'Tax', 'County tax-delinquent pulls, 2+ unpaid years.', 'parcel, owner, years delinquent, arrears $ where printed, assessed + year', 'county treasurer / Ascent', 'Monthly', 'DONE: core source, the bulk of the store is tax-driven', '2026-11-10', 'Muse', 5),
 (6, 'evictions', 'P2', 'Evictions', 'Eviction filing harvests; the plaintiff landlord is the prospect, tenants record-only.', 'landlord, address, parcel, filing count/dates', 'WCCA', 'Monthly', 'NOT DONE: in progress, 19,199 filings triaged, verification slices E1-E42 running, survivors not yet imported', '2026-11-10', 'Muse', 6),
 (7, 'bankruptcy', 'P2', 'Bankruptcy', 'Filer pulls; closed + active = outreach (never named to the seller; an active stay = no closing).', 'filer, case, address/parcel, status', 'PACER / public lists', 'Monthly', 'NOT DONE: posture set, no dedicated pull run yet', '2026-11-10', 'Muse', 7),
 (8, 'money_judgments', 'P3', 'Need-signal', 'Pre-lien money judgments and civil money suits (WCCA), last 2 months only. One motivation leg; never named to the seller.', 'defendant, case, amount, address/parcel', 'WCCA', 'Rides rotation', 'NOT DONE: adopted 2026-11-08, build not started', '2026-11-10', 'Muse', 8),
 (9, 'divorce_fa', 'P3', 'Need-signal', 'Divorce filings (FA).', 'parties, case, address/parcel', 'WCCA', 'Rides rotation', 'NOT DONE: adopted 2026-11-08, build not started', '2026-11-10', 'Muse', 9),
 (10, 'guardianship_gn', 'P3', 'Need-signal', 'Guardianship filings (GN). Human only: no text, no paid trace; Colin calls the guardian.', 'ward, guardian, case, address/parcel', 'WCCA', 'Rides rotation', 'NOT DONE: adopted 2026-11-08, build not started', '2026-11-10', 'Muse', 10),
 (11, 'water_shutoff', 'P3', 'Municipal/records', 'Water-shutoff lists (records desk).', 'address, parcel, shutoff date', 'municipal records requests', 'Monthly', 'NOT DONE: no pull run yet', '2026-11-10', 'Muse', 11),
 (12, 'fire_damage', 'P3', 'Municipal/records', 'Fire-damage lists (records desk).', 'address, parcel, incident date', 'fire departments, records requests', 'Monthly', 'NOT DONE: Eagle River request in flight, no list received', '2026-11-10', 'Muse', 12),
 (13, 'vacant_registry', 'P3', 'Municipal/records', 'Vacant registry.', 'address, parcel, registration date', 'municipal registries', 'Monthly', 'NOT DONE: no dedicated pull run yet', '2026-11-10', 'Muse', 13),
 (14, 'code_raze', 'P3', 'Municipal/records', 'Major code / raze orders.', 'address, parcel, order date, type', 'building inspection, DNS', 'Monthly', 'NOT DONE: no dedicated pull run yet', '2026-11-10', 'Muse', 14),
 (15, 'stage_d_verification', 'P3', 'Verification', 'Stage D assessor verification: owner, mailing, type, assessed + year + source, finished sq ft, beds, baths, basement statement; all required before a card is ready.', 'as listed', 'county assessor', 'Every batch', 'DONE: 1,220 agent-verified cards', '2026-11-10', 'Muse', 15),
 (16, 'name_to_parcel', 'P3', 'Verification', 'Name-to-parcel matching.', 'parcel per owner', 'county parcel layers', 'Every batch', 'DONE: runs inside every pull cycle', '2026-11-10', 'Muse', 16),
 (17, 'rod_mortgages', 'P3', 'Verification', 'ROD mortgage lookups into the equity band.', 'mortgages, amounts, dates', 'Register of Deeds (free index)', 'Nightly batches', 'DONE: batches 1-3 complete (batch 6 blocked, the server re-serves batch 3)', '2026-11-10', 'Muse', 17),
 (18, 'deed_pulls', 'P3', 'Verification', 'Deed pulls for estates with no appointment.', 'grantor, grantee, date', 'Register of Deeds', 'As triggered', 'DONE: rule live since 2026-10-29', '2026-11-10', 'Muse', 18),
 (19, 'phone_tracing', 'P3', 'Verification', 'Phone tracing (FPS): all numbers with type and carrier, EXACT/PARTIAL verdicts, separated counts.', 'phones per person', 'FPS', 'Nightly', 'DONE: phones_wanted nightly; S11 passes 1-4 loaded 396 numbers', '2026-11-10', 'Muse', 19),
 (20, 'mls_comps', 'P3', 'Verification', 'MLS comp and room check: FlexMLS/WIREX sold comps; ARV centre, as-is centre, LAO vs judgment.', 'comps, ARV, as-is, LAO', 'FlexMLS / WIREX', 'Per package / sale window', 'DONE: ready-11 + slices 1-2 done (13 with room); Milwaukee + slice 3 running 2026-11-10', '2026-11-10', 'Muse', 20)
on conflict (id) do nothing;

-- Nov 2026 ticks: only the jobs Muse listed as DONE
insert into public.research_ticks (job_id, month, done, note, by)
select id, date '2026-11-01', true, 'seeded from desk post 174 (status 2026-11-10)', 'Muse' from public.research_jobs where id in (1, 2, 3, 4, 5, 15, 16, 17, 18, 19, 20)
on conflict (job_id, month) do nothing;

-- the 21 buy-box counties, in the rotation's order
insert into public.research_counties (county, sort) values
 ('Milwaukee', 1), ('Bayfield', 2), ('Door', 3), ('Waukesha', 4), ('Vilas', 5), ('Sawyer', 6), ('Kenosha', 7), ('Rock', 8), ('Racine', 9), ('Walworth', 10), ('Washington', 11),
 ('Dane', 12), ('Brown', 13), ('Winnebago', 14), ('Fond du Lac', 15), ('Marathon', 16), ('Outagamie', 17), ('La Crosse', 18), ('Oneida', 19), ('Eau Claire', 20), ('Sheboygan', 21)
on conflict (county) do nothing;
insert into public.research_county_ticks (county, leg, done, note, by)
select c.county, leg, true, 'seeded from desk post 174 (2026-11-10)', 'Muse' from public.research_counties c, unnest(array['foreclosure_cv', 'tax', 'sale_refresh']) leg
on conflict (county, leg) do nothing;
insert into public.research_county_ticks (county, leg, done, note, by)
select c.county, 'probate_pr', true, 'seeded from desk post 174 (2026-11-10)', 'Muse' from public.research_counties c where c.county in ('Milwaukee', 'Dane', 'Winnebago')
on conflict (county, leg) do nothing;

-- the board, for the page (team) and the door (service role)
create or replace function public.research_board() returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'months', (select jsonb_agg(to_char(m, 'YYYY-MM-DD') order by m) from generate_series(date '2026-11-01', date '2027-10-01', interval '1 month') m),
    'jobs', (select coalesce(jsonb_agg(jsonb_build_object('id', j.id, 'key', j.key, 'priority', j.priority, 'category', j.category, 'job', j.job, 'data', j.data,
               'source', j.source, 'cadence', j.cadence, 'status', j.status, 'status_at', j.status_at, 'status_by', j.status_by,
               'ticks', (select coalesce(jsonb_object_agg(to_char(t.month, 'YYYY-MM-DD'), jsonb_build_object('done', t.done, 'note', t.note, 'by', t.by, 'at', t.at)), '{}'::jsonb)
                           from public.research_ticks t where t.job_id = j.id)) order by j.sort), '[]'::jsonb) from public.research_jobs j),
    'legs', jsonb_build_array('foreclosure_cv', 'probate_pr', 'tax', 'need_signal', 'sale_refresh'),
    'counties', (select coalesce(jsonb_agg(jsonb_build_object('county', c.county,
                   'legs', (select coalesce(jsonb_object_agg(t.leg, jsonb_build_object('done', t.done, 'note', t.note, 'by', t.by, 'at', t.at)), '{}'::jsonb)
                              from public.research_county_ticks t where t.county = c.county)) order by c.sort), '[]'::jsonb) from public.research_counties c),
    'as_of', now())
$$;
grant execute on function public.research_board() to authenticated, service_role;

-- a tick or a status note on a job (Muse's lanes when a cycle completes; the desk for the legs it runs)
create or replace function public.agent_research_set(p_job text, p_month date, p_done boolean, p_note text, p_status text, p_agent text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare j public.research_jobs; who text := coalesce(p_agent, 'agent'); m date;
begin
  select * into j from public.research_jobs where key = lower(coalesce(p_job, '')) or id::text = coalesce(p_job, '');
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such job: pass its number (1-20) or key', 'keys', (select jsonb_agg(key order by sort) from public.research_jobs)); end if;
  if p_status is not null then
    update public.research_jobs set status = left(btrim(p_status), 400), status_at = now(), status_by = who where id = j.id;
  end if;
  if p_month is not null then
    m := date_trunc('month', p_month)::date;
    if m < date '2026-11-01' or m > date '2027-10-01' then return jsonb_build_object('ok', false, 'reason', 'month is between 2026-11 and 2027-10'); end if;
    if p_done is null and p_note is null then return jsonb_build_object('ok', false, 'reason', 'with a month, pass done (true: the job ran end to end that month; false: it did not) and/or a note'); end if;
    insert into public.research_ticks (job_id, month, done, note, by, at) values (j.id, m, coalesce(p_done, false), nullif(btrim(coalesce(p_note, '')), ''), who, now())
    on conflict (job_id, month) do update set done = coalesce(p_done, research_ticks.done), note = coalesce(nullif(btrim(coalesce(p_note, '')), ''), research_ticks.note), by = who, at = now();
  elsif p_status is null then
    return jsonb_build_object('ok', false, 'reason', 'pass a month with done and/or a note, or a status');
  end if;
  return jsonb_build_object('ok', true, 'job', j.key, 'month', m, 'done', p_done, 'status', case when p_status is not null then left(btrim(p_status), 400) else j.status end);
end $$;
revoke all on function public.agent_research_set(text, date, boolean, text, text, text) from public, anon, authenticated;
grant execute on function public.agent_research_set(text, date, boolean, text, text, text) to service_role;

create or replace function public.agent_research_county_set(p_county text, p_leg text, p_done boolean, p_note text, p_agent text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare c text; who text := coalesce(p_agent, 'agent');
begin
  select county into c from public.research_counties where lower(county) = lower(btrim(coalesce(p_county, '')));
  if c is null then return jsonb_build_object('ok', false, 'reason', 'not a buy-box county', 'counties', (select jsonb_agg(county order by sort) from public.research_counties)); end if;
  if coalesce(p_leg, '') not in ('foreclosure_cv', 'probate_pr', 'tax', 'need_signal', 'sale_refresh') then
    return jsonb_build_object('ok', false, 'reason', 'leg is one of: foreclosure_cv, probate_pr, tax, need_signal, sale_refresh');
  end if;
  insert into public.research_county_ticks (county, leg, done, note, by, at) values (c, p_leg, coalesce(p_done, false), nullif(btrim(coalesce(p_note, '')), ''), who, now())
  on conflict (county, leg) do update set done = coalesce(p_done, research_county_ticks.done), note = coalesce(nullif(btrim(coalesce(p_note, '')), ''), research_county_ticks.note), by = who, at = now();
  return jsonb_build_object('ok', true, 'county', c, 'leg', p_leg, 'done', coalesce(p_done, (select done from public.research_county_ticks where county = c and leg = p_leg)));
end $$;
revoke all on function public.agent_research_county_set(text, text, boolean, text, text) from public, anon, authenticated;
grant execute on function public.agent_research_county_set(text, text, boolean, text, text) to service_role;
