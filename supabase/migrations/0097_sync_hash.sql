-- The laptop's push writes only what changed (2026-10-28, a call Thalia started failed with "canceling statement due to
-- statement timeout"): every 10 minutes the push rewrote all ~5,000 cards and ~28,000 phones in one transaction, and a
-- call started on a card in that minute waited past the 8-second limit for the card. Each pushed row now keeps a
-- fingerprint of what the laptop last sent (sync_hash); the push skips rows whose fingerprint has not changed, and
-- commits cards and phones separately (wpie/live/sync.py push()).
alter table public.leads add column if not exists sync_hash text;
alter table public.contacts add column if not exists sync_hash text;
