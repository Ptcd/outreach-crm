-- 0254: a card under contract says what is next in the closing, not "Not on a ladder yet".
--
-- 0253 takes a signed card off the belt. card_brief then read "Not on a ladder yet: your next step puts it on one",
-- and showed Colin's closing task as "Your other Nov 19: ..." to everyone who opened the card. Now "What happens next"
-- on a card under contract is one line from the closing track: to Colin the price, the closing day and the next step
-- due; to a caller only that it is under contract and that the selling has stopped (the track is Colin's).

create or replace function public.closing_plain(p_lead_id uuid) returns text
language sql stable security definer set search_path = public as $fn$
  select coalesce((
    select case when public.is_owner() then
             'Under contract' || coalesce(' at $' || to_char(d.price, 'FM999,999,999'), '') || coalesce(', closing ' || to_char(d.closing_on, 'FMMon FMDD'), '') || '. '
             || coalesce('Next: ' || s.label || coalesce(', by ' || to_char(s.due_on, 'Dy FMMon FMDD'), '') || '.',
                         case when exists (select 1 from public.closing_steps x where x.deal_id = d.id) then 'Every closing step is done.' else '' end)
           else 'Under contract' || coalesce(', closing ' || to_char(d.closing_on, 'FMMon FMDD'), '') || '. Colin has it from here: no more calls or texts to sell.' end
      from public.deals d
      left join lateral (select cs.label, cs.due_on from public.closing_steps cs
                          where cs.deal_id = d.id and cs.done_at is null and not cs.skipped order by cs.due_on nulls last, cs.sort limit 1) s on true
     where d.lead_id = p_lead_id order by d.created_at desc limit 1), 'Under contract.')
$fn$;
revoke all on function public.closing_plain(uuid) from public, anon;
grant execute on function public.closing_plain(uuid) to authenticated, service_role;

CREATE OR REPLACE FUNCTION public.card_brief(p_lead_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
declare l public.leads; me team_person; res jsonb;
begin
  perform public.card_guard(p_lead_id);   -- 0250: a card is its caller's
  if not public.is_team() then raise exception 'team only'; end if;
  me := public.wpie_person();
  select * into l from public.leads where id = p_lead_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card'); end if;
  select jsonb_build_object(
    'ok', true,
    'lane', l.lane,
    'say_next', l.say_next,
    -- 0254: a card under contract is off the belt; what is next is the closing track's next step
    'next_plain', case when l.stage = 'under_contract' then public.closing_plain(l.id)
                       when l.stage = 'closed_won' then 'Closed. Nothing more to do on this card.'
                       else public.next_plain(l.belt, l.next_stop_at, l.next_stop_who, l.next_stop_say, l.named_date, l.named_event, me,
                     (select tm.display_name from public.team_members tm where tm.person = public.card_caller(l.id))) end,
    'mine_next', (select jsonb_build_object('task_id', t.id, 'due_at', t.due_at, 'kind', t.kind, 'note', t.note, 'owner', t.owner, 'source', t.source)
                    from public.tasks t where t.lead_id = l.id and t.done_at is null and t.kind in ('call', 'callback', 'visit', 'text', 'other')
                     and coalesce(t.source, '') <> 'closing'   -- 0254: the closing step is said once, in next_plain
                   order by t.due_at nulls last limit 1),
    'why', jsonb_build_object(
       'reasons', l.reasons_to_sell,
       'motivation', (select lm.lines from public.lead_motivation lm where lm.lead_id = l.id),
       'last_words', (select left(mi.body, 240) from public.messages mi where mi.lead_id = l.id and mi.direction = 'in' and mi.channel = 'sms' order by mi.sent_at desc limit 1),
       'last_call', (select left(regexp_replace(coalesce(lc.body, ''), '^Call \([^)]*\) from \d+:\s*', ''), 240) from public.messages lc
                       where lc.lead_id = l.id and lc.channel = 'call' and lc.status is distinct from 'inbound_missed' order by lc.sent_at desc limit 1),
       'promise', (select pm.note from public.tasks pm where pm.lead_id = l.id and pm.source = 'mine' and pm.done_at is null order by pm.due_at limit 1)),
    'touches', (select coalesce(jsonb_agg(x order by x.at desc), '[]'::jsonb) from (
                  select m.sent_at at, m.channel, m.direction, coalesce(m.status, '') status, left(m.body, 140) body
                    from public.messages m where m.lead_id = l.id and m.channel in ('call', 'sms', 'note') order by m.sent_at desc limit 3) x),
    'touches_total', (select count(*) from public.messages m where m.lead_id = l.id and m.channel in ('call', 'sms')),
    'planned', (select coalesce(jsonb_agg(y order by y.at), '[]'::jsonb) from (
                  select t.due_at at, t.kind what, coalesce(t.title, t.note) words, t.owner::text who from public.tasks t
                   where t.lead_id = l.id and t.done_at is null and t.due_at is not null and t.kind <> 'nudge'
                  union all
                  select l.next_stop_at, 'belt', l.next_stop_say, l.next_stop_who where l.next_stop_at is not null and l.next_stop_at > now()
                  order by 1 limit 2) y),
    'rest', case when l.parked_at is not null then jsonb_build_object('until', l.rest_until, 'why', l.parked_why, 'by_colin', l.rest_until is null) end,
    'nudges', (select coalesce(jsonb_agg(jsonb_build_object('task_id', n.id, 'from', n.title, 'text', n.note, 'at', n.created_at, 'to', n.owner) order by n.created_at desc), '[]'::jsonb)
                 from public.tasks n where n.lead_id = l.id and n.kind = 'nudge' and n.done_at is null),
    'locked_to', l.locked_to, 'belt', l.belt, 'stage', l.stage)
  into res;
  return res;
end $fn$;
