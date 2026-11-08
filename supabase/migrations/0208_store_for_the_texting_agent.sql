-- 0208: the store for the texting agent (Colin 2026-11-08, "Ship it all", after Muse's desk posts 143 and 144: Muse works
-- the book like its own sales rep, not from a scoped window). Three read-only functions behind the agent door:
-- agent_store_cards (the whole store, paged, with people, phones, marks, motivations, the laptop's equity inputs and a
-- cadence summary), agent_store_cadence (per-card thread state and blockers), and agent_ready_to_text with p_all honoured
-- so the day's first texts can be chosen from the full pool. Nothing about sending mechanics changes: agent_queue_text
-- keeps every refusal (STOP/DNC, caller-texted card, already texted or talking, nine-attempt cap, wording), and the
-- laptop's nightly hand-off continues until Colin turns it off.

-- the whole store, a page at a time, for the texting agent: every card with its people, phones (textable flags), stage,
-- marks and holds, motivations, the equity inputs the laptop pushed (equity_inputs) and a cadence summary. Ordered by
-- (updated_at, id); pass next_after back to continue; p_since gives the nightly delta. Read-only.
create or replace function public.agent_store_cards(p_after_updated timestamptz default null, p_after_id uuid default null, p_since timestamptz default null,
  p_limit integer default 200, p_county text default null, p_stage text[] default null, p_live_only boolean default true)
