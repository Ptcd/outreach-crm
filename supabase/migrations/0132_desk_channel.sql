-- The desk channel: the laptop verification desk (Claude) and Muse talk inside WPIE, and Muse decides for the
-- campaign (Colin 2026-10-29: "Build a comms channel for you and muse inside wpie and let it make these decisions
-- as if it were in charge of the campaign").
--
-- * desk_messages: notes, reports, questions and decisions between the desk, Muse and Colin. A question carries its
--   options; Muse answers it with desk_decide and the answer is the decision of record (who, when, why).
-- * campaign_delegation: one row, Colin's standing grant. While muse_in_charge is on, Muse is the reviewer for records
--   letters that waited on Colin (first requests included): it releases them through records_release_batch. Nothing
--   sends without a review. What stays Colin's is listed in colin_only; money, fee-route, Colin-name and first DA/AG
--   letters are refused to Muse in code.
-- Colin turns it off with: update campaign_delegation set muse_in_charge = false where id = 1;

create table if not exists public.desk_messages (
  id          bigserial primary key,
  at          timestamptz not null default now(),
  author      text not null check (author in ('desk', 'muse', 'colin')),
  for_whom    text not null default 'muse' check (for_whom in ('desk', 'muse', 'colin', 'all')),
  kind        text not null check (kind in ('note', 'report', 'question', 'decision')),
  topic       text,
  body        text not null check (length(body) <= 12000),
  options     jsonb,                         -- a question: [{"id": "send", "label": "..."}, ...]
  reply_to    bigint references public.desk_messages(id),
  status      text not null default 'open' check (status in ('open', 'answered', 'closed')),
  choice      text,                          -- a decision: the option id chosen
  decided_by  text
);
create index if not exists desk_messages_open on public.desk_messages (for_whom, status, id);
alter table public.desk_messages enable row level security;
drop policy if exists desk_messages_read on public.desk_messages;
create policy desk_messages_read on public.desk_messages for select to authenticated using (public.is_team());

create table if not exists public.campaign_delegation (
  id             integer primary key default 1 check (id = 1),
  muse_in_charge boolean not null default false,
  granted_by     text,
  granted_at     timestamptz,
  grant_words    text,
  colin_only     text[] not null default '{}'
);
alter table public.campaign_delegation enable row level security;
drop policy if exists campaign_delegation_read on public.campaign_delegation;
create policy campaign_delegation_read on public.campaign_delegation for select to authenticated using (public.is_team());

insert into public.campaign_delegation (id, muse_in_charge, granted_by, granted_at, grant_words, colin_only)
values (1, true, 'colin', now(),
  'Build a comms channel for you and muse inside wpie and let it make these decisions as if it were in charge of the campaign (Colin, chat, 2026-10-29)',
  array[
    'money: any fee, payment, deposit, purchase, subscription or invoice (records letters that mention money stay Colin''s in code)',
    'prices: no offer, price or number to a seller; Colin prices deals himself at the house',
    'walk it / pass on a package',
    'spend: buying numbers, raising the daily text cap, paid skip traces, vendors',
    'accounts and credentials: creating accounts, logging in, CAPTCHA solving (never done by the desk)',
    'the first DA / Attorney General enforcement letter in a county',
    'STOP / DNC: never overridden',
    'automated WCCA reads (Colin: Muse''s fleet supervises them; the desk does not run them)',
    'deleting records or data'])
on conflict (id) do update set muse_in_charge = excluded.muse_in_charge, granted_by = excluded.granted_by, granted_at = excluded.granted_at,
  grant_words = excluded.grant_words, colin_only = excluded.colin_only;

create or replace function public.muse_in_charge() returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select muse_in_charge from public.campaign_delegation where id = 1), false)
$$;

create or replace function public.desk_post(p_author text, p_for text, p_kind text, p_topic text, p_body text, p_options jsonb default null,
  p_reply_to bigint default null) returns jsonb language plpgsql security definer set search_path = public as $$
