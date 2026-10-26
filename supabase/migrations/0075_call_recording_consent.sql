-- Which seller calls may be recorded (Colin 2026-10-26: no recording statement, "this is Wisconsin"). Wisconsin is
-- one-party consent and our caller is a party, so a call records silently. A seller who may be in an all-party-consent
-- state is never recorded: their phone's area code is one of those states', or their card's mailing state is, or any
-- card with that phone has such a mailing state. pm-phone asks before it puts recording on a call
-- (call_recording_allowed, service role); call_recording_ready asks again when the recording arrives, and a recording
-- that should not exist is marked not_allowed and deleted at Twilio by the call-notes function.
-- An area code says where the phone was issued, not where the seller is: this is a cautious filter, not a guarantee.

create or replace function public.all_party_consent_states() returns text[] language sql immutable as $$
  select array['CA', 'IL', 'FL', 'WA', 'PA', 'MD', 'MA', 'MT', 'NH', 'CT', 'MI', 'OR', 'NV', 'DE']
$$;

-- Area codes of those states (NANPA, 2026).
create or replace function public.all_party_area_codes() returns text[] language sql immutable as $$
  select array[
    -- CA
    '209', '213', '279', '310', '323', '341', '350', '369', '408', '415', '424', '442', '510', '530', '559', '562', '619',
    '626', '628', '650', '657', '661', '669', '707', '714', '738', '747', '760', '805', '818', '820', '831', '840', '858',
    '909', '916', '925', '949', '951',
    -- IL
    '217', '224', '309', '312', '331', '447', '464', '618', '630', '708', '730', '773', '779', '815', '847', '861', '872',
    -- FL
    '239', '305', '321', '324', '352', '386', '407', '448', '561', '645', '656', '689', '727', '728', '754', '772', '786',
    '813', '850', '863', '904', '941', '954',
    -- WA
    '206', '253', '360', '425', '509', '564',
    -- PA
    '215', '223', '267', '272', '412', '445', '484', '570', '582', '610', '717', '724', '814', '835', '878',
    -- MD
    '227', '240', '301', '410', '443', '667',
    -- MA
    '339', '351', '413', '508', '617', '774', '781', '857', '978',
    -- MT, NH, DE
    '406', '603', '302',
    -- CT
    '203', '475', '860', '959',
    -- MI
    '231', '248', '269', '313', '517', '586', '616', '679', '734', '810', '906', '947', '989',
    -- OR
    '458', '503', '541', '971',
    -- NV
    '702', '725', '775']
$$;

create or replace function public.call_recording_allowed(p_phone text, p_lead_id uuid default null)
returns jsonb language sql stable security definer set search_path = public as $$
  with d as (select right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10) as d),
  st as (
    select upper(btrim(l.mailing_state)) s from public.leads l where l.id = p_lead_id
    union
    select upper(btrim(l.mailing_state)) from public.contacts c join public.leads l on l.id = c.lead_id, d
     where c.kind = 'phone' and c.value_normalized = d.d
  )
  select case
    when d.d !~ '^[0-9]{10}$' then jsonb_build_object('record', false, 'reason', 'no seller number')
    when left(d.d, 3) = any(public.all_party_area_codes()) then
      jsonb_build_object('record', false, 'reason', 'area code ' || left(d.d, 3) || ' is in an all-party-consent state')
    when exists (select 1 from st where st.s = any(public.all_party_consent_states())) then
      jsonb_build_object('record', false, 'reason', 'mailing state ' || (select min(st.s) from st where st.s = any(public.all_party_consent_states()))
                                                      || ' is all-party consent')
    else jsonb_build_object('record', true) end
  from d
$$;
revoke all on function public.call_recording_allowed(text, uuid) from public, anon, authenticated;
grant execute on function public.call_recording_allowed(text, uuid) to service_role;
revoke all on function public.all_party_consent_states(), public.all_party_area_codes() from public, anon;

alter table public.call_recordings drop constraint if exists call_recordings_status_check;
alter table public.call_recordings add constraint call_recordings_status_check
  check (status in ('recorded', 'too_short', 'no_card', 'not_allowed', 'transcribing', 'summarizing', 'summarized', 'failed'));

-- 0073's call_recording_ready, plus the consent check: a recording that should not exist comes back delete = true.
create or replace function public.call_recording_ready(p_call_sid text, p_recording_sid text, p_direction text,
  p_duration integer, p_started_at timestamptz, p_caller text, p_from text, p_to text, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.call_recordings; lid uuid; d text; who text; min_s constant integer := 15; ok jsonb;
begin
  if coalesce(p_call_sid, '') !~ '^CA[0-9A-Fa-f]{32}$' then return jsonb_build_object('ok', false, 'reason', 'bad call id'); end if;
  if coalesce(p_recording_sid, '') !~ '^RE[0-9A-Fa-f]{32}$' then return jsonb_build_object('ok', false, 'reason', 'bad recording id'); end if;
  if p_direction not in ('out', 'in') then return jsonb_build_object('ok', false, 'reason', 'bad direction'); end if;
  select * into r from public.call_recordings where call_sid = p_call_sid for update;
  if found then
    return jsonb_build_object('ok', true, 'duplicate', true, 'lead_id', r.lead_id, 'status', r.status,
                              'transcribe', r.status = 'recorded' and r.transcript_sid is null, 'delete', r.status = 'not_allowed');
  end if;

  if p_direction = 'out' then
    select c.lead_id, c.phone10 into lid, d from public.human_call_provider_claims c where c.provider_call_sid = p_call_sid;
    d := coalesce(d, right(regexp_replace(coalesce(p_to, ''), '\D', '', 'g'), 10));
    who := nullif(regexp_replace(coalesce(p_caller, ''), '^client:', ''), '');
  else
    d := right(regexp_replace(coalesce(p_from, ''), '\D', '', 'g'), 10);
    select ic.lead_id into lid from public.inbound_calls ic where ic.call_sid = p_call_sid;
    if lid is null and d ~ '^[0-9]{10}$' then
      select c.lead_id into lid from public.contacts c join public.leads x on x.id = c.lead_id
       where c.kind = 'phone' and c.value_normalized = d
       order by (x.belt in ('dead', 'dnc') or x.stage in ('dead', 'dnc', 'closed_no_contact')) asc, x.updated_at desc limit 1;
    end if;
    who := null;
  end if;
  who := coalesce((select t.display_name from public.team_members t where t.person::text = who), who);
  ok := public.call_recording_allowed(d, lid);

  insert into public.call_recordings (call_sid, recording_sid, lead_id, direction, phone10, caller, duration_s, started_at, status,
                                      error, created_at, updated_at)
  values (p_call_sid, p_recording_sid, lid, p_direction, case when d ~ '^[0-9]{10}$' then d end, who, p_duration,
          coalesce(p_started_at, p_now - make_interval(secs => greatest(coalesce(p_duration, 0), 0))),
          case when not coalesce((ok->>'record')::boolean, false) then 'not_allowed'
               when lid is null then 'no_card' when coalesce(p_duration, 0) < min_s then 'too_short' else 'recorded' end,
          case when not coalesce((ok->>'record')::boolean, false) then ok->>'reason' end, p_now, p_now)
  returning * into r;
  return jsonb_build_object('ok', true, 'lead_id', r.lead_id, 'status', r.status, 'transcribe', r.status = 'recorded',
                            'delete', r.status = 'not_allowed', 'reason', r.error);
end $$;