returns jsonb language sql stable security definer set search_path = public as $$
  with page as (
    select l.*, coalesce(l.updated_at, l.created_at) as u from public.leads l
     where (p_after_updated is null or (coalesce(l.updated_at, l.created_at), l.id) > (p_after_updated, coalesce(p_after_id, '00000000-0000-0000-0000-000000000000'::uuid)))
       and (p_since is null or coalesce(l.updated_at, l.created_at) >= p_since)
       and (p_county is null or lower(coalesce(l.county, '')) = lower(p_county))
       and (p_stage is null or l.stage::text = any(p_stage))
       and (not p_live_only or l.stage not in ('dead', 'dnc', 'closed_no_contact', 'closed_won'))
     order by coalesce(l.updated_at, l.created_at), l.id
     limit greatest(1, least(coalesce(p_limit, 200), 500))),
  rows as (
    select l.u, l.id, jsonb_build_object(
      'lead_id', l.id, 'owner_name', l.owner_name, 'owner_type', l.owner_type,
      'address', l.property_address, 'city', l.municipality, 'county', l.county, 'zip', l.property_zip,
      'property', jsonb_build_object('type', l.property_type, 'units', l.units, 'parcel', l.parcel_id, 'lane', l.lane, 'score', l.score,
                                     'wpie_property_id', l.wpie_property_id, 'laptop_card', l.wpie_owner_id > 0),
      'stage', l.stage, 'stage_changed_at', l.stage_changed_at, 'dead_reason', l.dead_reason,
      'card_owner', (select tm.display_name from public.team_members tm where tm.person = l.locked_to), 'card_owner_key', l.locked_to,
      'held', jsonb_build_object('parked_at', l.parked_at, 'parked_why', l.parked_why, 'rest_until', l.rest_until,
                                 'human_takeover_at', l.human_takeover_at, 'elderly_or_ill', l.elderly_or_ill, 'grief', l.grief,
                                 'caller_texting', public.caller_texting(l.id)),
      'belt', jsonb_build_object('belt', l.belt, 'step', l.belt_step, 'next_stop_at', l.next_stop_at, 'who', l.next_stop_who, 'say', l.next_stop_say),
      'check_back_at', l.next_action_at, 'named_date', l.named_date, 'named_event', l.named_event, 'say_next', l.say_next,
      'reasons', l.reasons_to_sell,
      'reason_details', (select jsonb_agg(jsonb_build_object('kind', r.kind, 'detail', r.detail, 'date', r.event_date, 'amount', r.amount, 'source', r.source))
                           from public.prospect_reasons r where r.lead_id = l.id),
      'motivation', (select jsonb_build_object('tier', lm.tier, 'families', lm.families, 'family_list', lm.family_list, 'lines', lm.lines,
                                               'amplifiers', lm.amplifiers, 'tax_years', lm.tax_years, 'tax_owed', lm.tax_owed, 'as_of', lm.as_of)
                       from public.lead_motivation lm where lm.lead_id = l.id),
      'equity', (select jsonb_build_object('grade', e.equity_grade, 'line', e.equity_line, 'estimated', e.estimated,
                                           'value_used', e.value_used, 'value_source', e.value_source, 'assessed_total', e.assessed_total, 'est_market_value', e.est_market_value,
                                           'last_sale_date', e.last_sale_date, 'last_sale_price', e.last_sale_price, 'sale_source', e.sale_source,
                                           'tenure_from', e.tenure_from, 'tenure_source', e.tenure_source,
                                           'tax_years_behind', e.tax_years_behind, 'tax_owed', e.tax_owed, 'judgment_amount', e.judgment_amount, 'in_rem_amount', e.in_rem_amount,
                                           'mortgage_balance_est', e.mortgage_balance_est, 'assumed_loan_balance_est', e.assumed_loan_balance_est, 'mortgage_source', e.mortgage_source,
                                           'debt_total', e.debt_total, 'equity', e.equity, 'equity_share', e.equity_share, 'basis', e.basis, 'caveats', e.caveats, 'pushed_at', e.pushed_at)
                   from public.equity_inputs e where e.lead_id = l.id),
      'people', public.card_interests(l.id),
      'phones', (select coalesce(jsonb_agg(jsonb_build_object('phone', c.value_normalized, 'type', c.line_type, 'name', c.person_name, 'status', c.status,
                        'textable', c.status = 'ok' and not c.dnc_app and not c.suppressed and not c.dnc_vendor and c.dnc_scrub <> 'dnc' and public.agent_phone_ok(c.value_normalized, c.line_type),
                        'opted_out', exists (select 1 from public.suppressed_phones s where s.phone10 = c.value_normalized),
                        'blocked', public.phone_person_block(c.value_normalized),
                        'texts_sent', (select count(*) from public.messages m where m.lead_id = l.id and m.direction = 'out' and m.channel = 'sms'
                                         and m.provider_sid is not null and right(regexp_replace(coalesce(m.to_number, ''), '\D', '', 'g'), 10) = c.value_normalized),
                        'last_sent_at', (select max(m.sent_at) from public.messages m where m.lead_id = l.id and m.direction = 'out' and m.channel = 'sms'
                                           and m.provider_sid is not null and right(regexp_replace(coalesce(m.to_number, ''), '\D', '', 'g'), 10) = c.value_normalized),
                        'replies', (select count(*) from public.twilio_inbound t where t.lead_id = l.id and t.from10 = c.value_normalized))
                      order by c.created_at), '[]'::jsonb)
                   from public.contacts c where c.lead_id = l.id and c.kind = 'phone'),
      'cadence', jsonb_build_object(
        'texts_sent', (select count(*) from public.messages m where m.lead_id = l.id and m.direction = 'out' and m.channel = 'sms' and m.provider_sid is not null),
        'last_out_at', (select max(m.sent_at) from public.messages m where m.lead_id = l.id and m.direction = 'out' and m.channel = 'sms' and m.provider_sid is not null),
        'last_in_at', greatest((select max(t.received_at) from public.twilio_inbound t where t.lead_id = l.id),
                               (select max(m.sent_at) from public.messages m where m.lead_id = l.id and m.direction = 'in' and m.channel = 'sms')),
        'replied', exists (select 1 from public.twilio_inbound t where t.lead_id = l.id)
                   or exists (select 1 from public.messages m where m.lead_id = l.id and m.direction = 'in' and m.channel = 'sms'),
        'call_reached', exists (select 1 from public.messages m where m.lead_id = l.id and m.channel = 'call' and coalesce(m.status, '') not in ('no_answer', 'voicemail', 'inbound_missed', 'missed', 'busy', 'failed', 'canceled', 'blocked')),
        'planned', (select count(*) from public.planned_openers po where po.lead_id = l.id and po.send_status in ('planned', 'would_send', 'sending'))),
      'created_at', l.created_at, 'updated_at', l.u) as card
      from page l)
  select jsonb_build_object(
    'cards', coalesce((select jsonb_agg(r.card order by r.u, r.id) from rows r), '[]'::jsonb),
    'page', (select count(*) from rows),
    'next_after', (select jsonb_build_object('updated_at', r.u, 'id', r.id) from rows r order by r.u desc, r.id desc limit 1),
    'store_counts', case when p_after_updated is null then (
        select jsonb_build_object('cards', count(*), 'live', count(*) filter (where l.stage not in ('dead', 'dnc', 'closed_no_contact', 'closed_won')),
                                  'agent_loaded', count(*) filter (where l.wpie_owner_id < 0),
                                  'by_stage', (select coalesce(jsonb_object_agg(st, n), '{}'::jsonb) from (select stage::text st, count(*) n from public.leads group by 1) a),
                                  'with_equity_row', (select count(*) from public.equity_inputs),
                                  'with_sale_date', (select count(*) from public.equity_inputs e where e.last_sale_date is not null),
                                  'with_sale_price', (select count(*) from public.equity_inputs e where e.last_sale_price is not null))
          from public.leads l) end)
