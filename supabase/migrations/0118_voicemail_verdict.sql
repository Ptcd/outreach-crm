-- Don't call back the callers who aren't leads (Colin 2026-10-28: "not have her calling people that called in pissed or
-- are not real leads"). The reply agent's minute run reads every voicemail (Claude, with the rule words as a floor) and
-- sets a verdict: seller (call back), unclear (call back), stop (block the number: they asked), wrong_person (block that
-- number only, the card stays open), upset (no call back: Colin decides), not_seller (an agent, a vendor, a robocall, an
-- office: no call back). Power hour and Today's Missed calls box leave out the ones not to call, and an unread voicemail
-- waits up to 10 minutes before it can come up.

alter table public.inbound_calls add column if not exists vm_verdict text
  check (vm_verdict in ('seller', 'unclear', 'stop', 'wrong_person', 'upset', 'not_seller'));
alter table public.inbound_calls add column if not exists vm_reason text;
alter table public.inbound_calls add column if not exists vm_read_at timestamptz;

-- the voicemails waiting to be read (the minute run)
create or replace function public.voicemail_to_read(p_limit integer default 5) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('call_sid', x.call_sid, 'words', x.words, 'phone', x.from10,
           'owner_name', x.owner_name, 'property_address', x.property_address, 'stage', x.stage) order by x.created_at), '[]'::jsonb)
    from (select ic.call_sid, ic.from10, ic.created_at, l.owner_name, l.property_address, l.stage,
                 nullif(substring(m.body from 'Voicemail: "(.*)"'), '') as words
            from public.inbound_calls ic
            join public.messages m on m.id = ic.message_id
            left join public.leads l on l.id = ic.lead_id
           where ic.voicemail and ic.vm_verdict is null and ic.created_at > now() - interval '48 hours'
             and substring(m.body from 'Voicemail: "(.*)"') is not null
           order by ic.created_at limit greatest(1, least(coalesce(p_limit, 5), 20))) x
$$;

