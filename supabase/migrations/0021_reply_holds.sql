-- Per-phone hold on automatic replies (2026-10-22, after the false opt-out correction for owner 91999).
-- While a phone is held, nothing is sent to it on its own: a reply that would go out automatically
-- becomes a draft for Colin, and every reply raises a hot alert. A removal request (STOP and the like)
-- is still honoured at once and is final.
create table if not exists public.reply_holds (
  phone10    text primary key check (phone10 ~ '^[0-9]{10}$'),
  reason     text not null,
  created_by text,
  created_at timestamptz not null default now()
);
alter table public.reply_holds enable row level security;
create policy reply_holds_read on public.reply_holds for select to authenticated using (public.is_team());
grant select on public.reply_holds to authenticated;
grant select, insert, update, delete on public.reply_holds to service_role;

create or replace function public.reply_is_held(p_phone10 text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.reply_holds where phone10 = right(regexp_replace(coalesce(p_phone10, ''), '\D', '', 'g'), 10))
$$;
revoke all on function public.reply_is_held(text) from public, anon, authenticated;
grant execute on function public.reply_is_held(text) to service_role;

-- A reply Colin wrote himself, with no inbound text behind it (e.g. the correction after a false
-- opt-out), goes through the same Approve button: its draft has no inbound_sid.
alter table public.reply_drafts alter column inbound_sid drop not null;
