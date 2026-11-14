-- 0227: court rows an agent has banked go to the laptop, which ties each to a parcel; the result comes back per row.
--
-- Muse 2 read three and a half days of court filings (22,942 evictions over about 16,334 properties, 2,258 money
-- judgments) and loaded no card, because a filing carries no parcel, value or size and its rows waited for hand
-- verification (85 done). Colin 2026-11-13: have the laptop do the matching ("Sure that's fine"; on the agent reading
-- the court site: "it has access to get the data it's fine"). The laptop holds the statewide parcel records and
-- already ties court cases and town lists to parcels; a matched row becomes an event on the property and reaches a
-- card through the ordinary pipeline.
--
--   court_rows                 one filing: kind, county, case number, the parties, the address, and its result
--   agent_court_rows_deposit   the agent adds rows (the same county + case is the same row), 500 a call
--   agent_court_rows_status    counts by kind and result, why rows did not match, the rows themselves on request
-- The laptop reads waiting rows and writes results straight to the table (wpie.live.court_rows).

create table if not exists public.court_rows (
  id            uuid primary key default gen_random_uuid(),
  kind          text not null check (kind in ('eviction', 'money_judgment', 'divorce')),
  county        text not null,
  case_number   text not null,
  filed         date,
  class_code    text,
  caption       text,
  status_text   text,
  plaintiff     text,                       -- eviction: the landlord, who is the prospect when they own the property
  defendant     text,                       -- money judgment: the debtor; eviction: the tenant, record only, never a prospect
  address       text,                       -- eviction: the property the tenant lives at
  city          text,
  zip           text,
  amount        numeric,
  extra         jsonb not null default '{}'::jsonb,
  deposited_by  text not null,
  deposited_at  timestamptz not null default now(),
  -- the laptop's answer
  state         text not null default 'waiting' check (state in ('waiting', 'matched', 'unmatched', 'ambiguous', 'skipped')),
  result_note   text,
  parcel_id     text,
  wpie_property_id bigint,
  matched_owner text,
  pulled_at     timestamptz,
  result_at     timestamptz,
  updated_at    timestamptz not null default now(),
  unique (kind, county, case_number)
);
create index if not exists court_rows_state_idx on public.court_rows (kind, state);
alter table public.court_rows enable row level security;
grant select on public.court_rows to authenticated, service_role;
drop policy if exists court_rows_team_read on public.court_rows;
create policy court_rows_team_read on public.court_rows for select to authenticated using (public.is_team());

create or replace function public.agent_court_rows_deposit(p jsonb, p_agent text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  kind_ text := lower(btrim(coalesce(p->>'kind', '')));
  who   text := coalesce(nullif(btrim(p_agent), ''), 'agent');
  x jsonb; cn text; co text; why text; ex public.court_rows;
  added integer := 0; updated integer := 0; already integer := 0; refused jsonb := '[]'::jsonb;
begin
  if kind_ not in ('eviction', 'money_judgment', 'divorce') then
    return jsonb_build_object('ok', false, 'reason', 'kind is eviction, money_judgment or divorce');
  end if;
  if jsonb_typeof(p->'rows') is distinct from 'array' then return jsonb_build_object('ok', false, 'reason', 'rows is a list'); end if;
  if jsonb_array_length(p->'rows') > 500 then return jsonb_build_object('ok', false, 'reason', 'at most 500 rows a call: send the rest in the next call'); end if;
  for x in select * from jsonb_array_elements(p->'rows') loop
    cn := upper(regexp_replace(coalesce(x->>'case_number', ''), '[^0-9A-Za-z]', '', 'g'));
    co := initcap(btrim(regexp_replace(coalesce(x->>'county', ''), '\s+county$', '', 'i')));
    why := case
      when cn !~ '^\d{4}[A-Z]{2}\d{1,7}$' then 'case_number is the year, two letters and the number, e.g. 2026SC007476'
      when co = '' then 'no county'
      when kind_ = 'eviction' and coalesce(btrim(x->>'address'), '') = '' then 'an eviction row needs the address of the property (where the tenant lives)'
      when kind_ = 'eviction' and coalesce(btrim(x->>'city'), '') = '' then 'an eviction row needs the city of the property'
      when kind_ <> 'eviction' and coalesce(btrim(x->>'defendant'), '') = '' and coalesce(btrim(x->>'caption'), '') = '' then 'the row needs the defendant (or the caption, "X vs. Y")'
    end;
    if why is not null then
      refused := refused || jsonb_build_object('case_number', nullif(x->>'case_number', ''), 'county', nullif(co, ''), 'reason', why);
      continue;
    end if;
    select * into ex from public.court_rows where kind = kind_ and county = co and case_number = cn;
    if found and ex.state <> 'waiting' then already := already + 1; continue; end if;
    if found then
      update public.court_rows set filed = coalesce(nullif(x->>'filed', '')::date, filed), class_code = coalesce(nullif(btrim(x->>'class_code'), ''), class_code),
             caption = coalesce(nullif(btrim(x->>'caption'), ''), caption), status_text = coalesce(nullif(btrim(x->>'status'), ''), status_text),
             plaintiff = coalesce(nullif(btrim(x->>'plaintiff'), ''), plaintiff), defendant = coalesce(nullif(btrim(x->>'defendant'), ''), defendant),
             address = coalesce(nullif(btrim(x->>'address'), ''), address), city = coalesce(nullif(btrim(x->>'city'), ''), city),
             zip = coalesce(nullif(btrim(x->>'zip'), ''), zip),
             amount = coalesce(nullif(regexp_replace(coalesce(x->>'amount', ''), '[^0-9.]', '', 'g'), '')::numeric, amount),
             extra = extra || coalesce(x->'extra', '{}'::jsonb), pulled_at = null, updated_at = now()
       where id = ex.id;
      updated := updated + 1;
    else
      insert into public.court_rows (kind, county, case_number, filed, class_code, caption, status_text, plaintiff, defendant, address, city, zip, amount, extra, deposited_by)
      values (kind_, co, cn, nullif(x->>'filed', '')::date, nullif(btrim(x->>'class_code'), ''), nullif(btrim(x->>'caption'), ''), nullif(btrim(x->>'status'), ''),
              nullif(btrim(x->>'plaintiff'), ''), nullif(btrim(x->>'defendant'), ''), nullif(btrim(x->>'address'), ''), nullif(btrim(x->>'city'), ''),
              nullif(btrim(x->>'zip'), ''), nullif(regexp_replace(coalesce(x->>'amount', ''), '[^0-9.]', '', 'g'), '')::numeric,
              case when jsonb_typeof(x->'extra') = 'object' then x->'extra' else '{}'::jsonb end, who);
      added := added + 1;
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'kind', kind_, 'added', added, 'updated', updated, 'already_answered', already, 'refused', refused,
    'waiting', (select count(*) from public.court_rows where kind = kind_ and state = 'waiting'),
    'next', case kind_ when 'divorce' then 'banked. The laptop has no rule for divorce rows yet, so they wait here; nothing is lost.'
                 else 'the laptop takes waiting rows on its nightly run, ties each to a parcel and writes the result on the row: court_rows_status shows it. Do not load these rows as cards yourself.' end);