-- the verdict, and what follows from it
create or replace function public.voicemail_set_verdict(p_call_sid text, p_verdict text, p_reason text, p_by text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare ic public.inbound_calls; ph text; test boolean;
begin
  if p_verdict not in ('seller', 'unclear', 'stop', 'wrong_person', 'upset', 'not_seller') then
    return jsonb_build_object('ok', false, 'reason', 'verdict is seller, unclear, stop, wrong_person, upset or not_seller');
  end if;
  select * into ic from public.inbound_calls where call_sid = p_call_sid for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such call'); end if;
  if ic.vm_verdict is not null then return jsonb_build_object('ok', true, 'verdict', ic.vm_verdict, 'already', true); end if;
  update public.inbound_calls set vm_verdict = p_verdict, vm_reason = left(nullif(btrim(coalesce(p_reason, '')), ''), 300), vm_read_at = now()
   where call_sid = p_call_sid;
  ph := ic.from10;
  -- Colin's test phone plays a sample owner: never blocked by its own test voicemails
  test := exists (select 1 from public.campaign_control where id = 1 and ph = any(coalesce(test_phones, '{}')));
  if p_verdict = 'stop' and not test and ph ~ '^[0-9]{10}$' then
    insert into public.suppressed_phones (phone10, reason, source) values (ph, 'dnc_call', 'voicemail') on conflict (phone10) do nothing;
    update public.contacts set suppressed = true where kind = 'phone' and value_normalized = ph and suppressed is distinct from true;
  elsif p_verdict = 'wrong_person' and not test and ic.lead_id is not null and ph ~ '^[0-9]{10}$' then
    perform public.block_wrong_person_phone(ic.lead_id, ph, 'voicemail');
  end if;
  if p_verdict in ('stop', 'wrong_person', 'upset', 'not_seller') then
    update public.tasks set done_at = case when p_verdict in ('stop', 'wrong_person') then now() else done_at end,
           owner = case when p_verdict in ('upset', 'not_seller') then 'colin' else owner end,
           note = concat_ws(E'\n', note, 'Voicemail read: ' || case p_verdict when 'stop' then 'they asked us to stop. Do not call.'
             when 'wrong_person' then 'not the owner. That number is blocked; the card stays open.'
             when 'upset' then 'upset caller. No call back from the team; Colin decides.'
             else 'not a seller. No call back.' end || coalesce(' (' || left(p_reason, 200) || ')', ''))
     where id = ic.task_id and done_at is null;
    update public.messages set body = body || E'\nVoicemail read: ' || p_verdict || coalesce(' (' || left(p_reason, 200) || ')', '')
     where id = ic.message_id;
  end if;
  return jsonb_build_object('ok', true, 'verdict', p_verdict);
end $$;

revoke all on function public.voicemail_to_read(integer), public.voicemail_set_verdict(text, text, text, text) from public, anon, authenticated;
grant execute on function public.voicemail_to_read(integer), public.voicemail_set_verdict(text, text, text, text) to service_role;

CREATE OR REPLACE FUNCTION public.missed_calls_recent(p_hours integer DEFAULT 48)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'call_sid', ic.call_sid, 'at', ic.created_at, 'phone', ic.from10, 'status', ic.status, 'voicemail', ic.voicemail,
      'words', nullif(substring(m.body from 'Voicemail: "(.*)"'), ''),
      'verdict', ic.vm_verdict, 'verdict_reason', ic.vm_reason,
      'lead_id', l.id, 'owner_name', l.owner_name, 'property_address', l.property_address, 'municipality', l.municipality, 'stage', l.stage,
      'closed', l.stage::text in ('dnc', 'dead', 'closed_no_contact') or exists (select 1 from public.suppressed_phones s where s.phone10 = ic.from10),
      'card_closed', l.stage::text in ('dnc', 'dead', 'closed_no_contact'),
      'phone_blocked', exists (select 1 from public.suppressed_phones s where s.phone10 = ic.from10),
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
  -- a seller who called us and nobody picked up, not called back since (the same rule as Today's Missed calls box)
  missed as (
    select distinct on (ic.lead_id) ic.lead_id, ic.from10 as missed_phone, ic.created_at as missed_at, ic.voicemail,
           nullif(substring(m.body from 'Voicemail: "(.*)"'), '') as vm_words
      from public.inbound_calls ic left join public.messages m on m.id = ic.message_id
     where ic.lead_id is not null and ic.created_at > p_now - interval '48 hours'
       and (ic.status in ('missed', 'blocked', 'no_answer', 'busy', 'failed') or ic.voicemail)
       -- a caller whose number is on the stop list ("erase my number") is never a callback, on any of the card's numbers
       and not exists (select 1 from public.suppressed_phones s where s.phone10 = ic.from10)
       -- the voicemail was read (0118): an upset caller, a stop, the wrong person or someone who isn't a seller is never a
       -- callback; a voicemail not read yet waits up to 10 minutes so nobody calls a caller who was angry
       and coalesce(ic.vm_verdict, '') not in ('stop', 'wrong_person', 'upset', 'not_seller')
       and not (ic.voicemail and ic.vm_verdict is null and ic.created_at > p_now - interval '10 minutes')
       and not exists (select 1 from public.messages o where o.lead_id = ic.lead_id and o.channel = 'call' and o.sent_at > ic.created_at
                         and coalesce(o.status, '') not like 'inbound%')
     order by ic.lead_id, ic.created_at desc),
  due_tasks as (
    select distinct on (t.lead_id) t.lead_id, t.id as task_id, t.title, t.due_at, t.source as task_source, t.quote as reply_words,
           nullif(t.phone10, '') as reply_phone, t.created_at as task_at from public.tasks t
     where t.done_at is null and t.kind = 'call' and t.lead_id is not null and t.due_at <= p_now + interval '12 hours'
       and t.owner in ('thalia', 'adil')
     order by t.lead_id, (t.source = 'call_next') desc, t.due_at),
  pool as (
    select l.*, dt.task_id, dt.title as task_title, dt.reply_words, dt.task_at, (dt.task_source = 'call_next') as replied,
           mc.missed_at, mc.voicemail as missed_voicemail, mc.vm_words, mc.missed_phone,
           coalesce(mc.missed_phone, dt.reply_phone, ft.phone) as thread_phone, ft.sent_at as first_text_at,
           coalesce(tx.n, 0) as texts_sent, tx.last_at as last_text_at, coalesce(d.dials_7d, 0) as dials_7d, coalesce(d.dials_total, 0) as dials_total, d.last_dial,
           case when mc.lead_id is not null then -2 when dt.task_source = 'call_next' then -1 when dt.task_id is not null then 0 else 1 end as src
      from public.leads l
      left join missed mc on mc.lead_id = l.id
      left join due_tasks dt on dt.lead_id = l.id
      left join first_text ft on ft.lead_id = l.id
      left join texts tx on tx.lead_id = l.id
      left join dialed d on d.lead_id = l.id
     where (select ok from me)
       -- a walkthrough runs on TEST cards only, and the real queue never shows them
       and (l.owner_name ilike 'TEST %') = coalesce(p_test, false)
       -- a seller who called us comes first, whatever the card's stage or dial count (Colin 2026-10-28: "should
       -- automatically be top of the list to call"); only a dead or do-not-contact card is left out
       and ((mc.lead_id is not null and l.stage not in ('dnc', 'dead', 'closed_no_contact')) or (
           (dt.task_id is not null or (l.stage = 'opener_sent' and ft.sent_at < p_now - interval '3 days')
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
        and not exists (select 1 from public.messages mi where mi.lead_id = l.id and mi.direction = 'in' and mi.channel = 'sms')))))
       and extract(hour from (p_now at time zone public.agent_tz(coalesce(l.mailing_state, 'WI')))) between 9 and 19),
  pick as (
    select p.*, ph.value_normalized as phone, ph.line_type, ph.person_name as phone_person,
           (select count(*) from public.contacts c2 where c2.lead_id = p.id and c2.kind = 'phone' and c2.status = 'ok' and not c2.suppressed) - 1 as other_phones
      from pool p
      cross join lateral (
        select c.value_normalized, c.line_type, c.person_name from public.contacts c
         where c.lead_id = p.id and c.kind = 'phone' and c.status = 'ok' and c.value_normalized ~ '^[0-9]{10}$'
           and not c.suppressed and not coalesce(c.dnc_app, false)
           and (c.value_normalized = p.missed_phone or (not coalesce(c.dnc_vendor, false) and coalesce(c.dnc_scrub, '') <> 'dnc'))
           and not exists (select 1 from public.suppressed_phones s where s.phone10 = c.value_normalized)
           and public.phone_person_block(c.value_normalized) is null
         order by (c.value_normalized = p.thread_phone) desc,
                  (c.person_id is not null and exists (select 1 from public.interests i where i.lead_id = p.id and i.person_id = c.person_id
                     and i.role in ('owner_of_record', 'co_owner', 'personal_representative', 'trustee') and i.status = 'active')) desc,
                  (c.line_type = 'mobile') desc, c.created_at
         limit 1) ph
     order by p.src, p.missed_at desc nulls last, p.task_at nulls last, cardinality(p.reasons_to_sell) desc, p.first_text_at nulls last, p.id
     limit greatest(1, least(coalesce(p_limit, 80), 200)))
  select coalesce(jsonb_agg(jsonb_build_object(
      'lead_id', id, 'task_id', task_id, 'source', case when src = -2 then 'missed_call' when src = -1 then 'replied' when src = 0 then 'call_list' else 'texted_silent' end, 'why', task_title,
      'missed_at', missed_at, 'voicemail', missed_voicemail, 'voicemail_words', vm_words,
      'reply', reply_words,
      'owner_name', owner_name, 'address', property_address, 'municipality', municipality, 'mailing_state', mailing_state,
      'reasons', reasons_to_sell, 'lane', lane, 'stage', stage,
      'texts_sent', texts_sent, 'first_text_at', first_text_at, 'last_text_at', last_text_at,
      'dials_7d', dials_7d, 'dials_total', dials_total, 'last_dial', last_dial,
      'phone', phone, 'line_type', line_type, 'phone_person', phone_person, 'other_phones', greatest(other_phones, 0))
      order by src, missed_at desc nulls last, task_at nulls last, cardinality(reasons_to_sell) desc, first_text_at nulls last, id), '[]'::jsonb)
    from pick
$$;
