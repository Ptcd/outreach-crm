-- 0206: the assistant's simulator runs and the one-hour tokens that let the laptop trigger them (Colin 2026-11-07:
-- "e2e the development of this and think of all the edge cases possible so we don't have to run 40 tests"), and one
-- edge of the write-back: a real conversation whose extraction failed still reaches the caller as a task with the
-- transcript's tail, instead of being written up as a plain missed call.

create table if not exists public.voice_sim_runs (
  id bigserial primary key,
  persona text not null,
  name text,
  passed boolean not null,
  checks jsonb not null,                 -- [{name, ok, detail}]
  transcript jsonb,
  extraction jsonb,
  seconds integer,
  model text,
  prompt_version text,
  created_at timestamptz not null default now()
);
alter table public.voice_sim_runs enable row level security;
drop policy if exists voice_sim_runs_team_read on public.voice_sim_runs;
create policy voice_sim_runs_team_read on public.voice_sim_runs for select to authenticated using (public.is_team());
grant select on public.voice_sim_runs to authenticated;

create table if not exists public.voice_sim_tokens (
  token text primary key,
  created_at timestamptz not null default now()
);
alter table public.voice_sim_tokens enable row level security;   -- no policies: the service role only

-- a conversation with no extraction (the model's read failed) is still a conversation: the caller gets the task
create or replace function public.voice_agent_talked_no_extraction(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare sid text := p->>'call_sid'; ph text := right(regexp_replace(coalesce(p->>'from', ''), '\D', '', 'g'), 10);
        l public.leads; who public.team_person; tid uuid; tail text;
begin
  if nullif(p->>'lead_id', '') is not null then select * into l from public.leads where id = (p->>'lead_id')::uuid; end if;
  if l.id is null and ph <> '' then
    select l2.* into l from public.contacts c join public.leads l2 on l2.id = c.lead_id
     where c.kind = 'phone' and c.value_normalized = ph order by (l2.locked_to is not null) desc, l2.locked_at desc nulls last limit 1;
  end if;
  who := coalesce(l.locked_to, public.on_shift_person());
  if who not in ('thalia', 'adil') then who := public.on_shift_person(); end if;
  select string_agg(case when t->>'role' = 'agent' then 'assistant: ' else 'seller: ' end || left(t->>'text', 160), E'\n' order by ord)
    into tail from jsonb_array_elements(coalesce(p->'transcript', '[]'::jsonb)) with ordinality as x(t, ord) where ord > greatest(0, jsonb_array_length(coalesce(p->'transcript', '[]'::jsonb)) - 10);
  insert into public.tasks (lead_id, due_at, kind, owner, note, source, source_key, title, phone10)
  values (l.id, now() + interval '30 minutes', 'call', who,
          left('They talked to the assistant but its summary failed; read the thread and call back.' || E'\n' || coalesce(tail, ''), 1500),
          'voice_agent', 'voice:' || sid, 'Call back: they talked to the assistant (read the thread)', nullif(ph, ''))
  on conflict (source_key) do update set due_at = excluded.due_at, note = excluded.note, done_at = null, updated_at = now()
  returning id into tid;
  if l.id is not null then
    insert into public.messages (lead_id, direction, channel, body, from_number, to_number, source_key, status, sent_at)
    values (l.id, 'in', 'call', left('The assistant answered their call; its summary failed. The thread:' || E'\n' || coalesce(tail, ''), 2000), p->>'from', p->>'to', 'voice:' || sid, 'ai_answered', now())
    on conflict (source_key) do nothing;
  end if;
  insert into public.voice_calls (call_sid, lead_id, from10, to_number, ended_at, seconds, transcript, extraction, outcome, task_id, events)
  values (sid, l.id, ph, p->>'to', now(), nullif(p->>'seconds', '')::integer, p->'transcript', null, 'talked_no_extraction', tid, p->'events')
  on conflict (call_sid) do update set lead_id = excluded.lead_id, ended_at = now(), transcript = excluded.transcript, outcome = 'talked_no_extraction', task_id = excluded.task_id, events = excluded.events;
  return jsonb_build_object('ok', true, 'lead_id', l.id, 'outcome', 'talked_no_extraction', 'owner', who::text, 'task_id', tid);
end $$;
revoke all on function public.voice_agent_talked_no_extraction(jsonb) from public, anon, authenticated;
grant execute on function public.voice_agent_talked_no_extraction(jsonb) to service_role;
