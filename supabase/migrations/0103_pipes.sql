-- WPIE data pipes, phase 1a (Muse's dev spec 2026-10-28, Colin approved the direction the same day): free public feeds
-- land in STAGING here, pass the promotion gates, and become verification-queue items Muse's lanes claim and close.
--
-- Colin's six rules, as this schema keeps them:
--   1. Staging is not cards. Nothing here writes leads, contacts, texts or outreach. Promotion to a card stays on
--      add_prospects (the people / interests model); a verified queue item only says the lane may do that.
--   2. A parcel alone is never a lead. A queue item needs a distress signal (pipe_signals, or the reasons already on
--      a card); an MPROP row is the property side only.
--   3. Conflicts are preserved. When the pipe's owner disagrees with a card, both go in pipe_conflicts with their
--      source and date, the card is flagged there (and a re_screen item opens), and the card is never written.
--   4. Every value carries its basis: assessed value with its source, assessment year and the date of the file it
--      came from (pipe_parcels.vintage, pipe_sources.last_file_date). No judgment, listing, mortgage or estimate is
--      ever stored as a value.
--   5. Dedupe before create: a staged parcel matches ALL cards by county + parcel id first, then by normalized
--      address (addr_key(addr_main())) in the same county and town. A match is a stack candidate, never a new card.
--   6. No fees, no paid accounts, no WCCA scraping. The feeds are the city's and the state's free files.
--
-- The gates (pipe_screen): 1 county in the 21 buy-box counties (pipe_settings) · 2 type: single family, duplex or a
-- condo by explicit classification (MPROP LAND_USE 8811); 3+ units, commercial, land and exempt are out · 3 assessed
-- value strictly under $500,000 with its basis · 4 Milwaukee map: inside Muse's exclusion polygon = out, inside the
-- ~275 m band around it = held_buffer for Colin's parcel ruling, never guessed; no map loaded = not queued ·
-- 5 distress: one qualifying signal; tax only at 2+ unpaid years; a DOR row only pairs · 6 no freeze: an active
-- bankruptcy, a deceased sole owner with no live representative, or a dead / do-not-contact card blocks it.

-- ------------------------------------------------------------------ settings and sources
create table if not exists public.pipe_settings (
  id               smallint primary key default 1 check (id = 1),
  buy_box_counties text[] not null,
  value_cap        numeric not null default 500000,
  buffer_m         numeric not null default 275,
  claim_hours      integer not null default 24,
  updated_at       timestamptz not null default now()
);
-- Muse's 21 counties (docs/RECORDS_AGENT.md in WPIE, 2026-10-28)
insert into public.pipe_settings (id, buy_box_counties) values (1, array['Brown', 'Dane', 'Eau Claire', 'Fond du Lac', 'Kenosha',
  'La Crosse', 'Marathon', 'Milwaukee', 'Outagamie', 'Racine', 'Rock', 'Sheboygan', 'Walworth', 'Washington', 'Waukesha',
  'Winnebago', 'Vilas', 'Door', 'Oneida', 'Sawyer', 'Bayfield']) on conflict (id) do nothing;

create table if not exists public.pipe_sources (
  source          text primary key,
  name            text not null,
  county          text,
  url             text,
  cadence         text,
  grade           text not null default 'current' check (grade in ('current', 'pre_screen')),
  last_file_date  date,
  last_fetched_at timestamptz,
  last_sha        text,
  rows            integer,
  note            text
);
insert into public.pipe_sources (source, name, county, url, cadence, grade, note) values
  ('mke.mprop', 'City of Milwaukee MPROP master property file', 'Milwaukee',
   'https://data.milwaukee.gov/dataset/562ab824-48a5-42cd-b714-87e205e489ba/resource/0a2c7f31-cd15-4151-8222-09dd57d5f16d/download/mprop.csv',
   'daily', 'current', 'City of Milwaukee parcels only (not the suburbs). TAX_DELQ / BI_VIOL / RAZE_STATUS are masked in the public file and carry no signal.')
on conflict (source) do nothing;

-- ------------------------------------------------------------------ staged parcels (the property side)
create table if not exists public.pipe_parcels (
  county           text not null,
  parcel_id        text not null,
  source           text not null references public.pipe_sources (source),
  situs_address    text,
  addr_key         text,
  municipality     text,
  zip              text,
  owner_names      text[] not null default '{}',
  owner_key        text,
  mail_street      text,
  mail_city        text,
  mail_state       text,
  mail_zip         text,
  -- type: the source's own codes kept as the basis, use_class is the gate's reading of them:
  -- single_family | duplex | condo | residential (units unknown) | apartment_3plus | commercial | vacant_land | exempt | other
  use_class        text,
  land_use         text,
  land_use_group   text,
  prop_class       text,
  bldg_type        text,
  units            integer,
  condo            boolean not null default false,
  assessed_land    numeric,
  assessed_impr    numeric,
  assessed_total   numeric,
  assessment_year  integer,
  year_built       integer,
  zoning           text,
  last_conveyed    date,
  lat              double precision,
  lon              double precision,
  point_source     text,
  vintage          date not null,           -- the date of the file these facts were last changed in
  row_hash         text not null,
  first_seen       date not null,
  owner_changed_on date,                    -- the file date the owner last changed (the re-screen event)
  gone_on          date,                    -- the file date it stopped appearing (rows are never deleted)
  gate             jsonb,                   -- the last screen's verdict
  gate_at          timestamptz,
  updated_at       timestamptz not null default now(),
  primary key (county, parcel_id, source)
);
create index if not exists pipe_parcels_addr_idx on public.pipe_parcels (county, addr_key);
create index if not exists pipe_parcels_owner_changed_idx on public.pipe_parcels (owner_changed_on) where owner_changed_on is not null;

-- every change a file brought: new, owner, mailing, value, class, other, gone, back
create table if not exists public.pipe_parcel_changes (
  id         bigint generated always as identity primary key,
  county     text not null,
  parcel_id  text not null,
  source     text not null,
  changed_on date not null,
  kinds      text[] not null,
  before     jsonb,
  after      jsonb,
  created_at timestamptz not null default now()
);
create index if not exists pipe_parcel_changes_parcel_idx on public.pipe_parcel_changes (county, parcel_id, changed_on desc);
create index if not exists pipe_parcel_changes_day_idx on public.pipe_parcel_changes (changed_on, source);

-- staged signals (distress). A signal that stops appearing in its source stays: a stack is history, not a state.
create table if not exists public.pipe_signals (
  id               bigint generated always as identity primary key,
  source           text not null,
  source_record_id text not null,
  kind             text not null,          -- vacant_building, tax_delinquent, code_violation, raze_order, permit, bankruptcy, dor_delinquent ...
  county           text not null,
  parcel_id        text,
  address          text,
  addr_key         text,
  municipality     text,
  signal_date      date,
  tax_years        integer,                -- distinct unpaid tax years (installments are not years)
  pairs_only       boolean not null default false,  -- a DOR row: stacks and pairs, never qualifies alone
  active           boolean not null default true,   -- bankruptcy: an open case freezes
  detail           jsonb not null default '{}',
  fetched_at       timestamptz not null default now(),
  first_seen       date not null default current_date,
  last_seen        date not null default current_date,
  unique (source, source_record_id)
);
create index if not exists pipe_signals_parcel_idx on public.pipe_signals (county, parcel_id);
create index if not exists pipe_signals_addr_idx on public.pipe_signals (county, addr_key);

-- the pipe disagrees with a card: both sides, each with its source and date; the card is flagged here, never written
create table if not exists public.pipe_conflicts (
  id          bigint generated always as identity primary key,
  lead_id     uuid not null references public.leads (id) on delete cascade,
  county      text not null,
  parcel_id   text not null,
  field       text not null,               -- owner (cards carry no assessed value)
  card_value  text,
  card_basis  text,
  pipe_value  text not null,
  pipe_source text not null,
  pipe_date   date not null,
  created_at  timestamptz not null default now(),
  closed_at   timestamptz,
  closed_by   text,
  closed_note text,
  unique (lead_id, field, pipe_value)
);
create index if not exists pipe_conflicts_open_idx on public.pipe_conflicts (lead_id) where closed_at is null;

-- Muse's polygon(s) for Milwaukee: exclusion (inside = out, within buffer_m of it = held for Colin) and clear (a
-- place the band does not reach, e.g. on or east of Holton St in Riverwest). Rings are [lon, lat] pairs.
create table if not exists public.pipe_map_areas (
  id        bigint generated always as identity primary key,
  name      text not null unique,
  kind      text not null check (kind in ('exclusion', 'clear')),
  rings     jsonb not null,                -- [[ [lon, lat], ... ], ...] one outer ring per polygon
  buffer_m  numeric,
  note      text,
  loaded_by text not null,
  loaded_at timestamptz not null default now()
);

