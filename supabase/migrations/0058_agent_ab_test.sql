-- A/B testing the sender agent's texts (Colin 2026-10-26: "we should be testing performance on two messages"). Each
-- queued text can carry a variant (A, B, ...) and a template name; test_results reports per variant: queued, sent,
-- delivered, failed (with carrier codes), real replies, STOPs and wrong numbers, so the two versions are compared on
-- the same days, numbers and lists.

drop function if exists public.agent_queue_text(uuid, text, text, integer, timestamptz, text, timestamptz);

create or replace function public.agent_queue_text(p_lead_id uuid, p_phone text, p_body text, p_step integer,
  p_send_after timestamptz, p_agent text, p_now timestamptz default now(), p_variant text default null, p_template text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c     public.campaign_control;
  l     public.leads;
  num   text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10);
  tz    text;
  t     timestamptz;
  d     date;
  ws    timestamptz;
  we    timestamptz;
  i     integer;
  att   integer := case when coalesce(p_step, 1) = 1 then 1 else 10 + p_step end;
  v_id  uuid;
  b     text := btrim(coalesce(p_body, ''));
  v     text := nullif(upper(left(btrim(coalesce(p_variant, '')), 20)), '');
begin
  select * into c from public.campaign_control where id = 1;
  select * into l from public.leads where leads.id = p_lead_id;
  if not found then return jsonb_build_object('status', 'refused', 'reason', 'no such card'); end if;
  if coalesce(p_step, 1) not between 1 and 5 then return jsonb_build_object('status', 'refused', 'reason', 'step is 1 to 5'); end if;
  if l.stage in ('dnc', 'dead', 'closed_no_contact', 'closed_won', 'under_contract') then
    return jsonb_build_object('status', 'refused', 'reason', 'card is closed (' || l.stage::text || ')');
  end if;
  if coalesce(p_step, 1) = 1 and l.stage not in ('postcard_mailed', 'opener_queued') then
    return jsonb_build_object('status', 'refused', 'reason', 'already texted or talking (' || l.stage::text || '): a first text is for a new card');
  end if;
  if not exists (select 1 from public.contacts ct where ct.lead_id = p_lead_id and ct.kind = 'phone' and ct.value_normalized = num
                  and ct.status = 'ok' and not ct.dnc_app and not ct.suppressed and not ct.dnc_vendor and ct.dnc_scrub <> 'dnc') then
    return jsonb_build_object('status', 'refused', 'reason', 'that phone is not a usable phone on this card');
  end if;
  if exists (select 1 from public.suppressed_phones s where s.phone10 = num) then
    return jsonb_build_object('status', 'refused', 'reason', 'this phone opted out');
  end if;
  if exists (select 1 from public.twilio_inbound ti where ti.from10 = num) then
    return jsonb_build_object('status', 'refused', 'reason', 'they already texted back: replies go to the reply agent and the team');
  end if;
  if b = '' or position('STOP' in b) = 0 then return jsonb_build_object('status', 'refused', 'reason', 'the text needs a STOP line'); end if;
  if position('$' in b) > 0 then return jsonb_build_object('status', 'refused', 'reason', 'no prices or $ in a text'); end if;
  if length(b) > 320 then return jsonb_build_object('status', 'refused', 'reason', 'over 320 characters'); end if;
  if exists (select 1 from unnest(c.banned_words) w where w <> '' and position(lower(w) in lower(b)) > 0) then
    return jsonb_build_object('status', 'refused', 'reason', 'names the business');
  end if;
  if exists (select 1 from public.planned_openers po where po.lead_id = p_lead_id and po.step = coalesce(p_step, 1)
              and po.send_status in ('planned', 'would_send', 'sending')) then
    return jsonb_build_object('status', 'refused', 'reason', 'a text for this step is already waiting: withdraw it first');
  end if;
  tz := public.agent_tz(coalesce(l.mailing_state, 'WI'));
  t := greatest(p_now, coalesce(p_send_after, p_now));
  for i in 0..8 loop
    d := ((t at time zone tz)::date) + i;
    if c.no_sundays and extract(isodow from d) = 7 then continue; end if;
    ws := (d + c.window_start) at time zone tz;
    we := (d + c.window_end) at time zone tz;
    if we > t then t := greatest(t, ws); exit; end if;
  end loop;
  insert into public.planned_openers (plan_date, wpie_owner_id, attempt, lead_id, lane, template_lane, variant, phone, body,
         segments, scheduled_at, owner_name, property_address, decision, decided_by_name, decided_at, decision_note,
         send_status, window_start_utc, window_end_utc, governing_state, dnc_state, body_sha256, plan_created_at, step)
  values ((t at time zone c.timezone)::date, l.wpie_owner_id, att, l.id, 'agent', coalesce(nullif(left(btrim(coalesce(p_template, '')), 40), ''), 'agent'),
          coalesce(v, '-'), '+1' || num, b, case when length(b) <= 160 then 1 else 2 end, t, l.owner_name, l.property_address,
          'approved', 'Muse (' || coalesce(p_agent, 'agent') || ')', p_now, 'written and queued by the sender agent',
          'planned', ws, we, upper(coalesce(l.mailing_state, 'WI')), 'unknown', encode(sha256(convert_to(b, 'UTF8')), 'hex'), p_now,
          coalesce(p_step, 1))
  on conflict (plan_date, wpie_owner_id, attempt) do nothing
  returning planned_openers.id into v_id;
  if v_id is null then return jsonb_build_object('status', 'refused', 'reason', 'this card already has that text planned for that day'); end if;
  return jsonb_build_object('status', 'queued', 'text_id', v_id, 'goes_after', t, 'window_ends', we, 'variant', coalesce(v, '-'));
