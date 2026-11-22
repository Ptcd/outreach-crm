-- 0276: the rest of Grok's seat. 0275 let a key named Grok post in the room; reading it failed, because the table
-- that remembers how far each one has read (room_seen) and the one that holds a line's files (room_files) each list
-- who may be in the room, and Grok was on neither list. Caught by the test the moment it read.

alter table public.room_seen drop constraint if exists room_seen_who_check;
alter table public.room_seen add constraint room_seen_who_check
  check (who = any (array['desk', 'muse', 'muse 2', 'grok', 'colin', 'thalia', 'adil']));
alter table public.room_files drop constraint if exists room_files_uploaded_by_check;
alter table public.room_files add constraint room_files_uploaded_by_check
  check (uploaded_by = any (array['desk', 'muse', 'muse 2', 'grok', 'colin', 'thalia', 'adil']));