exception when invalid_datetime_format or datetime_field_overflow then
  return jsonb_build_object('ok', false, 'reason', 'filed is a date, YYYY-MM-DD (nothing in this call was saved)');
end $$;

create or replace function public.agent_court_rows_status(p jsonb, p_agent text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  kind_ text := nullif(lower(btrim(coalesce(p->>'kind', ''))), ''); st text := nullif(lower(btrim(coalesce(p->>'state', ''))), '');
  co text := nullif(initcap(btrim(coalesce(p->>'county', ''))), ''); lim integer := least(greatest(coalesce(nullif(p->>'limit', '')::integer, 100), 1), 500);
  after_ timestamptz := nullif(p->>'after', '')::timestamptz;
begin
  return jsonb_build_object(
    'by_kind', coalesce((select jsonb_object_agg(k, c) from (
        select r.kind k, jsonb_build_object('rows', count(*), 'waiting', count(*) filter (where r.state = 'waiting'), 'matched', count(*) filter (where r.state = 'matched'),
                 'unmatched', count(*) filter (where r.state = 'unmatched'), 'ambiguous', count(*) filter (where r.state = 'ambiguous'),
                 'skipped', count(*) filter (where r.state = 'skipped'), 'properties_matched', count(distinct r.parcel_id) filter (where r.state = 'matched'),
                 'last_deposit', max(r.deposited_at), 'last_result', max(r.result_at)) c
          from public.court_rows r where (kind_ is null or r.kind = kind_) and (co is null or r.county = co) group by r.kind) z), '{}'::jsonb),
    'why_not_matched', coalesce((select jsonb_object_agg(w, n) from (
        select left(coalesce(r.result_note, 'no note'), 110) w, count(*) n from public.court_rows r
         where r.state in ('unmatched', 'ambiguous', 'skipped') and (kind_ is null or r.kind = kind_) and (co is null or r.county = co)
         group by 1 order by 2 desc limit 15) z), '{}'::jsonb),
    'by_county', coalesce((select jsonb_object_agg(c, j) from (
        select r.county c, jsonb_build_object('rows', count(*), 'waiting', count(*) filter (where r.state = 'waiting'), 'matched', count(*) filter (where r.state = 'matched')) j
          from public.court_rows r where (kind_ is null or r.kind = kind_) group by r.county) z), '{}'::jsonb),
    'rows', case when coalesce((p->>'rows')::boolean, false) then coalesce((
        select jsonb_agg(jsonb_build_object('kind', r.kind, 'county', r.county, 'case_number', r.case_number, 'state', r.state, 'note', r.result_note,
                 'parcel_id', r.parcel_id, 'owner_of_record', r.matched_owner, 'address', r.address, 'result_at', r.result_at, 'updated_at', r.updated_at) order by r.updated_at)
          from (select * from public.court_rows q where (kind_ is null or q.kind = kind_) and (st is null or q.state = st) and (co is null or q.county = co)
                   and (after_ is null or q.updated_at > after_) order by q.updated_at limit lim) r), '[]'::jsonb) end,
    'how_it_works', 'Deposit with court_rows_deposit. Each night the laptop ties waiting rows to a parcel (an eviction by the property address, a money judgment by the debtor''s name inside the county) and writes matched, unmatched or ambiguous on the row. A matched row is a record on the property: it reaches a card through the ordinary pipeline, stacked with whatever else is on that property. You never load these rows as cards.');
end $$;

revoke all on function public.agent_court_rows_deposit(jsonb, text), public.agent_court_rows_status(jsonb, text) from public, anon, authenticated;
grant execute on function public.agent_court_rows_deposit(jsonb, text), public.agent_court_rows_status(jsonb, text) to service_role;
