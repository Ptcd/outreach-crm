-- Missed calls and voicemails where the caller sees them (Colin 2026-10-27, after Thalia asked "where can I see the
-- missed call?": a seller called four times, left two voicemails, and the callback task closed itself when his card
-- went do-not-contact). Every inbound call that nobody picked up, or that left a voicemail, in the last days, with the
-- voicemail's words, whether anyone called back since, and whether the card is closed (then it is shown, never dialed).
create or replace function public.missed_calls_recent(p_hours integer default 48) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'call_sid', ic.call_sid, 'at', ic.created_at, 'phone', ic.from10, 'status', ic.status, 'voicemail', ic.voicemail,
      'words', nullif(substring(m.body from 'Voicemail: "(.*)"'), ''),
      'lead_id', l.id, 'owner_name', l.owner_name, 'property_address', l.property_address, 'municipality', l.municipality, 'stage', l.stage,
      'closed', l.stage::text in ('dnc', 'dead', 'closed_no_contact') or exists (select 1 from public.suppressed_phones s where s.phone10 = ic.from10),
      'called_back', exists (select 1 from public.messages o where o.lead_id = ic.lead_id and o.channel = 'call' and o.sent_at > ic.created_at
                               and coalesce(o.status, '') not like 'inbound%'))
    order by ic.created_at desc), '[]'::jsonb)
    from public.inbound_calls ic
    left join public.leads l on l.id = ic.lead_id
    left join public.messages m on m.id = ic.message_id
   where (public.is_team() or auth.uid() is null)
     and ic.created_at > now() - make_interval(hours => greatest(1, least(p_hours, 336)))
     and (ic.status in ('missed', 'blocked', 'no_answer', 'busy', 'failed') or ic.voicemail)
$$;
revoke all on function public.missed_calls_recent(integer) from public, anon;
grant execute on function public.missed_calls_recent(integer) to authenticated, service_role;
