-- 0241: a guardianship filing has a way in, and a joint divorce petition is told how to come in.
--
-- Colin 2026-11-15, looking at the Research Board: "why aren't the muses keeping up with these", then "fix whatever
-- muse fucked up on" and "Go". Two of the five court jobs on the board could not be done by anyone:
--
--   Guardianship (GN)  the agents' deposit took only eviction, money_judgment and divorce, and the laptop's own route
--                      (the Monday supervised court pull) has brought nothing in since 2026-10-26. court_rows now takes
--                      kind guardianship: the person the guardianship is for in defendant (or the court's caption), the
--                      guardian or petitioner in plaintiff. The laptop writes the rows into the drop folder of its
--                      wi.courts.guardianships collector, which ties the person to their house by name inside the
--                      county, as it does for the Monday pull. Human only, as since 2026-10-23: no text, no paid trace,
--                      Colin calls the guardian (the laptop's selector enforces it; nothing here loads a card).
--   Divorce (FA)       655 of Muse 2's 1,617 rows were joint petitions, refused for having no respondent; Muse 2 asked
--                      which form to send (desk 273). The door already takes the co-petitioner in defendant; the
--                      refusal now says so: co-petitioner in defendant, "Joint petition: A and B" in caption.

alter table public.court_rows drop constraint if exists court_rows_kind_check;
alter table public.court_rows add constraint court_rows_kind_check check (kind in ('eviction', 'money_judgment', 'divorce', 'guardianship'));

-- agent_court_rows_deposit: from 0228_court_rows_corrections.sql
create or replace function public.agent_court_rows_deposit(p jsonb, p_agent text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  kind_ text := lower(btrim(coalesce(p->>'kind', '')));
  who   text := coalesce(nullif(btrim(p_agent), ''), 'agent');
  x jsonb; cn text; co text; why text; ex public.court_rows;
  added integer := 0; updated integer := 0; already integer := 0; refused jsonb := '[]'::jsonb;
begin
  if kind_ not in ('eviction', 'money_judgment', 'divorce', 'guardianship') then
    return jsonb_build_object('ok', false, 'reason', 'kind is eviction, money_judgment, divorce or guardianship');
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
      when kind_ not in ('eviction', 'guardianship', 'divorce') and coalesce(btrim(x->>'defendant'), '') = '' and coalesce(btrim(x->>'caption'), '') = '' then 'the row needs the defendant (or the caption, "X vs. Y")'
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
    'next', case kind_ when 'divorce' then 'banked. The laptop has no rule for divorce rows yet, so they wait here; nothing is lost.'
                 when 'guardianship' then 'the laptop takes waiting rows on its nightly run and ties the person to their house by name inside the county: court_rows_status shows it. A guardianship is worked by a person only: no text and no paid trace on it, ever; Colin calls the guardian, so put the guardian or petitioner in plaintiff. Do not load these rows as cards yourself.'
                 else 'the laptop takes waiting rows on its nightly run, ties each to a parcel and writes the result on the row: court_rows_status shows it. Do not load these rows as cards yourself.' end);
exception when invalid_datetime_format or datetime_field_overflow then
  return jsonb_build_object('ok', false, 'reason', 'filed is a date, YYYY-MM-DD (nothing in this call was saved)');
end $$;
