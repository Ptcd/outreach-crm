-- 0286: live work says what is true. On the first real card a caller asked for (74 Pioneer Ct, 2026-11-22) Grok's
-- notice read "1 seller said yes and is waiting on you". The seller had said nothing: a caller asked for the comps.

CREATE OR REPLACE FUNCTION public.agent_live_work(p_now timestamp with time zone DEFAULT now(), p_who text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare cards jsonb; n integer; n_late integer; body text;
begin
  with y as (
    select o.lead_id, o.opened_at, o.trigger_text, public.text_offer_view(o, p_now) as v
      from public.text_offers o where o.status = 'open' and o.trigger in ('yes_to_selling', 'caller_asked')
  ), w as (
    select l.id as lead_id, l.owner_name, l.property_address, l.municipality, l.county,
           coalesce(y.opened_at, b.wanted_at) as since, y.trigger_text,
           case when y.v->>'who' = 'muse' and y.v->>'step' in ('comp', 'call_prices') then y.v end as step,
           coalesce(b.status = 'wanted', false) as brief_wanted, b.due_at as brief_due,
           case when b.claimed_at > p_now - interval '45 minutes' then b.claimed_by end as claimed_by,
           public.card_asked_for_grok(l.id) as asked
      from public.leads l
      left join y on y.lead_id = l.id
      left join public.call_briefs b on b.lead_id = l.id
     where not public.card_is_closed(l.stage) and l.stage::text <> 'under_contract'
  ), t as (
    select w.*, (w.step is not null and coalesce((w.step->>'late')::boolean, false)) or (w.brief_wanted and w.brief_due < p_now) as late
      from w where (w.step is not null or w.brief_wanted)
       -- 0283: a card a caller asked for from its button is Grok's alone (Colin 2026-11-22)
       and not (w.asked and lower(coalesce(p_who, '')) like 'muse%')
  )
  select coalesce(jsonb_agg(jsonb_build_object('lead_id', t.lead_id, 'owner_name', t.owner_name, 'address', t.property_address, 'city', t.municipality,
           'county', t.county, 'caller', public.room_name(public.card_caller(t.lead_id)::text), 'said_yes_at', t.since, 'their_words', left(t.trigger_text, 300), 'late', t.late, 'claimed_by', t.claimed_by,
           'todo', (case when t.step is null then '[]'::jsonb
                         else jsonb_build_array(jsonb_build_object('what', t.step->>'step', 'due_at', t.step->>'due_at', 'late', (t.step->>'late')::boolean, 'do', t.step->>'say')) end)
                || (case when t.step->>'step' = 'comp'
                         then jsonb_build_array(jsonb_build_object('what', 'call_prices', 'do', 'Right after the comp: the street look and your prices (packet, part 2).')) else '[]'::jsonb end)
                || (case when not t.brief_wanted then '[]'::jsonb
                         else jsonb_build_array(jsonb_build_object('what', 'brief', 'due_at', t.brief_due, 'late', coalesce(t.brief_due < p_now, false),
                                'do', 'The story, what is owed, the unknowns and the script: call_briefs_wanted has this card''s records, then call_brief_set.')) end))
           order by t.since desc nulls last), '[]'::jsonb), count(*), count(*) filter (where t.late)
    into cards, n, n_late
    from (select * from t order by since desc nulls last limit 15) t;
  if n = 0 then
    return jsonb_build_object('live', 0, 'say', 'Nothing live: no card is waiting on you. Carry on with this run.');
  end if;
  select p.body into body from public.live_work_packet p where p.id = 1;
  return jsonb_build_object('live', n, 'late', n_late,
    'say', n::text || case when n = 1 then ' card is' else ' cards are' end || ' waiting on you'
           || case when n_late > 0 then ' (' || n_late::text || ' late)' else '' end
           || ': a seller said yes, or a caller asked for comps from the card. A caller cannot give a number until you are done. '
           || 'Call live_work, read the packet, and work the cards before anything else in this run, the newest first.',
    'packet', body, 'cards', cards);
end $function$;
