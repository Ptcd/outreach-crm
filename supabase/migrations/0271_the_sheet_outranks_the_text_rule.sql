-- 0271: the deal sheet outranks the no-tap text figure. On 2026-11-21 the rule OK'd $37,300 for a text on 2415 Hayes
-- St, a card where Colin's own number was $20,000 to $25,000; Muse held it and nothing was sent. Since 0245 the rule's
-- figure goes without Colin's tap. It still does, except on a card the deal sheet (0270) says is his: his own number
-- is on it and the rule's figure is above it, he passed, or the gate found a property the formula does not fit (a
-- manufactured home, comps far apart, a value far from the county's, no street picture). There the figure waits for
-- his tap, exactly as every figure did before 0245. Nothing else about the offer by text changes.

CREATE OR REPLACE FUNCTION public.text_offer_auto_ok(p_id uuid, p_now timestamp with time zone DEFAULT now())
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r public.text_offer_rules; o public.text_offers; v jsonb; n numeric; at_ timestamptz; why text; sheet jsonb;
begin
  select * into r from public.text_offer_rules where id = 1;
  if not coalesce(r.auto_ok, false) then return false; end if;
  select * into o from public.text_offers where id = p_id for update;
  if not found or o.status <> 'open' then return false; end if;
  if o.asked_at is null or (o.ok_at is not null and o.ok_at >= o.asked_at) then return false; end if;   -- nothing is waiting
  if o.colin_said is not null then return false; end if;                                                -- he passed, or asked: his
  if exists (select 1 from jsonb_array_elements(o.rounds) x where x->>'what' in ('colin_asked', 'pass')) then
    return false;                                                        -- a card he asked about or passed on stays his, answer and all
  end if;
  n := o.ask_number;
  if n is null or n <= 0 or o.mao is null or n > o.mao then return false; end if;                       -- never above the most
  if public.text_offer_comp_count(o.comps) < r.min_comps then return false; end if;
  -- 0271: the deal sheet outranks the rule. Colin's own number on the card (when the rule's figure is above it), his
  -- pass, or a card the sheet's gate sends to him: the figure waits for his tap, as it did before 0245.
  if exists (select 1 from public.deal_sheets s where s.lead_id = o.lead_id
              and (s.colin_pass or (s.colin_open is not null and n > coalesce(s.colin_top, s.colin_open)))) then return false; end if;
  sheet := public.deal_sheet_work(o.lead_id, p_now);
  if sheet->>'stage' in ('colin_prices', 'no_fit', 'passed') or jsonb_array_length(coalesce(sheet->'gate', '[]'::jsonb)) > 0 then return false; end if;
  v := public.text_offer_view(o, p_now);
  if v->>'step' <> 'colin' then return false; end if;                    -- a caller has it, the records stop it, the card is closed
  at_ := greatest(p_now, o.asked_at);
  why := 'by the rule, no tap: ' || case o.ask_kind when 'counter' then 'their counter, inside the most (' || public.text_money(o.mao) || ')'
                                                    when 'their_number' then 'the seller''s own number, under the rule''s offer'
                                                    else 'the rule''s offer' end;
  perform set_config('wpie.offer_by_rule', '1', true);
  update public.text_offers set ok_number = n, ok_at = at_, ok_numbers = array(select distinct unnest(ok_numbers || n)),
         colin_said = 'ok', colin_note = why, colin_at = at_, response = null, response_words = null, response_at = null, counter_number = null,
         late_posted = null, auto_told_at = null,
         rounds = rounds || jsonb_build_object('at', at_, 'what', 'ok', 'by', 'rule', 'asked', o.ask_number, 'number', n, 'kind', o.ask_kind), updated_at = at_
   where id = p_id;
  perform set_config('wpie.offer_by_rule', '', true);
  update public.leads set notes = concat_ws(' | ', notes, to_char(at_ at time zone 'America/Chicago', 'YYYY-MM-DD') || ' the rule OK''d ' || public.text_money(n)
         || ' as the number to text, no tap (Colin 2026-11-16: let Muse make offers)') where id = o.lead_id;
  return true;
end $function$;
