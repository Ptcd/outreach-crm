-- Send contract: our own e-signing (Colin 2026-10-21: "build it ourself"). Colin fills the official
-- WB-11 Residential Offer to Purchase from the lead card, signs it as Buyer, and gets a private link
-- per seller. The seller opens the link (no login), agrees to sign electronically, fills in the Real
-- Estate Condition Report (Wis. Stat. 709.03) when it applies, and signs. When every seller has
-- signed, the server seals one PDF (Offer + Condition Report + signature certificate), records its
-- SHA-256, moves the deal to "Signed: to title", and opens "Contract + deposit to title today".
--
-- Only hashes of the link tokens are stored. The audit log (contract_events) is append-only.
-- Every write goes through the contract functions (service_role); the team can read.

alter type public.deal_status add value if not exists 'signed_to_title';

create table public.contracts (
  id             uuid primary key default gen_random_uuid(),
  lead_id        uuid not null references public.leads (id) on delete restrict,
  form           text not null,                         -- e.g. 'WB-11 10-1-2026'
  status         text not null default 'sent' check (status in ('sent', 'signed', 'void')),
  terms          jsonb not null,                        -- what Colin typed (Wb11Terms)
  include_recr   boolean not null default true,         -- false when the seller is exempt (709.01)
  recr           jsonb,                                 -- the seller's answers, once given
  recr_signer_id uuid,
  buyer_name     text not null,
  buyer_signature_path text,
  buyer_signed_at timestamptz not null,
  offer_path     text not null,                         -- storage: the Offer as sent (Buyer signed)
  offer_sha256   text not null,
  final_path     text,                                  -- storage: the sealed PDF
  final_sha256   text,
  created_by     uuid,
  created_at     timestamptz not null default now(),
  signed_at      timestamptz,
  voided_at      timestamptz,
  void_reason    text
);
create index contracts_lead_idx on public.contracts (lead_id, created_at desc);

create table public.contract_signers (
  id             uuid primary key default gen_random_uuid(),
  contract_id    uuid not null references public.contracts (id) on delete cascade,
  position       smallint not null check (position in (1, 2)),
  name           text not null,
  email          text,
  phone          text,
  token_hash     text not null unique,
  expires_at     timestamptz not null,
  opened_at      timestamptz,
  consented_at   timestamptz,
  signed_at      timestamptz,
  signed_name    text,
  signature_path text,
  signed_ip      text,
  signed_ua      text,
  unique (contract_id, position)
);

create table public.contract_events (
  id          bigint generated always as identity primary key,
  contract_id uuid not null references public.contracts (id) on delete cascade,
  signer_id   uuid references public.contract_signers (id) on delete set null,
  at          timestamptz not null default now(),
  actor       text not null,
  kind        text not null,       -- created, buyer_signed, link_new, opened, consented, recr, signed, sealed, voided, emailed
  ip          text,
  user_agent  text,
  detail      jsonb
);
create index contract_events_idx on public.contract_events (contract_id, at);

create or replace function public.contract_events_append_only() returns trigger
language plpgsql as $$
begin
  raise exception 'contract_events is append-only';
end $$;
create trigger contract_events_no_change before update or delete on public.contract_events
  for each row execute function public.contract_events_append_only();

alter table public.contracts enable row level security;
alter table public.contract_signers enable row level security;
alter table public.contract_events enable row level security;
create policy contracts_read on public.contracts for select to authenticated using (public.is_team());
create policy contract_signers_read on public.contract_signers for select to authenticated using (public.is_team());
create policy contract_events_read on public.contract_events for select to authenticated using (public.is_team());
grant select on public.contracts, public.contract_events to authenticated;
-- every column but token_hash
grant select (id, contract_id, position, name, email, phone, expires_at, opened_at, consented_at, signed_at, signed_name,
  signature_path, signed_ip, signed_ua) on public.contract_signers to authenticated;
grant select, insert, update on public.contracts, public.contract_signers to service_role;
grant select, insert on public.contract_events to service_role;
grant usage on sequence public.contract_events_id_seq to service_role;

