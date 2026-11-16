-- 0243: a time Colin set with a seller alerts his phone, the way a caller's does.
--
-- Colin 2026-11-16, after booking his own callback to Stanley Schmid (502 3rd St, Albany) for Wednesday: "Have the app
-- send me a notification then?" The reminder (0170) was only ever for Thalia's and Adil's follow-ups. Colin's task list
-- is the belts' whole backlog (3,900 hold-lane stops), so his alert is narrow: a call or a visit on a card that is on
-- the call_booked or visit_booked belt, which is a day and time a seller agreed to. Ten minutes before, to the phones
-- registered under his login. Nothing else on his list alerts.

create or replace function public.followups_due_to_alert(p_now timestamp with time zone default now())
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
      'task_id', t.id, 'lead_id', t.lead_id, 'kind', t.kind, 'due_at', t.due_at, 'title', coalesce(t.title, t.kind),
      'note', left(coalesce(t.note, ''), 200), 'owner_name', l.owner_name, 'address', l.property_address, 'municipality', l.municipality,
      'person', t.owner::text, 'email', nullif(btrim(m.alert_email), ''), 'whatsapp', nullif(btrim(m.alert_whatsapp), ''), 'display_name', m.display_name)
      order by t.due_at), '[]'::jsonb)
    from public.tasks t
    join public.team_members m on m.person = t.owner
    left join public.leads l on l.id = t.lead_id
   where t.done_at is null and t.notified_at is null
     and (
       -- a caller's own call, callback or visit, ten minutes before (0170)
       (t.owner in ('thalia', 'adil')
        and t.kind in ('call', 'callback', 'visit')
        and coalesce(t.source, '') not in ('power_hour', 'power_hour_after', 'power_hour_reserve', 'call_list', 'reply')
        and t.due_at between p_now - interval '5 minutes' and p_now + interval '10 minutes')
       -- Colin's own booked time with a seller, ten minutes before (0243): the stop of a booked call or visit, nothing else
       or (t.owner = 'colin'
        and t.kind in ('call', 'callback', 'visit')
        and t.source = 'belt'
        and l.belt in ('call_booked', 'visit_booked')
        and t.due_at between p_now - interval '5 minutes' and p_now + interval '10 minutes')
       -- a heads-up from the other caller (0186), the minute it lands, for anyone on the team
       or (t.kind = 'nudge' and t.created_at <= p_now)
     )
$function$;
revoke all on function public.followups_due_to_alert(timestamptz) from public, anon, authenticated;
grant execute on function public.followups_due_to_alert(timestamptz) to service_role;
