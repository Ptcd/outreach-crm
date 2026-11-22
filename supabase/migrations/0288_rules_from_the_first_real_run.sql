-- 0288: what the first real run showed (74 Pioneer Ct, 2026-11-22), made into rules the server keeps:
--   * call_brief_set refuses a script whose opening raises a death, a foreclosure, back taxes or any other trouble
--     before the seller does.
--   * deal_price refuses a top above the caller's share of the way to the ceiling (deal_sheet_rules.caller_share):
--     the agent's top had been set equal to the most we pay, which is Colin's.
--   * the caller gets one "ready" alert a card: the prices wait up to four minutes for the brief.

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

CREATE OR REPLACE FUNCTION public.agent_deal_price(p_lead_id uuid, p_open numeric, p_top numeric, p_note text, p_agent text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare share numeric; l public.leads; w jsonb; cap numeric; clear numeric; cc public.team_person := public.card_caller(p_lead_id); mode text;
        note text := btrim(coalesce(p_note, ''));
begin
  select * into l from public.leads where id = p_lead_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card'); end if;
  if public.card_is_closed(l.stage) then return jsonb_build_object('ok', false, 'reason', 'the card is closed'); end if;
  if p_open is null or p_open <= 0 then return jsonb_build_object('ok', false, 'reason', 'open: the first number to say, in dollars'); end if;
  if p_top is not null and p_top < p_open then return jsonb_build_object('ok', false, 'reason', 'top is at or above open'); end if;
  if length(note) < 80 then
    return jsonb_build_object('ok', false, 'reason', 'note: the situation in plain words, why this number (what is pressing and when, what follows the house and what does not, what they walk away with), at least a couple of sentences');
  end if;
  w := public.deal_sheet_work(p_lead_id);
  cap := nullif(w->>'ceiling', '')::numeric;
  clear := coalesce(nullif(w->'math'->>'to_clear', '')::numeric, 0);
  if cap is null then
    return jsonb_build_object('ok', false, 'reason', 'no value on the card yet: comp it first (offer_update: arv, comps, sqft, then the street look and call_prices), then price it');
  end if;
  -- 0287: no number while something that may follow the house has no amount. The number has to clear it, and nobody
  -- can check that against a blank (74 Pioneer Ct, 2026-11-22: a number went on with the mortgage unknown).
  if not coalesce((w->'math'->>'owed_known')::boolean, false) and jsonb_array_length(coalesce(w->'math'->'open_owed', '[]'::jsonb)) > 0 then
    return jsonb_build_object('ok', false, 'reason', 'no number yet: ' || (select string_agg(coalesce(q->>'creditor', q->>'kind'), ', ') from jsonb_array_elements(w->'math'->'open_owed') q)
             || ' may follow the house and has no amount. Find the amount (the register of deeds, the court file) and put it in the brief, or leave the number off: '
             || 'the caller asks what is owed on the call and the sheet works the number from the answer.');
  end if;
  -- 0288: the caller's top stops part way to the ceiling; above it is Colin's (the sheet's own rule for its numbers)
  select caller_share into share from public.deal_sheet_rules where id = 1;
  if p_top is not null and p_open < cap and p_top > public.deal_round(p_open + (cap - p_open) * coalesce(share, 0.5), 500, true) then
    return jsonb_build_object('ok', false, 'reason', 'top is at most ' || public.text_money(public.deal_round(p_open + (cap - p_open) * coalesce(share, 0.5), 500, true))
             || ' for an opening of ' || public.text_money(p_open) || ': a caller goes part way to the most we pay, and above that is Colin''s.');
  end if;
  if coalesce(p_top, p_open) > cap then
    return jsonb_build_object('ok', false, 'reason', 'over the most we pay: ' || public.text_money(cap) || ' (' || round((select mao_pct from public.text_offer_rules where id = 1) * 100)::text
             || '% of the value minus the repairs). Colin prices anything above it.');
  end if;
  if clear > 0 and coalesce(p_top, p_open) < clear then
    return jsonb_build_object('ok', false, 'reason', 'that cannot close: ' || public.text_money(clear) || ' follows the house (mortgage, tax, liens) and has to be paid at closing. '
             || 'If what follows the house is more than we can pay, it is not a deal: say so in the brief and leave the number off.');
  end if;
  perform public.deal_sheet_touch(p_lead_id);
  update public.deal_sheets set agent_open = p_open, agent_top = p_top, agent_note = note, agent_by = coalesce(nullif(btrim(p_agent), ''), 'agent'),
         agent_at = now(), updated_at = now()
   where lead_id = p_lead_id;
  select r.mode into mode from public.deal_sheet_rules r where r.id = 1;
  if mode = 'on' and cc is not null and cc::text <> 'colin' then
    insert into public.tasks (lead_id, due_at, kind, owner, note, source, title)
    values (p_lead_id, now(), 'nudge', cc, 'A number is on the card for ' || coalesce(l.property_address, 'this card') || ' (' || coalesce(nullif(btrim(p_agent), ''), 'an agent')
            || '). Open the Deal sheet and the brief before you call.', 'nudge', 'Number ready');
  end if;
  return jsonb_build_object('ok', true, 'open', p_open, 'top', p_top, 'ceiling', cap, 'to_clear', clear, 'shown_to_caller', mode = 'on');
end $function$;

CREATE OR REPLACE FUNCTION public.yes_ready_claim(p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare out jsonb := '[]'::jsonb; r record; l public.leads; cc text; tell text[]; m public.team_members; p text; has_prices boolean; has_brief boolean;
begin
  if public.in_quiet_hours(p_now) then return out; end if;          -- held, and told when the quiet hours end
  update public.yes_ready_alerts set claimed_at = p_now, note = 'too old to tell' where claimed_at is null and at < p_now - interval '18 hours';
  for r in select a.lead_id, array_agg(a.id) as ids, array_agg(a.kind) as kinds from public.yes_ready_alerts a where a.claimed_at is null group by a.lead_id
            -- 0288: one alert a card. The prices wait up to 4 minutes for the brief (they land about a minute apart),
            -- so a caller who asked from the card is told once, with everything, not three times in two minutes
            having min(a.at) < p_now - interval '4 minutes' or count(distinct a.kind) >= 2
                   or not public.card_asked_for_grok(a.lead_id)   -- a seller who said yes: the caller is told at once, as before
            loop
    select * into l from public.leads where id = r.lead_id;
    if public.card_is_closed(l.stage) then
      update public.yes_ready_alerts set claimed_at = p_now, note = 'the card is closed' where id = any(r.ids);
      continue;
    end if;
    cc := public.card_caller(r.lead_id)::text;
    if cc is not null then tell := array[cc];
    else select coalesce(array_agg(t.person::text), '{}') into tell from public.team_members t where t.role = 'owner' and t.person::text <> 'muse';
    end if;
    has_prices := exists (select 1 from public.text_offers o where o.lead_id = r.lead_id and o.status = 'open' and o.call_prices is not null);
    has_brief := exists (select 1 from public.call_briefs b where b.lead_id = r.lead_id and b.status = 'ready');
    update public.yes_ready_alerts set claimed_at = p_now, people = array_to_string(tell, ', ') where id = any(r.ids);
    foreach p in array tell loop
      select * into m from public.team_members where person::text = p limit 1;
      out := out || jsonb_build_object('alert_ids', to_jsonb(r.ids), 'lead_id', r.lead_id, 'person', p, 'email', nullif(btrim(m.alert_email), ''),
        'owner_name', l.owner_name, 'address', l.property_address, 'municipality', l.municipality,
        'landed', to_jsonb(r.kinds), 'prices', has_prices, 'brief', has_brief, 'has_caller', cc is not null,
        'asked', public.card_asked_for_grok(r.lead_id));
    end loop;
  end loop;
  return out;
end $function$;