-- Colin signed and sent. p_signers: [{position, name, email, phone, token_hash}]
create or replace function public.contract_create(p_lead_id uuid, p_form text, p_terms jsonb, p_include_recr boolean,
  p_buyer_name text, p_buyer_signature_path text, p_offer_path text, p_offer_sha256 text, p_signers jsonb,
  p_actor text, p_actor_id uuid, p_ip text, p_ua text, p_expires timestamptz, p_now timestamptz default now(),
  p_id uuid default gen_random_uuid())
returns jsonb language plpgsql security definer set search_path = public as $$
declare s jsonb; sid uuid; ids jsonb := '[]'::jsonb;
begin
  if not exists (select 1 from public.leads where id = p_lead_id) then
    return jsonb_build_object('ok', false, 'reason', 'no such lead');
  end if;
  if jsonb_array_length(coalesce(p_signers, '[]'::jsonb)) not between 1 and 2 then
    return jsonb_build_object('ok', false, 'reason', 'one or two sellers');
  end if;
  insert into public.contracts (id, lead_id, form, terms, include_recr, buyer_name, buyer_signature_path, buyer_signed_at,
    offer_path, offer_sha256, created_by, created_at)
  values (p_id, p_lead_id, p_form, p_terms, p_include_recr, p_buyer_name, p_buyer_signature_path, p_now,
    p_offer_path, p_offer_sha256, p_actor_id, p_now);
  insert into public.contract_events (contract_id, at, actor, kind, ip, user_agent, detail)
  values (p_id, p_now, p_actor, 'buyer_signed', p_ip, p_ua,
          jsonb_build_object('offer_sha256', p_offer_sha256, 'price', p_terms->'price', 'include_recr', p_include_recr));
  for s in select * from jsonb_array_elements(p_signers) loop
    insert into public.contract_signers (contract_id, position, name, email, phone, token_hash, expires_at)
    values (p_id, (s->>'position')::smallint, s->>'name', nullif(s->>'email', ''), nullif(s->>'phone', ''), s->>'token_hash', p_expires)
    returning id into sid;
    ids := ids || jsonb_build_object('id', sid, 'position', (s->>'position')::int);
    insert into public.contract_events (contract_id, signer_id, at, actor, kind, detail)
    values (p_id, sid, p_now, p_actor, 'created', jsonb_build_object('for', s->>'name', 'expires_at', p_expires));
  end loop;
  if not exists (select 1 from public.deals where lead_id = p_lead_id) then
    insert into public.deals (lead_id, status) values (p_lead_id, 'offer');
  end if;
  insert into public.messages (lead_id, direction, channel, body, sent_at, status)
  values (p_lead_id, 'out', 'note', format('Offer (%s) sent for signature by %s.', p_form, p_actor), p_now, 'contract');
  return jsonb_build_object('ok', true, 'id', p_id, 'signers', ids);
end $$;

-- A fresh link for one seller (the old one stops working).
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
  return jsonb_build_object('ok', true);
end $$;

-- The seller opened their link. Returns what the signing page shows; never the token hash.
create or replace function public.contract_open(p_token_hash text, p_ip text, p_ua text, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare sg public.contract_signers; c public.contracts; others jsonb;
begin
  select * into sg from public.contract_signers where token_hash = p_token_hash for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'This link is not valid. Ask Colin for a new one.'); end if;
  select * into c from public.contracts where id = sg.contract_id;
  if c.status = 'void' then return jsonb_build_object('ok', false, 'reason', 'Colin withdrew this offer.'); end if;
  if sg.signed_at is null and sg.expires_at < p_now then
    return jsonb_build_object('ok', false, 'reason', 'This link has expired. Ask Colin for a new one.');
  end if;
  update public.contract_signers set opened_at = coalesce(opened_at, p_now) where id = sg.id;
  insert into public.contract_events (contract_id, signer_id, at, actor, kind, ip, user_agent)
  values (c.id, sg.id, p_now, sg.name, 'opened', p_ip, p_ua);
  select coalesce(jsonb_agg(jsonb_build_object('name', o.name, 'signed', o.signed_at is not null) order by o.position), '[]'::jsonb)
    into others from public.contract_signers o where o.contract_id = c.id and o.id <> sg.id;
  return jsonb_build_object('ok', true, 'contract_id', c.id, 'signer_id', sg.id, 'status', c.status, 'form', c.form,
    'terms', c.terms, 'include_recr', c.include_recr, 'recr', c.recr, 'buyer_name', c.buyer_name,
    'signer', jsonb_build_object('name', sg.name, 'position', sg.position, 'signed_at', sg.signed_at),
    'others', others, 'offer_path', c.offer_path, 'final_path', c.final_path);
