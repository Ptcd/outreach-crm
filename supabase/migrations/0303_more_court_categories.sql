-- 0303: six more court categories on the Research Board, and the tax warrant job it never had.
-- Colin 2026-11-22, on the list of other WCCA categories (partition, wills filed, land contract foreclosures,
-- construction and hospital liens, quiet title, receivership): "Make these new research types in the master sheet and
-- list". Each gets a board row and a how-to document. Tax warrants had been banked since 2026-11-21 with no board row.
-- The door banks the six new kinds (court_rows_deposit); the laptop has no rule for them yet, so their rows wait and
-- nothing is lost. A new job counts toward Behind from the week it starts (research_jobs.starts_week), not from the
-- board's first week, or it would be flagged the Monday after it was made.

alter table public.research_jobs add column if not exists starts_week date;

create or replace function public.research_standing(p_now timestamptz default now())
returns table (job_id integer, last_done date, weeks_missed integer) language sql stable security definer set search_path = public as $fn$
  select j.id, t.last_done,
         case when t.last_done is null
              then greatest(0, (public.research_week(p_now) - greatest(public.research_first_week(), coalesce(j.starts_week, public.research_first_week()))) / 7)
              else greatest(0, (public.research_week(p_now) - t.last_done) / 7 - 1) end
    from public.research_jobs j
    left join lateral (select max(w.week) as last_done from public.research_week_ticks w
                        where w.job_id = j.id and w.done and w.week <= public.research_week(p_now)) t on true
$fn$;
revoke all on function public.research_standing(timestamptz) from public, anon, authenticated;
grant execute on function public.research_standing(timestamptz) to service_role;

-- room in the order: tax warrants beside probate, the six after the court jobs
update public.research_jobs set sort = sort * 10 where sort < 100;

insert into public.research_jobs (id, key, priority, category, job, data, source, cadence, status, status_at, status_by, sort, starts_week)
select v.id, v.key, v.priority, v.category, v.job, v.data, 'WCCA', 'Weekly', v.status, now(), 'desk', v.sort, v.starts_week
  from (values
    (21, 'tax_warrant_tw', 'P1', 'Tax', 'WCCA state tax warrant (TW) pulls: the debtor in the caption tied to their house by name inside the county.',
     'debtor, county + case, amount, filing date', 'Banked by the agents since 2026-11-21; the laptop ties each to a parcel. The board had no row for it until 2026-11-22.', 45, date '2026-11-16'),
    (22, 'partition', 'P2', 'Court: new', 'Partition actions: heirs or co-owners asking a judge to divide or force the sale of a property.',
     'parties, county + case, class code, filing date, address if printed', 'NEW 2026-11-22 (Colin). First step: find the class code in WCCA advanced search and one week''s statewide count. Bank as court_rows_deposit kind partition. The laptop has no rule yet; rows wait.', 101, date '2026-11-23'),
    (23, 'wills_wl', 'P3', 'Court: new', 'Wills filed (case type WL): an earlier death signal than a probate when the will is filed at a death; many are only stored for safekeeping.',
     'person whose will it is, county + case, filing date, status', 'NEW 2026-11-22 (Colin). First step: one week''s statewide count, and how a will filed at a death differs on WCCA from one stored for safekeeping. Bank as kind will. No laptop rule yet.', 102, date '2026-11-23'),
    (24, 'land_contract', 'P3', 'Court: new', 'Land contract foreclosures (strict foreclosure, forfeiture): the buyer on a land contract being put out by the seller.',
     'vendor, vendee, county + case, class code, filing date, address if printed', 'NEW 2026-11-22 (Colin). First step: which class code WCCA files these under (they may not be 30404) and one week''s count. Bank as kind land_contract. No laptop rule yet.', 103, date '2026-11-23'),
    (25, 'court_liens', 'P3', 'Court: new', 'Construction liens and hospital liens filed with the clerk, if WCCA lists them: an unpaid contractor often means a stalled repair.',
     'owner, claimant, county + case, class code, amount, filing date', 'NEW 2026-11-22 (Colin). First step: whether WCCA lists these at all (case type or class code) and one week''s count. Bank as kind lien. No laptop rule yet.', 104, date '2026-11-23'),
    (26, 'quiet_title', 'P3', 'Court: new', 'Quiet title actions: a messy title being cleared; often an investor after a tax deed, so the weaker of the six.',
     'plaintiff, defendants, county + case, class code, filing date', 'NEW 2026-11-22 (Colin). First step: the class code and one week''s count, and how many plaintiffs are investors or counties. Bank as kind quiet_title. No laptop rule yet.', 105, date '2026-11-23'),
    (27, 'receivership', 'P3', 'Court: new', 'Receiverships: a city or lender asking the court to put a manager over a problem property. Rare.',
     'plaintiff, owner, county + case, class code, filing date, address if printed', 'NEW 2026-11-22 (Colin). First step: the class code and one week''s count. Bank as kind receivership. No laptop rule yet.', 106, date '2026-11-23')
  ) v(id, key, priority, category, job, data, status, sort, starts_week)
