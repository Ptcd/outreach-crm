-- The safety net (Colin 2026-10-26: "how do we not lose edge cases"). Two ways a lead gets lost: a card with no date
-- on it, or something that lands and no card claims. agent_stuck lists both every day, and due_today carries them,
-- so the agent and the Warm board see the same list:
--   no_next_step      a warm card (past the cold texts, not resting) with no date at all
--   reply_unanswered  someone texted back more than 2 hours ago (in the window) and nobody answered
--   unlogged_call     a call was started from the app and never logged (2 hours)
--   text_stale        a text planned for a day that is over and never went
--   unknown_caller    a text or call came in from a phone no card has
--   dormant_replied   a card put to sleep after the person had actually replied (a nudge rule misfiled it)

create or replace function public.agent_stuck(p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public as $$
  with s as (
    select l.id, 'no_next_step' as what, l.updated_at as since, 'no date on this card: it will never come back on its own' as why
      from public.leads l
     where l.belt is not null and l.belt not in ('cold_texts', 'dead', 'dnc', 'too_high_or_listed', 'dormant')
       and l.stage not in ('dnc', 'dead', 'closed_no_contact', 'closed_won')
       and l.next_stop_at is null and l.named_date is null and (l.stage <> 'follow_up' or l.next_action_at is null)
       and not exists (select 1 from public.planned_openers p where p.lead_id = l.id and p.send_status in ('planned', 'would_send', 'sending'))
    union all
    select t.lead_id, 'reply_unanswered', t.received_at, 'they texted ' || to_char(t.received_at at time zone 'America/Chicago', 'Dy FMHH12:MI AM') || ' and nobody answered'
      from (select distinct on (from10) * from public.twilio_inbound order by from10, received_at desc) t
      join public.leads l on l.id = t.lead_id
     where not t.is_opt_out and t.received_at < p_now - interval '2 hours' and t.received_at > p_now - interval '7 days'
       and l.stage not in ('dnc', 'dead', 'closed_no_contact', 'closed_won')
       and not exists (select 1 from public.suppressed_phones sp where sp.phone10 = t.from10)
       and not exists (select 1 from public.messages m where m.direction = 'out' and m.channel = 'sms' and m.sent_at > t.received_at
                        and right(regexp_replace(coalesce(m.to_number, ''), '\D', '', 'g'), 10) = t.from10)
       and not exists (select 1 from public.reply_drafts d where d.phone10 = t.from10 and d.inbound_at >= t.received_at and d.status in ('queued', 'sending', 'sent'))
    union all
    select l.id, 'unlogged_call', l.human_takeover_at, 'a call was started from the app ' || to_char(l.human_takeover_at at time zone 'America/Chicago', 'Dy FMHH12:MI AM') || ' and never logged'
      from public.leads l where l.human_takeover_at < p_now - interval '2 hours'
    union all
    select p.lead_id, 'text_stale', p.window_end_utc, 'a step ' || p.step || ' text was planned for ' || to_char(p.plan_date, 'Mon DD') || ' and never went'
      from public.planned_openers p
     where p.send_status in ('planned', 'would_send') and p.window_end_utc < p_now and p.lead_id is not null
    union all
    select null::uuid, 'unknown_caller', t.received_at, 'a text from ' || t.from10 || ' to ' || t.to_number || ' matches no card: "' || left(coalesce(t.body, ''), 80) || '"'
      from public.twilio_inbound t
     where t.lead_id is null and t.received_at > p_now - interval '7 days' and not t.is_opt_out
    union all
    select l.id, 'dormant_replied', l.belt_entered_at, 'put to sleep after they replied: "' || left(coalesce(t.body, ''), 80) || '"'
      from public.leads l
      join lateral (select body from public.twilio_inbound x where x.lead_id = l.id order by received_at desc limit 1) t on true
     where l.belt = 'dormant' and l.stage not in ('dnc', 'dead') and exists (select 1 from public.twilio_inbound x where x.lead_id = l.id and not x.is_opt_out))
  select coalesce(jsonb_agg((case when s.id is null then '{}'::jsonb else public.agent_card(s.id) end)
           || jsonb_build_object('what', s.what, 'since', s.since, 'why', s.why, 'days_late', greatest(0, (extract(epoch from p_now - s.since) / 86400)::int))
           order by s.since), '[]'::jsonb)
    from s
$$;

create or replace function public.agent_due_today(p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public as $$
  with due as (
    select l.id, 'check_back' as what, coalesce(l.named_date, l.next_action_at) as due_at,
           coalesce(nullif(l.named_event, ''), nullif(l.next_action, ''), 'check back') as why
      from public.leads l
     where l.stage not in ('dnc', 'dead', 'closed_no_contact', 'closed_won')
       and ((l.stage = 'follow_up' and l.next_action_at <= p_now)
            or (l.belt in ('not_now_dated', 'hold_not_now', 'estate_waiting', 'needs_family', 'elderly', 'not_now_condition') and l.named_date <= p_now))
    union all
    select l.id, case when l.belt = 'visit_booked' or l.named_event = 'visit' then 'booked_visit' else 'booked_call' end,
           coalesce(l.named_date, l.next_stop_at), coalesce(nullif(l.next_stop_say, ''), 'booked')
      from public.leads l
     where l.belt in ('call_booked', 'visit_booked') and coalesce(l.named_date, l.next_stop_at) <= p_now + interval '12 hours'
    union all
    select l.id, case when l.next_stop_who in ('thalia_call', 'colin_call', 'colin_visit') then 'call_due' else 'text_due' end,
           l.next_stop_at, coalesce(nullif(l.next_stop_say, ''), l.belt)
      from public.leads l
     where l.belt not in ('cold_texts', 'dead', 'dnc', 'call_booked', 'visit_booked', 'not_now_dated', 'hold_not_now', 'estate_waiting', 'needs_family', 'elderly', 'not_now_condition')
       and l.stage not in ('dnc', 'dead', 'closed_no_contact', 'closed_won') and l.next_stop_at <= p_now
    union all
    select c.lead_id, 'contract_waiting', c.created_at,
           'contract sent ' || to_char(c.created_at at time zone 'America/Chicago', 'Mon DD') || ', not signed'
           || coalesce(' (' || (select string_agg(s.name, ', ') from public.contract_signers s where s.contract_id = c.id and s.signed_at is null) || ' still to sign)', '')
      from public.contracts c
     where c.status = 'sent' and c.voided_at is null)
  select jsonb_build_object(
    'due', coalesce((select jsonb_agg(public.agent_card(d.id) || jsonb_build_object('what', d.what, 'due_at', d.due_at, 'why', d.why,
             'days_late', greatest(0, (extract(epoch from p_now - d.due_at) / 86400)::int)) order by d.due_at)
             from (select distinct on (id, what) id, what, due_at, why from due order by id, what, due_at) d), '[]'::jsonb),
    'stuck', public.agent_stuck(p_now))
$$;

-- the Warm board's "Needs a decision" uses the same net
create or replace function public.warm_stuck_count() returns integer language sql stable security definer set search_path = public as $$
  select jsonb_array_length(public.agent_stuck())
$$;

revoke all on function public.agent_stuck(timestamptz), public.agent_due_today(timestamptz) from public, anon, authenticated;
grant execute on function public.agent_stuck(timestamptz), public.agent_due_today(timestamptz) to service_role;
revoke all on function public.warm_stuck_count() from public, anon;
grant execute on function public.warm_stuck_count() to authenticated;