end $$;

-- The seller agreed, (filled the condition report,) and signed. Says whether everyone has now signed.
create or replace function public.contract_sign(p_token_hash text, p_signed_name text, p_signature_path text, p_recr jsonb,
  p_ip text, p_ua text, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare sg public.contract_signers; c public.contracts; left_ int;
begin
  select * into sg from public.contract_signers where token_hash = p_token_hash for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'This link is not valid.'); end if;
  select * into c from public.contracts where id = sg.contract_id for update;
  if c.status <> 'sent' then return jsonb_build_object('ok', false, 'reason', 'This offer is ' || c.status || '.'); end if;
  if sg.signed_at is not null then return jsonb_build_object('ok', false, 'reason', 'You already signed.'); end if;
  if sg.expires_at < p_now then return jsonb_build_object('ok', false, 'reason', 'This link has expired.'); end if;
  if btrim(coalesce(p_signed_name, '')) = '' then return jsonb_build_object('ok', false, 'reason', 'Type your full name.'); end if;
  if c.include_recr and c.recr is null and p_recr is null then
    return jsonb_build_object('ok', false, 'reason', 'Fill in the condition report first.');
  end if;
  insert into public.contract_events (contract_id, signer_id, at, actor, kind, ip, user_agent, detail)
  values (c.id, sg.id, p_now, sg.name, 'consented', p_ip, p_ua, jsonb_build_object('esign_consent', true));
  if c.include_recr and c.recr is null then
    update public.contracts set recr = p_recr, recr_signer_id = sg.id where id = c.id;
    insert into public.contract_events (contract_id, signer_id, at, actor, kind, ip, user_agent)
    values (c.id, sg.id, p_now, sg.name, 'recr', p_ip, p_ua);
  end if;
  update public.contract_signers
     set consented_at = p_now, signed_at = p_now, signed_name = btrim(p_signed_name), signature_path = p_signature_path,
         signed_ip = p_ip, signed_ua = left(p_ua, 300)
   where id = sg.id;
  insert into public.contract_events (contract_id, signer_id, at, actor, kind, ip, user_agent, detail)
  values (c.id, sg.id, p_now, sg.name, 'signed', p_ip, p_ua, jsonb_build_object('typed_name', btrim(p_signed_name)));
  select count(*) into left_ from public.contract_signers where contract_id = c.id and signed_at is null;
  return jsonb_build_object('ok', true, 'contract_id', c.id, 'all_signed', left_ = 0);
end $$;

