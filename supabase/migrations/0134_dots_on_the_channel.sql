-- Dots (OpenAI's always-on agent) on the desk channel (Colin 2026-10-29: "Set it up so dots by openai can also
-- communicate"). A new key scope, channel, covers the desk channel tools only (desk_inbox, desk_post, desk_decide).
-- Colin makes a key named "Dots" in Settings > Agent keys with only Channel ticked: it reads and posts in the channel
-- and can touch nothing else (no cards, texts, records or calendar). Dots communicates; decisions stay Muse's while
-- Colin has Muse in charge (desk_decide refuses Dots). Muse's agent key gets the channel scope too.

-- ------------------------------------------------------------------ the channel scope on keys
create or replace function public.agent_scopes_for(p_role text, p_scopes text[]) returns text[] language sql immutable as $$
  select coalesce(p_scopes, case p_role
    when 'intake' then array['prospects', 'marks']
    when 'sender' then array['texting', 'calendar', 'marks']
    when 'records' then array['records']
    else array['prospects', 'texting', 'calendar', 'records', 'marks', 'channel'] end)
$$;

create or replace function public.create_agent_key(p_name text, p_role text, p_scopes text[] default null)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare k text;
begin
  if not public.is_owner() then raise exception 'only Colin can make an agent key'; end if;
  if p_role not in ('intake', 'sender', 'records', 'agent') then raise exception 'role is agent, intake, sender or records'; end if;
  if coalesce(btrim(p_name), '') = '' then raise exception 'give the key a name'; end if;
  if p_scopes is not null and not (p_scopes <@ array['prospects', 'texting', 'calendar', 'records', 'marks', 'channel']) then
    raise exception 'scopes are prospects, texting, calendar, records, marks, channel';
  end if;
  k := 'wpie_' || p_role || '_' || replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  insert into public.agent_keys (name, role, key_sha256, key_hint, created_by, scopes)
  values (btrim(p_name), p_role, encode(sha256(convert_to(k, 'UTF8')), 'hex'), right(k, 4), public.wpie_person()::text,
          case when p_role = 'agent' then coalesce(p_scopes, array['prospects', 'texting', 'calendar', 'records', 'marks', 'channel']) else p_scopes end);
  return k;
end $$;

create or replace function public.set_agent_key_scopes(p_id uuid, p_scopes text[]) returns text[]
language plpgsql security definer set search_path = public as $$
declare out text[];
begin
  if not public.is_owner() then raise exception 'only Colin changes what an agent key may do'; end if;
  if not (coalesce(p_scopes, '{}') <@ array['prospects', 'texting', 'calendar', 'records', 'marks', 'channel']) then
    raise exception 'scopes are prospects, texting, calendar, records, marks, channel';
  end if;
  update public.agent_keys set scopes = coalesce(p_scopes, '{}') where id = p_id returning scopes into out;
  return out;
end $$;

-- Muse's all-scope agent key talks on the channel too
update public.agent_keys set scopes = scopes || array['channel']
 where role = 'agent' and revoked_at is null and scopes is not null and not ('channel' = any(scopes))
   and scopes @> array['prospects', 'texting', 'records'];

-- ------------------------------------------------------------------ Dots as a channel member
alter table public.desk_messages drop constraint if exists desk_messages_author_check;
alter table public.desk_messages add constraint desk_messages_author_check check (author in ('desk', 'muse', 'colin', 'dots'));
alter table public.desk_messages drop constraint if exists desk_messages_for_whom_check;
alter table public.desk_messages add constraint desk_messages_for_whom_check check (for_whom in ('desk', 'muse', 'colin', 'dots', 'all'));

create or replace function public.desk_decide(p_question_id bigint, p_choice text, p_reason text, p_author text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare q public.desk_messages; v bigint; lbl text;
begin
  select * into q from public.desk_messages where id = p_question_id for update;
  if not found or q.kind <> 'question' then return jsonb_build_object('ok', false, 'reason', 'no such question'); end if;
  if q.status <> 'open' then return jsonb_build_object('ok', false, 'reason', 'already ' || q.status || ' (' || coalesce(q.decided_by, '') || ': ' || coalesce(q.choice, '') || ')'); end if;
  if p_author not in ('desk', 'muse', 'colin') then
    return jsonb_build_object('ok', false, 'reason', 'decisions are Muse''s while Colin has Muse in charge (or Colin''s): post your view with desk_post, reply_to the question');
  end if;
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