end $$;

-- per variant: the agent's texts over the last N days, and what came back from each phone after its text
create or replace function public.agent_test_results(p_days integer default 14, p_step integer default 1)
returns jsonb language sql stable security definer set search_path = public as $$
  with s as (
    select p.variant, p.template_lane, p.send_status, p.error_code, right(p.phone, 10) ph,
           coalesce(p.sent_at, p.claimed_at) at
      from public.planned_openers p
     where p.lane = 'agent' and p.step = coalesce(p_step, 1) and p.created_at > now() - make_interval(days => greatest(1, least(p_days, 90)))),
  r as (
    select s.*,
      exists (select 1 from public.twilio_inbound t where t.from10 = s.ph and s.at is not null and t.received_at > s.at and not t.is_opt_out) as replied,
      exists (select 1 from public.twilio_inbound t where t.from10 = s.ph and s.at is not null and t.received_at > s.at and t.is_opt_out) as stopped,
      exists (select 1 from public.reply_drafts d where d.phone10 = s.ph and s.at is not null and d.inbound_at > s.at
                and (d.intent = 'wrong_number' or d.outcome = 'wrong_number')) as wrong
      from s)
  select jsonb_build_object('days', p_days, 'step', coalesce(p_step, 1), 'variants', coalesce(jsonb_agg(v order by v->>'variant'), '[]'::jsonb))
    from (select jsonb_build_object(
            'variant', variant,
            'templates', array_agg(distinct template_lane),
            'queued', count(*),
            'sent', count(*) filter (where send_status in ('sent', 'delivered', 'undelivered', 'failed')),
            'delivered', count(*) filter (where send_status = 'delivered'),
            'undelivered', count(*) filter (where send_status in ('undelivered', 'failed')),
            'filtered_30007', count(*) filter (where error_code = '30007'),
            'replied', count(*) filter (where replied),
            'stops', count(*) filter (where stopped),
            'wrong_numbers', count(*) filter (where wrong),
            'conversations', count(*) filter (where replied and not stopped and not wrong),
            'reply_rate', round(100.0 * count(*) filter (where replied and not stopped and not wrong) / nullif(count(*) filter (where send_status = 'delivered'), 0), 1),
            'stop_rate', round(100.0 * count(*) filter (where stopped) / nullif(count(*) filter (where send_status = 'delivered'), 0), 1)) v
            from r group by variant) x
$$;

revoke all on function public.agent_queue_text(uuid, text, text, integer, timestamptz, text, timestamptz, text, text),
  public.agent_test_results(integer, integer) from public, anon, authenticated;
grant execute on function public.agent_queue_text(uuid, text, text, integer, timestamptz, text, timestamptz, text, text),
  public.agent_test_results(integer, integer) to service_role;
