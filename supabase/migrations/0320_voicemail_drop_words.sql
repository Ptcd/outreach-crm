-- 0320: the recorded voicemail's words, as Colin wants them.
--
-- Colin 2026-11-24, on the first wording ("this is a recorded message from Thalia, with Colin Merrill's team. I had a
-- quick question about ..."): "Skip the recorded message line and Colin Merrills team, just thalia calling to see if
-- they'd be interested in selling that address". The callback number stays, once: without it nobody can call back from
-- a voicemail, and it is the one thing the rules for a recorded message still ask of this wording.

alter table public.voicemail_drop_rules alter column words set default
  '{hi} this is {caller}. I''m calling to see if you''d be interested in selling {place}. You can call or text me back at {number}. Thanks.';
update public.voicemail_drop_rules
   set words = '{hi} this is {caller}. I''m calling to see if you''d be interested in selling {place}. You can call or text me back at {number}. Thanks.',
       updated_at = now()
 where id = 1;
