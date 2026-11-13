-- Send offer (Colin 2026-11-12): "if we want to send a contract for esigning it's possible to do it from the card in a
-- couple clicks". The contract machinery is 0010 (the WB-11, the signing links, the sealed PDF). This adds what makes it
-- two clicks: the standing terms every offer carries, kept in one row Colin edits once; his signature kept with them, so
-- every offer goes out already signed and dated; who may send and at what price; and a record of each email the system
-- sends (the signing link, then the signed copy).
--
-- The standards (Colin's words): buyer WeLiveWI LLC; $500 earnest money to the title company; the buyer pays the closing
-- costs; the property is sold as is, where is, and the seller makes no warranties as to condition; the buyer's only out
-- is a walk-through and approval of the condition, which expires at closing; the WB-11 with the seller's Real Estate
-- Condition Report.
--
-- Who may send: Colin at any price. A caller only at Colin's number on the card (deal_packages.our_number, else
-- deals.colin_offer): the same rule as the callback ("the only number you say is Colin's"). Muse never: an agent does not
-- bind the company to a purchase.

create table if not exists public.offer_standards (
  id                  smallint primary key default 1 check (id = 1),
  buyer_name          text not null default 'WeLiveWI LLC',
  signer_name         text not null default 'Colin Merrill',
  signer_title        text not null default 'Authorized Representative',
  buyer_email         text,
  buyer_address       text,
  buyer_phone         text not null default '(262) 999-6513',
  earnest_money       numeric(12, 2) not null default 500 check (earnest_money >= 0),
  earnest_days        int not null default 5 check (earnest_days between 0 and 60),
  earnest_holder      text not null default 'the title company selected by Buyer',
  accept_days         int not null default 5 check (accept_days between 1 and 30),
  proof_of_funds_days int not null default 7 check (proof_of_funds_days between 0 and 60),
  included            text,
  excluded            text,
  additional          text not null default '',
  signature_png       text,                      -- Colin's drawn signature as a PNG data URL; null = his typed name
  updated_at          timestamptz not null default now(),
  updated_by          text
);
alter table public.offer_standards enable row level security;   -- no policies: read and written through the functions below
revoke all on public.offer_standards from public, anon, authenticated;
grant select on public.offer_standards to service_role;

insert into public.offer_standards (id, buyer_email, additional)
select 1,
  (select email from public.team_members where person = 'colin' and role = 'owner' limit 1),
  '1. CLOSING COSTS. Buyer shall pay all closing costs of this transaction: the title company''s closing fee, the owner''s policy of title insurance and gap endorsement described at lines 397-406, recording fees, and the Wisconsin Real Estate Transfer Fee, notwithstanding lines 392-393 and 397-402. Seller shall pay only what is needed to convey merchantable title (mortgages, liens, judgments, and the taxes, utilities and other items owed by or prorated to Seller through the day before closing). The earnest money shall be held by, and the closing held at, the title company named at lines 60-61.' || E'\n' ||
  '2. AS IS. Buyer is purchasing the Property as is, where is. Seller makes no warranties as to the condition of the Property and is not required to make any repairs. Seller''s Real Estate Condition Report is a disclosure and not a warranty; Seller completes and signs it together with this Offer.' || E'\n' ||
  '3. WALK-THROUGH CONTINGENCY. This Offer is contingent upon Buyer''s walk-through of the Property and Buyer''s approval, in Buyer''s sole discretion, of the condition of the Property. Seller shall give Buyer and Buyer''s contractors reasonable access for this purpose. If Buyer does not approve the condition of the Property, Buyer may deliver written notice to Seller at any time up to closing; this Offer is then null and void and the earnest money shall be returned to Buyer. This contingency expires at closing. This is Buyer''s only contingency.'
on conflict (id) do nothing;

-- Colin's number on a card: what he set on the package, else what he typed on the deal. Null = no number yet.
create or replace function public.offer_colin_number(p_lead_id uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select d.our_number from public.deal_packages d
      where d.lead_id = p_lead_id and d.our_number is not null and d.status not in ('declined', 'dead')
      order by d.created_at desc limit 1),
    (select d.colin_offer from public.deals d
      where d.lead_id = p_lead_id and d.colin_offer is not null order by d.created_at desc limit 1))
$$;