declare v bigint;
begin
  if coalesce(btrim(p_body), '') = '' then return jsonb_build_object('ok', false, 'reason', 'a message needs words'); end if;
  if p_kind = 'decision' then return jsonb_build_object('ok', false, 'reason', 'a decision is made with desk_decide on a question'); end if;
  if p_kind = 'question' and (p_options is null or jsonb_typeof(p_options) <> 'array' or jsonb_array_length(p_options) < 2) then
    return jsonb_build_object('ok', false, 'reason', 'a question needs at least two options: [{"id": "...", "label": "..."}]');
  end if;
  if p_reply_to is not null and not exists (select 1 from public.desk_messages where id = p_reply_to) then
    return jsonb_build_object('ok', false, 'reason', 'no such message to reply to');
  end if;
  insert into public.desk_messages (author, for_whom, kind, topic, body, options, reply_to)
  values (p_author, coalesce(nullif(p_for, ''), case when p_author = 'desk' then 'muse' else 'desk' end), p_kind, nullif(btrim(p_topic), ''),
          left(p_body, 12000), p_options, p_reply_to)
  returning id into v;
  if p_reply_to is not null and p_kind in ('note', 'report') then
    update public.desk_messages set status = 'answered' where id = p_reply_to and kind <> 'question' and status = 'open';
  end if;
  return jsonb_build_object('ok', true, 'id', v);
end $$;

create or replace function public.desk_decide(p_question_id bigint, p_choice text, p_reason text, p_author text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare q public.desk_messages; v bigint; lbl text;
begin
  select * into q from public.desk_messages where id = p_question_id for update;
  if not found or q.kind <> 'question' then return jsonb_build_object('ok', false, 'reason', 'no such question'); end if;
  if q.status <> 'open' then return jsonb_build_object('ok', false, 'reason', 'already ' || q.status || ' (' || coalesce(q.decided_by, '') || ': ' || coalesce(q.choice, '') || ')'); end if;
  if p_author = 'muse' and not public.muse_in_charge() then
    return jsonb_build_object('ok', false, 'reason', 'Colin has not put Muse in charge: this question waits for him');
  end if;
  select o->>'label' into lbl from jsonb_array_elements(q.options) o where o->>'id' = p_choice;
  if lbl is null then return jsonb_build_object('ok', false, 'reason', 'choice is one of: ' ||
    (select string_agg(o->>'id', ', ') from jsonb_array_elements(q.options) o)); end if;
  if coalesce(btrim(p_reason), '') = '' then return jsonb_build_object('ok', false, 'reason', 'say why (reason)'); end if;
  insert into public.desk_messages (author, for_whom, kind, topic, body, reply_to, status, choice, decided_by)
  values (p_author, 'all', 'decision', q.topic, format('Decision on #%s: %s. %s', q.id, lbl, btrim(p_reason)), q.id, 'closed', p_choice,
          case when p_author = 'muse' then 'Muse (in charge, Colin''s delegation)' else p_author end)
  returning id into v;
  update public.desk_messages set status = 'answered', choice = p_choice,
         decided_by = case when p_author = 'muse' then 'Muse (in charge, Colin''s delegation)' else p_author end where id = q.id;
  return jsonb_build_object('ok', true, 'decision_id', v, 'question', q.id, 'choice', p_choice);
end $$;

create or replace function public.desk_read(p_for text, p_since bigint default 0, p_open_only boolean default false, p_limit integer default 50)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'in_charge', (select to_jsonb(d) - 'id' from public.campaign_delegation d where d.id = 1),
    'open_questions', (select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'at', m.at, 'from', m.author, 'topic', m.topic, 'body', m.body, 'options', m.options) order by m.id), '[]')
                         from public.desk_messages m where m.kind = 'question' and m.status = 'open' and m.for_whom in (p_for, 'all')),
    'messages', (select coalesce(jsonb_agg(x order by (x->>'id')::bigint), '[]') from (
        select jsonb_build_object('id', m.id, 'at', m.at, 'from', m.author, 'for', m.for_whom, 'kind', m.kind, 'topic', m.topic, 'body', m.body,
                                  'options', m.options, 'reply_to', m.reply_to, 'status', m.status, 'choice', m.choice, 'decided_by', m.decided_by) as x
          from public.desk_messages m
         where m.id > coalesce(p_since, 0) and (m.for_whom in (p_for, 'all') or m.author = p_for)
           and (not coalesce(p_open_only, false) or m.status = 'open')
         order by m.id desc limit greatest(1, least(coalesce(p_limit, 50), 200))) t))
