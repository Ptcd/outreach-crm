-- 0197: three things from the evening of 2026-11-07.
--
-- 1. A caller's thread is the caller's. Adil texted PERL RENTALS from the card and Muse (the sender agent) kept
--    answering on the same thread, two voices on one phone ("Boss can you turn off the ai, it's ruining the
--    conversation"). From now on: once a team member has sent a text on a card's thread, the sender agent stays off
--    that thread for seven days (a new caller text restarts the week). agent_start_reply refuses, agent_replies_waiting
--    leaves the thread out. Muse still answers threads nobody on the team has touched.
--
-- 2. sale_history_agent + agent_sale_add: Muse loads parcel-keyed sale history (last sale date and price, from an
--    assessor record card, WIREX or a DOR transfer record it read in a browser) so the laptop's equity grade has
--    tenure where the store holds none (desk post 130: the store has a sale date for 1 card in 5). The laptop pulls
--    the rows into `sale` events through collector wi.assessor.sales_agent; never an estimate, never a Zestimate.
--
-- 3. equity_inputs + agent_equity_inputs: the full-store equity export, one row per card with every input the laptop
--    used and the grade it gave, pushed nightly, paged through the door so Muse can read it (there is no file channel).

-- 1 ---------------------------------------------------------------------------------------------------------------
create or replace function public.caller_texting(p_lead_id uuid, p_phone10 text) returns text
language sql stable security definer set search_path = public as $$
  select d.decided_by from public.reply_drafts d
   where d.lead_id = p_lead_id and d.phone10 = p_phone10 and d.draft_source = 'team' and d.status = 'sent'
     and d.sent_at > now() - interval '7 days'
   order by d.sent_at desc limit 1
$$;
revoke all on function public.caller_texting(uuid, text) from public, anon;
grant execute on function public.caller_texting(uuid, text) to authenticated, service_role;

create or replace function public.agent_start_reply(p_lead_id uuid, p_phone text, p_agent text) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  l public.leads;
  p text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10);
  li public.twilio_inbound;
  id uuid;
  who text;
begin
  select * into l from public.leads where leads.id = p_lead_id;
  if not found then raise exception 'no such card'; end if;
  if l.stage = 'dnc' then raise exception 'this card is closed (do not contact)'; end if;
  if exists (select 1 from public.suppressed_phones s where s.phone10 = p) then raise exception 'this phone opted out'; end if;
  who := public.caller_texting(p_lead_id, p);
  if who is not null then
    raise exception '% is texting this card themselves (within the last 7 days): the thread is theirs, leave it to them', who;
  end if;
  select * into li from public.twilio_inbound t where t.from10 = p and t.lead_id = p_lead_id order by t.received_at desc limit 1;
  if not found then raise exception 'they have not texted us from that phone: a first text or follow-up goes through queue_texts'; end if;
  insert into public.reply_drafts (phone10, our_number, lead_id, inbound_body, inbound_at, intent, kind, outcome, note, draft_source, status, notified_at)
  values (p, li.to_number, p_lead_id, li.body, now(), 'agent_reply', 'team', 'open', 'written by the sender agent (' || coalesce(p_agent, 'agent') || ')',
          'agent', 'awaiting_approval', now())
  returning reply_drafts.id into id;
  return id;
end $$;

create or replace function public.agent_replies_waiting(p_days integer default 7) returns jsonb
language sql stable security definer set search_path = public as $$
  with last_in as (
    select distinct on (t.from10) t.from10, t.lead_id, t.sid, t.body, t.received_at, t.to_number
      from public.twilio_inbound t
     where t.received_at > now() - make_interval(days => greatest(1, least(p_days, 30))) and t.lead_id is not null
     order by t.from10, t.received_at desc)
  select coalesce(jsonb_agg(public.agent_card(li.lead_id) || jsonb_build_object(
           'reply_to', jsonb_build_object('phone', li.from10, 'our_number', li.to_number, 'text', li.body, 'at', li.received_at),
           'reply_agent_read', (select jsonb_build_object('intent', d.intent, 'outcome', d.outcome, 'suggested_reply', d.body, 'note', d.note)
                                  from public.reply_drafts d where d.inbound_sid = li.sid),
           'hot', exists (select 1 from public.hot_alerts h where h.lead_id = li.lead_id and h.created_at > now() - interval '3 days'))
         order by li.received_at), '[]'::jsonb)
    from last_in li join public.leads l on l.id = li.lead_id
   where l.stage not in ('dnc', 'dead', 'closed_no_contact', 'closed_won')
     and not exists (select 1 from public.suppressed_phones s where s.phone10 = li.from10)
     and public.caller_texting(li.lead_id, li.from10) is null           -- a caller's thread is the caller's
     and not exists (select 1 from public.messages m where m.direction = 'out' and m.channel = 'sms' and m.sent_at > li.received_at
                      and right(regexp_replace(coalesce(m.to_number, ''), '\D', '', 'g'), 10) = li.from10)
     and not exists (select 1 from public.reply_drafts d where d.phone10 = li.from10 and d.inbound_at >= li.received_at
                      and d.status in ('queued', 'sending', 'sent'))
