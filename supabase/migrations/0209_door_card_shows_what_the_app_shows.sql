-- 0209: the door's card carries what the app's "Why this card" shows (Muse desk post 152, 2026-11-08, the Perl Rentals
-- card on E Parkway Ave: find_prospects returned reasons ['behind on taxes'] and reason_details null while the caller app
-- showed "Back taxes: 3 years delinquent, $16,593", the equity line and the value on record). The app draws
-- lead_motivation.lines; the door's reason_details is prospect_reasons, rows only about half the cards have. agent_card
-- (find_prospects) now carries motivation and equity exactly as store_cards does (0208), plus value_on_record.
-- Also contact_add (a number the seller gave on a call, now one tap on the Power hour card for Adil 2026-11-08) records
-- the team display name (Tyler) instead of the login key, as log_call does.

create or replace function public.agent_card(p_lead uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select jsonb_build_object(
    'lead_id', l.id, 'owner_name', l.owner_name, 'owner_type', l.owner_type,
    'address', l.property_address, 'city', l.municipality, 'county', l.county, 'zip', l.property_zip,
    'property', jsonb_build_object('type', l.property_type, 'units', l.units, 'parcel', l.parcel_id, 'lane', l.lane, 'score', l.score),
    'mailing', jsonb_build_object('street', l.mailing_street, 'city', l.mailing_city, 'state', l.mailing_state, 'zip', l.mailing_zip),
    'mailing_state', l.mailing_state,
    'stage', l.stage, 'belt', l.belt, 'next_step', l.next_stop_say, 'next_step_at', l.next_stop_at,
    'check_back_at', l.next_action_at, 'named_date', l.named_date, 'named_event', l.named_event,
    'elderly_or_ill', l.elderly_or_ill, 'grief', l.grief, 'notes', l.notes,
    'source', coalesce(l.source, case when l.wpie_owner_id > 0 then 'laptop' end),
    'reasons', l.reasons_to_sell,
    'reason_details', (select jsonb_agg(jsonb_build_object('kind', r.kind, 'detail', r.detail, 'date', r.event_date, 'amount', r.amount, 'source', r.source))
                         from public.prospect_reasons r where r.lead_id = l.id),
    -- what the app's "Why this card" shows (0209, Muse desk post 152): the laptop's motivation lines and the equity inputs
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
    'value_on_record', (select e.value_used from public.equity_inputs e where e.lead_id = l.id),
    'phones', (select jsonb_agg(jsonb_build_object('phone', c.value_normalized, 'type', c.line_type, 'name', c.person_name,
                      'textable', c.status = 'ok' and not c.dnc_app and not c.suppressed and not c.dnc_vendor and c.dnc_scrub <> 'dnc'
                                  and public.agent_phone_ok(c.value_normalized, c.line_type),
                      'also_on', (select jsonb_agg(jsonb_build_object('lead_id', c2.lead_id, 'owner_name', l2.owner_name, 'address', l2.property_address))
                                    from public.contacts c2 join public.leads l2 on l2.id = c2.lead_id
                                   where c2.value_normalized = c.value_normalized and c2.lead_id <> l.id)))
                 from public.contacts c where c.lead_id = l.id and c.kind = 'phone'),
    'people', public.card_interests(l.id),
    'links', public.card_links(l.id),
    'contracts', public.card_contracts(l.id),
    'conversation', (select jsonb_agg(x order by x->>'at') from (
        select jsonb_build_object('at', m.sent_at, 'who', case when m.direction = 'out' then 'us' else 'them' end,
                 'phone', case when m.direction = 'out' then m.to_number else m.from_number end,
                 'our_number', case when m.direction = 'out' then m.from_number else m.to_number end, 'text', m.body, 'status', m.status) x
          from public.messages m where m.lead_id = l.id and m.channel = 'sms'
        union all
        select jsonb_build_object('at', t.received_at, 'who', 'them', 'phone', t.from10, 'our_number', t.to_number, 'text', t.body,
                 'stop', t.is_opt_out)
          from public.twilio_inbound t where t.lead_id = l.id
           and not exists (select 1 from public.messages m2 where m2.lead_id = l.id and m2.direction = 'in' and m2.provider_sid = t.sid)) q),
    'calls', (select jsonb_agg(jsonb_build_object('at', m.sent_at, 'outcome', m.status, 'note', m.body) order by m.sent_at)
                from public.messages m where m.lead_id = l.id and m.channel = 'call'),
    'call_notes', public.card_call_notes(l.id),
    'call_facts', l.call_facts,
    'what_we_know', coalesce((select jsonb_object_agg(k, v) from (
                 select distinct on (e.key) e.key as k, e.value as v
                   from public.reply_drafts d, jsonb_each(d.facts) e
                  where d.lead_id = l.id and d.facts is not null and jsonb_typeof(d.facts) = 'object'
                  order by e.key, d.inbound_at desc) f), '{}'::jsonb),
    'replied', exists (select 1 from public.twilio_inbound t where t.lead_id = l.id),
    'waiting', (select jsonb_agg(jsonb_build_object('text_id', p.id, 'step', p.step, 'goes_after', p.scheduled_at, 'status', p.send_status))
                  from public.planned_openers p where p.lead_id = l.id and p.send_status in ('planned', 'would_send', 'sending')))
  from public.leads l where l.id = p_lead
$function$
;

create or replace function public.contact_add(p_lead_id uuid, p_kind text, p_value text, p_person_name text DEFAULT NULL::text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v text; norm text; cid uuid; who text;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  -- the name the team knows (Tyler), not the login key (0209); log_call does the same
  select display_name into who from public.team_members where lower(email) = lower(auth.jwt() ->> 'email');
  who := coalesce(who, public.wpie_person()::text, 'team');
  if p_kind = 'phone' then
    norm := right(regexp_replace(coalesce(p_value, ''), '\D', '', 'g'), 10);
    if length(norm) <> 10 then return jsonb_build_object('ok', false, 'reason', 'a phone needs 10 digits'); end if;
    v := norm;
  elsif p_kind = 'email' then
    v := lower(btrim(coalesce(p_value, '')));
    if v !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then return jsonb_build_object('ok', false, 'reason', 'that is not an email address'); end if;
    norm := v;
  else
    return jsonb_build_object('ok', false, 'reason', 'phone or email');
  end if;
  if exists (select 1 from public.contacts c where c.lead_id = p_lead_id and c.kind = p_kind::public.contact_kind and coalesce(c.value_normalized, c.value) = norm) then
    return jsonb_build_object('ok', false, 'reason', 'already on the card');
  end if;
  insert into public.contacts (lead_id, kind, value, value_normalized, person_name, source, status, note, created_at, updated_at)
  values (p_lead_id, p_kind::public.contact_kind, v, norm, nullif(btrim(p_person_name), ''), 'added by ' || initcap(who), 'ok',
          concat_ws(' | ', nullif(btrim(p_note), ''), to_char(now() at time zone 'America/Chicago', 'YYYY-MM-DD') || ' added by ' || initcap(who)), now(), now())
  returning id into cid;
  return jsonb_build_object('ok', true, 'id', cid);
end $function$
;
