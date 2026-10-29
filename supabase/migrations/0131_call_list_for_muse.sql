-- The callers' list, readable through the door (Muse 2026-10-29: "the queue had exactly one card ... no ranked slate
-- was generated"). The slate was there: the laptop's daily call list (wpie/campaign/calls.py, 40 owners ranked, posted
-- the evening before as call tasks due 7 AM) sat on Thalia's Call queue, but due_today reads card stages, never tasks,
-- so Muse saw only the one call_due. agent_call_list returns every open caller call task due that day or earlier, in the
-- order the callers work them, with what happened on each today. Read only.

create or replace function public.agent_call_list(p_date date default null) returns jsonb
language sql stable security definer set search_path = public as $$
  with d as (select coalesce(p_date, (now() at time zone 'America/Chicago')::date) as day),
  t as (
    select t.*, l.owner_name, l.property_address, l.municipality, l.stage, l.reasons_to_sell,
           nullif(substring(t.note from 'call list \(#(\d+)\)'), '')::int as list_rank
      from public.tasks t join public.leads l on l.id = t.lead_id, d
     where t.kind in ('call', 'callback') and t.owner in ('thalia', 'adil')
       and (t.due_at at time zone 'America/Chicago')::date <= d.day
       and (t.done_at is null or (t.done_at at time zone 'America/Chicago')::date = d.day))
  select coalesce(jsonb_agg(jsonb_build_object(
      'task_id', t.id, 'lead_id', t.lead_id, 'caller', t.owner, 'source', coalesce(t.source, t.kind), 'rank', t.list_rank,
      'title', t.title, 'why', t.note, 'their_words', t.quote, 'due_at', t.due_at, 'done_at', t.done_at,
      'days_late', greatest(0, (select day from d) - (t.due_at at time zone 'America/Chicago')::date),
      'owner_name', t.owner_name, 'address', t.property_address, 'municipality', t.municipality, 'stage', t.stage,
      'reasons', t.reasons_to_sell,
      'dials_today', (select count(*) from public.messages m where m.lead_id = t.lead_id and m.channel = 'call'
                        and coalesce(m.status, '') not like 'inbound%'
                        and (m.sent_at at time zone 'America/Chicago')::date = (select day from d)),
      'last_outcome', (select m.status from public.messages m where m.lead_id = t.lead_id and m.channel = 'call'
                        and coalesce(m.status, '') not like 'inbound%' order by m.sent_at desc limit 1))
      order by (t.kind = 'callback') desc, (t.source = 'call_next') desc, (t.source = 'call_list'), t.list_rank nulls last, t.due_at), '[]'::jsonb)
    from t
$$;
revoke all on function public.agent_call_list(date) from public, anon, authenticated;
grant execute on function public.agent_call_list(date) to service_role;
