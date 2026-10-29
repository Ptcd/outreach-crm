-- A WhatsApp number per person for alerts (Colin 2026-10-29: "wire up WhatsApp notifications for them"). Each caller
-- keeps their own in Settings (international numbers allowed: Adil is in Pakistan); a missed call for them goes to it
-- through the forwarding app's WhatsApp sender, alongside the email (0139).
alter table public.team_members add column if not exists alert_whatsapp text;
alter table public.shift_people add column if not exists alert_whatsapp text;

create or replace function public.person_alerts(p_person public.team_person)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r record;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  select alert_phone, alert_email, alert_whatsapp, display_name into r from public.team_members where person = p_person;
  if not found then
    select alert_phone, alert_email, alert_whatsapp, display_name into r from public.shift_people where person = p_person;
  end if;
  if r is null then return jsonb_build_object('ok', false, 'reason', 'not on the team'); end if;
  return jsonb_build_object('ok', true, 'person', p_person, 'name', r.display_name,
                            'alert_phone', r.alert_phone, 'alert_email', r.alert_email, 'alert_whatsapp', r.alert_whatsapp);
end $$;

drop function if exists public.set_person_alerts(public.team_person, text, text);
create or replace function public.set_person_alerts(p_person public.team_person, p_phone text, p_email text, p_whatsapp text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare d text; e text; w text;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  d := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  if length(d) = 11 and left(d, 1) = '1' then d := right(d, 10); end if;
  if d <> '' and length(d) <> 10 then return jsonb_build_object('ok', false, 'reason', 'A phone number is 10 digits.'); end if;
  e := lower(btrim(coalesce(p_email, '')));
  if e <> '' and e !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then return jsonb_build_object('ok', false, 'reason', 'That is not an email address.'); end if;
  w := regexp_replace(coalesce(p_whatsapp, ''), '\D', '', 'g');
  if w <> '' and length(w) = 10 then w := '1' || w; end if;   -- a bare US number
  if w <> '' and (length(w) < 8 or length(w) > 15) then return jsonb_build_object('ok', false, 'reason', 'A WhatsApp number needs the country code, like +92 324 6343665 or +1 414 555 0101.'); end if;
  if w <> '' then w := '+' || w; end if;
  update public.team_members set alert_phone = nullif(d, ''), alert_email = nullif(e, ''), alert_whatsapp = nullif(w, '') where person = p_person;
  if not found then
    update public.shift_people set alert_phone = nullif(d, ''), alert_email = nullif(e, ''), alert_whatsapp = nullif(w, ''), updated_at = now() where person = p_person;
    if not found then return jsonb_build_object('ok', false, 'reason', 'not on the team'); end if;
  end if;
  return jsonb_build_object('ok', true, 'person', p_person, 'phone', nullif(d, ''), 'email', nullif(e, ''), 'whatsapp', nullif(w, ''));
end $$;
revoke all on function public.person_alerts(public.team_person), public.set_person_alerts(public.team_person, text, text, text) from public, anon;
grant execute on function public.person_alerts(public.team_person), public.set_person_alerts(public.team_person, text, text, text) to authenticated;

-- a missed call carries the caller's WhatsApp number too
create or replace function public.missed_calls_to_alert(p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'call_sid', ic.call_sid, 'lead_id', ic.lead_id, 'from10', ic.from10, 'at', ic.created_at, 'voicemail', ic.voicemail,
      'vm_verdict', ic.vm_verdict, 'owner_name', l.owner_name, 'address', l.property_address, 'municipality', l.municipality,
      'person', t.owner::text, 'email', coalesce(nullif(btrim(m.alert_email), ''), m.email), 'whatsapp', nullif(btrim(m.alert_whatsapp), ''),
      'display_name', m.display_name)
      order by ic.created_at), '[]'::jsonb)
    from public.inbound_calls ic
    join public.tasks t on t.id = ic.task_id
    join public.leads l on l.id = ic.lead_id
    join public.team_members m on m.person = t.owner
   where ic.status = 'missed' and ic.alerted_at is null
     and ic.created_at > p_now - interval '6 hours' and ic.created_at <= p_now
     and t.owner in ('thalia', 'adil')
$$;
