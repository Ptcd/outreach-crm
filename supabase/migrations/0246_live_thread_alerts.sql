-- 0246: a caller is told when a seller on their card is texting back and forth right now.
--
-- Colin 2026-11-16: "Make it so when there are active conversations going on back and forth for thalia and Tyler they
-- get notifications." Until now a caller heard about a thread only when it turned into a task (a yes, a call asked
-- for). On Nov 16 ten cards had a live exchange with the texting agent, one of them agreeing a time to meet, and the
-- caller the card belongs to was told about none of them while it was happening.
--
-- Live means: the seller texted in the last 15 minutes, we had answered them inside the 30 minutes before that, and
-- they had written before our answer inside the hour. So the first reply to a first text is not "live" (that already
-- goes its own way); the second one in a running exchange is.
--
-- Who is told: the caller the card belongs to (locked_to, else assigned_to). If that caller is marked off today, the
-- other caller is told and the alert says whose card it is. One alert per card per hour, nothing in quiet hours,
-- nothing for a do-not-contact or dead card, and nothing for a thread a caller has already taken over (they are in it).
-- A push to that person's phones and an email to their alert address. Nothing here touches a seller.

alter table public.campaign_control
  add column if not exists live_thread_alerts  boolean not null default true,
  add column if not exists live_thread_gap_min integer not null default 60;      -- one alert per card this often

create table if not exists public.live_thread_alerts (
  id          uuid primary key default gen_random_uuid(),
  lead_id     uuid not null references public.leads (id) on delete cascade,
  person      text not null,                       -- who was told
  card_caller text not null,                       -- whose card it is
  inbound_sid text,
  their_words text,
  at          timestamptz not null default now(),
  reached     integer,                             -- pushes plus emails that got through; null until the sender reports
  note        text
);
create index if not exists live_thread_alerts_lead_idx on public.live_thread_alerts (lead_id, at desc);
alter table public.live_thread_alerts enable row level security;
grant select on public.live_thread_alerts to authenticated, service_role;
drop policy if exists live_thread_alerts_team_read on public.live_thread_alerts;
create policy live_thread_alerts_team_read on public.live_thread_alerts for select to authenticated using (public.is_team());

-- The threads that are live right now and whose caller has not been told inside the gap. Each is handed out once.
create or replace function public.live_threads_claim(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  out   jsonb := '[]'::jsonb;
  c     public.campaign_control;
  r     record;
  today date := (p_now at time zone 'America/Chicago')::date;
  owner_ text; who text; aid uuid; m public.team_members; mo public.team_members;
begin
  select * into c from public.campaign_control where id = 1;
  if not coalesce(c.live_thread_alerts, true) then return out; end if;
  if public.in_quiet_hours(p_now) then return out; end if;
  for r in
    select distinct on (i.lead_id) i.lead_id, i.sid, i.body, i.received_at, l.owner_name, l.property_address, l.municipality,
           l.locked_to::text as locked_to, l.assigned_to::text as assigned_to,
           (select count(*) from public.twilio_inbound x where x.lead_id = i.lead_id and not coalesce(x.is_opt_out, false)
                and x.received_at > p_now - interval '60 minutes' and x.received_at <= p_now) as theirs
      from public.twilio_inbound i
      join public.leads l on l.id = i.lead_id
     where i.received_at > p_now - interval '15 minutes' and i.received_at <= p_now
       and not coalesce(i.is_opt_out, false)
       and l.stage::text not in ('dnc', 'dead')
       and l.human_takeover_at is null
       and exists (
         select 1 from public.messages o
          where o.lead_id = i.lead_id and o.direction = 'out' and o.channel = 'sms' and coalesce(o.status, '') not in ('failed', 'undelivered')
            and coalesce(o.sent_at, o.created_at) <= i.received_at
            and coalesce(o.sent_at, o.created_at) > i.received_at - interval '30 minutes'
            and exists (select 1 from public.twilio_inbound p
                         where p.lead_id = i.lead_id and not coalesce(p.is_opt_out, false)
                           and p.received_at < coalesce(o.sent_at, o.created_at)
                           and p.received_at > i.received_at - interval '60 minutes'))
       and not exists (select 1 from public.live_thread_alerts a
                        where a.lead_id = i.lead_id and a.at > p_now - make_interval(mins => greatest(coalesce(c.live_thread_gap_min, 60), 5)))
     order by i.lead_id, i.received_at desc
  loop
    owner_ := case when r.locked_to in ('thalia', 'adil') then r.locked_to when r.assigned_to in ('thalia', 'adil') then r.assigned_to end;
    if owner_ is null then continue; end if;                       -- a card with no caller: nobody to tell
    who := owner_;
    if public.caller_is_off(who::public.team_person, today) then
      who := case owner_ when 'thalia' then 'adil' else 'thalia' end;
      if public.caller_is_off(who::public.team_person, today) then continue; end if;   -- both off today
    end if;
    select * into m from public.team_members where person::text = who limit 1;
    select * into mo from public.team_members where person::text = owner_ limit 1;
    insert into public.live_thread_alerts (lead_id, person, card_caller, inbound_sid, their_words, at)
    values (r.lead_id, who, owner_, r.sid, left(r.body, 300), p_now) returning id into aid;
    out := out || jsonb_build_object('alert_id', aid, 'lead_id', r.lead_id, 'person', who, 'display_name', m.display_name,
      'card_caller', owner_, 'card_caller_name', mo.display_name, 'email', nullif(btrim(m.alert_email), ''),
      'owner_name', r.owner_name, 'address', r.property_address, 'municipality', r.municipality,
      'their_words', left(r.body, 300), 'texts_this_hour', r.theirs, 'at', r.received_at);
  end loop;
  return out;
end $$;

create or replace function public.live_thread_alerted(p_id uuid, p_reached integer, p_note text) returns void
language sql security definer set search_path = public as $$
  update public.live_thread_alerts set reached = p_reached, note = nullif(btrim(coalesce(p_note, '')), '') where id = p_id
$$;

revoke all on function public.live_threads_claim(timestamptz), public.live_thread_alerted(uuid, integer, text) from public, anon, authenticated;
grant execute on function public.live_threads_claim(timestamptz), public.live_thread_alerted(uuid, integer, text) to service_role;
