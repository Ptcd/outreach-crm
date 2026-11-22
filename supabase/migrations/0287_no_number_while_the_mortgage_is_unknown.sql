-- 0287: an agent puts no number on a card while what may follow the house is unknown. Found on the first real run
-- (74 Pioneer Ct, 2026-11-22): Grok's brief said, rightly, that the lender's claim and any purchase loan had no amount
-- yet and that "this decides the number", and then put $110,300 on the deal sheet, which showed the caller a number to
-- say. Colin's rule is that the number clears what follows the house ("Mortgage high then no go deal"); with the
-- amount blank that cannot be checked. Without an agent's number the sheet already does the right thing: it tells the
-- caller to ask what is owed and works the number from the answer.

create or replace function public.agent_deal_price(p_lead_id uuid, p_open numeric, p_top numeric, p_note text, p_agent text) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare l public.leads; w jsonb; cap numeric; clear numeric; cc public.team_person := public.card_caller(p_lead_id); mode text;
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
end $fn$;
revoke all on function public.agent_deal_price(uuid, numeric, numeric, text, text) from public, anon, authenticated;
