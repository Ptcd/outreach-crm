-- Bind pm-phone's outbound TwiML to the exact live human-call takeover.
--
-- phone_is_blocked (0036) remains the single DNC/STOP verdict. This gate adds the facts a phone-only
-- lookup cannot prove: the number is on this lead, this exact attempt is still paused, the card is not
-- terminal or reassigned, and one Twilio parent CallSid owns the attempt. A retry of that same CallSid is
-- harmless; a second provider call cannot reuse the browser's key.

create table if not exists public.human_call_provider_claims (
  attempt_key       text primary key,
  lead_id           uuid not null references public.leads (id) on delete cascade,
  phone10           text not null check (phone10 ~ '^[0-9]{10}$'),
  provider_call_sid text not null unique check (provider_call_sid ~ '^CA[0-9A-Fa-f]{32}$'),
  claimed_at        timestamptz not null default now()
);
comment on table public.human_call_provider_claims is
  'One provider call owns one active browser-call authorization; used only by the service-role TwiML gate.';

alter table public.human_call_provider_claims enable row level security;
revoke all on table public.human_call_provider_claims from public, anon, authenticated;

create or replace function public.claim_human_call_provider(
  p_lead_id uuid, p_phone10 text, p_key text, p_provider_call_sid text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  l public.leads;
  d text := right(regexp_replace(coalesce(p_phone10, ''), '\D', '', 'g'), 10);
  gate jsonb;
  prior public.human_call_provider_claims;
begin
  if p_lead_id is null then
    return jsonb_build_object('allowed', false, 'reason', 'missing lead');
  end if;
  if d !~ '^[0-9]{10}$' then
    return jsonb_build_object('allowed', false, 'reason', 'not a 10-digit number');
  end if;
  if coalesce(p_key, '') !~ '^[A-Za-z0-9_-]{8,100}$' then
    return jsonb_build_object('allowed', false, 'reason', 'bad call key');
  end if;
  if coalesce(p_provider_call_sid, '') !~ '^CA[0-9A-Fa-f]{32}$' then
    return jsonb_build_object('allowed', false, 'reason', 'bad provider call id');
  end if;

  -- Keep the conveyor lock order: lead first. The provider claim has no reply-draft lock.
  select * into l from public.leads where id = p_lead_id for update;
  if not found then return jsonb_build_object('allowed', false, 'reason', 'no such lead'); end if;
  if l.stage in ('dnc', 'dead', 'closed_no_contact', 'closed_won') or l.belt in ('dnc', 'dead') then
    return jsonb_build_object('allowed', false, 'reason', 'this card is closed or do-not-contact');
  end if;
  if l.human_takeover_at is null then
    return jsonb_build_object('allowed', false, 'reason', 'call authorization is not active');
  end if;
  if l.human_takeover_key is distinct from p_key then
    return jsonb_build_object('allowed', false, 'reason', 'that is not the active call');
  end if;
  if l.human_takeover_phone is distinct from d then
    return jsonb_build_object('allowed', false, 'reason', 'the active call has a different destination');
  end if;
  if l.assigned_to is distinct from l.human_takeover_assigned_to then
    return jsonb_build_object('allowed', false, 'reason', 'the card assignment changed after authorization');
  end if;
  if not exists (select 1 from public.contacts c where c.lead_id = p_lead_id and c.kind = 'phone'
      and c.value_normalized = d) then
    return jsonb_build_object('allowed', false, 'reason', 'that phone is not on this card');
  end if;
  gate := public.phone_is_blocked(d);
  if coalesce((gate->>'blocked')::boolean, true) then
    return jsonb_build_object('allowed', false, 'reason', coalesce(gate->>'reason', 'phone block check failed'));
  end if;

  select * into prior from public.human_call_provider_claims where attempt_key = p_key;
  if found then
    if prior.lead_id = p_lead_id and prior.phone10 = d and prior.provider_call_sid = p_provider_call_sid then
      return jsonb_build_object('allowed', true, 'duplicate', true);
    end if;
    return jsonb_build_object('allowed', false, 'reason', 'that call authorization was already claimed');
  end if;
  if exists (select 1 from public.human_call_provider_claims where provider_call_sid = p_provider_call_sid) then
    return jsonb_build_object('allowed', false, 'reason', 'that provider call already claimed another authorization');
  end if;

  begin
    insert into public.human_call_provider_claims (attempt_key, lead_id, phone10, provider_call_sid)
      values (p_key, p_lead_id, d, p_provider_call_sid);
  exception when unique_violation then
    -- A different lead can race for the same CallSid without sharing the lead lock. Fail closed with a
    -- verdict instead of surfacing a database error; the winning claim remains the only authorization.
    return jsonb_build_object('allowed', false, 'reason', 'that provider call was already claimed');
  end;
  return jsonb_build_object('allowed', true, 'duplicate', false);
end $$;

revoke all on function public.claim_human_call_provider(uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.claim_human_call_provider(uuid, text, text, text) to service_role;