$$;
revoke all on function public.agent_store_cards(timestamptz, uuid, timestamptz, integer, text, text[], boolean) from public, anon, authenticated;
grant execute on function public.agent_store_cards(timestamptz, uuid, timestamptz, integer, text, text[], boolean) to service_role;

-- per-card conversation and cadence state for up to 200 cards: each phone's texts, replies, opt-out and blocks; the
-- thread (the phone the first text ran on, how many texts, when the next step falls due on the 1-3-10-17-24 schedule);
-- what is planned; and the blockers that stop a follow-up (replied, a call that reached them, elderly or grief, a human
-- took over, the caller texted the card themselves, parked, resting, closed). Read-only. Follow-up ownership can live
-- with the texting agent from this (Colin 2026-11-08, Muse 144 part 2).
create or replace function public.agent_store_cadence(p_lead_ids uuid[]) returns jsonb
language sql stable security definer set search_path = public as $$
  with ids as (select distinct x as id from unnest(p_lead_ids[1:200]) x),
  outs as (
    select m.lead_id, right(regexp_replace(coalesce(m.to_number, ''), '\D', '', 'g'), 10) as phone, m.sent_at, m.status, m.is_opener
      from public.messages m join ids on ids.id = m.lead_id
     where m.direction = 'out' and m.channel = 'sms' and m.provider_sid is not null),
  ins as (
    select t.lead_id, t.from10 as phone, t.received_at as at, t.is_opt_out from public.twilio_inbound t join ids on ids.id = t.lead_id
    union all
    select m.lead_id, right(regexp_replace(coalesce(m.from_number, ''), '\D', '', 'g'), 10), m.sent_at, m.is_opt_out from public.messages m join ids on ids.id = m.lead_id
     where m.direction = 'in' and m.channel = 'sms'),
  first_text as (
    select distinct on (o.lead_id) o.lead_id, o.phone, o.sent_at as first_at from outs o
     where o.is_opener and coalesce(o.status, '') not in ('undelivered', 'failed') order by o.lead_id, o.sent_at desc),
  thread as (
    select f.lead_id, f.phone, f.first_at, count(o.*)::int as n, max(o.sent_at) as last_at
      from first_text f join outs o on o.lead_id = f.lead_id and o.phone = f.phone and o.sent_at >= f.first_at group by 1, 2, 3)
  select coalesce(jsonb_agg(jsonb_build_object(
    'lead_id', l.id, 'stage', l.stage, 'card_owner', (select tm.display_name from public.team_members tm where tm.person = l.locked_to),
    'phones', (select coalesce(jsonb_agg(jsonb_build_object('phone', c.value_normalized, 'type', c.line_type, 'name', c.person_name,
                 'textable', c.status = 'ok' and not c.dnc_app and not c.suppressed and not c.dnc_vendor and c.dnc_scrub <> 'dnc' and public.agent_phone_ok(c.value_normalized, c.line_type),
                 'texts_sent', (select count(*) from outs o where o.lead_id = l.id and o.phone = c.value_normalized),
                 'last_sent_at', (select max(o.sent_at) from outs o where o.lead_id = l.id and o.phone = c.value_normalized),
                 'last_status', (select o.status from outs o where o.lead_id = l.id and o.phone = c.value_normalized order by o.sent_at desc limit 1),
                 'replies', (select count(*) from ins i where i.lead_id = l.id and i.phone = c.value_normalized),
                 'last_reply_at', (select max(i.at) from ins i where i.lead_id = l.id and i.phone = c.value_normalized),
                 'opted_out', exists (select 1 from public.suppressed_phones s where s.phone10 = c.value_normalized),
                 'blocked', public.phone_person_block(c.value_normalized),
                 'hold', (select h.reason from public.reply_holds h where h.phone10 = c.value_normalized limit 1)) order by c.created_at), '[]'::jsonb)
               from public.contacts c where c.lead_id = l.id and c.kind = 'phone'),
    'thread', (select jsonb_build_object('phone', t.phone, 'first_text_at', t.first_at, 'texts_in_thread', t.n, 'last_sent_at', t.last_at,
                 'next_step', case when t.n between 1 and 4 then t.n + 1 end,
                 'next_due_day', case when t.n between 1 and 4 then (t.first_at at time zone 'America/Chicago')::date
                                        + (case t.n + 1 when 2 then 2 when 3 then 9 when 4 then 16 else 23 end) end)
                 from thread t where t.lead_id = l.id),
    'replied', exists (select 1 from ins i where i.lead_id = l.id),
    'last_inbound_at', (select max(i.at) from ins i where i.lead_id = l.id),
    'call_reached', exists (select 1 from public.messages m where m.lead_id = l.id and m.channel = 'call' and coalesce(m.status, '') not in ('no_answer', 'voicemail', 'inbound_missed', 'missed', 'busy', 'failed', 'canceled', 'blocked')),
    'planned', (select coalesce(jsonb_agg(jsonb_build_object('step', po.step, 'phone', right(regexp_replace(coalesce(po.phone, ''), '\D', '', 'g'), 10), 'scheduled_at', po.scheduled_at,
                  'send_status', po.send_status, 'lane', po.lane) order by po.scheduled_at), '[]'::jsonb)
                  from public.planned_openers po where po.lead_id = l.id and po.send_status in ('planned', 'would_send', 'sending')),
    'blockers', (select coalesce(jsonb_agg(b), '[]'::jsonb) from unnest(array_remove(array[
        case when exists (select 1 from ins i where i.lead_id = l.id) then 'replied' end,
        case when exists (select 1 from public.messages m where m.lead_id = l.id and m.channel = 'call' and coalesce(m.status, '') not in ('no_answer', 'voicemail', 'inbound_missed', 'missed', 'busy', 'failed', 'canceled', 'blocked')) then 'call_reached' end,
        case when coalesce(l.elderly_or_ill, false) then 'elderly_or_ill' end,
        case when coalesce(l.grief, false) then 'grief' end,
        case when l.human_takeover_at is not null then 'human_takeover' end,
        case when public.caller_texting(l.id) is not null then 'caller_texting' end,
        case when l.parked_at is not null then 'parked' end,
        case when l.rest_until > now() then 'resting' end,
        case when l.stage in ('dead', 'dnc', 'closed_no_contact', 'closed_won', 'under_contract') then 'closed' end,
        case when exists (select 1 from public.planned_openers po where po.lead_id = l.id and po.send_status in ('planned', 'would_send', 'sending')) then 'planned_waiting' end
      ], null)) b),
    'check_back_at', l.next_action_at, 'parked_at', l.parked_at, 'parked_why', l.parked_why, 'rest_until', l.rest_until,
    'belt', jsonb_build_object('belt', l.belt, 'step', l.belt_step, 'next_stop_at', l.next_stop_at, 'who', l.next_stop_who, 'say', l.next_stop_say),
    'named_date', l.named_date, 'named_event', l.named_event, 'say_next', l.say_next)), '[]'::jsonb)
    from public.leads l join ids on ids.id = l.id
