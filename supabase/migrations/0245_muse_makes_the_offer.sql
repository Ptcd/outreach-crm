-- 0245: Muse makes the offer by text by itself, on the rule.
--
-- Colin 2026-11-16: "Allow offer sending", then, asked whether he meant one figure or every figure: "Let muse make
-- offers". Since 0223 every figure waited for his tap (his word of Nov 13: "Muse needs to check with me first"), and a
-- seller who asked for a number waited as long as he did.
--
-- What changes: with text_offer_rules.auto_ok on, a figure the RULE worked out is OK'd by the server the moment it is
-- ready, and Muse's next step is to text it. That is the rule's offer (65% of the value fixed up, minus repairs), the
-- seller's own number when it is under that, and a counter up to the most (70%).
--
-- What does not change:
--   * the door still refuses every dollar figure that is not OK'd for that card, so Muse cannot text a figure of its own;
--   * no figure above the most is ever OK'd by the rule;
--   * fewer than three sold comps, a vague condition, a retail ask, a listed house, a sale inside 14 days: no number;
--   * a card Colin passed on, or asked a question about, stays his;
--   * the written offer is Colin's, from the card. Muse never sends one.
-- Colin is told of each figure the rule OK'd (a push and an email), so he can step in from the card.

alter table public.text_offer_rules
  add column if not exists auto_ok     boolean not null default false,   -- the rule's own figure needs no tap
  add column if not exists auto_ok_by  text,
  add column if not exists auto_ok_at  timestamptz,
  add column if not exists auto_ok_why text;
alter table public.text_offers
  add column if not exists ok_by        text,                            -- 'colin' (his tap) or 'rule' (no tap)
  add column if not exists auto_told_at timestamptz;                     -- Colin was told of the rule's OK

-- Who OK'd the figure: the rule (text_offer_auto_ok says so for its own write) or Colin's tap (every other write)
create or replace function public.text_offer_mark_ok_by() returns trigger
language plpgsql as $$
begin
  if new.ok_at is not null and new.ok_at is distinct from old.ok_at then
    new.ok_by := case when current_setting('wpie.offer_by_rule', true) = '1' then 'rule' else 'colin' end;
  end if;
  return new;
end $$;
drop trigger if exists text_offer_mark_ok_by on public.text_offers;
create trigger text_offer_mark_ok_by before update of ok_at on public.text_offers
  for each row execute function public.text_offer_mark_ok_by();

-- OK the figure that is waiting, by the rule. True when it did.
create or replace function public.text_offer_auto_ok(p_id uuid, p_now timestamptz default now()) returns boolean
language plpgsql security definer set search_path = public as $$
declare r public.text_offer_rules; o public.text_offers; v jsonb; n numeric; at_ timestamptz; why text;
begin
  select * into r from public.text_offer_rules where id = 1;
  if not coalesce(r.auto_ok, false) then return false; end if;
  select * into o from public.text_offers where id = p_id for update;
  if not found or o.status <> 'open' then return false; end if;
  if o.asked_at is null or (o.ok_at is not null and o.ok_at >= o.asked_at) then return false; end if;   -- nothing is waiting
  if o.colin_said is not null then return false; end if;                                                -- he passed, or asked: his
  if exists (select 1 from jsonb_array_elements(o.rounds) x where x->>'what' in ('colin_asked', 'pass')) then
    return false;                                                        -- a card he asked about or passed on stays his, answer and all
  end if;
  n := o.ask_number;
  if n is null or n <= 0 or o.mao is null or n > o.mao then return false; end if;                       -- never above the most
  if public.text_offer_comp_count(o.comps) < r.min_comps then return false; end if;
  v := public.text_offer_view(o, p_now);
  if v->>'step' <> 'colin' then return false; end if;                    -- a caller has it, the records stop it, the card is closed
  at_ := greatest(p_now, o.asked_at);
  why := 'by the rule, no tap: ' || case o.ask_kind when 'counter' then 'their counter, inside the most (' || public.text_money(o.mao) || ')'
                                                    when 'their_number' then 'the seller''s own number, under the rule''s offer'
                                                    else 'the rule''s offer' end;
  perform set_config('wpie.offer_by_rule', '1', true);
  update public.text_offers set ok_number = n, ok_at = at_, ok_numbers = array(select distinct unnest(ok_numbers || n)),
         colin_said = 'ok', colin_note = why, colin_at = at_, response = null, response_words = null, response_at = null, counter_number = null,
         late_posted = null, auto_told_at = null,
         rounds = rounds || jsonb_build_object('at', at_, 'what', 'ok', 'by', 'rule', 'asked', o.ask_number, 'number', n, 'kind', o.ask_kind), updated_at = at_
   where id = p_id;
  perform set_config('wpie.offer_by_rule', '', true);
  update public.leads set notes = concat_ws(' | ', notes, to_char(at_ at time zone 'America/Chicago', 'YYYY-MM-DD') || ' the rule OK''d ' || public.text_money(n)
         || ' as the number to text, no tap (Colin 2026-11-16: let Muse make offers)') where id = o.lead_id;
  return true;
