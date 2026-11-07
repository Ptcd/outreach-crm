-- 0195: mortgages_wanted, the hand-off of equity lookups to Muse (Colin 2026-11-07: "Is there a way we can figure out
-- the equity these people have before we waste time on outreach" ... "Wire it up, also muse can do anything on a
-- browser if we need to involve it"). The laptop grades every property's equity from the records (wpie.core.equity);
-- the one input it never had is the mortgage itself, which sits in each county's Register of Deeds index. Every night
-- the laptop lists here the parcels whose grade is unknown or estimated, real need first, counties with a free public
-- index first. Muse claims a batch (mortgages_wanted), reads the free index parcel by parcel, and loads what it shows
-- with mortgage_add: document number, recording date, lender, the original principal when the index prints it, and
-- satisfactions. The laptop's live cycle pulls the finished rows into mortgage events and the next refresh grades
-- the card for real. Same shape as phones_wanted (0190).

create table if not exists public.mortgages_wanted (
  wpie_property_id integer primary key,
  lead_id uuid references public.leads(id) on delete set null,
  parcel_id text not null,
  county text not null,
  municipality text,
  property_address text not null,
  owner_name text,
  equity_grade text,                                  -- the grade the laptop holds now: unknown | thin | likely | ...
  equity_line text,                                   -- its one-line reading
  need text not null default 'real need',             -- real need | less motivated (same words as phones_wanted)
  why text,
  index_url text,                                     -- the county index to search (docs/MORTGAGE_LOOKUPS.md)
  index_notes text,                                   -- how that county's index works, in one line
  listed_on date not null default current_date,
  claimed_by text, claimed_at timestamptz,
  done_at timestamptz, done_how text,
  found boolean,                                      -- Muse: true = documents recorded, false = index searched, nothing
  result jsonb,                                       -- Muse's documents (the laptop preserves this as the raw artifact)
  pulled_at timestamptz,                              -- the laptop took the result
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists mortgages_wanted_open_idx on public.mortgages_wanted (need, county) where done_at is null;
create index if not exists mortgages_wanted_pull_idx on public.mortgages_wanted (done_at) where done_at is not null and pulled_at is null;
alter table public.mortgages_wanted enable row level security;
drop policy if exists mortgages_wanted_team_read on public.mortgages_wanted;
create policy mortgages_wanted_team_read on public.mortgages_wanted for select to authenticated using (public.is_team());
grant select on public.mortgages_wanted to authenticated;

-- Muse's batch: open rows nobody holds (a claim older than two days with no result is open again), real need first,
-- counties with a free index first (the laptop sets index_url only where one exists), then the oldest listing.
create or replace function public.agent_mortgages_wanted(p_agent text, p_limit integer default 50, p_county text default null,
                                                         p_counts_only boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare ids integer[]; out jsonb; counts jsonb;
begin
  select jsonb_build_object(
           'open', count(*) filter (where done_at is null and (claimed_at is null or claimed_at < now() - interval '2 days')),
           'open_real_need', count(*) filter (where done_at is null and need = 'real need' and (claimed_at is null or claimed_at < now() - interval '2 days')),
           'claimed', count(*) filter (where done_at is null and claimed_at >= now() - interval '2 days'),
           'yours', count(*) filter (where done_at is null and claimed_by = p_agent and claimed_at >= now() - interval '2 days'),
           'done_7d', count(*) filter (where done_at > now() - interval '7 days'),
           'found_7d', count(*) filter (where done_at > now() - interval '7 days' and found),
           'by_county', (select coalesce(jsonb_object_agg(county, n), '{}'::jsonb) from (
               select county, count(*) n from public.mortgages_wanted where done_at is null group by county order by n desc limit 30) c))
    into counts from public.mortgages_wanted;
  if coalesce(p_counts_only, false) then return jsonb_build_object('counts', counts, 'parcels', '[]'::jsonb); end if;
  with pick as (
    select w.wpie_property_id from public.mortgages_wanted w
     where w.done_at is null and (w.claimed_at is null or w.claimed_at < now() - interval '2 days' or w.claimed_by = p_agent)
       and (p_county is null or w.county = p_county)
     order by (w.need = 'real need') desc, (w.index_url is not null) desc, w.listed_on, w.wpie_property_id
     limit greatest(1, least(coalesce(p_limit, 50), 200))
     for update skip locked),
  u as (update public.mortgages_wanted w set claimed_by = p_agent, claimed_at = now(), updated_at = now()
          from pick where w.wpie_property_id = pick.wpie_property_id returning w.wpie_property_id)
  select coalesce(array_agg(wpie_property_id), '{}') into ids from u;
  select coalesce(jsonb_agg(jsonb_build_object(
           'wpie_property_id', w.wpie_property_id, 'parcel', w.parcel_id, 'address', w.property_address, 'city', w.municipality,
           'county', w.county, 'owner_name', w.owner_name, 'equity_grade', w.equity_grade, 'equity_line', w.equity_line,
           'need', w.need, 'why', w.why, 'index_url', w.index_url, 'index_notes', w.index_notes, 'card', w.lead_id)
           order by (w.need = 'real need') desc, (w.index_url is not null) desc, w.listed_on, w.wpie_property_id), '[]'::jsonb)
    into out from public.mortgages_wanted w where w.wpie_property_id = any(ids);
  return jsonb_build_object('counts', counts, 'parcels', out);
end $$;
revoke all on function public.agent_mortgages_wanted(text, integer, text, boolean) from public, anon, authenticated;
grant execute on function public.agent_mortgages_wanted(text, integer, text, boolean) to service_role;

-- Muse's result for one parcel: p = {wpie_property_id, found, documents: [{doc_type, document_number, recorded_on, amount,
-- lender, borrower, satisfies_document_number, notes, source_url, page_reference, extraction_confidence}], notes}.
-- Validated here only for shape; the laptop validates every document against wpie/agents/schemas.py MORTGAGE_SCHEMA
-- when it pulls, and refuses what does not fit (the row then reopens with the reason in done_how).
create or replace function public.agent_mortgage_add(p jsonb, p_agent text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare pid integer := (p->>'wpie_property_id')::integer; w public.mortgages_wanted; docs jsonb := coalesce(p->'documents', '[]'::jsonb);
        d jsonb; n integer := 0; bad text;
begin
  if pid is null then return jsonb_build_object('ok', false, 'reason', 'wpie_property_id is required (from your mortgages_wanted batch)'); end if;
  select * into w from public.mortgages_wanted where wpie_property_id = pid;
  if not found then return jsonb_build_object('ok', false, 'reason', 'that parcel is not on the list'); end if;
  if jsonb_typeof(docs) <> 'array' then return jsonb_build_object('ok', false, 'reason', 'documents must be a list'); end if;
  for d in select * from jsonb_array_elements(docs) loop
    n := n + 1;
    if coalesce(d->>'doc_type', '') not in ('mortgage', 'satisfaction', 'assignment', 'modification', 'other') then
      bad := format('document %s: doc_type must be mortgage | satisfaction | assignment | modification | other', n); exit;
    end if;
    if coalesce(d->>'source_url', '') = '' then bad := format('document %s: source_url is required (the index page you read)', n); exit; end if;
    if d ? 'amount' and d->>'amount' is not null and (d->>'amount') !~ '^[0-9]+(\.[0-9]+)?$' then
      bad := format('document %s: amount is digits only, no $ or commas', n); exit;
    end if;
    if d ? 'recorded_on' and d->>'recorded_on' is not null and (d->>'recorded_on') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
      bad := format('document %s: recorded_on is YYYY-MM-DD', n); exit;
    end if;
  end loop;
  if bad is not null then return jsonb_build_object('ok', false, 'reason', bad); end if;
  if coalesce((p->>'found')::boolean, n > 0) is false and n > 0 then
    return jsonb_build_object('ok', false, 'reason', 'found=false with documents: say found=true, or send no documents');
  end if;
  update public.mortgages_wanted
     set found = coalesce((p->>'found')::boolean, n > 0), result = jsonb_build_object('documents', docs, 'notes', p->>'notes', 'agent', p_agent, 'at', now()),
         done_at = now(), done_how = 'Muse (' || coalesce(p_agent, 'agent') || ')', pulled_at = null,
         claimed_by = coalesce(claimed_by, p_agent), updated_at = now()
   where wpie_property_id = pid;
  return jsonb_build_object('ok', true, 'wpie_property_id', pid, 'documents', n, 'found', coalesce((p->>'found')::boolean, n > 0),
                            'note', 'the laptop pulls this within ten minutes and the card''s equity line updates on the next refresh');
end $$;
revoke all on function public.agent_mortgage_add(jsonb, text) from public, anon, authenticated;
grant execute on function public.agent_mortgage_add(jsonb, text) to service_role;