on conflict (id) do nothing;

alter table public.court_rows drop constraint if exists court_rows_kind_check;
alter table public.court_rows add constraint court_rows_kind_check check (kind in ('eviction', 'money_judgment', 'divorce', 'guardianship', 'foreclosure',
  'probate', 'tax_warrant', 'partition', 'will', 'land_contract', 'lien', 'quiet_title', 'receivership'));

CREATE OR REPLACE FUNCTION public.agent_court_rows_deposit(p jsonb, p_agent text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  kind_ text := lower(btrim(coalesce(p->>'kind', '')));
  who   text := coalesce(nullif(btrim(p_agent), ''), 'agent');
  x jsonb; cn text; co text; why text; ex public.court_rows;
  added integer := 0; updated integer := 0; already integer := 0; refused jsonb := '[]'::jsonb;
begin
  if kind_ not in ('eviction', 'money_judgment', 'divorce', 'guardianship', 'foreclosure', 'probate', 'tax_warrant',
                   'partition', 'will', 'land_contract', 'lien', 'quiet_title', 'receivership') then
    return jsonb_build_object('ok', false, 'reason', 'kind is eviction, money_judgment, divorce, guardianship, foreclosure, probate, tax_warrant, partition, will, land_contract, lien, quiet_title or receivership');
  end if;
  if jsonb_typeof(p->'rows') is distinct from 'array' then return jsonb_build_object('ok', false, 'reason', 'rows is a list'); end if;
  if jsonb_array_length(p->'rows') > 500 then return jsonb_build_object('ok', false, 'reason', 'at most 500 rows a call: send the rest in the next call'); end if;
  for x in select * from jsonb_array_elements(p->'rows') loop
    cn := upper(regexp_replace(coalesce(x->>'case_number', ''), '[^0-9A-Za-z]', '', 'g'));
    co := replace(initcap(btrim(regexp_replace(coalesce(x->>'county', ''), '\s+county$', '', 'i'))), ' Du ', ' du ');
    why := case
      when cn !~ '^\d{4}[A-Z]{2}\d{1,7}$' then 'case_number is the year, two letters and the number, e.g. 2026SC007476'
      when co = '' then 'no county'
      when kind_ = 'eviction' and coalesce(btrim(x->>'address'), '') = '' then 'an eviction row needs the address of the property (where the tenant lives)'
      when kind_ = 'eviction' and coalesce(btrim(x->>'city'), '') = '' then 'an eviction row needs the city of the property'
      when kind_ = 'guardianship' and cn !~ '^[0-9]{4}GN' then 'a guardianship case number has GN in it, e.g. 2026GN000123'
      when kind_ = 'guardianship' and coalesce(btrim(x->>'defendant'), '') = '' and coalesce(btrim(x->>'caption'), '') = ''
        then 'a guardianship row needs the person the guardianship is for, in defendant (or the caption, "In the Matter of the Guardianship of X")'
      when kind_ = 'divorce' and coalesce(btrim(x->>'defendant'), '') = '' and coalesce(btrim(x->>'caption'), '') = ''
        then 'the row needs the other spouse in defendant (or the caption). A joint petition has no respondent: put the co-petitioner in defendant and "Joint petition: A and B" in caption'
      -- 0274: the three strongest court signals
      when kind_ = 'foreclosure' and cn !~ '^[0-9]{4}CV' then 'a mortgage foreclosure case number has CV in it, e.g. 2026CV001234'
      when kind_ = 'foreclosure' and coalesce(btrim(x->>'class_code'), '') <> '' and position('30404' in x->>'class_code') = 0
        then 'a mortgage foreclosure is class code 30404; a CV case of another class is not one (a money judgment goes in as kind money_judgment)'
      when kind_ = 'probate' and cn !~ '^[0-9]{4}(PR|IN)' then 'a probate case number has PR (or IN, informal administration) in it, e.g. 2026PR000123'
      when kind_ = 'probate' and coalesce(btrim(x->>'defendant'), '') = '' and coalesce(btrim(x->>'caption'), '') = ''
        then 'a probate row needs the person who died, in defendant (or the caption, "In the Matter of the Estate of X"); put whoever opened the estate in plaintiff'
      when kind_ = 'tax_warrant' and cn !~ '^[0-9]{4}TW' then 'a tax warrant case number has TW in it, e.g. 2026TW000045'
      -- 0303: six more categories, banked only until the laptop has a rule for each
      when kind_ in ('partition', 'land_contract', 'lien', 'quiet_title', 'receivership') and coalesce(btrim(x->>'class_code'), '') = ''
        then 'this kind needs class_code (the class the court prints, number and words), so the rule can be written from what was banked'
      when kind_ = 'will' and coalesce(btrim(x->>'defendant'), '') = '' and coalesce(btrim(x->>'caption'), '') = ''
        then 'a will row needs the person whose will it is, in defendant (or the caption)'
      when kind_ not in ('eviction', 'guardianship', 'divorce', 'probate', 'will') and coalesce(btrim(x->>'defendant'), '') = '' and coalesce(btrim(x->>'caption'), '') = '' then 'the row needs the defendant (or the caption, "X vs. Y")'
    end;
    if why is not null then
      refused := refused || jsonb_build_object('case_number', nullif(x->>'case_number', ''), 'county', nullif(co, ''), 'reason', why);
      continue;
    end if;
    select * into ex from public.court_rows where kind = kind_ and county = co and case_number = cn;
    -- a row the laptop tied to a parcel is settled; one it could not tie may be corrected and goes back in line
    if found and ex.state = 'matched' then already := already + 1; continue; end if;
    if found then
      update public.court_rows set filed = coalesce(nullif(x->>'filed', '')::date, filed), class_code = coalesce(nullif(btrim(x->>'class_code'), ''), class_code),
             caption = coalesce(nullif(btrim(x->>'caption'), ''), caption), status_text = coalesce(nullif(btrim(x->>'status'), ''), status_text),
             plaintiff = coalesce(nullif(btrim(x->>'plaintiff'), ''), plaintiff), defendant = coalesce(nullif(btrim(x->>'defendant'), ''), defendant),
             address = coalesce(nullif(btrim(x->>'address'), ''), address), city = coalesce(nullif(btrim(x->>'city'), ''), city),
             zip = coalesce(nullif(btrim(x->>'zip'), ''), zip),
             amount = coalesce(nullif(regexp_replace(coalesce(x->>'amount', ''), '[^0-9.]', '', 'g'), '')::numeric, amount),
             extra = extra || coalesce(x->'extra', '{}'::jsonb), state = 'waiting', result_note = null, result_at = null, pulled_at = null, updated_at = now()
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
    'next', case when kind_ in ('partition', 'will', 'land_contract', 'lien', 'quiet_title', 'receivership')
                   then 'banked. The laptop has no rule for this kind yet, so the rows wait here and nothing is lost. Do not load them as cards yourself; write what you learn about the category on its Research Board document (category_instructions_set).'
                 else case kind_ when 'divorce' then 'banked. The laptop has no rule for divorce rows yet, so they wait here; nothing is lost.'
                 when 'guardianship' then 'the laptop takes waiting rows on its nightly run and ties the person to their house by name inside the county: court_rows_status shows it. A guardianship is worked by a person only: no text and no paid trace on it, ever; Colin calls the guardian, so put the guardian or petitioner in plaintiff. Do not load these rows as cards yourself.'
                 when 'foreclosure' then 'the laptop takes waiting rows every ten minutes by day, ties the defendant to their house by name inside the county and writes the result on the row: court_rows_status shows it. Do not load a foreclosure as a card yourself: in the records it stacks with the taxes, code cases and estates already known on that house, and on a card of your own it cannot.'
                 when 'probate' then 'the laptop takes waiting rows every ten minutes by day, ties the person who died to their house by name inside the county and writes the result on the row: court_rows_status shows it. Do not load a probate as a card yourself. Nobody texts an estate inside 30 days of the filing.'
                 else 'the laptop takes waiting rows every ten minutes by day, ties each to a parcel and writes the result on the row: court_rows_status shows it. Do not load these rows as cards yourself.' end end);
exception when invalid_datetime_format or datetime_field_overflow then
  return jsonb_build_object('ok', false, 'reason', 'filed is a date, YYYY-MM-DD (nothing in this call was saved)');
end $function$;

revoke all on function public.agent_court_rows_deposit(jsonb, text) from public, anon, authenticated;
grant execute on function public.agent_court_rows_deposit(jsonb, text) to service_role;
