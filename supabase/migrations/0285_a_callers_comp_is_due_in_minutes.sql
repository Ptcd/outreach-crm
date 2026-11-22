-- 0285: a comp a caller asked for from the card is due in 30 minutes, any day. Found walking the flow as Tyler on a
-- Sunday (2026-11-22): the brief was due in 30 minutes but the comp carried the text-offer clock (text_offer_due),
-- which pushes a Sunday to Monday 10 AM, so the card would not have shown late until the next morning.
create or replace function public.card_work_due() returns trigger language plpgsql as $fn$
begin
  if new.trigger = 'caller_asked' then
    new.comp_due_at := least(coalesce(new.comp_due_at, now() + interval '30 minutes'), now() + interval '30 minutes');
  end if;
  return new;
end $fn$;
drop trigger if exists card_work_due on public.text_offers;
create trigger card_work_due before insert on public.text_offers for each row execute function public.card_work_due();
