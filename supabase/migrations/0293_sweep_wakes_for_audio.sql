-- 0293: the call-notes sweep (pg_cron job wpie-call-notes-sweep) only woke while a call was mid-notes. Since 0291 it
-- also saves audio, deletes Twilio's copy after the notes are done and archives other recordings after 14 days, so it
-- wakes as well when audio is waiting to be saved or Twilio still holds a saved copy, and once an hour regardless.
do $$ declare c text; begin
  if to_regclass('cron.job') is null then return; end if;      -- no scheduler here (a test database)
  select command into c from cron.job where jobname = 'wpie-call-notes-sweep';
  if c is null then raise notice 'no sweep job'; return; end if;
  if c not like '%audio_saved_at%' then
    c := replace(c, $o$and r.created_at > now() - interval '2 days');$o$,
      $n$and r.created_at > now() - interval '2 days')
         or exists (select 1 from public.call_recordings r where r.twilio_deleted_at is null and coalesce(r.recording_sid, '') <> ''
                      and (r.audio_saved_at is not null or r.created_at > now() - interval '30 days'))
         or extract(minute from now()) < 5;$n$);
    if c not like '%audio_saved_at%' then raise exception 'sweep job text not as expected'; end if;
    perform cron.alter_job((select jobid from cron.job where jobname = 'wpie-call-notes-sweep'), command := c);
  end if;
end $$;
