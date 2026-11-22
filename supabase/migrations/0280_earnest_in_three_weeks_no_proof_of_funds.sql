-- 0280: the sent offer's earnest money is due 21 days after acceptance, and there is no proof of funds in it at all.
-- Colin 2026-11-22: "make earnest money due 3 weeks after signing in the contract and remove the proof of funds
-- completely from the contract ... This is for the automated offer sending."
--
--   * offer_standards.earnest_days 5 -> 21 (the WB-11 counts it from acceptance, which is the seller's signature).
--   * offer_standards.proof_of_funds_days may be empty, and is: an empty WB-11 blank would read "7" by the form's own
--     words, so the contract builder strikes lines 296-303 when it is empty, and added provision 4 says they do not
--     apply. The closing track (0253) already leaves out the proof-of-funds step when the contract has no days.
--   * The Standards screen saves an empty box as empty, not 0 days.

alter table public.offer_standards alter column proof_of_funds_days drop not null;
alter table public.offer_standards alter column proof_of_funds_days drop default;

update public.offer_standards
   set earnest_days = 21,
       proof_of_funds_days = null,
       additional = case when additional ilike '%VERIFICATION OF FUNDS%' then additional
                         else rtrim(additional) || E'\n' || '4. VERIFICATION OF FUNDS. Lines 296-303 of this Offer (verification of Buyer''s funds) do not apply. Buyer will not deliver written verification of funds or other documentation, and Seller has no right to terminate this Offer for the lack of it.' end,
       updated_at = now(), updated_by = 'desk (Colin 2026-11-22: earnest in 3 weeks, no proof of funds)'
 where id = 1;

CREATE OR REPLACE FUNCTION public.offer_standards_set(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me public.team_person := public.wpie_person(); sig text;
begin
  if not public.is_owner() or me is not distinct from 'muse' then
    return jsonb_build_object('ok', false, 'reason', 'Only Colin changes the offer standards.');
  end if;
  if p ? 'signature_png' then
    sig := nullif(p->>'signature_png', '');
    if sig is not null and (sig not like 'data:image/png;base64,%' or length(sig) > 400000) then
      return jsonb_build_object('ok', false, 'reason', 'That signature could not be saved. Draw it again.');
    end if;
  end if;
  if p ? 'earnest_money' and not ((p->>'earnest_money') ~ '^\d+(\.\d{1,2})?$') then
    return jsonb_build_object('ok', false, 'reason', 'Earnest money must be a dollar amount.');
  end if;
  update public.offer_standards set
    buyer_name          = coalesce(nullif(btrim(p->>'buyer_name'), ''), buyer_name),
    signer_name         = coalesce(nullif(btrim(p->>'signer_name'), ''), signer_name),
    signer_title        = case when p ? 'signer_title' then coalesce(btrim(p->>'signer_title'), '') else signer_title end,
    buyer_email         = case when p ? 'buyer_email' then nullif(btrim(p->>'buyer_email'), '') else buyer_email end,
    buyer_address       = case when p ? 'buyer_address' then nullif(btrim(p->>'buyer_address'), '') else buyer_address end,
    buyer_phone         = coalesce(nullif(btrim(p->>'buyer_phone'), ''), buyer_phone),
    earnest_money       = case when p ? 'earnest_money' then (p->>'earnest_money')::numeric else earnest_money end,
    earnest_days        = case when p ? 'earnest_days' then least(60, greatest(0, (p->>'earnest_days')::int)) else earnest_days end,
    earnest_holder      = coalesce(nullif(btrim(p->>'earnest_holder'), ''), earnest_holder),
    accept_days         = case when p ? 'accept_days' then least(30, greatest(1, (p->>'accept_days')::int)) else accept_days end,
    -- 0280: blank means no proof of funds at all (lines 296-303 struck), not 0 days
    proof_of_funds_days = case when p ? 'proof_of_funds_days' then case when nullif(btrim(coalesce(p->>'proof_of_funds_days', '')), '') is null then null
                            else least(60, greatest(0, (p->>'proof_of_funds_days')::int)) end else proof_of_funds_days end,
    included            = case when p ? 'included' then nullif(btrim(p->>'included'), '') else included end,
    excluded            = case when p ? 'excluded' then nullif(btrim(p->>'excluded'), '') else excluded end,
    additional          = case when p ? 'additional' then left(coalesce(p->>'additional', ''), 8000) else additional end,
    signature_png       = case when p ? 'signature_png' then sig else signature_png end,
    updated_at = now(), updated_by = me::text
  where id = 1;
  return jsonb_build_object('ok', true);
end $function$;