-- What the Send offer panel needs: the standards in plain fields, Colin's number, and what this person may do.
create or replace function public.offer_setup(p_lead_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s public.offer_standards; me public.team_person := public.wpie_person(); boss boolean;
begin
  if not public.is_team() then return jsonb_build_object('ok', false, 'reason', 'not on the team'); end if;
  select * into s from public.offer_standards where id = 1;
  boss := public.is_owner() and me is distinct from 'muse';
  return jsonb_build_object('ok', true,
    'standards', (to_jsonb(s) - 'signature_png' - 'id') || jsonb_build_object('has_signature', s.signature_png is not null),
    'signature_png', case when boss then s.signature_png end,
    'colin_number', public.offer_colin_number(p_lead_id),
    'can_send', me is distinct from 'muse',
    'can_set_price', boss,
    'can_edit_standards', boss);
end $$;

-- Colin changes the standards (and his signature). Only the keys named here; everything else is ignored.
create or replace function public.offer_standards_set(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
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
    proof_of_funds_days = case when p ? 'proof_of_funds_days' then least(60, greatest(0, (p->>'proof_of_funds_days')::int)) else proof_of_funds_days end,
    included            = case when p ? 'included' then nullif(btrim(p->>'included'), '') else included end,
    excluded            = case when p ? 'excluded' then nullif(btrim(p->>'excluded'), '') else excluded end,
    additional          = case when p ? 'additional' then left(coalesce(p->>'additional', ''), 8000) else additional end,
    signature_png       = case when p ? 'signature_png' then sig else signature_png end,
    updated_at = now(), updated_by = me::text
  where id = 1;
  return jsonb_build_object('ok', true);
end $$;

-- What the contract function needs to build an offer from the card (service_role only): the standards with the
-- signature, the card's own facts, Colin's number, and who is asking.
create or replace function public.offer_context(p_lead_id uuid, p_email text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'standards', (select to_jsonb(s) from public.offer_standards s where s.id = 1),
    'lead', (select jsonb_build_object('id', l.id, 'owner_name', l.owner_name, 'property_address', l.property_address,
               'municipality', l.municipality, 'county', l.county, 'mailing_street', l.mailing_street, 'mailing_city', l.mailing_city,
               'mailing_state', l.mailing_state, 'mailing_zip', l.mailing_zip, 'stage', l.stage)
               from public.leads l where l.id = p_lead_id),
    'colin_number', public.offer_colin_number(p_lead_id),
    'me', (select jsonb_build_object('person', t.person, 'role', t.role, 'display_name', t.display_name)
             from public.team_members t where t.email = lower(coalesce(p_email, ''))),
    'open_contract', (select c.id from public.contracts c where c.lead_id = p_lead_id and c.status = 'sent' limit 1))
$$;

-- The system emailed something about a contract: the signing link to a seller, or the signed copy to a party.
-- Recorded in the audit trail, on the signer (so the card can say "emailed 3:02 pm"), and on the card's timeline.
alter table public.contract_signers add column if not exists emailed_at timestamptz;
alter table public.contract_signers add column if not exists emailed_to text;
grant select (emailed_at, emailed_to) on public.contract_signers to authenticated;

create or replace function public.contract_mailed(p_id uuid, p_signer_id uuid, p_what text, p_to text, p_actor text,
  p_ok boolean default true, p_error text default null, p_now timestamptz default now())
returns void language plpgsql security definer set search_path = public as $$
declare lid uuid;
begin
  select lead_id into lid from public.contracts where id = p_id;
  if lid is null then return; end if;
  insert into public.contract_events (contract_id, signer_id, at, actor, kind, detail)
  values (p_id, p_signer_id, p_now, p_actor, case when p_ok then 'emailed' else 'email_failed' end,
          jsonb_strip_nulls(jsonb_build_object('what', p_what, 'to', p_to, 'error', left(p_error, 200))));
  if p_ok and p_signer_id is not null and p_what = 'link' then
    update public.contract_signers set emailed_at = p_now, emailed_to = p_to where id = p_signer_id;
  end if;
  insert into public.messages (lead_id, direction, channel, body, sent_at, status)
  values (lid, 'out', 'note',
    case when not p_ok then format('The offer email to %s did not go: %s', p_to, coalesce(left(p_error, 160), 'unknown'))
         when p_what = 'link' then format('Offer emailed to %s for signature (the signing link is not kept here).', p_to)
         else format('Signed offer emailed to %s.', p_to) end,
    p_now, 'contract');
end $$;

-- A fresh link also says which contract it belongs to, so the function can email it.
create or replace function public.contract_new_link(p_signer_id uuid, p_token_hash text, p_expires timestamptz, p_actor text,
  p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare sg public.contract_signers; c public.contracts;
begin
  select * into sg from public.contract_signers where id = p_signer_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such signer'); end if;
  select * into c from public.contracts where id = sg.contract_id;
  if c.status <> 'sent' then return jsonb_build_object('ok', false, 'reason', 'contract is ' || c.status); end if;
  if sg.signed_at is not null then return jsonb_build_object('ok', false, 'reason', 'already signed'); end if;
  update public.contract_signers set token_hash = p_token_hash, expires_at = p_expires where id = p_signer_id;
  insert into public.contract_events (contract_id, signer_id, at, actor, kind) values (c.id, p_signer_id, p_now, p_actor, 'link_new');
  return jsonb_build_object('ok', true, 'contract_id', c.id);
end $$;

revoke all on function public.offer_colin_number(uuid), public.offer_context(uuid, text),
  public.contract_mailed(uuid, uuid, text, text, text, boolean, text, timestamptz) from public, anon, authenticated;
grant execute on function public.offer_colin_number(uuid), public.offer_context(uuid, text),
  public.contract_mailed(uuid, uuid, text, text, text, boolean, text, timestamptz) to service_role;
revoke all on function public.offer_setup(uuid), public.offer_standards_set(jsonb) from public, anon;
grant execute on function public.offer_setup(uuid), public.offer_standards_set(jsonb) to authenticated;
