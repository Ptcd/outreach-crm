-- A missed call emails the caller it is for (Colin 2026-10-29: "have it email them when a missed call comes to
-- them"). The reply agent (every minute) reads missed_calls_to_alert: seller calls nobody picked up in the last
-- six hours whose call-back task belongs to a caller (Thalia or Adil; Colin already gets the forwarding app's text
-- on his cell), not yet alerted; it emails that person at their alert email, or their sign-in email when none is
-- set, and marks the call alerted. The card and Power hour are unchanged: the email points at both.
alter table public.inbound_calls add column if not exists alerted_at timestamptz;

create or replace function public.missed_calls_to_alert(p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'call_sid', ic.call_sid, 'lead_id', ic.lead_id, 'from10', ic.from10, 'at', ic.created_at, 'voicemail', ic.voicemail,
      'vm_verdict', ic.vm_verdict, 'owner_name', l.owner_name, 'address', l.property_address, 'municipality', l.municipality,
      'person', t.owner::text, 'email', coalesce(nullif(btrim(m.alert_email), ''), m.email), 'display_name', m.display_name)
      order by ic.created_at), '[]'::jsonb)
    from public.inbound_calls ic
    join public.tasks t on t.id = ic.task_id
    join public.leads l on l.id = ic.lead_id
    join public.team_members m on m.person = t.owner
   where ic.status = 'missed' and ic.alerted_at is null
     and ic.created_at > p_now - interval '6 hours' and ic.created_at <= p_now
     and t.owner in ('thalia', 'adil')
$$;

create or replace function public.missed_call_alerted(p_call_sid text, p_note text default null) returns void
language sql security definer set search_path = public as $$
  update public.inbound_calls set alerted_at = now(), updated_at = now() where call_sid = p_call_sid and alerted_at is null
$$;

revoke all on function public.missed_calls_to_alert(timestamptz), public.missed_call_alerted(text, text) from public, anon, authenticated;
grant execute on function public.missed_calls_to_alert(timestamptz), public.missed_call_alerted(text, text) to service_role;
