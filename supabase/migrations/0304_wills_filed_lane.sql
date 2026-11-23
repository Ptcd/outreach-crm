-- 0304: wills filed with no probate become a real lane; the three jobs WCCA cannot read are closed.
-- Grok's count, one week statewide (Nov 16-22), relayed by Colin 2026-11-22: "Wills Filed - No Probate" (WL, class
-- 50111) 172, more than every other new court category together; liens 34 (construction 19, hospital 8, condo 7);
-- "Other - Real Estate" (30405) 14, and WCCA shows no complaint text, so a partition, a quiet title or a receivership
-- cannot be told from any other property dispute without the courthouse papers; safekeeping wills 10 (living
-- people); agricultural foreclosures 0.
--   * kind will: WL and class 50111 only; the laptop ties it like a probate (wi.courts.wills_filed, estate_ownership /
--     probate_filing), so the probate signal, the estate wording and the 30-day floor from the filing apply as they are.
--   * partition, quiet_title, receivership: closed (research_jobs.closed_at), never flagged behind; rows already
--     banked stay.
--   * court liens: the codes are known; still banked only.

alter table public.research_jobs add column if not exists closed_at timestamptz;

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
      when kind_ = 'will' and cn !~ '^[0-9]{4}WL' then 'a will case number has WL in it, e.g. 2026WL000101'
      when kind_ = 'will' and position('50111' in coalesce(x->>'class_code', '')) = 0
        then 'a will row is class code 50111 (Wills Filed - No Probate), and says so in class_code; a will deposited for safekeeping is a living person and is not banked'
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
    'next', case when kind_ = 'will'
                   then 'the laptop takes waiting rows every ten minutes by day and ties the person whose will it is to their house by name inside the county, exactly like a probate: court_rows_status shows it. Do not load these as cards yourself. Nobody texts an estate inside 30 days of the filing.'
                 when kind_ in ('partition', 'land_contract', 'lien', 'quiet_title', 'receivership')
                   then 'banked. The laptop has no rule for this kind yet, so the rows wait here and nothing is lost. Do not load them as cards yourself; write what you learn about the category on its Research Board document (category_instructions_set).'
                 else case kind_ when 'divorce' then 'banked. The laptop has no rule for divorce rows yet, so they wait here; nothing is lost.'
                 when 'guardianship' then 'the laptop takes waiting rows on its nightly run and ties the person to their house by name inside the county: court_rows_status shows it. A guardianship is worked by a person only: no text and no paid trace on it, ever; Colin calls the guardian, so put the guardian or petitioner in plaintiff. Do not load these rows as cards yourself.'
                 when 'foreclosure' then 'the laptop takes waiting rows every ten minutes by day, ties the defendant to their house by name inside the county and writes the result on the row: court_rows_status shows it. Do not load a foreclosure as a card yourself: in the records it stacks with the taxes, code cases and estates already known on that house, and on a card of your own it cannot.'
                 when 'probate' then 'the laptop takes waiting rows every ten minutes by day, ties the person who died to their house by name inside the county and writes the result on the row: court_rows_status shows it. Do not load a probate as a card yourself. Nobody texts an estate inside 30 days of the filing.'
                 else 'the laptop takes waiting rows every ten minutes by day, ties each to a parcel and writes the result on the row: court_rows_status shows it. Do not load these rows as cards yourself.' end end);
exception when invalid_datetime_format or datetime_field_overflow then
  return jsonb_build_object('ok', false, 'reason', 'filed is a date, YYYY-MM-DD (nothing in this call was saved)');
end $function$;

CREATE OR REPLACE FUNCTION public.research_behind(p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object('job', j.id, 'key', j.key, 'priority', j.priority, 'category', j.category, 'what', left(j.job, 160),
           'last_ran_week_of', s.last_done, 'weeks_with_no_tick', s.weeks_missed, 'status', j.status) order by j.sort), '[]'::jsonb)
    from public.research_jobs j join public.research_standing(p_now) s on s.job_id = j.id
   where s.weeks_missed >= 2 and j.closed_at is null
$function$;

update public.research_jobs set status = 'LANE since 2026-11-22: WL, class 50111 (Wills Filed - No Probate). 172 statewide Nov 16-22 (Grok). Bank as kind will; the laptop ties each like a probate, and the 30-day floor runs from the filing. Safekeeping deposits (living people) are never banked.',
       status_at = now(), status_by = 'desk', job = 'Wills filed with no probate (WL, class 50111): a death where nobody has opened an estate. Tied and scored exactly like a probate.'
 where key = 'wills_wl';
update public.research_jobs set status = 'CLOSED 2026-11-22: these file under 30405 Other - Real Estate (14 statewide Nov 16-22), and WCCA shows no complaint text, so they cannot be told from any other property dispute without the courthouse papers (Grok: 1 of 12 sampled classifiable, not a seller lead).',
       status_at = now(), status_by = 'desk', closed_at = now()
 where key in ('partition', 'quiet_title', 'receivership') and closed_at is null;
update public.research_jobs set status = 'Codes found 2026-11-22: construction 19, hospital 8, condo 7 statewide Nov 16-22 (Grok). Bank as kind lien with the class code; no laptop rule yet, so they wait.',
       status_at = now(), status_by = 'desk'
 where key = 'court_liens';