end $$;

-- The moment a figure is waiting, the rule answers it (when it is on).
create or replace function public.text_offer_auto_trigger() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'open' and new.asked_at is not null and new.colin_said is null
     and (new.ok_at is null or new.ok_at < new.asked_at) then
    perform public.text_offer_auto_ok(new.id, now());
  end if;
  return null;
end $$;
drop trigger if exists text_offer_auto on public.text_offers;
create trigger text_offer_auto after insert or update of asked_at, ask_number, colin_said, mao, comps on public.text_offers
  for each row execute function public.text_offer_auto_trigger();

-- The switch. On: every figure now waiting is answered by the rule. Off: figures wait for Colin's tap again; what the
-- rule already OK'd stands.
create or replace function public.text_offer_auto_set(p_on boolean, p_by text, p_why text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o record; n integer := 0;
begin
  if coalesce(btrim(p_by), '') = '' or coalesce(btrim(p_why), '') = '' then
    return jsonb_build_object('ok', false, 'reason', 'say who and why: this decides whether a figure reaches a seller without Colin''s tap');
  end if;
  update public.text_offer_rules set auto_ok = coalesce(p_on, false), auto_ok_by = btrim(p_by), auto_ok_at = now(), auto_ok_why = btrim(p_why),
         updated_at = now(), updated_by = btrim(p_by) where id = 1;
  if coalesce(p_on, false) then
    for o in select id from public.text_offers where status = 'open' order by asked_at nulls last loop
      if public.text_offer_auto_ok(o.id, now()) then n := n + 1; end if;
    end loop;
  end if;
  return jsonb_build_object('ok', true, 'auto_ok', coalesce(p_on, false), 'okd_now', n);
end $$;

-- What to push to Colin: from 0223, plus a notice for each figure the rule OK'd by itself.
create or replace function public.text_offer_ping_claim(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public as $$
declare out jsonb := '[]'::jsonb; o public.text_offers; v jsonb; l public.leads;
begin
  if public.in_quiet_hours(p_now) then return out; end if;
  for o in select * from public.text_offers where status = 'open' order by asked_at nulls last for update skip locked loop
    v := public.text_offer_view(o, p_now);
    select * into l from public.leads where id = o.lead_id;
    if o.ok_by = 'rule' and o.ok_at is not null and o.auto_told_at is null then
      update public.text_offers set auto_told_at = p_now where id = o.id;
      out := out || jsonb_build_object('kind', 'auto', 'offer_id', o.id, 'lead_id', o.lead_id, 'address', l.property_address, 'owner_name', l.owner_name,
        'number', o.ok_number, 'ask_kind', o.ask_kind, 'note', o.ask_note, 'arv', o.arv, 'repairs', o.repairs, 'repairs_basis', o.repairs_basis,
        'most', o.mao, 'their_number', o.their_number, 'sold_comps', public.text_offer_comp_count(o.comps));
    elsif v->>'step' = 'colin' and o.colin_pinged_at is null then
      update public.text_offers set colin_pinged_at = p_now where id = o.id;
      out := out || jsonb_build_object('kind', 'ask', 'offer_id', o.id, 'lead_id', o.lead_id, 'address', l.property_address, 'owner_name', l.owner_name,
        'number', o.ask_number, 'ask_kind', o.ask_kind, 'note', o.ask_note, 'arv', o.arv, 'repairs', o.repairs, 'repairs_basis', o.repairs_basis,
        'most', o.mao, 'their_number', o.their_number, 'sold_comps', public.text_offer_comp_count(o.comps));
    elsif v->>'step' = 'colin' and (v->>'late')::boolean and o.colin_reminded_at is null then
      update public.text_offers set colin_reminded_at = p_now where id = o.id;
      out := out || jsonb_build_object('kind', 'reminder', 'offer_id', o.id, 'lead_id', o.lead_id, 'address', l.property_address, 'owner_name', l.owner_name, 'number', o.ask_number);
    elsif v->>'step' = 'written_offer' and o.written_pinged_at is null then
      update public.text_offers set written_pinged_at = p_now where id = o.id;
      out := out || jsonb_build_object('kind', 'written', 'offer_id', o.id, 'lead_id', o.lead_id, 'address', l.property_address, 'owner_name', l.owner_name,
        'number', o.accepted_number, 'signers', o.signers, 'seller_email', o.seller_email);
    end if;
  end loop;
  return out;
end $$;

-- The agent's worklist: from 0223; the line about Colin says which way the switch is.
create or replace function public.agent_offer_worklist(p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public as $$
  with rows as (select public.agent_offer_row(o, p_now) as j from public.text_offers o where o.status = 'open')
  select jsonb_build_object(
    'now', p_now,
    'yours', coalesce((select jsonb_agg(j order by (j->'next'->>'late')::boolean desc, j->'next'->>'due_at') from rows where j->'next'->>'who' = 'muse'), '[]'::jsonb),
    'waiting_on_colin', coalesce((select jsonb_agg(j order by j->'next'->>'due_at') from rows where j->'next'->>'who' = 'colin'), '[]'::jsonb),
    'waiting_on_the_seller', coalesce((select jsonb_agg(j order by j->'next'->>'due_at') from rows where j->'next'->>'who' = 'seller'), '[]'::jsonb),
    'with_a_caller', coalesce((select jsonb_agg(j) from rows where j->'next'->>'who' = 'caller'), '[]'::jsonb),
    'call_tasks_nobody_dialed', public.text_offer_calls_not_dialed(p_now),
    'rule', (select jsonb_build_object('offer', round(r.lao_pct * 100)::text || '% of the after-repair value minus repairs, to the nearest ' || public.text_money(r.round_to),
               'most', round(r.mao_pct * 100)::text || '% of the value minus repairs: a counter above it is not taken',
               'repair_items', r.items, 'repairs_by_the_square_foot', r.per_ft, 'sold_comps_needed', r.min_comps,
               'figures_without_a_tap', coalesce(r.auto_ok, false),
               'colin', case when coalesce(r.auto_ok, false)
                 then 'Colin 2026-11-16: "Let Muse make offers." The server OKs the rule''s own figure by itself (the offer, the seller''s own number under it, a counter up to the most), and your step becomes send_number. You still text only a figure in figures_you_may_text: the door refuses any other, so never work one out yourself. A card Colin passed on or asked about stays his. Colin sends the written offer; you never do.'
                 else 'Every figure is Colin''s to OK before it is texted. The door refuses any other dollar figure. Colin sends the written offer; you never do.' end)
               from public.text_offer_rules r where r.id = 1))
$$;

revoke all on function public.text_offer_auto_ok(uuid, timestamptz), public.text_offer_auto_set(boolean, text, text),
  public.text_offer_auto_trigger(), public.text_offer_mark_ok_by() from public, anon, authenticated;
grant execute on function public.text_offer_auto_ok(uuid, timestamptz), public.text_offer_auto_set(boolean, text, text) to service_role;