$$;
revoke all on function public.agent_replies_waiting(integer), public.agent_start_reply(uuid, text, text) from public, anon, authenticated;
grant execute on function public.agent_replies_waiting(integer), public.agent_start_reply(uuid, text, text) to service_role;

-- 2 ---------------------------------------------------------------------------------------------------------------
create table if not exists public.sale_history_agent (
  id bigserial primary key,
  wpie_property_id integer,
  lead_id uuid references public.leads(id) on delete set null,
  parcel_id text not null,
  county text not null,
  sale_date date not null,
  sale_price numeric,                                 -- null when the record shows the date only
  source text not null,                               -- assessor record card | WIREX | DOR transfer return | register of deeds | ...
  source_url text not null,
  notes text,
  agent text,
  created_at timestamptz not null default now(),
  pulled_at timestamptz,                              -- the laptop took it into a sale event
  unique (county, parcel_id, sale_date)
);
create index if not exists sale_history_agent_pull_idx on public.sale_history_agent (created_at) where pulled_at is null;
alter table public.sale_history_agent enable row level security;
drop policy if exists sale_history_agent_team_read on public.sale_history_agent;
create policy sale_history_agent_team_read on public.sale_history_agent for select to authenticated using (public.is_team());
grant select on public.sale_history_agent to authenticated;

-- p = {sales: [{parcel_id, county, sale_date, sale_price, source, source_url, notes, wpie_property_id, lead_id}]}
create or replace function public.agent_sale_add(p jsonb, p_agent text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s jsonb; n integer := 0; added integer := 0; bad text; sales jsonb := coalesce(p->'sales', '[]'::jsonb);
begin
  if jsonb_typeof(sales) <> 'array' or jsonb_array_length(sales) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'sales must be a non-empty list');
  end if;
  if jsonb_array_length(sales) > 200 then return jsonb_build_object('ok', false, 'reason', 'at most 200 sales per call'); end if;
  for s in select * from jsonb_array_elements(sales) loop
    n := n + 1;
    if coalesce(s->>'parcel_id', '') = '' or coalesce(s->>'county', '') = '' then bad := format('sale %s: parcel_id and county are required', n); exit; end if;
    if coalesce(s->>'sale_date', '') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then bad := format('sale %s: sale_date is YYYY-MM-DD', n); exit; end if;
    if (s->>'sale_date')::date > current_date then bad := format('sale %s: sale_date is in the future', n); exit; end if;
    if s ? 'sale_price' and s->>'sale_price' is not null and (s->>'sale_price') !~ '^[0-9]+(\.[0-9]+)?$' then
      bad := format('sale %s: sale_price is digits only, no $ or commas (leave it out when the record shows no price)', n); exit;
    end if;
    if coalesce(s->>'source', '') = '' or coalesce(s->>'source_url', '') = '' then bad := format('sale %s: source and source_url are required', n); exit; end if;
    if s->>'source' ~* 'estimat|zestimat|zillow|redfin|avm|model|guess' or coalesce(s->>'notes', '') ~* 'zestimat|estimated (sale|price)' then
      bad := format('sale %s: a sale is a recorded transfer (assessor record, WIREX, DOR return, deed index), never an estimate', n); exit;
    end if;
  end loop;
  if bad is not null then return jsonb_build_object('ok', false, 'reason', bad); end if;
  for s in select * from jsonb_array_elements(sales) loop
    insert into public.sale_history_agent (wpie_property_id, lead_id, parcel_id, county, sale_date, sale_price, source, source_url, notes, agent)
    values (nullif(s->>'wpie_property_id', '')::integer, nullif(s->>'lead_id', '')::uuid, trim(s->>'parcel_id'), trim(s->>'county'),
            (s->>'sale_date')::date, nullif(s->>'sale_price', '')::numeric, trim(s->>'source'), trim(s->>'source_url'), s->>'notes', p_agent)
    on conflict (county, parcel_id, sale_date) do update
      set sale_price = coalesce(excluded.sale_price, sale_history_agent.sale_price), source = excluded.source, source_url = excluded.source_url,
          notes = coalesce(excluded.notes, sale_history_agent.notes), wpie_property_id = coalesce(excluded.wpie_property_id, sale_history_agent.wpie_property_id),
          lead_id = coalesce(excluded.lead_id, sale_history_agent.lead_id), agent = p_agent, pulled_at = null;
    added := added + 1;
  end loop;
  return jsonb_build_object('ok', true, 'sales', added,
                            'note', 'the laptop pulls these within ten minutes; the equity grade and the card''s Equity line update on the next refresh');
