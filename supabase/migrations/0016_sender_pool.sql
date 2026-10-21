-- Sender pool (Colin 2026-10-21, after Rick's playbook): openers go out with the Messaging
-- Service only (no From), so Twilio's sticky sender spreads new conversations across
-- +12629996513 and +12624180202. The number Twilio actually used is kept on the row (from the
-- send answer when Twilio gives it, else from the status callback or the reconcile step).

alter table public.planned_openers add column if not exists from_number text;

create or replace function public.record_from(p_sid text, p_from text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare f text := nullif(btrim(coalesce(p_from, '')), '');
begin
  if f is null or coalesce(p_sid, '') = '' then return jsonb_build_object('ok', false); end if;
  update public.planned_openers set from_number = f where provider_sid = p_sid and from_number is distinct from f;
  update public.messages set from_number = f where provider_sid = p_sid and from_number is null;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.record_from(text, text) from public, anon, authenticated;
grant execute on function public.record_from(text, text) to service_role;