$$;
revoke all on function public.agent_store_cadence(uuid[]) from public, anon, authenticated;
grant execute on function public.agent_store_cadence(uuid[]) to service_role;

-- agent_ready_to_text restated from the live body: p_all (the door's all_sources) was accepted and never read, so the
-- agent's new-card pool was always its own and the handed cards. With p_all the pool is every card in opener_queued or
-- postcard_mailed with a textable mobile and nothing sent or planned (7,150 cards on 2026-11-08 against 512); the
-- stacked-first order is unchanged, each card says laptop_card. Follow-ups and next_numbers are unchanged: a laptop
-- card's follow-ups stay the laptop's until Colin moves them. Every refusal in agent_queue_text still applies.
create or replace function public.agent_ready_to_text(p_limit integer, p_followups boolean, p_all boolean, p_now timestamp with time zone DEFAULT now())
returns jsonb language sql stable security definer set search_path = public as $$
  with handed as (
    select distinct on (p.lead_id, p.step) p.lead_id, p.step, p.body as laptop_text, right(p.phone, 10) as laptop_phone, p.plan_date
      from public.planned_openers p
     where p.lane <> 'agent' and p.send_reason = 'handed to the sender agent' and p.send_status = 'withdrawn'
       and p.plan_date >= ((p_now at time zone 'America/Chicago')::date - 7)
     order by p.lead_id, p.step, p.plan_date desc),
  new_cards as (
    select l.id, 1 as step, h.laptop_text, h.laptop_phone, coalesce(h.plan_date, l.created_at::date) as since,
           cardinality(l.reasons_to_sell) as nreasons, l.stacked_at, l.wpie_owner_id > 0 as laptop_card from public.leads l
      left join handed h on h.lead_id = l.id and h.step = 1
     where l.stage in ('opener_queued', 'postcard_mailed')
       -- p_all (the door's all_sources): the whole store, not only agent-loaded or handed cards (Colin 2026-11-08, Muse 143/144)
       and (p_all or l.wpie_owner_id < 0 or h.lead_id is not null)
       and not exists (select 1 from public.planned_openers po where po.lead_id = l.id and po.step = 1
                        and po.send_status in ('planned', 'would_send', 'sending', 'sent', 'delivered'))
       and not exists (select 1 from public.messages m where m.lead_id = l.id and m.direction = 'out' and m.channel = 'sms')
       and exists (select 1 from public.contacts c where c.lead_id = l.id and c.kind = 'phone' and c.status = 'ok' and not c.dnc_app
                    and not c.suppressed and not c.dnc_vendor and c.dnc_scrub <> 'dnc' and public.agent_phone_ok(c.value_normalized, c.line_type))
     -- stacked cards first (Muse 2026-10-28: "moving them up is the point of stacking"): most reasons, then the
     -- latest stacked, then the oldest waiting
     order by (cardinality(l.reasons_to_sell) > 1) desc, cardinality(l.reasons_to_sell) desc, l.stacked_at desc nulls last, since, l.created_at
     limit greatest(1, least(p_limit, 300))),
  first_text as (
    -- the latest first text that was not a bounce: the phone this thread runs on
    select distinct on (m.lead_id) m.lead_id, right(regexp_replace(m.to_number, '\D', '', 'g'), 10) as phone, m.sent_at as first_at
      from public.messages m join public.leads l on l.id = m.lead_id
     where p_followups and l.stage = 'opener_sent' and m.direction = 'out' and m.channel = 'sms' and m.is_opener
       and m.provider_sid is not null and coalesce(m.status, '') not in ('undelivered', 'failed')
     order by m.lead_id, m.sent_at desc),
  thread as (
    select f.lead_id, f.phone, f.first_at, count(m.*)::int as n, max(m.sent_at) as last_at
      from first_text f join public.messages m on m.lead_id = f.lead_id and m.direction = 'out' and m.channel = 'sms'
       and m.provider_sid is not null and right(regexp_replace(m.to_number, '\D', '', 'g'), 10) = f.phone and m.sent_at >= f.first_at
     group by 1, 2, 3),
  due as (
    select t.lead_id, t.phone, t.n + 1 as step, t.last_at,
           (t.first_at at time zone 'America/Chicago')::date + (case t.n + 1 when 2 then 2 when 3 then 9 when 4 then 16 else 23 end) as due_day
      from thread t where t.n between 1 and 4),
  follow as (
    select d.lead_id as id, d.step, d.phone,
           case when extract(isodow from d.due_day) = 7 then d.due_day + 1 else d.due_day end as due_day,
           h.laptop_text, h.laptop_phone, cardinality(l.reasons_to_sell) as nreasons, l.stacked_at
      from due d join public.leads l on l.id = d.lead_id
      left join handed h on h.lead_id = d.lead_id and h.step = d.step
     where (case when extract(isodow from d.due_day) = 7 then d.due_day + 1 else d.due_day end) <= (p_now at time zone 'America/Chicago')::date
       and d.last_at < p_now - interval '1 day'
       and not coalesce(l.elderly_or_ill, false) and not coalesce(l.grief, false) and l.human_takeover_at is null
       -- they wrote back, from any phone on the card (or a phone that belongs to it)
       and not exists (select 1 from public.twilio_inbound ti where ti.lead_id = l.id
                         or ti.from10 in (select c.value_normalized from public.contacts c where c.lead_id = l.id and c.kind = 'phone'))
       and not exists (select 1 from public.messages m where m.lead_id = l.id and m.direction = 'in' and m.channel = 'sms')
       -- a call that REACHED them ends the texting; a dial nobody answered does not (call first, text the no-answers)
       and not exists (select 1 from public.messages m where m.lead_id = l.id and m.channel = 'call'
                         and coalesce(m.status, '') not in ('no_answer', 'voicemail', 'inbound_missed', 'missed', 'busy', 'failed', 'canceled', 'blocked'))
       and not exists (select 1 from public.suppressed_phones s where s.phone10 = d.phone)
       and exists (select 1 from public.contacts c where c.lead_id = l.id and c.kind = 'phone' and c.value_normalized = d.phone and c.status = 'ok'
                    and not c.dnc_app and not c.suppressed and not c.dnc_vendor and c.dnc_scrub <> 'dnc')
       and public.phone_person_block(d.phone) is null
       and not exists (select 1 from public.planned_openers po where po.lead_id = l.id and po.send_status in ('planned', 'would_send', 'sending'))),
  -- the owner's next number (Colin 2026-10-28: "one of the other numbers might be right ... try the other numbers"): a
  -- card whose texted number turned out to be someone else's (data_fix), with a usable mobile the next-phone rule (0079)
  -- allows a first text to; the one listed first on the card goes first
  next_numbers as (
    select l.id, ph.value_normalized as phone, cardinality(l.reasons_to_sell) as nreasons, l.stacked_at
      from public.leads l
      cross join lateral (
        select c.value_normalized from public.contacts c
         where c.lead_id = l.id and c.kind = 'phone' and c.status = 'ok' and not c.dnc_app and not c.suppressed and not c.dnc_vendor
           and c.dnc_scrub <> 'dnc' and public.agent_phone_ok(c.value_normalized, c.line_type)
           and public.phone_person_block(c.value_normalized) is null
           and public.next_phone_problem(l.id, c.value_normalized) is null
         order by c.created_at, c.value_normalized limit 1) ph
     where l.stage = 'data_fix' and not coalesce(l.elderly_or_ill, false) and not coalesce(l.grief, false) and l.human_takeover_at is null
       and not exists (select 1 from public.planned_openers po where po.lead_id = l.id and po.send_status in ('planned', 'would_send', 'sending'))
     order by (cardinality(l.reasons_to_sell) > 1) desc, cardinality(l.reasons_to_sell) desc, l.updated_at
     limit greatest(1, least(p_limit, 300))),
  shown as (select * from follow order by (nreasons > 1) desc, nreasons desc, stacked_at desc nulls last, due_day, id limit greatest(1, least(p_limit, 300)))
  select jsonb_build_object(
    'new_cards', (select coalesce(jsonb_agg(public.agent_card(id) || jsonb_build_object('next_step', step, 'laptop_text', laptop_text,
                    'laptop_phone', laptop_phone, 'reasons_count', nreasons, 'stacked_at', stacked_at, 'laptop_card', laptop_card)
                    order by (nreasons > 1) desc, nreasons desc, stacked_at desc nulls last, since), '[]'::jsonb) from new_cards),
    'followups_due', (select coalesce(jsonb_agg(public.agent_card(id) || jsonb_build_object('next_step', step, 'due_since', due_day,
                    'phone', phone, 'laptop_text', laptop_text, 'laptop_phone', laptop_phone, 'reasons_count', nreasons, 'stacked_at', stacked_at)
                    order by (nreasons > 1) desc, nreasons desc, stacked_at desc nulls last, due_day), '[]'::jsonb) from shown),
    'next_numbers', (select coalesce(jsonb_agg(public.agent_card(id) || jsonb_build_object('next_step', 1, 'phone', phone,
                    'why', 'the number we texted reached someone else; this is the owner''s next number', 'reasons_count', nreasons)
                    order by (nreasons > 1) desc, nreasons desc), '[]'::jsonb) from next_numbers),
    'followups_due_total', (select count(*) from follow),
    'followups_due_by_step', (select coalesce(jsonb_object_agg(step, n), '{}'::jsonb) from (select step, count(*) n from follow group by step) x))
$$;
