-- 0187: heads-ups push at once, the weekly digest, and the rest that wakes on its own (Colin 2026-11-04: "build the full
-- shit so the system isnt stupid anymore"; Thalia and Adil's walkthrough: "a heads-up to the other caller without
-- going through Colin, and a badge that a note landed", "a weekly morning digest of This week with the reasons, pushed,
-- not found").
--
-- 1. followups_due_to_alert also returns a heads-up (tasks.kind = 'nudge', 0186) the minute it is written, for whoever it
--    is for (a caller or Colin), with its title "Heads-up from X" and the text; followup_alerted marks it as before. The
--    call / callback / visit reminders are unchanged.
-- 2. weekly_digest(person, now): what the week holds for one caller, read by the reply agent on Monday morning; digest_log
--    keeps it to one per person per week (digest_mark).
-- 3. wake_rested (0186) is called by the reply agent once a minute; nothing to add here.

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
       -- a heads-up from the other caller (0186), the minute it lands, for anyone on the team
       or (t.kind = 'nudge' and t.created_at <= p_now)
     )
$function$;

create table if not exists public.digest_log (
  person public.team_person not null,
  week_start date not null,
  sent_at timestamptz not null default now(),
  summary jsonb,
  primary key (person, week_start)
);
alter table public.digest_log enable row level security;
drop policy if exists digest_log_owner_reads on public.digest_log;
create policy digest_log_owner_reads on public.digest_log for select using (public.is_owner());

-- true once: the first caller to mark a week gets to send it
create or replace function public.digest_mark(p_person public.team_person, p_week_start date, p_summary jsonb default null) returns boolean
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  insert into public.digest_log (person, week_start, summary) values (p_person, p_week_start, p_summary)
  on conflict (person, week_start) do nothing;
  get diagnostics n = row_count;
  return n > 0;
end $$;

-- the week ahead for one caller, in counts and the first three names (read with the service key; it does not go
-- through my_piles because that reads the signed-in person)
create or replace function public.weekly_digest(p_person public.team_person, p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare wk_start timestamptz; wk_end timestamptz; res jsonb;
begin
  wk_start := date_trunc('week', p_now at time zone 'America/Chicago') at time zone 'America/Chicago';
  wk_end := wk_start + interval '7 days';
  select jsonb_build_object(
    'person', p_person,
    'week_start', (wk_start at time zone 'America/Chicago')::date,
    'email', (select nullif(btrim(m.alert_email), '') from public.team_members m where m.person = p_person limit 1),
    'display_name', (select m.display_name from public.team_members m where m.person = p_person limit 1),
    'calls', (select count(*) from public.tasks t where t.owner = p_person and t.done_at is null and t.kind in ('call', 'callback', 'visit')
                 and t.due_at >= wk_start - interval '7 days' and t.due_at < wk_end
                 and coalesce(t.source, '') not in ('power_hour', 'power_hour_after', 'power_hour_reserve')),
    'first_three', (select coalesce(jsonb_agg(jsonb_build_object('name', x.owner_name, 'address', x.property_address, 'when', x.due_at,
                        'reasons', x.reasons_to_sell, 'say', x.say_next) order by x.due_at), '[]'::jsonb)
                      from (select l.owner_name, l.property_address, t.due_at, l.reasons_to_sell, l.say_next
                              from public.tasks t join public.leads l on l.id = t.lead_id
                             where t.owner = p_person and t.done_at is null and t.kind in ('call', 'callback', 'visit')
                               and t.due_at >= wk_start - interval '7 days' and t.due_at < wk_end
                               and coalesce(t.source, '') not in ('power_hour', 'power_hour_after', 'power_hour_reserve')
                             order by t.due_at limit 3) x),
    'resting_waking', (select count(*) from public.leads l where l.locked_to = p_person and l.parked_at is not null
                          and l.rest_until >= wk_start and l.rest_until < wk_end),
    'nudges', (select count(*) from public.tasks t where t.owner = p_person and t.done_at is null and t.kind = 'nudge'),
    'no_step', (select count(*) from public.leads l
                  where l.locked_to = p_person and l.parked_at is null
                    and l.stage::text not in ('dead', 'dnc', 'closed_won', 'closed_no_contact', 'mail_only', 'walkthrough_booked', 'offer', 'under_contract')
                    and l.belt is distinct from 'call_booked' and l.belt is distinct from 'visit_booked'
                    and exists (select 1 from public.messages m3 where m3.lead_id = l.id and m3.channel = 'call'
                                  and m3.status in ('interested', 'reached_no_decision', 'not_now', 'inbound_answered'))
                    and not exists (select 1 from public.tasks t where t.lead_id = l.id and t.owner = p_person and t.done_at is null)
                    and (l.next_stop_at is null or l.next_stop_at < p_now)))
  into res;
  return res;
end $$;

revoke all on function public.weekly_digest(public.team_person, timestamptz) from public, authenticated;
revoke all on function public.digest_mark(public.team_person, date, jsonb) from public, authenticated;
grant execute on function public.weekly_digest(public.team_person, timestamptz) to service_role;
grant execute on function public.digest_mark(public.team_person, date, jsonb) to service_role;
