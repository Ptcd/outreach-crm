-- 0256: an agent can read the files on a card (contracts first).
--
-- Muse, desk 311, 2026-11-19, from Colin: "Muse must be able to read ALL files stored in WPIE, not just card fields."
-- find_prospects gave only a contract's envelope (form, status, signers, dates). The filled terms (price, closing
-- date, earnest money, who pays which closing cost, contingencies, the title company if one is named) were in the
-- document and no tool could read it: Muse was about to phone five title companies with questions the signed
-- contract already answers.
--
-- The files WPIE stores are of two kinds: contracts (the offer sent, the sealed signed PDF) and records attachments
-- (already readable through records_file_get). This function is the contracts half: every contract on a card with
-- its whole terms, the seller's condition report answers, who signed and when, and where the PDFs are. The agent door
-- (tool card_files) turns the paths into short-lived links and never hands out the paths themselves. Read only.

create or replace function public.agent_card_files(p_lead_id uuid default null, p_contract_id uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public as $fn$
declare lid uuid; l public.leads; d public.deals; files jsonb;
begin
  lid := coalesce(p_lead_id, (select c.lead_id from public.contracts c where c.id = p_contract_id));
  if lid is null then
    return jsonb_build_object('ok', false, 'reason', case when p_contract_id is not null then 'no such contract' else 'name a card (lead_id) or a contract (contract_id)' end);
  end if;
  select * into l from public.leads where id = lid;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card'); end if;
  select * into d from public.deals where lead_id = lid order by created_at desc limit 1;
  select coalesce(jsonb_agg(x.f order by x.created_at), '[]'::jsonb) into files from (
    select c.created_at, jsonb_build_object(
      'kind', 'contract', 'contract_id', c.id, 'form', c.form,
      'status', case when c.voided_at is not null then 'void' else c.status end,
      'created_at', c.created_at, 'buyer_signed_at', c.buyer_signed_at, 'signed_at', c.signed_at,
      'voided_at', c.voided_at, 'void_reason', c.void_reason,
      'buyer', c.buyer_name, 'terms', c.terms,
      'condition_report_included', coalesce(c.include_recr, false),
      'condition_report', case when c.include_recr then c.recr end,
      'sellers', (select coalesce(jsonb_agg(jsonb_build_object('name', s.name, 'email', s.email, 'phone', s.phone, 'link_opened_at', s.opened_at,
                                                               'signed_at', s.signed_at, 'signed_name', s.signed_name) order by s.position), '[]'::jsonb)
                    from public.contract_signers s where s.contract_id = c.id),
      'offer_path', c.offer_path, 'offer_sha256', c.offer_sha256, 'final_path', c.final_path, 'final_sha256', c.final_sha256) as f
      from public.contracts c
     where c.lead_id = lid and (p_contract_id is null or c.id = p_contract_id)) x;
  return jsonb_build_object('ok', true, 'lead_id', lid, 'owner_name', l.owner_name, 'address', l.property_address,
    'municipality', l.municipality, 'county', l.county, 'stage', l.stage::text,
    'deal', case when d.id is not null then jsonb_build_object('status', d.status::text, 'price', d.price, 'closing_on', d.closing_on,
                                                                'title_company', d.title_company, 'title_contact', d.title_contact,
                                                                'title_phone', d.title_phone, 'title_email', d.title_email) end,
    'files', files);
end $fn$;
revoke all on function public.agent_card_files(uuid, uuid) from public, anon, authenticated;
grant execute on function public.agent_card_files(uuid, uuid) to service_role;