-- the verification queue Muse's lanes claim and close
create table if not exists public.pipe_queue (
  id           uuid primary key default gen_random_uuid(),
  county       text not null,
  parcel_id    text not null,
  address      text,
  kind         text not null check (kind in ('new', 'stack', 're_screen')),
  state        text not null default 'open' check (state in ('open', 'claimed', 'held_buffer', 'held', 'verified', 'killed')),
  lead_id      uuid references public.leads (id) on delete set null,
  lead_ids     uuid[] not null default '{}',
  why          text[] not null default '{}',   -- signal | owner_changed | owner_conflict
  signal_ids   bigint[] not null default '{}',
  facts        jsonb not null default '{}',
  conflicts    jsonb not null default '[]',
  missing      text[] not null default '{}',
  gates        jsonb not null default '{}',
  claimed_by   text,
  claimed_at   timestamptz,
  outcome      text,
  outcome_note text,
  verified     jsonb,
  closed_by    text,
  closed_at    timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create unique index if not exists pipe_queue_live_idx on public.pipe_queue (county, parcel_id) where state in ('open', 'claimed', 'held_buffer', 'held');
create index if not exists pipe_queue_state_idx on public.pipe_queue (state, created_at);
create index if not exists pipe_queue_parcel_idx on public.pipe_queue (county, parcel_id, created_at desc);

create table if not exists public.pipe_runs (
  id          bigint generated always as identity primary key,
  source      text not null,
  started_at  timestamptz not null,
  finished_at timestamptz not null default now(),
  ok          boolean not null,
  file_date   date,
  counts      jsonb not null default '{}',
  note        text
);

-- the card lookups the screen makes (5,000 cards: built in milliseconds)
create index if not exists leads_parcel_idx on public.leads (parcel_id) where parcel_id is not null;
create index if not exists leads_addr_main_key_idx on public.leads (public.addr_key(public.addr_main(property_address)));

alter table public.pipe_settings enable row level security;
alter table public.pipe_sources enable row level security;
alter table public.pipe_parcels enable row level security;
alter table public.pipe_parcel_changes enable row level security;
alter table public.pipe_signals enable row level security;
alter table public.pipe_conflicts enable row level security;
alter table public.pipe_map_areas enable row level security;
alter table public.pipe_queue enable row level security;
alter table public.pipe_runs enable row level security;
create policy pipe_queue_owner on public.pipe_queue for select to authenticated using (public.is_owner());
create policy pipe_conflicts_owner on public.pipe_conflicts for select to authenticated using (public.is_owner());
create policy pipe_runs_owner on public.pipe_runs for select to authenticated using (public.is_owner());
grant select on public.pipe_queue, public.pipe_conflicts, public.pipe_runs to authenticated;

-- ------------------------------------------------------------------ names
-- "WAGNER, ASHLEY L" | "ASHLEY L WAGNER LIV TR" -> one key for change detection
create or replace function public.pipe_owner_key(p text[]) returns text language sql immutable as $$
  select nullif(array_to_string(array(select btrim(regexp_replace(upper(regexp_replace(coalesce(n, ''), '[^A-Za-z0-9 ]', ' ', 'g')), '\s+', ' ', 'g'))
                                         from unnest(coalesce(p, '{}')) n where btrim(coalesce(n, '')) <> ''), ' | '), '')
$$;

-- the words of a name that can identify a person: two letters or more, not entity or estate words
create or replace function public.pipe_name_words(p text) returns text[] language sql immutable as $$
  select coalesce(array_agg(distinct w), '{}') from regexp_split_to_table(upper(regexp_replace(coalesce(p, ''), '[^A-Za-z ]', ' ', 'g')), '\s+') w
   where length(w) >= 2 and w not in ('LLC', 'INC', 'CO', 'CORP', 'LP', 'LLP', 'LTD', 'TRUST', 'TR', 'TRS', 'TRUSTEE', 'TRUSTEES', 'REV', 'REVOCABLE',
     'LIV', 'LIVING', 'FAMILY', 'ESTATE', 'EST', 'OF', 'THE', 'AND', 'ET', 'AL', 'UX', 'JR', 'SR', 'II', 'III', 'IV', 'MR', 'MRS', 'MS', 'DR',
     'LE', 'LIFE', 'DTD', 'DATED', 'UTD', 'AGREEMENT', 'IRREV', 'IRREVOCABLE', 'HEIRS', 'DECEASED', 'C', 'O', 'CO', 'ATTN')
$$;

-- ------------------------------------------------------------------ loading (the laptop's publisher calls these)
-- A batch of a source's rows (jsonb array of pipe_parcels-shaped objects). Rows whose hash did not change are not
-- written. Each change is logged with what it was and what it became; an owner change stamps owner_changed_on (the
-- re-screen event). p_initial: the first load of a source logs no 'new' rows.
create or replace function public.pipe_upsert_parcels(p_source text, p_vintage date, p_rows jsonb, p_initial boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare n_written integer; n_changes integer; owners integer;
begin
  if not exists (select 1 from public.pipe_sources where source = p_source) then raise exception 'unknown pipe source %', p_source; end if;
  create temp table if not exists pipe_in on commit drop as select * from public.pipe_parcels limit 0;
  truncate pipe_in;
  insert into pipe_in select * from jsonb_populate_recordset(null::public.pipe_parcels, p_rows);
  update pipe_in set source = p_source, owner_names = coalesce(owner_names, '{}'), owner_key = public.pipe_owner_key(owner_names),
         addr_key = public.addr_key(public.addr_main(situs_address)), condo = coalesce(condo, false), vintage = p_vintage;

  with ch as (
    insert into public.pipe_parcel_changes (county, parcel_id, source, changed_on, kinds, before, after)
    select i.county, i.parcel_id, p_source, p_vintage,
           coalesce(nullif(array_remove(array[
             case when o.parcel_id is null then 'new' end,
             case when o.gone_on is not null then 'back' end,
             case when o.parcel_id is not null and i.owner_key is distinct from o.owner_key then 'owner' end,
             case when o.parcel_id is not null and (i.mail_street, i.mail_city, i.mail_state, i.mail_zip) is distinct from (o.mail_street, o.mail_city, o.mail_state, o.mail_zip) then 'mailing' end,
             case when o.parcel_id is not null and (i.assessed_total, i.assessment_year) is distinct from (o.assessed_total, o.assessment_year) then 'value' end,
             case when o.parcel_id is not null and (i.use_class, i.land_use, i.units, i.condo) is distinct from (o.use_class, o.land_use, o.units, o.condo) then 'class' end
           ], null), '{}'), '{other}'),
           case when o.parcel_id is null then null else jsonb_build_object('owner_names', o.owner_names, 'mail', jsonb_build_array(o.mail_street, o.mail_city, o.mail_state, o.mail_zip),
             'assessed_total', o.assessed_total, 'assessment_year', o.assessment_year, 'use_class', o.use_class, 'land_use', o.land_use, 'units', o.units, 'vintage', o.vintage) end,
           jsonb_build_object('owner_names', i.owner_names, 'mail', jsonb_build_array(i.mail_street, i.mail_city, i.mail_state, i.mail_zip),
             'assessed_total', i.assessed_total, 'assessment_year', i.assessment_year, 'use_class', i.use_class, 'land_use', i.land_use, 'units', i.units)
      from pipe_in i
      left join public.pipe_parcels o on o.county = i.county and o.parcel_id = i.parcel_id and o.source = p_source
     where (o.parcel_id is null and not p_initial) or (o.parcel_id is not null and (o.row_hash is distinct from i.row_hash or o.gone_on is not null))
    returning kinds)
  select count(*), count(*) filter (where 'owner' = any(kinds)) into n_changes, owners from ch;

  insert into public.pipe_parcels as p (county, parcel_id, source, situs_address, addr_key, municipality, zip, owner_names, owner_key,
         mail_street, mail_city, mail_state, mail_zip, use_class, land_use, land_use_group, prop_class, bldg_type, units, condo,
         assessed_land, assessed_impr, assessed_total, assessment_year, year_built, zoning, last_conveyed, lat, lon, point_source,
         vintage, row_hash, first_seen)
  select county, parcel_id, source, situs_address, addr_key, municipality, zip, owner_names, owner_key,
         mail_street, mail_city, mail_state, mail_zip, use_class, land_use, land_use_group, prop_class, bldg_type, units, condo,
         assessed_land, assessed_impr, assessed_total, assessment_year, year_built, zoning, last_conveyed, lat, lon, point_source,
         vintage, row_hash, p_vintage
    from pipe_in
  on conflict (county, parcel_id, source) do update set
         situs_address = excluded.situs_address, addr_key = excluded.addr_key, municipality = excluded.municipality, zip = excluded.zip,
         owner_names = excluded.owner_names, owner_key = excluded.owner_key, mail_street = excluded.mail_street, mail_city = excluded.mail_city,
         mail_state = excluded.mail_state, mail_zip = excluded.mail_zip, use_class = excluded.use_class, land_use = excluded.land_use,
         land_use_group = excluded.land_use_group, prop_class = excluded.prop_class, bldg_type = excluded.bldg_type, units = excluded.units,
         condo = excluded.condo, assessed_land = excluded.assessed_land, assessed_impr = excluded.assessed_impr,
         assessed_total = excluded.assessed_total, assessment_year = excluded.assessment_year, year_built = excluded.year_built,
         zoning = excluded.zoning, last_conveyed = excluded.last_conveyed,
         lat = coalesce(excluded.lat, p.lat), lon = coalesce(excluded.lon, p.lon), point_source = coalesce(excluded.point_source, p.point_source),
         vintage = excluded.vintage, row_hash = excluded.row_hash,
         owner_changed_on = case when p.owner_key is distinct from excluded.owner_key then p_vintage else p.owner_changed_on end,
         gone_on = null, updated_at = now()
   where p.row_hash is distinct from excluded.row_hash or p.gone_on is not null;
  get diagnostics n_written = row_count;
  truncate pipe_in;
  return jsonb_build_object('written', n_written, 'changes', n_changes, 'owner_changes', owners);
end $$;

-- the parcels a file no longer carries: stamped gone (kept, with their history)
create or replace function public.pipe_parcels_gone(p_source text, p_vintage date, p_parcels text[]) returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  with g as (
    update public.pipe_parcels set gone_on = p_vintage, updated_at = now()
     where source = p_source and parcel_id = any(p_parcels) and gone_on is null
    returning county, parcel_id)
  insert into public.pipe_parcel_changes (county, parcel_id, source, changed_on, kinds) select county, parcel_id, p_source, p_vintage, '{gone}' from g;
  get diagnostics n = row_count;
  return n;
end $$;

-- the publisher's diff key: every parcel id and hash a source holds
create or replace function public.pipe_parcel_hashes(p_source text) returns table (parcel_id text, row_hash text, gone boolean)
language sql stable security definer set search_path = public as $$
  select parcel_id, row_hash, gone_on is not null from public.pipe_parcels where source = p_source
$$;

create or replace function public.pipe_source_seen(p_source text, p_file_date date, p_sha text, p_rows integer) returns void
language sql security definer set search_path = public as $$
  update public.pipe_sources set last_file_date = p_file_date, last_fetched_at = now(), last_sha = p_sha, rows = p_rows where source = p_source
$$;

-- map points for parcels (from the laptop's parcel-point cache); a point never changes the row hash
create or replace function public.pipe_set_points(p_source text, p_points jsonb) returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  update public.pipe_parcels p set lat = (x->>'lat')::double precision, lon = (x->>'lon')::double precision, point_source = coalesce(x->>'point_source', 'parcel centroid')
    from jsonb_array_elements(p_points) x
   where p.source = p_source and p.parcel_id = x->>'parcel_id' and (p.lat is null or p.lon is null);
  get diagnostics n = row_count;
  return n;
end $$;

-- ------------------------------------------------------------------ the map (no PostGIS: ray casting and an equirectangular distance)
create or replace function public.pipe_in_ring(p_lon double precision, p_lat double precision, p_ring jsonb) returns boolean
language plpgsql immutable as $$
declare n integer := jsonb_array_length(p_ring); i integer; j integer; xi float8; yi float8; xj float8; yj float8; inside boolean := false;
begin
  j := n - 1;
  for i in 0 .. n - 1 loop
    xi := (p_ring->i->>0)::float8; yi := (p_ring->i->>1)::float8; xj := (p_ring->j->>0)::float8; yj := (p_ring->j->>1)::float8;
    if ((yi > p_lat) <> (yj > p_lat)) and (p_lon < (xj - xi) * (p_lat - yi) / (yj - yi) + xi) then inside := not inside; end if;
    j := i;
  end loop;
  return inside;
end $$;

create or replace function public.pipe_ring_distance_m(p_lon double precision, p_lat double precision, p_ring jsonb) returns double precision
language plpgsql immutable as $$
declare n integer := jsonb_array_length(p_ring); i integer; kx float8 := 111320 * cos(radians(p_lat)); ky float8 := 110540;
        ax float8; ay float8; bx float8; by_ float8; dx float8; dy float8; t float8; best float8 := 'infinity';
begin
  for i in 0 .. n - 1 loop
    ax := ((p_ring->i->>0)::float8 - p_lon) * kx; ay := ((p_ring->i->>1)::float8 - p_lat) * ky;
    bx := ((p_ring->((i + 1) % n)->>0)::float8 - p_lon) * kx; by_ := ((p_ring->((i + 1) % n)->>1)::float8 - p_lat) * ky;
    dx := bx - ax; dy := by_ - ay;
    t := case when dx = 0 and dy = 0 then 0 else greatest(0, least(1, -(ax * dx + ay * dy) / (dx * dx + dy * dy))) end;
    best := least(best, sqrt((ax + t * dx) ^ 2 + (ay + t * dy) ^ 2));
  end loop;
  return best;
end $$;

-- ok | excluded | held_buffer | no_point | no_map. Only the City of Milwaukee is mapped; elsewhere ok.
create or replace function public.pipe_map_verdict(p_county text, p_municipality text, p_lat double precision, p_lon double precision)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare a record; r jsonb; d float8; near text; buf float8; s public.pipe_settings;
begin
  if lower(coalesce(p_county, '')) <> 'milwaukee' or lower(coalesce(p_municipality, '')) <> 'milwaukee' then return jsonb_build_object('verdict', 'ok'); end if;
  if not exists (select 1 from public.pipe_map_areas where kind = 'exclusion') then return jsonb_build_object('verdict', 'no_map'); end if;
  if p_lat is null or p_lon is null then return jsonb_build_object('verdict', 'no_point'); end if;
  select * into s from public.pipe_settings where id = 1;
  for a in select * from public.pipe_map_areas where kind = 'exclusion' loop
    for r in select * from jsonb_array_elements(a.rings) loop
      if public.pipe_in_ring(p_lon, p_lat, r) then return jsonb_build_object('verdict', 'excluded', 'area', a.name); end if;
      d := public.pipe_ring_distance_m(p_lon, p_lat, r);
      buf := coalesce(a.buffer_m, s.buffer_m);
      if d <= buf and near is null then near := a.name || ' (' || round(d::numeric) || ' m)'; end if;
    end loop;
  end loop;
  if near is not null then
    for a in select * from public.pipe_map_areas where kind = 'clear' loop
      for r in select * from jsonb_array_elements(a.rings) loop
        if public.pipe_in_ring(p_lon, p_lat, r) then return jsonb_build_object('verdict', 'ok', 'clear', a.name, 'near', near); end if;
      end loop;
    end loop;
    return jsonb_build_object('verdict', 'held_buffer', 'near', near);
  end if;
  return jsonb_build_object('verdict', 'ok');
end $$;

-- ------------------------------------------------------------------ the static gates (county, type, value)
create or replace function public.pipe_static_fails(p public.pipe_parcels, s public.pipe_settings) returns text[]
language sql immutable as $$
  select array_remove(array[
    case when not (p.county = any(s.buy_box_counties)) then 'county_not_in_buy_box' end,
    case when p.use_class in ('single_family', 'duplex', 'condo', 'residential') then null
         when p.use_class = 'apartment_3plus' then 'type_3plus_units'
         when p.use_class = 'commercial' then 'type_commercial'
         when p.use_class = 'vacant_land' then 'type_vacant_land'
         when p.use_class = 'exempt' then 'type_exempt'
         else 'type_other' end,
    case when p.assessed_total is null or p.assessed_total <= 0 then 'value_missing'
         when p.assessed_total >= s.value_cap then 'value_over_cap' end
  ], null)
$$;

-- the cards for a parcel: county + parcel id first, then the same address in the same county and town (or zip)
create or replace function public.pipe_card_ids(p public.pipe_parcels) returns uuid[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(id order by by_parcel desc, live desc, wpie desc, created_at), '{}') from (
    select l.id, bool_or(l.parcel_id = p.parcel_id) by_parcel, l.stage not in ('dead', 'dnc', 'closed_no_contact') live,
           coalesce(l.wpie_owner_id, 0) > 0 wpie, l.created_at
      from public.leads l
     where lower(l.county) = lower(p.county)
       and (l.parcel_id = p.parcel_id
            or (p.addr_key is not null and public.addr_key(public.addr_main(l.property_address)) = p.addr_key
                and (l.parcel_id is null or l.parcel_id = p.parcel_id)
                and (l.municipality is null or lower(l.municipality) = lower(coalesce(p.municipality, l.municipality))
                     or left(coalesce(l.property_zip, ''), 5) = left(coalesce(p.zip, ''), 5))))
     group by l.id, l.stage, l.wpie_owner_id, l.created_at) x
$$;

-- the facts a lane sees, each with its source and vintage
create or replace function public.pipe_facts(p public.pipe_parcels) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'parcel', jsonb_build_object('county', p.county, 'parcel_id', p.parcel_id, 'address', p.situs_address, 'municipality', p.municipality, 'zip', p.zip),
    'owner', jsonb_build_object('names', to_jsonb(p.owner_names), 'changed_on', p.owner_changed_on, 'source', src.name, 'vintage', p.vintage,
                                'confirmed_in_file_of', src.last_file_date, 'grade', src.grade),
    'mailing', jsonb_build_object('street', p.mail_street, 'city', p.mail_city, 'state', p.mail_state, 'zip', p.mail_zip, 'source', src.name, 'vintage', p.vintage),
    'assessed_value', jsonb_build_object('total', p.assessed_total, 'land', p.assessed_land, 'improvements', p.assessed_impr,
                                         'assessment_year', p.assessment_year, 'basis', 'assessed value (assessor)', 'source', src.name,
                                         'vintage', p.vintage, 'confirmed_in_file_of', src.last_file_date),
    'type', jsonb_build_object('use_class', p.use_class, 'land_use', p.land_use, 'land_use_group', p.land_use_group, 'prop_class', p.prop_class,
                               'bldg_type', p.bldg_type, 'units', p.units, 'condo_by_classification', p.condo, 'source', src.name, 'vintage', p.vintage),
    'building', jsonb_build_object('year_built', p.year_built, 'zoning', p.zoning, 'last_conveyed', p.last_conveyed),
    'point', case when p.lat is null then null else jsonb_build_object('lat', p.lat, 'lon', p.lon, 'source', p.point_source) end)
  from public.pipe_sources src where src.source = p.source
$$;

-- ------------------------------------------------------------------ one parcel through the gates
-- Re-runs the gates for one parcel and opens, refreshes or closes its queue item. Returns the verdict.
create or replace function public.pipe_screen(p_county text, p_parcel_id text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  s public.pipe_settings; p public.pipe_parcels; v_cards uuid[]; v_live uuid[]; v_main public.leads;
  v_fails text[]; v_sigs bigint[]; v_sig_kinds text[]; v_qualifying integer; v_tax_short integer; v_pairs integer; v_card_reasons boolean;
  v_map jsonb := null; v_conflicts jsonb := '[]'; v_why text[] := '{}'; v_missing text[] := '{}'; v_facts jsonb; v_gates jsonb;
  v_item public.pipe_queue; v_last public.pipe_queue; v_seen bigint[]; v_kind text; v_state text; v_new_signals boolean; v_owner_news boolean;
  c record; v_card_words text[];
begin
  select * into s from public.pipe_settings where id = 1;
  select * into p from public.pipe_parcels x where x.county = p_county and x.parcel_id = p_parcel_id and x.gone_on is null
   order by (select grade from public.pipe_sources where source = x.source) = 'current' desc, x.vintage desc limit 1;
  if p.parcel_id is null then return jsonb_build_object('error', 'no staged parcel ' || p_county || ' ' || p_parcel_id); end if;

  v_cards := public.pipe_card_ids(p);
  select coalesce(array_agg(l.id), '{}') into v_live from public.leads l where l.id = any(v_cards) and l.stage not in ('dead', 'dnc', 'closed_no_contact');
  select * into v_main from public.leads l where l.id = coalesce(v_live[1], v_cards[1]);

  -- signals on this parcel (by parcel id, or by address when the source printed no parcel)
  select coalesce(array_agg(g.id order by g.id), '{}'), coalesce(array_agg(distinct g.kind), '{}'),
         count(*) filter (where not g.pairs_only and g.kind not in ('bankruptcy', 'permit') and (g.kind <> 'tax_delinquent' or coalesce(g.tax_years, 0) >= 2)),
         count(*) filter (where g.kind = 'tax_delinquent' and coalesce(g.tax_years, 0) < 2),
         count(*) filter (where g.pairs_only)
    into v_sigs, v_sig_kinds, v_qualifying, v_tax_short, v_pairs
    from public.pipe_signals g
   where g.county = p.county and (g.parcel_id = p.parcel_id or (g.parcel_id is null and g.addr_key is not null and g.addr_key = p.addr_key));
  v_card_reasons := exists (select 1 from public.leads l where l.id = any(v_live) and l.reasons_to_sell <> '{}');

  v_fails := public.pipe_static_fails(p, s);
  if v_qualifying = 0 and not v_card_reasons then
    v_fails := v_fails || case when v_tax_short > 0 then 'tax_under_2_years' when v_pairs > 0 then 'dor_needs_a_pair' else 'no_distress' end;
  end if;
  if exists (select 1 from public.pipe_signals g where g.county = p.county and g.kind = 'bankruptcy' and g.active
              and (g.parcel_id = p.parcel_id or (g.parcel_id is null and g.addr_key = p.addr_key))) then v_fails := v_fails || 'bankruptcy_active'::text; end if;
  if exists (select 1 from public.leads l where l.id = any(v_cards) and l.stage in ('dead', 'dnc', 'closed_no_contact')) then v_fails := v_fails || 'card_dead_or_dnc'::text; end if;
  if v_main.id is not null and exists (select 1 from public.interests i where i.lead_id = v_main.id and i.role = 'owner_of_record' and i.status = 'deceased')
     and not exists (select 1 from public.interests i where i.lead_id = v_main.id and i.status = 'active'
                       and i.role in ('owner_of_record', 'co_owner', 'personal_representative', 'special_administrator', 'heir', 'trustee', 'spouse'))
  then v_fails := v_fails || 'deceased_no_representative'::text; end if;

  -- the map last: it is only read for a parcel that passed everything else
  if cardinality(v_fails) = 0 then
    v_map := public.pipe_map_verdict(p.county, p.municipality, p.lat, p.lon);
    if v_map->>'verdict' = 'excluded' then v_fails := v_fails || 'map_excluded'::text;
    elsif v_map->>'verdict' = 'no_map' then v_fails := v_fails || 'map_not_loaded'::text;
    elsif v_map->>'verdict' = 'no_point' then v_fails := v_fails || 'map_no_point'::text; end if;
  end if;

  -- the card's owner against the pipe's: no shared name word on a live card = a conflict, kept, both sides stamped
  if cardinality(p.owner_names) > 0 then
    for c in select l.id, l.owner_name from public.leads l where l.id = any(v_live) loop
      select coalesce(array_agg(distinct z.w), '{}') into v_card_words from (
        select unnest(public.pipe_name_words(c.owner_name)) w
        union select unnest(public.pipe_name_words(pe.name)) from public.interests i join public.people pe on pe.id = i.person_id
         where i.lead_id = c.id and i.status = 'active' and i.role in ('owner_of_record', 'co_owner', 'trustee')) z;
      if cardinality(v_card_words) > 0 and not (v_card_words && public.pipe_name_words(array_to_string(p.owner_names, ' '))) then
        insert into public.pipe_conflicts (lead_id, county, parcel_id, field, card_value, card_basis, pipe_value, pipe_source, pipe_date)
        values (c.id, p.county, p.parcel_id, 'owner', c.owner_name, 'the card', array_to_string(p.owner_names, ' & '), p.source, p.vintage)
        on conflict (lead_id, field, pipe_value) do nothing;
      end if;
    end loop;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'lead_id', x.lead_id, 'field', x.field, 'card', x.card_value, 'card_basis', x.card_basis,
           'pipe', x.pipe_value, 'pipe_source', x.pipe_source, 'pipe_date', x.pipe_date, 'since', x.created_at) order by x.id), '[]')
    into v_conflicts from public.pipe_conflicts x where x.lead_id = any(v_live) and x.closed_at is null and x.parcel_id = p.parcel_id;

  v_gates := jsonb_build_object('pass', cardinality(v_fails) = 0 and coalesce(v_map->>'verdict', 'ok') = 'ok', 'fails', to_jsonb(v_fails), 'map', v_map,
                                'signals', cardinality(v_sigs), 'qualifying_signals', v_qualifying, 'card_reasons', v_card_reasons,
                                'cards', to_jsonb(v_cards), 'at', now());
  update public.pipe_parcels x set gate = v_gates, gate_at = now() where x.county = p.county and x.parcel_id = p.parcel_id and x.source = p.source;

  -- what is new since the last item for this parcel: signals on no earlier item, an owner change it did not carry
  select * into v_item from public.pipe_queue q where q.county = p.county and q.parcel_id = p.parcel_id and q.state in ('open', 'claimed', 'held_buffer', 'held');
  select * into v_last from public.pipe_queue q where q.county = p.county and q.parcel_id = p.parcel_id order by q.created_at desc limit 1;
  select coalesce(array_agg(distinct x), '{}') into v_seen from public.pipe_queue q, unnest(q.signal_ids) x where q.county = p.county and q.parcel_id = p.parcel_id;
  v_new_signals := exists (select 1 from unnest(v_sigs) x where not (x = any(v_seen)));
  v_owner_news := p.owner_changed_on is not null and (v_last.id is null or (v_last.facts->'owner'->>'changed_on') is distinct from p.owner_changed_on::text);

  if cardinality(v_live) > 0 and p.owner_changed_on is not null and (v_owner_news or v_item.id is not null) then v_why := v_why || 'owner_changed'::text; end if;
  if jsonb_array_length(v_conflicts) > 0 then v_why := v_why || 'owner_conflict'::text; end if;
  if cardinality(v_sigs) > 0 then v_why := v_why || 'signal'::text; end if;

  if cardinality(v_live) > 0 and (v_owner_news or jsonb_array_length(v_conflicts) > 0 or v_item.kind = 're_screen') then
    v_kind := 're_screen'; v_state := 'open';                   -- a card to look at again, whatever the gates say now
  elsif cardinality(v_fails) = 0 and (v_new_signals or v_item.id is not null) then
    v_kind := case when cardinality(v_live) > 0 then 'stack' else 'new' end;
    v_state := case when v_map->>'verdict' = 'held_buffer' then 'held_buffer' else 'open' end;
  else
    v_kind := null;
  end if;

  v_missing := array_remove(array[
    case when not exists (select 1 from public.contacts ct where ct.lead_id = any(v_live)) then 'phones' end,
    case when p.owner_changed_on is not null or (select grade from public.pipe_sources where source = p.source) <> 'current' or jsonb_array_length(v_conflicts) > 0
         then 'current_ownership_confirmation' end,
    case when p.use_class = 'residential' then 'unit_count_evidence' end,
    case when v_sig_kinds && array['foreclosure', 'probate', 'sheriff_sale', 'bankruptcy', 'lis_pendens', 'judgment'] then 'case_detail_read' end
  ], null);
  v_facts := public.pipe_facts(p);

  if v_kind is not null then
    if v_item.id is null then
      insert into public.pipe_queue (county, parcel_id, address, kind, state, lead_id, lead_ids, why, signal_ids, facts, conflicts, missing, gates)
      values (p.county, p.parcel_id, p.situs_address, v_kind, v_state, v_main.id, v_cards, v_why, v_sigs, v_facts, v_conflicts, v_missing, v_gates)
      returning * into v_item;
    else
      update public.pipe_queue q set kind = case when q.kind = 're_screen' then q.kind else v_kind end,
             state = case when q.state in ('open', 'held_buffer') then v_state else q.state end,
             lead_id = v_main.id, lead_ids = v_cards, why = (select array_agg(distinct w) from unnest(q.why || v_why) w),
             signal_ids = v_sigs, facts = v_facts, conflicts = v_conflicts, missing = v_missing, gates = v_gates, updated_at = now()
       where q.id = v_item.id returning * into v_item;
    end if;
  elsif v_item.id is not null then
    if v_item.state in ('open', 'held_buffer') then
      -- nobody has it and it no longer qualifies: closed by the pipe, with why
      update public.pipe_queue q set state = 'killed', outcome = 'gate_failed', outcome_note = array_to_string(v_fails, ', '), closed_by = 'pipe',
             closed_at = now(), gates = v_gates, facts = v_facts, updated_at = now() where q.id = v_item.id returning * into v_item;
    else
      update public.pipe_queue q set gates = v_gates, facts = v_facts, conflicts = v_conflicts, missing = v_missing, updated_at = now()
       where q.id = v_item.id returning * into v_item;
    end if;
  end if;
  return v_gates || jsonb_build_object('item', v_item.id, 'item_state', v_item.state, 'item_kind', v_item.kind);
end $$;

-- every parcel of a source that can matter: a card on it, a signal on it, an owner change since the last screen, or a
-- live queue item. Returns the counts (screened, items by state and kind).
create or replace function public.pipe_screen_source(p_source text, p_limit integer default 5000) returns jsonb
language plpgsql security definer set search_path = public as $$
declare k record; n integer := 0; v jsonb; fails jsonb := '{}'; f text;
begin
  for k in
    with cand as (
      select p.county, p.parcel_id from public.pipe_parcels p
       where p.source = p_source and p.gone_on is null
         and (exists (select 1 from public.leads l where lower(l.county) = lower(p.county) and l.parcel_id = p.parcel_id)
              or exists (select 1 from public.leads l where lower(l.county) = lower(p.county) and p.addr_key is not null
                           and public.addr_key(public.addr_main(l.property_address)) = p.addr_key)
              or exists (select 1 from public.pipe_signals g where g.county = p.county and (g.parcel_id = p.parcel_id or (g.parcel_id is null and g.addr_key = p.addr_key)))
              or (p.owner_changed_on is not null and (p.gate_at is null or p.owner_changed_on >= (p.gate_at at time zone 'America/Chicago')::date))
              or exists (select 1 from public.pipe_queue q where q.county = p.county and q.parcel_id = p.parcel_id and q.state in ('open', 'claimed', 'held_buffer', 'held'))))
    select * from cand order by county, parcel_id limit p_limit
  loop
    v := public.pipe_screen(k.county, k.parcel_id);
    n := n + 1;
    for f in select jsonb_array_elements_text(v->'fails') loop
      fails := jsonb_set(fails, array[f], to_jsonb(coalesce((fails->>f)::integer, 0) + 1));
    end loop;
  end loop;
  return jsonb_build_object('screened', n, 'fails', fails,
    'queue', (select coalesce(jsonb_object_agg(state || ':' || kind, c), '{}') from (select state, kind, count(*) c from public.pipe_queue group by 1, 2) q));
end $$;

-- the gate picture for a whole source (static gates for every parcel, first failure counted; plus stack vs new)
create or replace function public.pipe_gate_counts(p_source text) returns jsonb
language sql stable security definer set search_path = public as $$
  with byp as (select distinct lower(county) county, parcel_id from public.leads where parcel_id is not null),
  bya as (select distinct lower(county) county, public.addr_key(public.addr_main(property_address)) ak from public.leads where parcel_id is null),
  p as (select x.*, public.pipe_static_fails(x, s) fails from public.pipe_parcels x cross join public.pipe_settings s where s.id = 1 and x.source = p_source and x.gone_on is null),
  pc as (select p.*, (exists (select 1 from byp where byp.county = lower(p.county) and byp.parcel_id = p.parcel_id)
                      or exists (select 1 from bya where bya.county = lower(p.county) and bya.ak = p.addr_key)) has_card
           from p)
  select jsonb_build_object(
    'staged', count(*),
    'by_use_class', (select jsonb_object_agg(coalesce(use_class, 'none'), n) from (select use_class, count(*) n from p group by 1) u),
    'first_static_fail', (select coalesce(jsonb_object_agg(f, n), '{}') from (select fails[1] f, count(*) n from p where cardinality(fails) > 0 group by 1) z),
    'pass_static', count(*) filter (where cardinality(fails) = 0),
    'pass_static_with_card', count(*) filter (where cardinality(fails) = 0 and has_card),
    'pass_static_no_card', count(*) filter (where cardinality(fails) = 0 and not has_card),
    'with_card_any', count(*) filter (where has_card),
    'owner_changed_ever', count(*) filter (where owner_changed_on is not null))
  from pc
$$;

-- ------------------------------------------------------------------ the agent door (scope: prospects)
create or replace function public.pipe_item_json(q public.pipe_queue) returns jsonb
language sql stable security definer set search_path = public as $$
  select to_jsonb(q) || jsonb_build_object(
    'signals', (select coalesce(jsonb_agg(jsonb_build_object('id', g.id, 'kind', g.kind, 'source', g.source, 'record', g.source_record_id, 'date', g.signal_date,
                  'tax_years', g.tax_years, 'pairs_only', g.pairs_only, 'active', g.active, 'detail', g.detail, 'first_seen', g.first_seen, 'last_seen', g.last_seen) order by g.id), '[]')
                  from public.pipe_signals g where g.id = any(q.signal_ids)),
    'card', (select jsonb_build_object('id', l.id, 'owner_name', l.owner_name, 'address', l.property_address, 'stage', l.stage, 'reasons', to_jsonb(l.reasons_to_sell),
                  'source', coalesce(l.source, 'laptop'), 'other_cards', to_jsonb(array_remove(q.lead_ids, l.id)))
               from public.leads l where l.id = q.lead_id),
    'changes', (select coalesce(jsonb_agg(jsonb_build_object('on', c.changed_on, 'kinds', to_jsonb(c.kinds), 'before', c.before, 'after', c.after) order by c.id desc), '[]')
                  from (select * from public.pipe_parcel_changes c where c.county = q.county and c.parcel_id = q.parcel_id order by id desc limit 10) c))
$$;

create or replace function public.pipe_door_counts() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'sources', (select coalesce(jsonb_agg(jsonb_build_object('source', s.source, 'name', s.name, 'cadence', s.cadence, 'grade', s.grade, 'last_file_date', s.last_file_date,
                  'rows', s.rows, 'staged', (select count(*) from public.pipe_parcels p where p.source = s.source and p.gone_on is null))), '[]') from public.pipe_sources s),
    'last_runs', (select coalesce(jsonb_agg(r order by r.finished_at desc), '[]') from (select source, finished_at, ok, file_date, counts, note from public.pipe_runs order by finished_at desc limit 5) r),
    'queue', (select coalesce(jsonb_object_agg(state, n), '{}') from (select state, count(*) n from public.pipe_queue group by 1) q),
    'queue_open_by_kind', (select coalesce(jsonb_object_agg(kind, n), '{}') from (select kind, count(*) n from public.pipe_queue where state = 'open' group by 1) q),
    'open_conflicts', (select count(*) from public.pipe_conflicts where closed_at is null),
    'map_loaded', exists (select 1 from public.pipe_map_areas where kind = 'exclusion'),
    'signals', (select coalesce(jsonb_object_agg(kind, n), '{}') from (select kind, count(*) n from public.pipe_signals group by 1) g))
