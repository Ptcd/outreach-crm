-- Offers are sent by callers as well as Colin (Colin 2026-11-12: "other people are going to be sending these so show
-- their name not mine when sent by them"). The email and the signing page now name whoever sent the offer
-- (terms.sentBy). These three messages a seller can meet on a dead link named Colin outright; a dead link cannot say
-- who sent it, so they name nobody. Nothing else about opening a link changes.
create or replace function public.contract_open(p_token_hash text, p_ip text, p_ua text, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare sg public.contract_signers; c public.contracts; others jsonb;
begin
  select * into sg from public.contract_signers where token_hash = p_token_hash for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'This link is not valid. Ask us for a new one.'); end if;
  select * into c from public.contracts where id = sg.contract_id;
  if c.status = 'void' then return jsonb_build_object('ok', false, 'reason', 'This offer was withdrawn.'); end if;
  if sg.signed_at is null and sg.expires_at < p_now then
    return jsonb_build_object('ok', false, 'reason', 'This link has expired. Ask us for a new one.');
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

revoke all on function public.contract_open(text, text, text, timestamptz) from public, anon, authenticated;
grant execute on function public.contract_open(text, text, text, timestamptz) to service_role;