$$;

-- Muse in charge is the reviewer for letters that waited on Colin: records_muse_decide (the door's
-- records_release_batch) may release a first request or any other letter whose only blocker was Colin's approval.
-- Nothing sends on its own: records_draft_standing (what goes out with no review) is unchanged. Money, a fee-route
-- letter, a letter naming Colin and the first DA/AG letter in a county stay Colin's.
create or replace function public.records_muse_may_release(p_draft_id uuid) returns text
language sql stable security definer set search_path = public as $$
  select case
    when st is null then null
    when st like 'ramp:%' then null
    when not public.muse_in_charge() then st
    when d.purpose = 'fee' then 'a fee-route letter (it talks about a charge): Colin approves it'
    when st like 'mentions money%' or st like 'records letters are signed%' or st like 'the first DA%' or st = 'no such draft' then st
    else null end
    from (select public.records_draft_standing(p_draft_id) as st) x
    left join public.records_drafts d on d.id = p_draft_id
$$;

create or replace function public.records_muse_decide(p_batch_id uuid, p_approve boolean, p_drop uuid[], p_note text, p_agent text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare n integer := 0; bad text;
begin
  if not exists (select 1 from public.records_batches where id = p_batch_id and status = 'proposed') then
    return jsonb_build_object('ok', false, 'reason', 'that batch is not waiting');
  end if;
  select string_agg(public.records_muse_may_release(d.id), '; ') into bad from public.records_drafts d
   where d.batch_id = p_batch_id and d.status = 'in_batch' and not (d.id = any(coalesce(p_drop, '{}')))
     and public.records_muse_may_release(d.id) is not null;
  if p_approve and bad is not null then
    return jsonb_build_object('ok', false, 'reason', 'only Colin approves these: ' || bad || ' (drop them with drop[] to release the rest)');
  end if;
  if coalesce(array_length(p_drop, 1), 0) > 0 then
    update public.records_drafts set status = 'draft', batch_id = null where batch_id = p_batch_id and id = any(p_drop);
    insert into public.records_log (author, for_whom, note) values (coalesce(p_agent, 'muse'), 'records_agent',
      format('returned %s letter(s) from batch %s: %s', array_length(p_drop, 1), left(p_batch_id::text, 8), coalesce(p_note, 'see the drafts')));
  end if;
  if p_approve then
    update public.records_drafts set status = 'approved' where batch_id = p_batch_id and status = 'in_batch';
    get diagnostics n = row_count;
    update public.records_batches set status = case when n > 0 then 'approved' else 'rejected' end, decided_at = now(),
           decided_by = case when public.muse_in_charge() then 'Muse (in charge, Colin''s delegation)' else 'Muse (ramp review)' end
                        || coalesce(': ' || nullif(btrim(p_note), ''), '') where id = p_batch_id;
  else
    update public.records_drafts set status = 'draft', batch_id = null where batch_id = p_batch_id and status = 'in_batch';
    update public.records_batches set status = 'rejected', decided_at = now(), decided_by = 'Muse' where id = p_batch_id;
    insert into public.records_log (author, for_whom, note) values (coalesce(p_agent, 'muse'), 'records_agent',
      format('returned batch %s: %s', left(p_batch_id::text, 8), coalesce(p_note, 'see the drafts')));
  end if;
  return jsonb_build_object('ok', true, 'released', n);
end $$;

revoke all on function public.desk_post(text, text, text, text, text, jsonb, bigint), public.desk_decide(bigint, text, text, text),
  public.desk_read(text, bigint, boolean, integer) from public, anon, authenticated;
grant execute on function public.desk_post(text, text, text, text, text, jsonb, bigint), public.desk_decide(bigint, text, text, text),
  public.desk_read(text, bigint, boolean, integer) to service_role;
grant execute on function public.muse_in_charge() to authenticated, service_role;
revoke all on function public.records_muse_may_release(uuid) from public, anon, authenticated;
grant execute on function public.records_muse_may_release(uuid) to service_role;
