-- 0292: Colin can listen to a call from the card (0291 keeps the audio in the private calls bucket). Only the owner
-- login gets a path and may read the bucket; a caller does not, and nobody reads it without a short-lived signed link.
create or replace function public.call_audio_path(p_call_sid text) returns text
language plpgsql stable security definer set search_path = public as $fn$
begin
  if not public.is_owner() then raise exception 'only Colin listens to calls'; end if;
  return (select r.audio_path from public.call_recordings r where r.call_sid = p_call_sid and r.audio_saved_at is not null);
end $fn$;
revoke all on function public.call_audio_path(text) from public, anon;
grant execute on function public.call_audio_path(text) to authenticated, service_role;

do $$ begin
  if exists (select 1 from information_schema.tables where table_schema = 'storage' and table_name = 'objects') then
    drop policy if exists calls_owner_reads on storage.objects;
    create policy calls_owner_reads on storage.objects for select to authenticated using (bucket_id = 'calls' and public.is_owner());
  end if;
end $$;
