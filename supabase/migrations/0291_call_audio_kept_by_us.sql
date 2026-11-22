-- 0291: call recordings are kept by us, not by Twilio. Colin 2026-11-22: "Record calls on this program and then store
-- with supa or vercel not with twilio, delete recordings from twilio. I want you to be able to review calls later."
--
--   * A private storage bucket, calls, holds the audio. No login reads it; a person or the desk gets a short-lived link.
--   * call_recordings gains where its audio is (audio_path, audio_bytes, audio_saved_at) and when Twilio's copy was
--     deleted (twilio_deleted_at). The call-notes function saves the audio the moment Twilio says the recording is done,
--     and deletes Twilio's copy once the words are written to the card (or failed for good, or a day has passed).
--     Never before the audio is saved here: a recording is deleted only from a row with a saved file.
--   * twilio_recordings_archive: every other recording on the account (voicemails, tests) is copied here and then
--     deleted from Twilio after 14 days. Voicemail links already texted or emailed stop working then; the audio stays.
--   * call_review: the calls as the desk reads them back: who, when, how long, the notes, the words, where the audio is.

do $$ begin
  if exists (select 1 from information_schema.tables where table_schema = 'storage' and table_name = 'buckets') then
    insert into storage.buckets (id, name, public, file_size_limit) values ('calls', 'calls', false, 104857600)
    on conflict (id) do nothing;
  end if;
end $$;

alter table public.call_recordings add column if not exists audio_path text;
alter table public.call_recordings add column if not exists audio_bytes integer;
alter table public.call_recordings add column if not exists audio_saved_at timestamptz;
alter table public.call_recordings add column if not exists twilio_deleted_at timestamptz;

create table if not exists public.twilio_recordings_archive (
  recording_sid  text primary key,
  call_sid       text,
  duration_s     integer,
  recorded_at    timestamptz,
  audio_path     text,
  audio_bytes    integer,
  saved_at       timestamptz,
  deleted_at     timestamptz,
  error          text,
  created_at     timestamptz not null default now()
);
alter table public.twilio_recordings_archive enable row level security;

create or replace function public.call_audio_saved(p_call_sid text, p_path text, p_bytes integer) returns jsonb
language plpgsql security definer set search_path = public as $fn$
begin
  if coalesce(p_bytes, 0) <= 0 or coalesce(btrim(p_path), '') = '' then return jsonb_build_object('ok', false, 'reason', 'no audio'); end if;
  update public.call_recordings set audio_path = p_path, audio_bytes = p_bytes, audio_saved_at = now(), updated_at = now()
   where call_sid = p_call_sid;
  return jsonb_build_object('ok', found);
end $fn$;

create or replace function public.call_twilio_deleted(p_call_sid text) returns jsonb
language plpgsql security definer set search_path = public as $fn$
begin
  update public.call_recordings set twilio_deleted_at = now() where call_sid = p_call_sid and audio_saved_at is not null;
  return jsonb_build_object('ok', found);
end $fn$;

-- what the sweep has to do with audio: save what is not saved yet; delete Twilio's copy of what is saved and finished
create or replace function public.call_audio_due(p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public as $fn$
  select jsonb_build_object(
    'save', coalesce((select jsonb_agg(jsonb_build_object('call_sid', r.call_sid, 'recording_sid', r.recording_sid, 'started_at', r.started_at, 'created_at', r.created_at))
                        from (select * from public.call_recordings r
                               where r.audio_saved_at is null and r.twilio_deleted_at is null and coalesce(r.recording_sid, '') <> ''
                                 and r.created_at < p_now - interval '1 minute' and r.created_at > p_now - interval '30 days'
                               order by r.created_at limit 10) r), '[]'::jsonb),
    'purge', coalesce((select jsonb_agg(jsonb_build_object('call_sid', r.call_sid, 'recording_sid', r.recording_sid))
                         from (select * from public.call_recordings r
                                where r.audio_saved_at is not null and r.twilio_deleted_at is null
                                  and (r.status in ('summarized', 'failed', 'too_short', 'no_card') or r.created_at < p_now - interval '1 day')
                                order by r.created_at limit 20) r), '[]'::jsonb))
$fn$;

create or replace function public.twilio_archive_saved(p_recording_sid text, p_call_sid text, p_duration integer, p_recorded_at timestamptz,
  p_path text, p_bytes integer) returns jsonb
language plpgsql security definer set search_path = public as $fn$
begin
  if coalesce(p_bytes, 0) <= 0 then return jsonb_build_object('ok', false, 'reason', 'no audio'); end if;
  insert into public.twilio_recordings_archive (recording_sid, call_sid, duration_s, recorded_at, audio_path, audio_bytes, saved_at)
  values (p_recording_sid, p_call_sid, p_duration, p_recorded_at, p_path, p_bytes, now())
  on conflict (recording_sid) do update set audio_path = excluded.audio_path, audio_bytes = excluded.audio_bytes, saved_at = now(), error = null;
  return jsonb_build_object('ok', true);
end $fn$;

create or replace function public.twilio_archive_deleted(p_recording_sid text) returns jsonb
language plpgsql security definer set search_path = public as $fn$
begin
  update public.twilio_recordings_archive set deleted_at = now() where recording_sid = p_recording_sid and saved_at is not null;
  return jsonb_build_object('ok', found);
end $fn$;

-- a recording the call-notes path already owns is not archived twice
create or replace function public.twilio_archive_known(p_recording_sids jsonb) returns jsonb
language sql stable security definer set search_path = public as $fn$
  select coalesce(jsonb_agg(s), '[]'::jsonb) from jsonb_array_elements_text(coalesce(p_recording_sids, '[]'::jsonb)) s
   where exists (select 1 from public.call_recordings r where r.recording_sid = s)
      or exists (select 1 from public.twilio_recordings_archive a where a.recording_sid = s and a.deleted_at is not null)
$fn$;

do $$ declare f text; begin
  foreach f in array array['call_audio_saved(text,text,integer)', 'call_twilio_deleted(text)', 'call_audio_due(timestamptz)',
    'twilio_archive_saved(text,text,integer,timestamptz,text,integer)', 'twilio_archive_deleted(text)', 'twilio_archive_known(jsonb)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;

-- the calls, as the desk reads them back (no login reads it: service role only)
create or replace view public.call_review as
  select r.call_sid, r.started_at, r.direction, r.caller, r.duration_s, r.status, r.lead_id,
         l.owner_name, l.property_address, l.municipality, r.audio_path, r.audio_bytes, r.twilio_deleted_at,
         (select t.words from public.call_transcripts t where t.call_sid = r.call_sid limit 1) as words,
         (select jsonb_build_object('summary', n.summary, 'outcome', n.outcome, 'next_step', n.next_step, 'quote', n.quote, 'pillars', n.pillars, 'facts', n.facts)
            from public.call_notes n where n.call_sid = r.call_sid order by n.created_at desc limit 1) as notes
    from public.call_recordings r left join public.leads l on l.id = r.lead_id;
revoke all on public.call_review from public, anon, authenticated;
grant select on public.call_review to service_role;
