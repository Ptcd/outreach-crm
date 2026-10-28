-- Muse puts a texter on Power hour's next call (Colin 2026-10-28: "during power hour we should have muse read the
-- messages and if there's a bit of interest it should be the next one on the call queue"; Rick: any interest at all,
-- call, don't keep texting). agent_call_next opens a call task (source call_next) with their words and the number
-- they texted from; power_dial_queue puts those first, oldest first, past the usual "nobody who replied, not twice in
-- two days" rules. Logging the call closes the task (0102). A card that is dead, DNC, on hold for elderly or grief,
-- already booked or with Colin, or whose phone opted out, is refused.

CREATE OR REPLACE FUNCTION public.power_dial_queue(p_limit integer DEFAULT 80, p_now timestamp with time zone DEFAULT now(), p_test boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $$
  with me as (select public.is_team() as ok),
  dialed as (
    select m.lead_id, count(*) filter (where m.sent_at > p_now - interval '7 days') as dials_7d, count(*) as dials_total, max(m.sent_at) as last_dial
      from public.messages m where m.channel = 'call' group by m.lead_id),
  reached as (
    select distinct m.lead_id from public.messages m
     where m.channel = 'call' and coalesce(m.status, '') not in ('no_answer', 'voicemail', 'inbound_missed', 'missed', 'busy', 'failed', 'canceled', 'blocked')),
  first_text as (
    select distinct on (m.lead_id) m.lead_id, right(regexp_replace(m.to_number, '\D', '', 'g'), 10) as phone, m.sent_at
      from public.messages m
     where m.direction = 'out' and m.channel = 'sms' and m.is_opener and m.provider_sid is not null and coalesce(m.status, '') not in ('undelivered', 'failed')
     order by m.lead_id, m.sent_at),
  texts as (
    select m.lead_id, count(*) as n, max(m.sent_at) as last_at from public.messages m
     where m.direction = 'out' and m.channel = 'sms' and m.provider_sid is not null group by m.lead_id),
  due_tasks as (
    select distinct on (t.lead_id) t.lead_id, t.id as task_id, t.title, t.due_at, t.source as task_source, t.quote as reply_words,
           nullif(t.phone10, '') as reply_phone, t.created_at as task_at from public.tasks t
     where t.done_at is null and t.kind = 'call' and t.lead_id is not null and t.due_at <= p_now + interval '12 hours'
       and t.owner in ('thalia', 'adil')
     order by t.lead_id, (t.source = 'call_next') desc, t.due_at),
  pool as (
    select l.*, dt.task_id, dt.title as task_title, dt.reply_words, dt.task_at, (dt.task_source = 'call_next') as replied,
           coalesce(dt.reply_phone, ft.phone) as thread_phone, ft.sent_at as first_text_at,
           coalesce(tx.n, 0) as texts_sent, tx.last_at as last_text_at, coalesce(d.dials_7d, 0) as dials_7d, coalesce(d.dials_total, 0) as dials_total, d.last_dial,
           case when dt.task_source = 'call_next' then -1 when dt.task_id is not null then 0 else 1 end as src
      from public.leads l
      left join due_tasks dt on dt.lead_id = l.id
      left join first_text ft on ft.lead_id = l.id
      left join texts tx on tx.lead_id = l.id
      left join dialed d on d.lead_id = l.id
     where (select ok from me)
       -- a walkthrough runs on TEST cards only, and the real queue never shows them
       and (l.owner_name ilike 'TEST %') = coalesce(p_test, false)
       and (dt.task_id is not null or (l.stage = 'opener_sent' and ft.sent_at < p_now - interval '3 days')
            or (coalesce(p_test, false) and l.stage = 'opener_sent'))   -- a TEST card needs no task and no texts
       and l.stage not in ('dnc', 'dead', 'closed_no_contact', 'closed_won', 'under_contract', 'walkthrough_booked', 'offer')
       and not coalesce(l.elderly_or_ill, false) and not coalesce(l.grief, false)
       and l.human_takeover_at is null
       and (l.named_date is null or l.named_date <= p_now)
       -- someone who just texted back with a bit of interest (Muse's call_next) is called next, whatever the dial rules say
       and (dt.task_source = 'call_next' or (
            coalesce(d.dials_7d, 0) < 3
        and (d.last_dial is null or d.last_dial < p_now - interval '2 days')
        and (dt.task_id is not null or l.id not in (select lead_id from reached))
        and not exists (select 1 from public.twilio_inbound ti where ti.lead_id = l.id)
        and not exists (select 1 from public.messages mi where mi.lead_id = l.id and mi.direction = 'in' and mi.channel = 'sms')))
       and extract(hour from (p_now at time zone public.agent_tz(coalesce(l.mailing_state, 'WI')))) between 9 and 19),
  pick as (
    select p.*, ph.value_normalized as phone, ph.line_type, ph.person_name as phone_person,
           (select count(*) from public.contacts c2 where c2.lead_id = p.id and c2.kind = 'phone' and c2.status = 'ok' and not c2.suppressed) - 1 as other_phones
      from pool p
      cross join lateral (
        select c.value_normalized, c.line_type, c.person_name from public.contacts c
         where c.lead_id = p.id and c.kind = 'phone' and c.status = 'ok' and c.value_normalized ~ '^[0-9]{10}$'
           and not c.suppressed and not coalesce(c.dnc_app, false) and not coalesce(c.dnc_vendor, false) and coalesce(c.dnc_scrub, '') <> 'dnc'
           and not exists (select 1 from public.suppressed_phones s where s.phone10 = c.value_normalized)
           and public.phone_person_block(c.value_normalized) is null
         order by (c.value_normalized = p.thread_phone) desc,
                  (c.person_id is not null and exists (select 1 from public.interests i where i.lead_id = p.id and i.person_id = c.person_id
                     and i.role in ('owner_of_record', 'co_owner', 'personal_representative', 'trustee') and i.status = 'active')) desc,
                  (c.line_type = 'mobile') desc, c.created_at
         limit 1) ph
     order by p.src, p.task_at nulls last, cardinality(p.reasons_to_sell) desc, p.first_text_at nulls last, p.id
     limit greatest(1, least(coalesce(p_limit, 80), 200)))
  select coalesce(jsonb_agg(jsonb_build_object(
      'lead_id', id, 'task_id', task_id, 'source', case when src = -1 then 'replied' when src = 0 then 'call_list' else 'texted_silent' end, 'why', task_title,
      'reply', reply_words,
      'owner_name', owner_name, 'address', property_address, 'municipality', municipality, 'mailing_state', mailing_state,
      'reasons', reasons_to_sell, 'lane', lane, 'stage', stage,
      'texts_sent', texts_sent, 'first_text_at', first_text_at, 'last_text_at', last_text_at,
      'dials_7d', dials_7d, 'dials_total', dials_total, 'last_dial', last_dial,
      'phone', phone, 'line_type', line_type, 'phone_person', phone_person, 'other_phones', greatest(other_phones, 0))
      order by src, task_at nulls last, cardinality(reasons_to_sell) desc, first_text_at nulls last, id), '[]'::jsonb)
    from pick
$$;

create or replace function public.agent_call_next(p_lead_id uuid, p_phone text, p_words text, p_agent text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare l public.leads; ph text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10); tz text := 'America/Chicago';
        t_now timestamp := now() at time zone 'America/Chicago'; who public.team_person; tid uuid;
        ph_hour boolean;
begin
  select * into l from public.leads where id = p_lead_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card'); end if;
  if l.stage in ('dnc', 'dead', 'closed_no_contact', 'closed_won', 'under_contract', 'walkthrough_booked', 'offer') then
    return jsonb_build_object('ok', false, 'reason', 'this card is ' || l.stage || ': nothing to call');
  end if;
  if coalesce(l.elderly_or_ill, false) or coalesce(l.grief, false) then
    return jsonb_build_object('ok', false, 'reason', 'an older, ill or grieving owner: answer by text, gently, or tell Colin');
  end if;
  if l.human_takeover_at is not null then return jsonb_build_object('ok', false, 'reason', 'Colin has this one'); end if;
  if length(ph) <> 10 then return jsonb_build_object('ok', false, 'reason', 'phone = the number that texted us'); end if;
  if exists (select 1 from public.suppressed_phones s where s.phone10 = ph) then return jsonb_build_object('ok', false, 'reason', 'that phone opted out'); end if;
  if coalesce(btrim(p_words), '') = '' then return jsonb_build_object('ok', false, 'reason', 'words = what they texted, word for word'); end if;
  who := case when extract(isodow from t_now) in (6, 7) then 'adil' else 'thalia' end;
  ph_hour := extract(isodow from t_now) between 1 and 5 and t_now::time between time '15:45' and time '18:15';
  select id into tid from public.tasks where lead_id = p_lead_id and source = 'call_next' and done_at is null limit 1;
  if tid is not null then
    update public.tasks set quote = left(btrim(p_words), 500), phone10 = ph, due_at = least(due_at, now()) where id = tid;
  else
    insert into public.tasks (lead_id, due_at, kind, owner, source, title, quote, phone10, note)
    values (p_lead_id, now(), 'call', who, 'call_next', 'Texted back: call next', left(btrim(p_words), 500), ph,
            'Call next: they texted back with a bit of interest (' || coalesce(nullif(btrim(p_agent), ''), 'Muse') || ')')
    returning id into tid;
  end if;
  return jsonb_build_object('ok', true, 'task_id', tid, 'caller', who, 'power_hour_now', ph_hour,
    'note', case when ph_hour then 'next on Power hour: do not text them back unless the call does not reach them'
                 else 'Power hour is weekdays 4-6 PM: until then it waits on the caller''s list; a short reply by text may be kinder' end);
end $$;
revoke all on function public.agent_call_next(uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.agent_call_next(uuid, text, text, text) to service_role;