end $$;
revoke all on function public.agent_sale_add(jsonb, text) from public, anon, authenticated;
grant execute on function public.agent_sale_add(jsonb, text) to service_role;

-- 3 ---------------------------------------------------------------------------------------------------------------
create table if not exists public.equity_inputs (
  lead_id uuid primary key references public.leads(id) on delete cascade,
  wpie_owner_id integer, wpie_property_id integer, parcel_id text,
  owner_name text, owner_type text, property_address text, municipality text, county text, stage text, locked_to text,
  property_class text, units integer,
  assessed_total numeric, est_market_value numeric, value_used numeric, value_source text,
  last_sale_date date, last_sale_price numeric, sale_source text, tenure_from date, tenure_source text,
  tax_years_behind integer, tax_owed numeric, judgment_amount numeric, in_rem_amount numeric,
  mortgage_balance_est numeric, assumed_loan_balance_est numeric, mortgage_source text,
  debt_total numeric, equity numeric, equity_share numeric,
  equity_grade text not null default 'unknown', estimated boolean, equity_line text, basis text, caveats text,
  tier text, families text, reasons_to_sell text,
  pushed_at timestamptz not null default now()
);
create index if not exists equity_inputs_grade_idx on public.equity_inputs (equity_grade, county);
alter table public.equity_inputs enable row level security;
drop policy if exists equity_inputs_team_read on public.equity_inputs;
create policy equity_inputs_team_read on public.equity_inputs for select to authenticated using (public.is_team());
grant select on public.equity_inputs to authenticated;

create or replace function public.agent_equity_inputs(p_after text default null, p_limit integer default 200, p_county text default null,
                                                      p_grade text default null, p_counts_only boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare counts jsonb; rows jsonb; last_id text; lim integer := greatest(1, least(coalesce(p_limit, 200), 500));
begin
  select jsonb_build_object(
           'cards', count(*),
           'by_grade', (select coalesce(jsonb_object_agg(g, n), '{}'::jsonb) from (select e.equity_grade g, count(*) n from public.equity_inputs e group by 1) x),
           'with_sale_date', count(*) filter (where e.last_sale_date is not null),
           'with_sale_price', count(*) filter (where e.last_sale_price is not null),
           'pushed_at', max(e.pushed_at))
    into counts from public.equity_inputs e;
  if coalesce(p_counts_only, false) then return jsonb_build_object('counts', counts, 'rows', '[]'::jsonb, 'next_after', null); end if;
  with page as (
    select e.* from public.equity_inputs e
     where (p_after is null or e.lead_id::text > p_after)
       and (p_county is null or e.county = p_county)
       and (p_grade is null or e.equity_grade = p_grade)
     order by e.lead_id limit lim)
  select coalesce(jsonb_agg(to_jsonb(page) order by page.lead_id), '[]'::jsonb), max(page.lead_id::text) into rows, last_id from page;
  return jsonb_build_object('counts', counts, 'rows', rows, 'next_after', case when jsonb_array_length(rows) = lim then last_id else null end);
end $$;
revoke all on function public.agent_equity_inputs(text, integer, text, text, boolean) from public, anon, authenticated;
grant execute on function public.agent_equity_inputs(text, integer, text, text, boolean) to service_role;
