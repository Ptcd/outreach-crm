-- 0205: the assistant's own event log per call (Colin 2026-11-07: "Ran a test and it died and stopped replying").
-- There is no log command for the function, so it writes what happened on the socket here: setup, each prompt and
-- interrupt, each model turn's start, end or error, the timers, the close. Read it on the call's row in voice_calls.
alter table public.voice_calls add column if not exists events jsonb;