-- Sealed: the signed PDF is stored. Deal -> Signed: to title, lead -> Under contract, task for today.
create or replace function public.contract_sealed(p_id uuid, p_final_path text, p_final_sha256 text, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare c public.contracts; addr text; tid uuid;
begin
  select * into c from public.contracts where id = p_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such contract'); end if;
  if c.status = 'signed' then return jsonb_build_object('ok', true, 'already', true); end if;
  if c.status <> 'sent' or exists (select 1 from public.contract_signers where contract_id = p_id and signed_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'not everyone has signed');
  end if;
  update public.contracts set status = 'signed', signed_at = p_now, final_path = p_final_path, final_sha256 = p_final_sha256 where id = p_id;
  insert into public.contract_events (contract_id, at, actor, kind, detail)
  values (p_id, p_now, 'system', 'sealed', jsonb_build_object('final_sha256', p_final_sha256));
  if exists (select 1 from public.deals where lead_id = c.lead_id) then
    update public.deals set status = 'signed_to_title', contract_date = coalesce(contract_date, (p_now at time zone 'America/Chicago')::date)
     where id = (select id from public.deals where lead_id = c.lead_id order by created_at desc limit 1);
  else
    insert into public.deals (lead_id, status, contract_date) values (c.lead_id, 'signed_to_title', (p_now at time zone 'America/Chicago')::date);
  end if;
  update public.leads set stage = 'under_contract' where id = c.lead_id;
  select coalesce(property_address, owner_name) into addr from public.leads where id = c.lead_id;
  insert into public.tasks (lead_id, due_at, kind, owner, note, source, title)
  values (c.lead_id, p_now, 'other', 'colin', 'Signed contract and earnest money to the title company today.',
          'contract', 'Contract + deposit to title today: ' || coalesce(addr, ''))
  returning id into tid;
  insert into public.messages (lead_id, direction, channel, body, sent_at, status)
  values (c.lead_id, 'out', 'note', format('Offer signed by every seller. Sealed PDF SHA-256 %s.', p_final_sha256), p_now, 'contract');
  return jsonb_build_object('ok', true, 'lead_id', c.lead_id, 'task_id', tid, 'address', addr);
end $$;

create or replace function public.contract_void(p_id uuid, p_reason text, p_actor text, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare c public.contracts;
begin
  select * into c from public.contracts where id = p_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such contract'); end if;
  if c.status <> 'sent' then return jsonb_build_object('ok', false, 'reason', 'contract is ' || c.status); end if;
  update public.contracts set status = 'void', voided_at = p_now, void_reason = nullif(btrim(coalesce(p_reason, '')), '') where id = p_id;
  insert into public.contract_events (contract_id, at, actor, kind, detail)
  values (p_id, p_now, p_actor, 'voided', jsonb_build_object('reason', p_reason));
  insert into public.messages (lead_id, direction, channel, body, sent_at, status)
  values (c.lead_id, 'out', 'note', format('Offer withdrawn by %s%s.', p_actor, coalesce(': ' || nullif(btrim(p_reason), ''), '')), p_now, 'contract');
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.contract_log(p_id uuid, p_actor text, p_kind text, p_detail jsonb, p_now timestamptz default now())
returns void language sql security definer set search_path = public as $$
  insert into public.contract_events (contract_id, at, actor, kind, detail) values (p_id, p_now, p_actor, p_kind, p_detail)
$$;

-- Everything the sealer needs (service_role only).
create or replace function public.contract_bundle(p_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'contract', to_jsonb(c),
    'lead', jsonb_build_object('owner_name', l.owner_name, 'property_address', l.property_address),
    'signers', (select coalesce(jsonb_agg(to_jsonb(s) - 'token_hash' order by s.position), '[]'::jsonb)
                  from public.contract_signers s where s.contract_id = c.id),
    'events', (select coalesce(jsonb_agg(to_jsonb(e) order by e.at, e.id), '[]'::jsonb)
                 from public.contract_events e where e.contract_id = c.id))
  from public.contracts c join public.leads l on l.id = c.lead_id where c.id = p_id
$$;

revoke all on function public.contract_create(uuid, text, jsonb, boolean, text, text, text, text, jsonb, text, uuid, text, text, timestamptz, timestamptz, uuid),
  public.contract_new_link(uuid, text, timestamptz, text, timestamptz),
  public.contract_open(text, text, text, timestamptz),
  public.contract_sign(text, text, text, jsonb, text, text, timestamptz),
  public.contract_sealed(uuid, text, text, timestamptz),
  public.contract_void(uuid, text, text, timestamptz),
  public.contract_log(uuid, text, text, jsonb, timestamptz),
  public.contract_bundle(uuid) from public, anon, authenticated;
grant execute on function public.contract_create(uuid, text, jsonb, boolean, text, text, text, text, jsonb, text, uuid, text, text, timestamptz, timestamptz, uuid),
  public.contract_new_link(uuid, text, timestamptz, text, timestamptz),
  public.contract_open(text, text, text, timestamptz),
  public.contract_sign(text, text, text, jsonb, text, text, timestamptz),
  public.contract_sealed(uuid, text, text, timestamptz),
  public.contract_void(uuid, text, text, timestamptz),
  public.contract_log(uuid, text, text, jsonb, timestamptz),
  public.contract_bundle(uuid) to service_role;

-- Private storage for the PDFs and signature images (only the Edge Functions touch it).
do $$
begin
  if exists (select 1 from pg_namespace where nspname = 'storage') then
    insert into storage.buckets (id, name, public) values ('contracts', 'contracts', false) on conflict (id) do nothing;
  end if;
end $$;
