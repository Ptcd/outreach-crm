-- Call notes (Colin 2026-10-26: calls kept going unlogged; "take the notes for them"; the Muse texting agent has to know
-- what was said on the phone). A seller call through the app (the card's Call button, or a seller calling a seller line)
-- is recorded by Twilio after a disclosure line (pm-phone, behind CALL_RECORDING), transcribed by Twilio Voice
-- Intelligence and summarized by Claude (the call-notes Edge Function). What lands on the card:
--   * a call entry (messages, channel 'call', status 'call_notes' / 'inbound_call_notes'): the summary, the 4 pillars
--     (why selling, condition, timeline, their number and where it came from) plus who signs, the outcome and the next
--     step with its date. It is a note, not an outcome: the belt does not move on it.
--   * the card's call_facts, in the call script's own keys and choice ids. A key is written only when the card has no
--     answer for it, or the answer it has is from before this call: whatever the caller tapped during the call wins.
--   * a suggested mark (hot, not now with a date, held, dead, no answer, reached, wrong number, do not contact) that the
--     caller confirms in one tap on the card (call_note_confirm): the confirm logs the call through log_call, exactly
--     like "Save the call", so the belt moves the way it always does. A call already logged by hand is not logged twice.
-- The transcript itself (call_transcripts) is team only: never in agent_card, never in a call entry, never logged.
-- agent_card gets call_notes: the summary, pillars, outcome and next step of each recorded call.

create table if not exists public.call_recordings (
  call_sid        text primary key check (call_sid ~ '^CA[0-9A-Fa-f]{32}$'),   -- the parent call (the app's leg, or the caller's)
  recording_sid   text unique check (recording_sid ~ '^RE[0-9A-Fa-f]{32}$'),
  lead_id         uuid references public.leads (id) on delete cascade,
  direction       text not null check (direction in ('out', 'in')),
  phone10         text,
  caller          text,                                                     -- who was on our side, when known
  duration_s      integer,
  started_at      timestamptz,
  status          text not null default 'recorded'
                  check (status in ('recorded', 'too_short', 'no_card', 'transcribing', 'summarizing', 'summarized', 'failed')),
  transcript_sid  text unique,
  attempts        integer not null default 0,
  claimed_at      timestamptz,
  error           text,
  message_id      uuid references public.messages (id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index if not exists call_recordings_lead_idx on public.call_recordings (lead_id, created_at desc);
create index if not exists call_recordings_open_idx on public.call_recordings (updated_at) where status in ('recorded', 'transcribing', 'summarizing');

-- The words. Team only (the card's "show the transcript"); nothing else reads this table.
create table if not exists public.call_transcripts (
  call_sid    text primary key references public.call_recordings (call_sid) on delete cascade,
  lead_id     uuid references public.leads (id) on delete cascade,
  words       text not null,
  created_at  timestamptz not null default now()
);

create table if not exists public.call_notes (
  id               uuid primary key default gen_random_uuid(),
  call_sid         text not null unique references public.call_recordings (call_sid) on delete cascade,
  lead_id          uuid not null references public.leads (id) on delete cascade,
  direction        text not null,
  caller           text,
  started_at       timestamptz,
  duration_s       integer,
  summary          text not null,
  pillars          jsonb not null default '{}'::jsonb,    -- motivation, condition, timeline, price, signers: short lines
  facts            jsonb not null default '{}'::jsonb,    -- call_facts values in the call script's keys
  outcome          text,
  next_step        text,
  next_step_at     timestamptz,
  next_step_kind   text check (next_step_kind in ('walk', 'callback', 'text', 'other')),
  suggested_mark   text check (suggested_mark in ('hot', 'not_now', 'held', 'dead', 'no_answer', 'reached', 'wrong_number', 'dnc')),
  suggested_until  timestamptz,
  suggested_reason text,
  quote            text,
  facts_written    text[] not null default '{}',
  logged_before    text,                                  -- the outcome already logged by hand for this call, if any
  confirmed_at     timestamptz,
  confirmed_by     text,
  confirmed_mark   text,
  model            text,
  message_id       uuid references public.messages (id) on delete set null,
  created_at       timestamptz not null default now()
);
create index if not exists call_notes_lead_idx on public.call_notes (lead_id, created_at desc);

alter table public.call_recordings enable row level security;
alter table public.call_transcripts enable row level security;
alter table public.call_notes enable row level security;
create policy call_recordings_team_read on public.call_recordings for select to authenticated using (public.is_team());
create policy call_transcripts_team_read on public.call_transcripts for select to authenticated using (public.is_team());
create policy call_notes_team_read on public.call_notes for select to authenticated using (public.is_team());
revoke all on public.call_recordings, public.call_transcripts, public.call_notes from public, anon;
grant select on public.call_recordings, public.call_transcripts, public.call_notes to authenticated;
grant all on public.call_recordings, public.call_transcripts, public.call_notes to service_role;

-- The call outcomes log_call writes (the belt's hook). An entry with one of these since the call started means the
-- call was already logged by hand.
create or replace function public.call_outcome_since(p_lead_id uuid, p_since timestamptz)
returns text language sql stable security definer set search_path = public as $$
  select m.status from public.messages m
   where m.lead_id = p_lead_id and m.channel = 'call' and m.sent_at >= p_since
     and m.status in ('interested', 'not_now', 'not_interested', 'wrong_number', 'dnc', 'no_answer', 'reached_no_decision')
   order by m.sent_at desc limit 1
$$;

-- Twilio says a recording is ready. Which card it belongs to: an app call by the claim pm-phone made when it placed it
-- (human_call_provider_claims), a call to a seller line by the inbound_calls row the phone line wrote, else the caller's
-- phone on a card. Safe to repeat (Twilio retries): one row per call.
create or replace function public.call_recording_ready(p_call_sid text, p_recording_sid text, p_direction text,
  p_duration integer, p_started_at timestamptz, p_caller text, p_from text, p_to text, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.call_recordings; lid uuid; d text; who text; min_s constant integer := 15;
begin
  if coalesce(p_call_sid, '') !~ '^CA[0-9A-Fa-f]{32}$' then return jsonb_build_object('ok', false, 'reason', 'bad call id'); end if;
  if coalesce(p_recording_sid, '') !~ '^RE[0-9A-Fa-f]{32}$' then return jsonb_build_object('ok', false, 'reason', 'bad recording id'); end if;
  if p_direction not in ('out', 'in') then return jsonb_build_object('ok', false, 'reason', 'bad direction'); end if;
  select * into r from public.call_recordings where call_sid = p_call_sid for update;
  if found then
    return jsonb_build_object('ok', true, 'duplicate', true, 'lead_id', r.lead_id, 'status', r.status,
                              'transcribe', r.status = 'recorded' and r.transcript_sid is null);
  end if;

  if p_direction = 'out' then
    select c.lead_id, c.phone10 into lid, d from public.human_call_provider_claims c where c.provider_call_sid = p_call_sid;
    d := coalesce(d, right(regexp_replace(coalesce(p_to, ''), '\D', '', 'g'), 10));
    who := nullif(regexp_replace(coalesce(p_caller, ''), '^client:', ''), '');
  else
    d := right(regexp_replace(coalesce(p_from, ''), '\D', '', 'g'), 10);
    select ic.lead_id into lid from public.inbound_calls ic where ic.call_sid = p_call_sid;
    if lid is null and d ~ '^[0-9]{10}$' then
      select c.lead_id into lid from public.contacts c join public.leads x on x.id = c.lead_id
       where c.kind = 'phone' and c.value_normalized = d
       order by (x.belt in ('dead', 'dnc') or x.stage in ('dead', 'dnc', 'closed_no_contact')) asc, x.updated_at desc limit 1;
    end if;
    who := null;
  end if;
  -- the team member's name, when the identity is one of ours
  who := coalesce((select t.display_name from public.team_members t where t.person::text = who), who);

  insert into public.call_recordings (call_sid, recording_sid, lead_id, direction, phone10, caller, duration_s, started_at, status,
                                      created_at, updated_at)
  values (p_call_sid, p_recording_sid, lid, p_direction, case when d ~ '^[0-9]{10}$' then d end, who, p_duration,
          coalesce(p_started_at, p_now - make_interval(secs => greatest(coalesce(p_duration, 0), 0))),
          case when lid is null then 'no_card' when coalesce(p_duration, 0) < min_s then 'too_short' else 'recorded' end, p_now, p_now)
  returning * into r;
  return jsonb_build_object('ok', true, 'lead_id', r.lead_id, 'status', r.status, 'transcribe', r.status = 'recorded');
end $$;

create or replace function public.call_recording_transcribing(p_call_sid text, p_transcript_sid text, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  update public.call_recordings set transcript_sid = p_transcript_sid, status = 'transcribing', error = null, updated_at = p_now
   where call_sid = p_call_sid and status in ('recorded', 'failed');
  return jsonb_build_object('ok', found);
end $$;

-- A step failed. p_retry: leave it for the sweep (5 tries in all), else it stays failed. p_new_transcript: the transcript
-- itself failed at Twilio, so the sweep asks for a new one.
create or replace function public.call_recording_failed(p_call_sid text, p_error text, p_retry boolean default true,
  p_new_transcript boolean default false, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.call_recordings;
begin
  update public.call_recordings
     set status = case when not p_retry or attempts >= 4 then 'failed'
                       when transcript_sid is null or p_new_transcript then 'recorded' else 'transcribing' end,
         transcript_sid = case when p_new_transcript then null else transcript_sid end,
         attempts = attempts + 1,
         claimed_at = null, error = left(coalesce(p_error, 'failed'), 300), updated_at = p_now
   where call_sid = p_call_sid and status not in ('summarized', 'too_short', 'no_card')
  returning * into r;
  return jsonb_build_object('ok', r.call_sid is not null, 'status', r.status);
end $$;

-- Take a transcribed call to summarize it (the transcript webhook and the sweep can both arrive): one taker at a time,
-- a stale take (5 minutes) can be taken again. Returns what the summarizer needs to know about the card.
create or replace function public.call_recording_claim(p_call_sid text, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.call_recordings; l public.leads;
begin
  update public.call_recordings set status = 'summarizing', claimed_at = p_now, updated_at = p_now
   where call_sid = p_call_sid and transcript_sid is not null
     and (status = 'transcribing' or (status = 'summarizing' and claimed_at < p_now - interval '5 minutes'))
  returning * into r;
  if r.call_sid is null then return jsonb_build_object('ok', false, 'reason', 'not waiting to be summarized'); end if;
  select * into l from public.leads where id = r.lead_id;
  return jsonb_build_object('ok', true, 'call_sid', r.call_sid, 'transcript_sid', r.transcript_sid, 'lead_id', r.lead_id,
    'direction', r.direction, 'phone10', r.phone10, 'caller', r.caller, 'duration_s', r.duration_s, 'started_at', r.started_at,
    'owner_name', l.owner_name, 'address', l.property_address, 'city', l.municipality, 'mailing_state', l.mailing_state,
    'stage', l.stage, 'elderly_or_ill', l.elderly_or_ill, 'grief', l.grief, 'call_facts', l.call_facts);
end $$;

-- The keys call notes may write into call_facts: the call script's answers (src/lib/callScript.ts). next_step is not one
-- of them (a booking is the caller's to make, or the one-tap confirm's); last_call is log_call's.
create or replace function public.call_note_fact_keys() returns text[] language sql immutable as $$
  select array['owner', 'identity', 'motivation', 'condition', 'occupancy', 'work_list', 'happened', 'timeline',
               'decision_makers', 'price', 'anchor', 'flexibility', 'debt', 'behind', 'ready']
$$;

-- The summary is in: keep the words (team only), the notes, the call entry on the card, and the call_facts the card
-- does not already have from this call.
create or replace function public.call_notes_save(p_call_sid text, p_words text, p_notes jsonb, p_body text, p_model text,
  p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.call_recordings; l public.leads; nid uuid; mid uuid; k text; v jsonb; cur jsonb; written text[] := '{}';
  since timestamptz; logged text; mark text; until_at timestamptz; ns_at timestamptz; ns_kind text;
begin
  select * into r from public.call_recordings where call_sid = p_call_sid for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such call'); end if;
  if r.status = 'summarized' then
    return jsonb_build_object('ok', true, 'duplicate', true, 'note_id', (select id from public.call_notes where call_sid = p_call_sid));
  end if;
  if r.lead_id is null then return jsonb_build_object('ok', false, 'reason', 'call is on no card'); end if;
  if coalesce(btrim(p_notes->>'summary'), '') = '' then return jsonb_build_object('ok', false, 'reason', 'no summary'); end if;
  select * into l from public.leads where id = r.lead_id for update;
  since := coalesce(r.started_at, r.created_at);
  logged := public.call_outcome_since(r.lead_id, since);

  mark := nullif(p_notes->>'suggested_mark', '');
  if mark is not null and mark not in ('hot', 'not_now', 'held', 'dead', 'no_answer', 'reached', 'wrong_number', 'dnc') then mark := null; end if;
  begin until_at := nullif(p_notes->>'suggested_until', '')::timestamptz; exception when others then until_at := null; end;
  begin ns_at := nullif(p_notes->>'next_step_at', '')::timestamptz; exception when others then ns_at := null; end;
  ns_kind := nullif(p_notes->>'next_step_kind', '');
  if ns_kind is not null and ns_kind not in ('walk', 'callback', 'text', 'other') then ns_kind := 'other'; end if;

  insert into public.call_transcripts (call_sid, lead_id, words, created_at)
  values (p_call_sid, r.lead_id, coalesce(p_words, ''), p_now)
  on conflict (call_sid) do update set words = excluded.words;

  -- call_facts: only keys the call script knows, only objects, never over an answer given during or after this call
  for k, v in select e.key, e.value from jsonb_each(coalesce(p_notes->'facts', '{}'::jsonb)) e loop
    continue when not (k = any(public.call_note_fact_keys())) or jsonb_typeof(v) <> 'object';
    cur := l.call_facts->k;
    if cur is null or coalesce(nullif(cur->>'at', '')::timestamptz, '-infinity'::timestamptz) < since then
      l.call_facts := jsonb_set(l.call_facts, array[k], jsonb_build_object('value', v, 'at', p_now, 'by', 'Call notes'));
      written := array_append(written, k);
    end if;
  end loop;
  if array_length(written, 1) > 0 then
    update public.leads set call_facts = l.call_facts where id = r.lead_id;
  end if;

  insert into public.messages (lead_id, direction, channel, body, from_number, to_number, source_key, status, sent_at, seen_at, created_by)
  values (r.lead_id, 'in', 'call', left(coalesce(p_body, p_notes->>'summary'), 4000),
          case when r.phone10 is not null and r.direction = 'in' then '+1' || r.phone10 end,
          case when r.phone10 is not null and r.direction = 'out' then '+1' || r.phone10 end,
          'cnote:' || p_call_sid, case when r.direction = 'in' then 'inbound_call_notes' else 'call_notes' end,
          coalesce(r.started_at, p_now), p_now, null)
  on conflict (source_key) do nothing
  returning id into mid;

  insert into public.call_notes (call_sid, lead_id, direction, caller, started_at, duration_s, summary, pillars, facts, outcome,
                                 next_step, next_step_at, next_step_kind, suggested_mark, suggested_until, suggested_reason, quote,
                                 facts_written, logged_before, model, message_id, created_at)
  values (p_call_sid, r.lead_id, r.direction, r.caller, r.started_at, r.duration_s, left(p_notes->>'summary', 1500),
          coalesce(p_notes->'pillars', '{}'::jsonb), coalesce(p_notes->'facts', '{}'::jsonb), nullif(left(btrim(coalesce(p_notes->>'outcome', '')), 300), ''),
          nullif(left(btrim(coalesce(p_notes->>'next_step', '')), 300), ''), ns_at, ns_kind, mark, until_at,
          nullif(left(btrim(coalesce(p_notes->>'suggested_reason', '')), 300), ''),
          left(nullif(p_notes->>'quote', ''), 120), written, logged, p_model, mid, p_now)
  on conflict (call_sid) do nothing
  returning id into nid;

  update public.call_recordings set status = 'summarized', message_id = mid, error = null, updated_at = p_now where call_sid = p_call_sid;
  return jsonb_build_object('ok', true, 'note_id', nid, 'message_id', mid, 'facts_written', to_jsonb(written), 'logged_before', logged);
end $$;

-- What the sweep (pg_cron, every 5 minutes, through the call-notes function) picks up: a recording whose transcript was
-- never asked for, a transcript whose webhook never came, a summary that stalled.
create or replace function public.call_recordings_due(p_now timestamptz default now())
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('call_sid', r.call_sid, 'recording_sid', r.recording_sid, 'status', r.status,
                                               'transcript_sid', r.transcript_sid, 'direction', r.direction) order by r.updated_at), '[]'::jsonb)
    from (select * from public.call_recordings r
           where r.attempts < 5 and r.created_at > p_now - interval '2 days'
             and ((r.status = 'recorded' and r.updated_at < p_now - interval '2 minutes')
               or (r.status = 'transcribing' and r.updated_at < p_now - interval '3 minutes')
               or (r.status = 'summarizing' and r.claimed_at < p_now - interval '5 minutes'))
           order by r.updated_at limit 20) r
$$;

-- The caller's one tap: confirm (or change) the suggested mark. It logs the call through log_call, the same as "Save the
-- call", so the belt, the hot alert and the follow-ups all move the way they always do.
create or replace function public.call_note_confirm(p_note_id uuid, p_mark text, p_until timestamptz default null,
  p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare n public.call_notes; r public.call_recordings; who text; res jsonb; logged text; why text; outcome text; extra jsonb;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  select * into n from public.call_notes where id = p_note_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such call note'); end if;
  if n.confirmed_at is not null then return jsonb_build_object('ok', false, 'reason', 'already confirmed: ' || n.confirmed_mark); end if;
  select * into r from public.call_recordings where call_sid = n.call_sid;
  logged := public.call_outcome_since(n.lead_id, coalesce(n.started_at, n.created_at));
  if logged is not null then
    update public.call_notes set confirmed_at = now(), confirmed_mark = 'logged:' || logged where id = p_note_id;
    return jsonb_build_object('ok', false, 'reason', 'this call is already logged (' || replace(logged, '_', ' ') || ')');
  end if;
  if p_mark not in ('hot', 'not_now', 'held', 'dead', 'no_answer', 'reached', 'wrong_number', 'dnc') then
    return jsonb_build_object('ok', false, 'reason', 'pick a mark');
  end if;
  why := coalesce(nullif(btrim(coalesce(p_reason, '')), ''), n.suggested_reason);
  if p_mark = 'held' and why is null then return jsonb_build_object('ok', false, 'reason', 'a hold needs what they are waiting on'); end if;
  select display_name into who from public.team_members where lower(email) = lower(auth.jwt() ->> 'email');
  outcome := case p_mark when 'hot' then 'interested' when 'not_now' then 'not_now' when 'dead' then 'not_interested'
                         when 'no_answer' then 'no_answer' when 'wrong_number' then 'wrong_number' when 'dnc' then 'dnc'
                         else 'reached_no_decision' end;
  res := public.log_call(n.lead_id, r.phone10, outcome,
           'From the call notes: ' || left(n.summary, 400) || coalesce(E'\n' || why, ''),
           case when p_mark = 'not_now' then p_until end);
  if not coalesce((res->>'ok')::boolean, false) then return res; end if;

  if p_mark = 'hot' then
    update public.leads set hot_at = coalesce(hot_at, now()) where id = n.lead_id;
    -- a call-back or walk-through they agreed to on the phone is booked with the same tap
    if n.next_step_kind in ('walk', 'callback') and n.next_step_at > now() then
      extra := public.call_answer(n.lead_id, 'next_step', jsonb_build_object('kind', n.next_step_kind, 'at', n.next_step_at,
                 'choices', jsonb_build_array(n.next_step_kind), 'when', n.next_step_at));
    end if;
  elsif p_mark = 'not_now' and p_until is null and why is not null then
    update public.leads set named_event = left(why, 200) where id = n.lead_id;
  elsif p_mark = 'held' then
    update public.leads set named_event = left(why, 200), next_action = 'Waiting on: ' || left(why, 120) where id = n.lead_id;
    extra := public.belt_event(n.lead_id, 'move', jsonb_strip_nulls(jsonb_build_object('belt', 'hold_not_now', 'reason', why,
               'named_date', p_until)), coalesce(who, 'team'), now());
  end if;

  update public.call_notes set confirmed_at = now(), confirmed_by = who, confirmed_mark = p_mark where id = p_note_id;
  return jsonb_build_object('ok', true, 'mark', p_mark, 'outcome', outcome, 'logged', res, 'extra', extra);
end $$;

revoke all on function public.call_outcome_since(uuid, timestamptz),
  public.call_recording_ready(text, text, text, integer, timestamptz, text, text, text, timestamptz),
  public.call_recording_transcribing(text, text, timestamptz), public.call_recording_failed(text, text, boolean, boolean, timestamptz),
  public.call_recording_claim(text, timestamptz), public.call_notes_save(text, text, jsonb, text, text, timestamptz),
  public.call_recordings_due(timestamptz), public.call_note_confirm(uuid, text, timestamptz, text)
  from public, anon, authenticated;
grant execute on function public.call_outcome_since(uuid, timestamptz),
  public.call_recording_ready(text, text, text, integer, timestamptz, text, text, text, timestamptz),
  public.call_recording_transcribing(text, text, timestamptz), public.call_recording_failed(text, text, boolean, boolean, timestamptz),
  public.call_recording_claim(text, timestamptz), public.call_notes_save(text, text, jsonb, text, text, timestamptz),
  public.call_recordings_due(timestamptz) to service_role;
grant execute on function public.call_note_confirm(uuid, text, timestamptz, text) to authenticated;

-- What the texting agent sees of a call: the notes, never the words.
create or replace function public.card_call_notes(p_lead uuid) returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('at', coalesce(n.started_at, n.created_at), 'direction', n.direction,
           'who', coalesce(n.caller, 'the team'), 'minutes', round(coalesce(n.duration_s, 0) / 60.0, 1), 'summary', n.summary,
           'pillars', n.pillars, 'outcome', n.outcome, 'next_step', n.next_step, 'next_step_at', n.next_step_at,
           'suggested_mark', n.suggested_mark, 'confirmed_mark', n.confirmed_mark) order by coalesce(n.started_at, n.created_at)), '[]'::jsonb)
    from public.call_notes n where n.lead_id = p_lead
$$;
revoke all on function public.card_call_notes(uuid) from public, anon, authenticated;
grant execute on function public.card_call_notes(uuid) to service_role;

-- agent_card (0066) plus call_notes.
create or replace function public.agent_card(p_lead uuid) returns jsonb language sql stable security definer set search_path = public as $$
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
    'phones', (select jsonb_agg(jsonb_build_object('phone', c.value_normalized, 'type', c.line_type, 'name', c.person_name,
                      'textable', c.status = 'ok' and not c.dnc_app and not c.suppressed and not c.dnc_vendor and c.dnc_scrub <> 'dnc'
                                  and public.agent_phone_ok(c.value_normalized, c.line_type),
                      'also_on', (select jsonb_agg(jsonb_build_object('lead_id', c2.lead_id, 'owner_name', l2.owner_name, 'address', l2.property_address))
                                    from public.contacts c2 join public.leads l2 on l2.id = c2.lead_id
                                   where c2.value_normalized = c.value_normalized and c2.lead_id <> l.id)))
                 from public.contacts c where c.lead_id = l.id and c.kind = 'phone'),
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
$$;
revoke all on function public.agent_card(uuid) from public, anon, authenticated;
grant execute on function public.agent_card(uuid) to service_role;

-- The sweep: every 5 minutes, the call-notes function picks up anything a lost webhook left behind (same shared secret as
-- the conveyor). Skipped where pg_cron, pg_net or the secret are absent (the local test database).
do $do$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron')
     and exists (select 1 from pg_extension where extname = 'pg_net')
     and to_regclass('vault.decrypted_secrets') is not null then
    if exists (select 1 from cron.job where jobname = 'wpie-call-notes-sweep') then perform cron.unschedule('wpie-call-notes-sweep'); end if;
    perform cron.schedule(
      'wpie-call-notes-sweep',
      '*/5 * * * *',
      $job$
      select net.http_post(
        url := 'https://jyfetargyaaxcqmxdgft.supabase.co/functions/v1/call-notes?event=sweep',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'x-wpie-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'send_openers_cron_secret')),
        body := '{}'::jsonb,
        timeout_milliseconds := 55000)
      where exists (select 1 from public.call_recordings r where r.status in ('recorded', 'transcribing', 'summarizing')
                      and r.created_at > now() - interval '2 days');
      $job$);
  end if;
end $do$;