$$;

create or replace function public.pipe_door_list(p_state text default 'open', p_county text default null, p_kind text default null, p_limit integer default 50)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('item_id', q.id, 'kind', q.kind, 'state', q.state, 'county', q.county, 'parcel_id', q.parcel_id, 'address', q.address,
           'why', to_jsonb(q.why), 'missing', to_jsonb(q.missing), 'conflicts', jsonb_array_length(q.conflicts), 'lead_id', q.lead_id,
           'claimed_by', q.claimed_by, 'outcome', q.outcome, 'created_at', q.created_at) order by q.created_at, q.id), '[]')
    from (select * from public.pipe_queue q
           where q.state = coalesce(nullif(p_state, ''), 'open') and (p_county is null or lower(q.county) = lower(p_county)) and (p_kind is null or q.kind = p_kind)
           order by q.created_at, q.id limit least(greatest(coalesce(p_limit, 50), 1), 200)) q
$$;

create or replace function public.pipe_door_item(p_id uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce((select public.pipe_item_json(q) from public.pipe_queue q where q.id = p_id), jsonb_build_object('ok', false, 'error', 'no such item'))
$$;

-- claim open items for one lane (a claim older than claim_hours goes back to open first)
create or replace function public.pipe_door_claim(p_agent text, p_limit integer default 10, p_county text default null, p_kind text default null, p_item uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare hrs integer; out jsonb;
begin
  select claim_hours into hrs from public.pipe_settings where id = 1;
  update public.pipe_queue set state = 'open', claimed_by = null, claimed_at = null, updated_at = now()
   where state = 'claimed' and claimed_at < now() - make_interval(hours => hrs);
  with pick as (
    select id from public.pipe_queue
     where (state = 'open' or (p_item is not null and state = 'held')) and (p_item is null or id = p_item) and (p_county is null or lower(county) = lower(p_county)) and (p_kind is null or kind = p_kind)
     order by (kind = 're_screen') desc, created_at, id limit least(greatest(coalesce(p_limit, 10), 1), 50)
     for update skip locked),
  c as (update public.pipe_queue q set state = 'claimed', claimed_by = p_agent, claimed_at = now(), updated_at = now() from pick where q.id = pick.id returning q.*)
  select coalesce(jsonb_agg(public.pipe_item_json(c) order by c.created_at), '[]') into out from c;
  return jsonb_build_object('claimed', jsonb_array_length(out), 'claim_hours', hrs, 'items', out);
end $$;

-- close with an outcome code. verified: fields stamped with source and date (the lane then promotes through
-- add_prospects; the pipe makes no card). killed: a reason code. held: the blocker. release: back to open.
-- A held_buffer item takes only Colin's ruling: ruled_in (back to open) or ruled_out (killed), with his words.
create or replace function public.pipe_door_close(p_id uuid, p_agent text, p_outcome text, p_code text default null, p_note text default null,
  p_verified jsonb default null, p_lead_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare q public.pipe_queue; k text; v jsonb; bad text[] := '{}';
  kill_codes text[] := array['not_residential', 'over_value_cap', 'owner_mismatch', 'sold_or_transferred', 'no_distress', 'distress_resolved',
    'bankruptcy_active', 'deceased_no_representative', 'card_dead_or_dnc', 'map_excluded', 'listed_for_sale', 'duplicate', 'bad_data', 'out_of_area', 'other'];
begin
  select * into q from public.pipe_queue where id = p_id for update;
  if q.id is null then return jsonb_build_object('ok', false, 'error', 'no such item'); end if;
  if q.state in ('verified', 'killed') then return jsonb_build_object('ok', false, 'error', 'already closed: ' || q.state || coalesce(' (' || q.outcome || ')', '')); end if;
  if q.state = 'held_buffer' then
    if p_outcome not in ('ruled_in', 'ruled_out') then return jsonb_build_object('ok', false, 'error', 'a buffer item waits for Colin''s parcel ruling: outcome ruled_in or ruled_out, with his words in note'); end if;
    if btrim(coalesce(p_note, '')) = '' then return jsonb_build_object('ok', false, 'error', 'note: Colin''s ruling, in his words'); end if;
    update public.pipe_queue set state = case when p_outcome = 'ruled_in' then 'open' else 'killed' end,
           outcome = case when p_outcome = 'ruled_out' then 'map_excluded' end, outcome_note = 'Colin: ' || p_note,
           closed_by = case when p_outcome = 'ruled_out' then p_agent end, closed_at = case when p_outcome = 'ruled_out' then now() end, updated_at = now()
     where id = p_id returning * into q;
    return jsonb_build_object('ok', true, 'item_id', q.id, 'state', q.state);
  end if;
  if q.state = 'claimed' and q.claimed_by is distinct from p_agent then return jsonb_build_object('ok', false, 'error', 'claimed by ' || q.claimed_by); end if;
  if p_outcome = 'release' then
    update public.pipe_queue set state = 'open', claimed_by = null, claimed_at = null, outcome_note = coalesce(p_note, outcome_note), updated_at = now() where id = p_id;
    return jsonb_build_object('ok', true, 'item_id', p_id, 'state', 'open');
  elsif p_outcome = 'verified' then
    if p_verified is null or jsonb_typeof(p_verified) <> 'object' or p_verified = '{}' then
      return jsonb_build_object('ok', false, 'error', 'verified needs fields: {"owner": {"value": ..., "source": ..., "date": "YYYY-MM-DD"}, ...}');
    end if;
    for k, v in select * from jsonb_each(p_verified) loop
      if jsonb_typeof(v) <> 'object' or coalesce(v->>'source', '') = '' or coalesce(v->>'date', '') !~ '^\d{4}-\d{2}-\d{2}' or not (v ? 'value') then bad := bad || k; end if;
      if k ~* '(value|price|amount)' and coalesce(v->>'basis', '') !~* 'assess' then bad := bad || (k || ' (a value field needs basis "assessed")'); end if;
    end loop;
    if cardinality(bad) > 0 then return jsonb_build_object('ok', false, 'error', 'each verified field needs value, source and date: ' || array_to_string(bad, ', ')); end if;
    update public.pipe_queue set state = 'verified', outcome = coalesce(nullif(p_code, ''), 'verified'), outcome_note = p_note, verified = p_verified,
           lead_id = coalesce(p_lead_id, lead_id), closed_by = p_agent, closed_at = now(), updated_at = now() where id = p_id;
    -- a re-screen that verified the owner settles the card's open owner conflicts
    if q.kind = 're_screen' and p_verified ? 'owner' then
      update public.pipe_conflicts set closed_at = now(), closed_by = p_agent, closed_note = 'verified owner: ' || (p_verified->'owner'->>'value') || ' (' || (p_verified->'owner'->>'source') || ', ' || (p_verified->'owner'->>'date') || ')'
       where lead_id = any(q.lead_ids) and parcel_id = q.parcel_id and field = 'owner' and closed_at is null;
    end if;
    return jsonb_build_object('ok', true, 'item_id', p_id, 'state', 'verified', 'next', case when q.kind = 'new' then 'promote through add_prospects (people model, interests[]); the pipe makes no card' else 'the card is already there: stack onto it' end);
  elsif p_outcome = 'killed' then
    if not (coalesce(p_code, '') = any(kill_codes)) then return jsonb_build_object('ok', false, 'error', 'killed needs a code: ' || array_to_string(kill_codes, ', ')); end if;
    if p_code = 'other' and btrim(coalesce(p_note, '')) = '' then return jsonb_build_object('ok', false, 'error', 'code other needs a note'); end if;
    update public.pipe_queue set state = 'killed', outcome = p_code, outcome_note = p_note, closed_by = p_agent, closed_at = now(), updated_at = now() where id = p_id;
    if q.kind = 're_screen' then
      update public.pipe_conflicts set closed_at = now(), closed_by = p_agent, closed_note = 'queue item killed: ' || p_code || coalesce(' (' || p_note || ')', '')
       where lead_id = any(q.lead_ids) and parcel_id = q.parcel_id and closed_at is null;
    end if;
    return jsonb_build_object('ok', true, 'item_id', p_id, 'state', 'killed');
  elsif p_outcome = 'held' then
    if btrim(coalesce(p_note, '')) = '' then return jsonb_build_object('ok', false, 'error', 'held needs the blocker named in note'); end if;
    update public.pipe_queue set state = 'held', outcome = coalesce(nullif(p_code, ''), 'held'), outcome_note = p_note, claimed_by = p_agent, updated_at = now() where id = p_id;
    return jsonb_build_object('ok', true, 'item_id', p_id, 'state', 'held');
  end if;
  return jsonb_build_object('ok', false, 'error', 'outcome: verified | killed | held | release (ruled_in / ruled_out for a buffer item)');
end $$;

-- Muse loads the Milwaukee exclusion polygon (GeoJSON Polygon, MultiPolygon or Feature / FeatureCollection of them)
create or replace function public.pipe_door_set_map(p_agent text, p_name text, p_kind text, p_geojson jsonb, p_buffer_m numeric default null, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare g jsonb := p_geojson; v_rings jsonb := '[]'; f jsonb; n integer;
begin
  if coalesce(btrim(p_name), '') = '' then return jsonb_build_object('ok', false, 'error', 'name the area'); end if;
  if p_kind not in ('exclusion', 'clear') then return jsonb_build_object('ok', false, 'error', 'kind: exclusion (inside = out, the band = held) or clear (the band does not reach it)'); end if;
  if g->>'type' = 'FeatureCollection' then
    for f in select * from jsonb_array_elements(g->'features') loop
      v_rings := v_rings || case when f->'geometry'->>'type' = 'Polygon' then jsonb_build_array(f->'geometry'->'coordinates'->0)
                             when f->'geometry'->>'type' = 'MultiPolygon' then (select coalesce(jsonb_agg(x->0), '[]') from jsonb_array_elements(f->'geometry'->'coordinates') x) else '[]' end;
    end loop;
  else
    if g->>'type' = 'Feature' then g := g->'geometry'; end if;
    v_rings := case when g->>'type' = 'Polygon' then jsonb_build_array(g->'coordinates'->0)
                  when g->>'type' = 'MultiPolygon' then (select coalesce(jsonb_agg(x->0), '[]') from jsonb_array_elements(g->'coordinates') x) else '[]' end;
  end if;
  if jsonb_array_length(v_rings) = 0 then return jsonb_build_object('ok', false, 'error', 'no polygon found: send GeoJSON Polygon / MultiPolygon with [lon, lat] coordinates'); end if;
  if exists (select 1 from jsonb_array_elements(v_rings) r, jsonb_array_elements(r) pt
              where not ((pt->>0)::float8 between -88.2 and -87.8 and (pt->>1)::float8 between 42.8 and 43.25)) then
    return jsonb_build_object('ok', false, 'error', 'coordinates must be [lon, lat] inside Milwaukee (lon about -88.07 to -87.86, lat about 42.92 to 43.19)');
  end if;
  insert into public.pipe_map_areas (name, kind, rings, buffer_m, note, loaded_by) values (p_name, p_kind, v_rings, p_buffer_m, p_note, p_agent)
  on conflict (name) do update set kind = excluded.kind, rings = excluded.rings, buffer_m = excluded.buffer_m, note = excluded.note,
     loaded_by = excluded.loaded_by, loaded_at = now();
  select count(*) into n from jsonb_array_elements(v_rings);
  return jsonb_build_object('ok', true, 'name', p_name, 'kind', p_kind, 'polygons', n, 'buffer_m', coalesce(p_buffer_m, (select buffer_m from public.pipe_settings where id = 1)),
    'next', 'the next pipe run (nightly) re-screens Milwaukee parcels against it');
end $$;

do $$
declare f text;
begin
  foreach f in array array['pipe_owner_key(text[])', 'pipe_name_words(text)', 'pipe_upsert_parcels(text, date, jsonb, boolean)', 'pipe_parcels_gone(text, date, text[])',
    'pipe_parcel_hashes(text)', 'pipe_source_seen(text, date, text, integer)', 'pipe_set_points(text, jsonb)',
    'pipe_in_ring(double precision, double precision, jsonb)', 'pipe_ring_distance_m(double precision, double precision, jsonb)',
    'pipe_map_verdict(text, text, double precision, double precision)', 'pipe_static_fails(public.pipe_parcels, public.pipe_settings)',
    'pipe_card_ids(public.pipe_parcels)', 'pipe_facts(public.pipe_parcels)', 'pipe_screen(text, text)', 'pipe_screen_source(text, integer)',
    'pipe_gate_counts(text)', 'pipe_item_json(public.pipe_queue)', 'pipe_door_counts()', 'pipe_door_list(text, text, text, integer)', 'pipe_door_item(uuid)',
    'pipe_door_claim(text, integer, text, text, uuid)', 'pipe_door_close(uuid, text, text, text, text, jsonb, uuid)',
    'pipe_door_set_map(text, text, text, jsonb, numeric, text)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;
