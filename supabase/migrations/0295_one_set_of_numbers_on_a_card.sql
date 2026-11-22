-- 0295: one set of numbers on a card. The live-work packet told an agent to copy its price rows into the call script
-- ("so the card says one thing"); with the Deal sheet switched on for callers that made two: the script's rows and
-- the sheet. On 226 60th Ave, Somers (2026-11-22) the script said open at $236,800, the sheet said no number, and the
-- caller texted the seller a third figure. Now the script names no price of ours, and the server refuses one that does.

update public.live_work_packet
   set body = replace(body, 'In the script''s money part use the rows you stored in call_prices, so the card says one thing.',
                      'The story and the script name NO price of ours: no open, no top, no "we can do $X". The caller''s number is the Deal sheet''s alone, and the server refuses a script that gives one. In the money part write "the number on the Deal sheet", and say what to do when the sheet has none (give none, book a time).'),
       updated_at = now(), updated_by = 'desk'
 where body like '%In the script''s money part use the rows you stored in call_prices%';

CREATE OR REPLACE FUNCTION public.agent_call_brief_set(p jsonb, p_agent text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare lid uuid; l public.leads; b public.call_briefs; e jsonb; owed jsonb := '[]'::jsonb; amt numeric; kind text; f text; i integer := 0; v integer;
        story text := btrim(coalesce(p->>'story', '')); script text := btrim(coalesce(p->>'script', '')); unk jsonb;
        opening text; raised text;
        angles jsonb := case when jsonb_typeof(p->'angles') = 'array' then p->'angles' else '[]'::jsonb end;
        situation text := nullif(btrim(coalesce(p->>'situation', '')), '');
begin
  begin lid := nullif(p->>'lead_id', '')::uuid; exception when others then lid := null; end;
  if lid is null then return jsonb_build_object('ok', false, 'reason', 'lead_id is the card'); end if;
  select * into l from public.leads where id = lid;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card'); end if;
  if length(story) < 60 then return jsonb_build_object('ok', false, 'reason', 'story: say what is going on with the house and the people, in plain words (a few sentences): who owns it, why they might sell, what is pressing'); end if;
  if length(script) < 300 then return jsonb_build_object('ok', false, 'reason', 'script: the words for the call, by section (open, what is owed, the house, who decides, money, and a close for each way the unknowns can turn out)'); end if;
  -- 0288: the opening of a call never raises their trouble first (74 Pioneer Ct, 2026-11-22: a script opened with
  -- "I understand there may have been a loss in the family"). The opening is everything before the second heading.
  opening := split_part(regexp_replace(script, '^\s*\*\*[^*]+\*\*', ''), '**', 1);
  raised := (regexp_match(opening, '(loss in the family|sorry for your loss|passed away|\mdied\M|\mdeath\M|deceased|foreclos\w*|sheriff.s? sale|behind on (your |the )?(taxes|payments|mortgage)|back taxes|delinquen\w*|\mprobate\M|lis pendens|\mjudgment\M|tax warrant|evict\w*|bankrupt\w*|divorce)', 'i'))[1];
  if raised is not null then
    return jsonb_build_object('ok', false, 'reason', 'script: the opening raises "' || raised || '" before the seller does. Open with who you are and the house, ask who is on the title and who decides, and let them tell you. Their trouble is why we call, never what we say first; put what to say IF they bring it up in a later section.');
  end if;
  -- 0295: the caller's number is the Deal sheet's and nothing else's (226 60th Ave, 2026-11-22: the script carried
  -- three price rows, the sheet said no number, and a third figure got texted to the seller)
  raised := (regexp_match(lower(script || ' ' || story), '((?:\mopen(?:ing)?(?: at| with)?|no higher than|not higher than|\mtop(?: at| of)?|\mmax(?:imum)?|we can (?:do|pay|offer)|our (?:offer|number|price)(?: is| of)?|offer (?:of|at)):?\s*\$\s?[0-9][0-9,]*)'))[1];
  if raised is not null and (select mode from public.deal_sheet_rules where id = 1) <> 'off' then
    return jsonb_build_object('ok', false, 'reason', 'script: it gives the caller a price ("' || raised || '"). The caller''s number comes from the Deal sheet on the card and nowhere else: two sets of numbers on one card got a wrong figure texted to a seller. Take every figure for what we would pay out of the story and the script and write "the number on the Deal sheet" instead. What is owed, what it sells for finished and the seller''s own number may stay. To put a number on the sheet, use deal_price.');
  end if;
  if length(script) > 20000 or length(story) > 6000 then return jsonb_build_object('ok', false, 'reason', 'too long: a story is 6,000 characters at most and a script 20,000'); end if;
  if jsonb_typeof(p->'owed') is distinct from 'array' then
    return jsonb_build_object('ok', false, 'reason', 'owed is a list, one row for each thing owed: kind, creditor, amount, basis, follows_house. Send an empty list only with nothing_owed_found: true');
  end if;
  if jsonb_array_length(p->'owed') = 0 and coalesce((p->>'nothing_owed_found')::boolean, false) is not true then
    return jsonb_build_object('ok', false, 'reason', 'owed is empty: if you looked (the mortgage records, the tax roll, the court) and found nothing owed, say nothing_owed_found: true and say where you looked in sources');
  end if;
  for e in select * from jsonb_array_elements(p->'owed') loop
    i := i + 1;
    kind := lower(btrim(coalesce(e->>'kind', '')));
    if kind not in ('mortgage', 'tax', 'judgment', 'lien', 'estate_claim', 'utility', 'hoa', 'other') then
      return jsonb_build_object('ok', false, 'reason', 'owed row ' || i || ': kind is mortgage, tax, judgment, lien, estate_claim, utility, hoa or other');
    end if;
    begin amt := nullif(regexp_replace(coalesce(e->>'amount', ''), '[^0-9.]', '', 'g'), '')::numeric; exception when others then amt := null; end;
    f := lower(btrim(coalesce(e->>'follows_house', 'unknown')));
    if f in ('true', 't') then f := 'yes'; elsif f in ('false', 'f') then f := 'no'; end if;
    if f not in ('yes', 'no', 'unknown') then
      return jsonb_build_object('ok', false, 'reason', 'owed row ' || i || ': follows_house is yes (a lien on the house: it is paid at closing), no (owed by the person or the estate but not secured on the house) or unknown');
    end if;
    if coalesce(btrim(e->>'basis'), '') = '' then
      return jsonb_build_object('ok', false, 'reason', 'owed row ' || i || ': basis says where the figure was read (the seller said it, the court record, the register of deeds, the tax roll) or that it is an estimate');
    end if;
    owed := owed || jsonb_build_object('kind', kind, 'creditor', nullif(btrim(coalesce(e->>'creditor', '')), ''), 'amount', amt, 'basis', btrim(e->>'basis'),
                                       'follows_house', f, 'note', nullif(btrim(coalesce(e->>'note', '')), ''));
  end loop;
  unk := case when jsonb_typeof(p->'unknowns') = 'array' then p->'unknowns' else '[]'::jsonb end;
  -- 0281: the angles, ranked: what we can give that is not money, and why it matters to this seller
  i := 0;
  for e in select * from jsonb_array_elements(angles) loop
    i := i + 1;
    if jsonb_typeof(e) <> 'object' or coalesce(btrim(e->>'angle'), '') = '' or coalesce(btrim(e->>'why'), '') = '' then
      return jsonb_build_object('ok', false, 'reason', 'angles row ' || i || ': {angle, why}: what we can give that is not money (close on their date, stay after closing, take what is left in it, pay the back taxes at closing, handle the estate papers, no showings, moving money) and why it matters to THIS seller');
    end if;
  end loop;
  select * into b from public.call_briefs where lead_id = lid for update;
  v := coalesce(b.version, 0) + 1;
  insert into public.call_briefs (lead_id, status, wanted_at, story, owed, unknowns, angles, situation, script, sources, to_clear, owed_total, written_by, written_at, version, updated_at)
  values (lid, 'ready', coalesce(b.wanted_at, now()), story, owed, unk, angles, situation, script, nullif(btrim(coalesce(p->>'sources', '')), ''),
          (select sum((x->>'amount')::numeric) from jsonb_array_elements(owed) x where x->>'follows_house' = 'yes'),
          (select sum((x->>'amount')::numeric) from jsonb_array_elements(owed) x),
          coalesce(nullif(btrim(p_agent), ''), 'agent'), now(), v, now())
  on conflict (lead_id) do update set status = 'ready', story = excluded.story, owed = excluded.owed, unknowns = excluded.unknowns, script = excluded.script,
         angles = excluded.angles, situation = excluded.situation, claimed_by = null, claimed_at = null,
         sources = excluded.sources, to_clear = excluded.to_clear, owed_total = excluded.owed_total, written_by = excluded.written_by,
         written_at = excluded.written_at, version = excluded.version, updated_at = now();
  insert into public.call_brief_versions (lead_id, version, story, owed, unknowns, script, sources, by)
  values (lid, v, story, owed, unk, script, nullif(btrim(coalesce(p->>'sources', '')), ''), coalesce(nullif(btrim(p_agent), ''), 'agent'));
  perform public.yes_sheet_to_task(lid);
  select * into b from public.call_briefs where lead_id = lid;
  return jsonb_build_object('ok', true, 'lead_id', lid, 'version', v, 'to_clear', b.to_clear, 'owed_total', b.owed_total, 'owed_line', public.call_brief_owed_line(b.owed));
end $function$;
